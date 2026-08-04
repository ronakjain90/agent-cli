# frozen_string_literal: true

require_relative "tools"

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

  # Cap on workers running at once within a single delegation batch, so a
  # manager that fans out many subtasks doesn't open unbounded connections.
  MAX_PARALLEL = 6

  DELEGATE_TOOL_NAME = "delegate"

  MANAGER_SYSTEM = <<~TXT
    You are the manager agent — an orchestrator working in the user's current directory.
    You have the normal file and shell tools, plus a `delegate` tool that hands a focused,
    self-contained subtask to a fresh worker agent with its own tools.

    How to work:
    - For small or quick tasks, just use the tools yourself. To change an existing file, use
      `edit_file` with an exact snippet — reserve `write_file` for creating new files.
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

    Rules:
    - Stay strictly within your assigned subtask — do not expand the scope.
    - After changing code, verify it with the `run_tests` tool before reporting back.
    - When finished, end with a short report: what you changed or found, the key file paths,
      and anything the manager must know. That report is the ONLY thing the manager receives,
      so make it self-contained.
  TXT

  DELEGATE_TOOL = {
    name: DELEGATE_TOOL_NAME,
    description:
      "Hand a focused, self-contained subtask to a fresh worker agent that has its own " \
      "file and shell tools. The worker cannot see this conversation, so include every " \
      "detail it needs. Returns the worker's final report.",
    input_schema: {
      type: "object",
      properties: {
        title: {
          type: "string",
          description: "Short label for the subtask (a few words), shown in the UI."
        },
        task: {
          type: "string",
          description:
            "Complete, self-contained instructions for the worker: what to do, the " \
            "relevant files/paths, and exactly what it should report back."
        }
      },
      required: ["task"]
    }
  }.freeze

  # Project context file, loaded into the manager's system prompt at the start
  # of a session so the model knows the repo conventions up front.
  AGENTS_FILE = "AGENTS.md"

  module_function

  # Base tools every agent gets, plus `delegate` while below the depth cap.
  def tools_for(depth)
    tools = Tools::DEFINITIONS.dup
    tools << DELEGATE_TOOL if depth < MAX_DEPTH
    tools
  end

  # System prompt for a given depth. The manager (depth 0) additionally gets the
  # project's AGENTS.md appended, so session context travels with every turn.
  def system_for(depth)
    return WORKER_SYSTEM unless depth.zero?

    [MANAGER_SYSTEM, agents_context].compact.join("\n")
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
        "Re-issue the call with valid JSON — make sure every string is properly " \
        "escaped (quotes, newlines, backslashes)."
      ]
    end
    dispatch_tool(call[:name], call[:input], events, depth)
  end

  # Execute one assistant turn's tool calls and return per-call results in the
  # original order as [{ id:, result: }, ...]. When a turn contains two or more
  # `delegate` calls, those workers run concurrently (capped at MAX_PARALLEL);
  # a single delegate or plain tools run inline, preserving prior behavior.
  #
  # `calls` is an ordered array of { id:, name:, input: }.
  def run_tool_batch(calls, events, depth)
    delegate_positions = (0...calls.length).select do |i|
      calls[i][:name] == Agents::DELEGATE_TOOL_NAME
    end

    if delegate_positions.length < 2
      # Sequential: announce each call, run it, emit its result inline.
      return calls.map do |c|
        events << { kind: :tool, text: announce_text(c), depth: depth }
        emit_tool_result(events, c, run_call(c, events, depth), depth)
      end
    end

    # Parallel fan-out. Announce every call up front so the UI shows all the
    # delegations before their interleaved worker logs stream in.
    calls.each do |c|
      events << { kind: :tool, text: announce_text(c), depth: depth }
    end

    outcomes = Array.new(calls.length)

    # Non-delegate tools run inline (they touch the filesystem/shell serially).
    (0...calls.length).each do |i|
      next if delegate_positions.include?(i)
      outcomes[i] = run_call(calls[i], events, depth)
    end

    # Delegates run concurrently, in capped slices.
    delegate_positions.each_slice(Agents::MAX_PARALLEL) do |slice|
      slice.map do |i|
        Thread.new { outcomes[i] = run_worker(calls[i][:input] || {}, events, depth) }
      end.each(&:join)
    end

    calls.each_index.map { |i| emit_tool_result(events, calls[i], outcomes[i], depth) }
  end

  private

  # UI text announcing a tool call. Parse-failed calls have no usable input.
  def announce_text(call)
    return "#{call[:name]} (unparseable arguments)" if call[:parse_error]
    "#{call[:name]} #{JSON.generate(call[:input])}"
  end

  def emit_tool_result(events, call, outcome, depth)
    summary, result, diff = outcome
    event = { kind: :tool_result, text: summary, depth: depth }
    event[:diff] = diff if diff
    events << event
    { id: call[:id], result: result.to_s }
  end

  # Spawn a worker agent for one subtask and return its report to the manager.
  def run_worker(input, events, depth)
    child = depth + 1
    task  = input["task"].to_s.strip
    title = input["title"].to_s.strip
    title = task.split("\n").first.to_s[0, 60] if title.empty?

    if task.empty?
      return ["delegate: missing task", "Error: delegate requires a 'task' description."]
    end
    if depth >= Agents::MAX_DEPTH
      return ["delegate refused (depth #{depth})",
              "Delegation depth limit reached — complete this subtask yourself."]
    end

    runner = worker_runner
    events << { kind: :worker_start, text: title, depth: child }
    messages = [{ "role" => "user", "content" => task }]
    report =
      begin
        runner.agent_run(
          messages, events,
          system: Agents::WORKER_SYSTEM,
          tools: Agents.tools_for(child),
          depth: child
        ).to_s.strip
      rescue => e
        events << { kind: :error, text: "worker failed: #{e.class}: #{e.message}", depth: child }
        "Worker failed: #{e.class}: #{e.message}"
      end
    report = "(worker finished without a written summary)" if report.empty?
    events << { kind: :worker_done, text: title, depth: child }

    ["delegated → #{title}", report]
  end
end
