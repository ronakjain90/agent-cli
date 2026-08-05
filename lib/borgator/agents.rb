# frozen_string_literal: true

require 'json'

require_relative 'tools'

# Manager -> worker multi-agent orchestration.
#
# The top-level agent runs as a *manager*: it has the normal file/shell tools
# plus a `delegate` tool that hands a focused, self-contained subtask to a fresh
# *worker* agent. The worker runs its own tool-use loop (on the same provider)
# and reports a summary back to the manager as the tool result. Workers may
# delegate further, up to MAX_DEPTH, forming a manager -> worker tree.
module Agents
  # manager is depth 0; workers are depth >= 1. A worker may itself delegate
  # only while its depth is below MAX_DEPTH, which bounds the recursion.
  MAX_DEPTH = 2

  # Context-window budget; past it, the oldest tool results are compacted away.
  MAX_CONTEXT_TOKENS = 60_000

  # Cap on the size of a worker's report to the manager. A chatty worker
  # can otherwise blow the manager's context budget.
  WORKER_REPORT_MAX_BYTES = 8_000

  # Rough heuristic: ~4 characters per token.
  CHARS_PER_TOKEN = 4

  # Cap on workers running at once within a single delegation batch, so a
  # manager that fans out many subtasks doesn't open unbounded connections.
  MAX_PARALLEL = 6

  DELEGATE_TOOL_NAME = 'delegate'

  MANAGER_SYSTEM = <<~TXT
    You are the manager agent — an orchestrator working in the user's current directory.
    You have the normal file and shell tools, plus a `delegate` tool that hands a focused,
    self-contained subtask to a fresh worker agent with its own tools.

    How to work:
    - For small or quick tasks, just use the tools yourself. To change an existing file, use
      `edit_file` with an exact snippet — reserve `write_file` for creating new files.
    - Prefer `search_code` over grepping via `run_command`. Prefer `git_status` / `git_diff`
      over shell git for read-only repo state. After edits, prefer `diagnostics` (when a
      linter exists) before or alongside focused `run_tests`.
    - Emit independent tool calls together in ONE response — they run in parallel. Split them
      across responses only when a later call needs an earlier one's result.
    - For larger tasks, split the work into independent subtasks and `delegate` each one.
      A worker does NOT see this conversation, so its brief must be complete on its own:
      say exactly what to do, which files/paths are involved, and what to report back.
    - Good things to delegate: scoped investigation ("find where X is handled and summarize it"),
      and well-bounded edits ("update file Y to do Z").
    - To run subtasks IN PARALLEL, emit multiple `delegate` calls in a single response — those
      workers then execute concurrently. Only parallelize subtasks that are independent (e.g. do
      not have two workers edit the same file at once).
    - After workers report back, integrate their results, reconcile any conflicts, and give
      the user one concise final answer.
    - After changing code, verify it with the `run_tests` tool (it auto-detects the project's
      test runner) rather than assuming the change works.
    - Keep prose brief; let the tools and workers do the work.
  TXT

  WORKER_SYSTEM = <<~TXT
    You are a worker agent working in the user's current directory. You have been given ONE
    focused subtask by your manager. Use the tools to inspect and modify files and run commands.
    Prefer reading before writing. To change an existing file, use `edit_file` with an exact
    snippet copied verbatim from the file — do NOT rewrite the whole file with `write_file`.
    Prefer `search_code` over shell grep, and `git_status`/`git_diff`/`diagnostics` over
    reinventing those via `run_command`.

    Rules:
    - Stay strictly within your assigned subtask — do not expand the scope.
    - Emit independent tool calls together in ONE response — they run in parallel. Split them
      across responses only when a later call needs an earlier one's result.
    - After changing code, verify it with the `run_tests` tool before reporting back.
    - When finished, end with a short report: what you changed or found, the key file paths,
      and anything the manager must know. That report is the ONLY thing the manager receives,
      so make it self-contained.
  TXT

  DELEGATE_TOOL = {
    name: DELEGATE_TOOL_NAME,
    description:
      'Hand a focused, self-contained subtask to a fresh worker agent that has its own ' \
      'file and shell tools. The worker cannot see this conversation, so include every ' \
      "detail it needs. Returns the worker's final report.",
    input_schema: {
      type: 'object',
      properties: {
        title: {
          type: 'string',
          description: 'Short label for the subtask (a few words), shown in the UI.'
        },
        task: {
          type: 'string',
          description:
            'Complete, self-contained instructions for the worker: what to do, the ' \
            'relevant files/paths, and exactly what it should report back.'
        }
      },
      required: ['task']
    }
  }.freeze

  # Project context file, loaded into the manager's system prompt at the start
  # of a session so the model knows the repo conventions up front.
  AGENTS_FILE = 'AGENTS.md'

  module_function

  # Base tools every agent gets, plus `delegate` while below the depth cap.
  def tools_for(depth)
    tools = Tools.definitions.dup
    tools << DELEGATE_TOOL if depth < MAX_DEPTH
    tools
  end

  # System prompt for a given depth. The manager (depth 0) additionally gets the
  # project's AGENTS.md appended, so session context travels with every turn.
  def system_for(depth)
    return WORKER_SYSTEM unless depth.zero?

    [MANAGER_SYSTEM, agents_context].compact.join("\n")
  end

  def step_limit_event(depth)
    who = depth.zero? ? 'turn' : 'worker'
    {
      kind: :error,
      depth: depth,
      text: "step limit reached — this #{who} used all #{MAX_STEPS} tool-loop steps and stopped " \
            'before answering. Send a follow-up (e.g. "continue") to keep going.'
    }
  end

  COMPACTED_PLACEHOLDER = '[earlier tool result omitted — re-run the tool for full output]'

  SUPERSEDED_PLACEHOLDER = '[superseded — the same call was made again later; see the newer result]'

  # Snapshots of on-disk state, where a later call supersedes an earlier one.
  # Excludes run_command / run_tests: a run before a fix and one after it are
  # both meaningful.
  IDEMPOTENT_READ_TOOLS = %w[
    read_file list_files search_code git_status git_diff diagnostics
  ].freeze

  def estimate_tokens(messages)
    messages.sum { |msg| message_chars(msg) } / CHARS_PER_TOKEN
  end

  # Handles string content and OpenAI ("text") / Anthropic ("content") parts.
  def message_chars(msg)
    content = msg['content']
    return 0 unless content
    return content.length unless content.is_a?(Array)

    content.sum do |part|
      next part.to_s.length unless part.is_a?(Hash)

      (part['text'] || part['content'] || part).to_s.length
    end
  end

  # Either wire format: OpenAI's "tool" role, or Anthropic's tool_result parts.
  def tool_result?(msg)
    return true if msg['role'] == 'tool'
    return false unless msg['role'] == 'user' && msg['content'].is_a?(Array)

    msg['content'].any? { |part| part.is_a?(Hash) && part['type'] == 'tool_result' }
  end

  def compacted_message(msg)
    return msg.merge('content' => COMPACTED_PLACEHOLDER) if msg['role'] == 'tool'

    msg.merge('content' => msg['content'].map do |part|
      next part unless part.is_a?(Hash) && part['type'] == 'tool_result'

      part.merge('content' => COMPACTED_PLACEHOLDER)
    end)
  end

  # Normalized so the same call still matches when the model spelled its
  # arguments differently the second time.
  def call_signature(name, args)
    parsed = args.is_a?(String) ? JSON.parse(args) : args
    parsed = parsed.sort.to_h if parsed.is_a?(Hash)
    "#{name}:#{JSON.generate(parsed)}"
  rescue JSON::ParserError, JSON::GeneratorError
    "#{name}:#{args}"
  end

  # tool_call_id => signature, for idempotent read tools only.
  def read_call_signatures(messages)
    messages.each_with_object({}) do |msg, sigs|
      next unless msg['role'] == 'assistant'

      Array(msg['tool_calls']).each do |tc|
        fn = tc['function'] || {}
        next unless IDEMPOTENT_READ_TOOLS.include?(fn['name'])

        sigs[tc['id']] = call_signature(fn['name'], fn['arguments'])
      end

      next unless msg['content'].is_a?(Array)

      msg['content'].each do |block|
        next unless block.is_a?(Hash) && block['type'] == 'tool_use'
        next unless IDEMPOTENT_READ_TOOLS.include?(block['name'])

        sigs[block['id']] = call_signature(block['name'], block['input'])
      end
    end
  end

  # Every trimming pass a provider should run between tool-use steps. Returns
  # the same array it was given — the live conversation the UI reads.
  def trim_messages(messages)
    compact_messages(dedupe_stale_results(messages))
  end

  # Keeps only the newest result per repeated read — the earlier ones describe
  # state that no longer holds. Runs every step, unlike compact_messages, which
  # waits for the budget.
  def dedupe_stale_results(messages)
    sigs = read_call_signatures(messages)
    return messages if sigs.empty?

    # Newest-first, so the first sighting of a signature is the copy we keep.
    seen = {}
    messages.each_index.reverse_each do |i|
      next unless tool_result?(messages[i])

      messages[i] = superseded_message(messages[i], sigs, seen)
    end

    messages
  end

  def superseded_message(msg, sigs, seen)
    if msg['role'] == 'tool'
      sig = sigs[msg['tool_call_id']]
      return msg unless sig
      return msg.merge('content' => SUPERSEDED_PLACEHOLDER) if seen[sig]

      seen[sig] = true
      return msg
    end

    changed = false
    parts = msg['content'].map do |part|
      next part unless part.is_a?(Hash) && part['type'] == 'tool_result'

      sig = sigs[part['tool_use_id']]
      next part unless sig

      if seen[sig]
        changed = true
        part.merge('content' => SUPERSEDED_PLACEHOLDER)
      else
        seen[sig] = true
        part
      end
    end

    changed ? msg.merge('content' => parts) : msg
  end

  # Trims oldest tool results in place — the caller's array is the live
  # conversation the UI reads, so it must stay the same object.
  def compact_messages(messages)
    budget = MAX_CONTEXT_TOKENS * CHARS_PER_TOKEN
    remaining = messages.sum { |msg| message_chars(msg) }
    return messages if remaining <= budget

    messages.each_index do |i|
      break if remaining <= budget
      next unless tool_result?(messages[i])

      before = message_chars(messages[i])
      messages[i] = compacted_message(messages[i])
      remaining -= before - message_chars(messages[i])
    end

    messages
  end

  # AGENTS.md wrapped for the system prompt, or nil when the file is absent or
  # empty. Read fresh each turn so edits to the file take effect immediately.
  def agents_context
    return nil unless File.file?(AGENTS_FILE)

    content = File.read(AGENTS_FILE).strip
    return nil if content.empty?

    <<~TXT
      Project context from #{AGENTS_FILE} (follow these conventions):

      #{content}
    TXT
  rescue SystemCallError
    nil
  end
end

# Mixed into providers that drive their own tool-use loop (Anthropic + OpenAI
# family). Provides delegation: dispatching the `delegate` tool to a nested
# worker agent. Each host provider must implement:
#
#   agent_run(messages, events, system:, tools:, depth:) -> final assistant text
#
module Delegation
  # Optional dedicated provider instance (its own model, and possibly its own
  # provider/API key) that runs worker agents. When nil, workers reuse the
  # manager's provider/model.
  attr_accessor :worker_provider

  # Provider instance that should run worker turns.
  def worker_runner
    worker_provider || self
  end

  # Route a tool call: `delegate` spawns a worker; everything else is a normal
  # tool. Returns [summary_for_ui, result_for_model] or a 3-tuple with a diff —
  # the same shape as Tools.call.
  def dispatch_tool(name, input, events, depth)
    if name == Agents::DELEGATE_TOOL_NAME
      run_worker(input || {}, events, depth)
    else
      Tools.call(name, input || {})
    end
  end

  # Run one call, short-circuiting calls whose arguments failed to parse so the
  # model gets an actionable error (and the tool never runs with empty input).
  def run_call(call, events, depth)
    if (err = call[:parse_error])
      return [
        "#{call[:name]}: invalid arguments",
        "Error: could not parse the JSON arguments for #{call[:name]} (#{err}). " \
        'Re-issue the call with valid JSON — make sure every string is properly ' \
        'escaped (quotes, newlines, backslashes).'
      ]
    end
    dispatch_tool(call[:name], call[:input], events, depth)
  end

  # Execute one assistant turn's tool calls and return per-call results in the
  # original order as [{ id:, result: }, ...]. Every call runs concurrently,
  # MAX_PARALLEL at a time; Tools locks the paths and the shell so overlapping
  # calls can't corrupt each other.
  def run_tool_batch(calls, events, depth)
    calls.each { |c| events << { kind: :tool, text: announce_text(c), depth: depth } }

    outcomes = Array.new(calls.length)
    calls.each_index.each_slice(Agents::MAX_PARALLEL) do |slice|
      threads = slice.map do |i|
        Thread.new do
          outcomes[i] = run_call_safely(calls[i], events, depth)
          emit_tool_event(events, outcomes[i], depth)
        end
      end

      begin
        threads.each(&:join)
      ensure
        threads.each(&:kill)
      end
    end

    calls.each_index.map { |i| result_for(calls[i], outcomes[i]) }
  end

  # Truncates a worker's report to WORKER_REPORT_MAX_BYTES on a whole-line
  # boundary, appending a hint when the cap was hit so the manager knows the
  # output was trimmed for context budget reasons.
  def truncate_worker_report(report)
    max = Agents::WORKER_REPORT_MAX_BYTES
    return report if report.bytesize <= max

    hint = "… (truncated — full output capped at #{max} bytes)"
    cutoff = max - hint.bytesize
    return hint if cutoff <= 0

    truncated = report[0, cutoff]
    # Trim on a whole-line boundary: cut back to the last newline so we don't
    # leave a half-finished line fragment.
    last_nl = truncated.rindex("\n")
    truncated = truncated[0, last_nl] if last_nl

    "#{truncated}#{hint}"
  end

  private

  # A raised exception would otherwise surface at `join` and abort the whole
  # batch, losing the other calls' results.
  def run_call_safely(call, events, depth)
    run_call(call, events, depth)
  rescue StandardError => e
    ["error in #{call[:name]}: #{e.message}", "Error: #{e.class}: #{e.message}"]
  end

  # UI text announcing a tool call. Parse-failed calls have no usable input.
  def announce_text(call)
    return "#{call[:name]} (unparseable arguments)" if call[:parse_error]

    "#{call[:name]} #{JSON.generate(call[:input])}"
  end

  def emit_tool_event(events, outcome, depth)
    summary, _result, diff = outcome
    event = { kind: :tool_result, text: summary, depth: depth }
    event[:diff] = diff if diff
    events << event
  end

  def result_for(call, outcome)
    _summary, result, _diff = outcome
    result = 'Error: tool call did not complete.' if outcome.nil?
    { id: call[:id], result: result.to_s }
  end

  # Spawn a worker agent for one subtask and return its report to the manager.
  def run_worker(input, events, depth)
    child = depth + 1
    task  = input['task'].to_s.strip
    title = input['title'].to_s.strip
    title = task.split("\n").first.to_s[0, 60] if title.empty?

    return ['delegate: missing task', "Error: delegate requires a 'task' description."] if task.empty?
    if depth >= Agents::MAX_DEPTH
      return ["delegate refused (depth #{depth})",
              'Delegation depth limit reached — complete this subtask yourself.']
    end

    runner = worker_runner
    events << { kind: :worker_start, text: title, depth: child }
    messages = [{ 'role' => 'user', 'content' => task }]
    report =
      begin
        runner.agent_run(
          messages, events,
          system: Agents::WORKER_SYSTEM,
          tools: Agents.tools_for(child),
          depth: child
        ).to_s.strip
      rescue StandardError => e
        events << { kind: :error, text: "worker failed: #{e.class}: #{e.message}", depth: child }
        "Worker failed: #{e.class}: #{e.message}"
      end
    report = '(worker finished without a written summary)' if report.empty?
    report = truncate_worker_report(report)
    events << { kind: :worker_done, text: title, depth: child }

    ["delegated → #{title}", report]
  end
end
