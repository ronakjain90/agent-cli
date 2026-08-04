# frozen_string_literal: true

require "json"
require "open3"

require_relative "constants"
require_relative "diff"
require_relative "preferences"
require_relative "sandbox"
require_relative "errors"

# Capabilities exposed to the model (anthropic / openai / openrouter / google / groq / ollama providers).
module Tools
  # Serializes user permission prompts so concurrent workers ask one at a time
  # (the TUI can only hold one pending permission request).
  APPROVAL_MUTEX = Mutex.new

  # Guards the run_command rate-limit window against parallel workers.
  RATE_MUTEX = Mutex.new

  # Read-only command prefixes that are always allowed without prompting.
  # Users can extend this at runtime via the permission prompt (persisted in Preferences).
  DEFAULT_ALLOWED = [
    "git status", "git log", "git diff", "git show", "git branch",
    "git remote", "git rev-parse", "git describe", "git blame",
    "git ls-files", "git shortlog", "git tag", "git stash list",
    "git config --get", "git config --list"
  ].freeze

  # Tools whose first argument is a subcommand, so a persisted prefix keeps two words
  # (e.g. "git status" rather than just "git").
  SUBCOMMAND_TOOLS = %w[git gh npm yarn pnpm bundle cargo go docker kubectl].freeze

  # Reject anything that could chain, redirect, or substitute another command;
  # such lines always require explicit approval even if they start with an allowed prefix.
  SHELL_METACHARS = /[;&|`><\n]|\$\(/.freeze
  DEFINITIONS = [
    {
      name: "read_file",
      description:
        "Read a UTF-8 text file relative to the working directory. Omit " \
        "`start_line`/`end_line` to read the whole file — do that unless you already know " \
        "the exact region you need, or are resuming a read that came back truncated. A " \
        "truncated read tells you the line to resume from.",
      input_schema: {
        type: "object",
        properties: {
          path:       { type: "string" },
          start_line: { type: "integer", description: "First line to read (1-indexed, inclusive). Optional." },
          end_line:   { type: "integer", description: "Last line to read (1-indexed, inclusive). Optional." }
        },
        required: ["path"]
      }
    },
    {
      name: "write_file",
      description:
        "Create a NEW file, or completely replace a file's contents. For changing part " \
        "of an existing file, prefer `edit_file` — it needs far less text and is less " \
        "error-prone.",
      input_schema: {
        type: "object",
        properties: { path: { type: "string" }, content: { type: "string" } },
        required: ["path", "content"]
      }
    },
    {
      name: "edit_file",
      description:
        "Edit an existing file by replacing an exact snippet. Provide `old_string` copied " \
        "VERBATIM from the file (including indentation and whitespace) and `new_string` to " \
        "replace it with. `old_string` must be unique in the file — include a few surrounding " \
        "lines for context if needed — or set `replace_all` to replace every occurrence. Use " \
        "an empty `new_string` to delete the snippet. Prefer this over `write_file` for " \
        "changes to existing files: you only send the changed lines, not the whole file.",
      input_schema: {
        type: "object",
        properties: {
          path:        { type: "string" },
          old_string:  { type: "string", description: "Exact text to find, copied verbatim from the file." },
          new_string:  { type: "string", description: "Replacement text. Empty string deletes the match." },
          replace_all: { type: "boolean", description: "Replace every occurrence instead of requiring a unique match. Default false." }
        },
        required: ["path", "old_string", "new_string"]
      }
    },
    {
      name: "list_files",
      description: "List files and directories under a path (default '.').",
      input_schema: {
        type: "object",
        properties: { path: { type: "string" } }
      }
    },
    {
      name: "run_command",
      description: "Run a shell command in the working directory and return its output. May require user approval.",
      input_schema: {
        type: "object",
        properties: { command: { type: "string" } },
        required: ["command"]
      }
    },
    {
      name: "run_tests",
      description:
        "Run the project's test suite and return its output. Prefer this over " \
        "run_command for running tests: the runner is auto-detected for the " \
        "project (RSpec, Rails/minitest, rake, pytest, jest/npm, go test, cargo). " \
        "Pass `path` to run a single test file or directory instead of the whole " \
        "suite, or `runner` to override the detected command. Runs sandboxed and " \
        "may require user approval, exactly like run_command.",
      input_schema: {
        type: "object",
        properties: {
          path:   { type: "string", description: "Optional test file or directory to run instead of the whole suite (appended to the runner; best for rspec/minitest/pytest)." },
          runner: { type: "string", description: "Optional explicit test command to use instead of auto-detection, e.g. \"bin/rails test\" or \"bundle exec rspec\"." }
        }
      }
    }
  ].freeze

  COMMAND_ALIASES = %w[shell bash sh zsh run_shell run_bash execute exec terminal command].freeze

  # Tool calls in one turn run concurrently, so a path is locked for the whole
  # read-modify-write of an edit.
  FILE_LOCKS = {}
  FILE_LOCKS_MUTEX = Mutex.new

  # A shell command can touch any path, so there is nothing finer to lock on
  # than "one command at a time".
  SHELL_MUTEX = Mutex.new

  class << self
    # Callable that receives (tool_name, detail) and returns :allow, :always, or :deny.
    # Set by the TUI so the worker thread can block until the user answers.
    attr_accessor :approver

    def session_shell?
      @session_shell
    end

    def allow_shell_session!
      @session_shell = true
    end

    def reset_session!
      @session_shell = false
      RATE_MUTEX.synchronize { @command_times = [] }
    end

    # Sliding-window rate check: records now and returns true if under the cap,
    # else returns false without recording (rejected commands don't count).
    def rate_limit_ok?(now = Time.now.to_f)
      RATE_MUTEX.synchronize do
        @command_times ||= []
        cutoff = now - COMMAND_RATE_WINDOW
        @command_times.reject! { |t| t < cutoff }
        return false if @command_times.length >= MAX_COMMANDS_PER_WINDOW

        @command_times << now
        true
      end
    end

    def shell_permitted?
      ENV["AGENT_ALLOW_SHELL"] == "1" || session_shell?
    end

    # True when a command matches a built-in or user-persisted allowlist prefix and
    # contains no shell metacharacters that could smuggle in a second command.
    def auto_allowed?(cmd)
      norm = cmd.to_s.strip
      return false if norm.empty? || norm.match?(SHELL_METACHARS)

      allowlist.any? { |prefix| norm == prefix || norm.start_with?("#{prefix} ") }
    end

    def allowlist
      DEFAULT_ALLOWED + Preferences.allowed_commands
    end

    # The prefix to persist when the user permanently allows a command: the first token,
    # or the first two tokens for subcommand-style tools like git/npm/docker.
    def persist_prefix(cmd)
      tokens = cmd.to_s.strip.split(/\s+/)
      return cmd.to_s.strip if tokens.empty?

      count = SUBCOMMAND_TOOLS.include?(tokens[0]) ? 2 : 1
      tokens.first(count).join(" ")
    end

    # Dispatch a tool call by name and return its outcome.
    #
    # @param name [String] the tool name (e.g. +"read_file"+)
    # @param input [Hash, nil] the tool's JSON arguments
    # @return [Array(String, String)] +[summary_for_ui, result_for_model]+
    # @return [Array(String, String, String)] the same, plus a unified diff, for
    #   tools that modify a file
    def call(name, input)
      summary, result, diff = dispatch(name, input)
      [summary, truncate_for_model(result, cap_for(name)), diff]
    end

    private

    # Reads are how the model sees code, so they get a far larger budget.
    def cap_for(name)
      name == "read_file" ? MAX_FILE_RESULT_BYTES : MAX_MODEL_OUTPUT_BYTES
    end

    # Results flow back through {call}, which caps them — handlers don't.
    def dispatch(name, input)
      input = input || {}
      name = "run_command" if COMMAND_ALIASES.include?(name)
      case name
      when "read_file"
        read_file(input)
      when "write_file"
        write_file(input)
      when "edit_file"
        edit_file(input)
      when "list_files"
        path = input["path"] || "."
        entries = Dir.children(path).sort.map do |e|
          File.directory?(File.join(path, e)) ? "#{e}/" : e
        end
        ["list #{path}", entries.join("\n")]
      when "run_command"
        run_command(require_arg!(input, "command"))
      when "run_tests"
        run_tests(input)
      else
        valid = DEFINITIONS.map { |d| d[:name] }.join(", ")
        ["unknown tool #{name}",
         "Error: unknown tool `#{name}`. Available tools: #{valid}. " \
         "To run a shell command, call `run_command` with a `command` argument."]
      end
    rescue ArgumentError => e
      # Missing/invalid tool arguments: report back so the model can retry correctly.
      ["error in #{name}: #{e.message}", "Error: #{e.message}"]
    rescue => e
      ["error in #{name}: #{e.message}", "Error: #{e.class}: #{e.message}"]
    end

    # Returns raw text with no line-number prefixes so snippets stay copy-pasteable
    # into {edit_file} anchors. An over-budget read is cut on a line boundary and
    # names the line to resume from — a silent cut would leave the model believing
    # it saw a whole file.
    def read_file(input)
      path = require_arg!(input, "path")
      body = with_file_lock(path) { File.read(path) }

      start_line = input["start_line"]
      end_line   = input["end_line"]
      ranged     = !(start_line.nil? && end_line.nil?)

      lines = body.lines
      total = lines.length
      s = (start_line || 1).to_i
      e = (end_line || total).to_i
      s = 1 if s < 1
      e = total if e > total
      if ranged && (s > e || s > total)
        raise ArgumentError,
          "requested lines #{start_line.inspect}..#{end_line.inspect} are out of range for " \
          "#{path} (#{total} lines)."
      end

      kept, last = take_within_budget(lines[(s - 1)...e] || [], s)
      truncated  = last < e

      return ["read #{path}", kept.join] unless ranged || truncated

      text = "# #{path} lines #{s}-#{last} of #{total}\n" + kept.join
      if truncated
        # No blank line before the hint, or the gap reads as file content.
        text += "\n" unless text.end_with?("\n")
        text += "…[truncated to fit: this read stopped at line #{last} of #{total}. " \
                "Call read_file again with start_line: #{last + 1} to continue.]"
      end
      ["read #{path} (lines #{s}-#{last}#{", truncated" if truncated})", text]
    end

    # Whole lines only, so a truncated read never ends mid-line. The slack leaves
    # room for the header and resume hint. Returns [lines_kept, last_line_kept].
    def take_within_budget(lines, first_line)
      budget = MAX_FILE_RESULT_BYTES - 512
      bytes  = 0
      kept   = []
      lines.each do |line|
        bytes += line.bytesize
        # Always take one line, even if it alone blows the budget.
        break if bytes > budget && !kept.empty?

        kept << line
      end
      [kept, first_line + kept.length - 1]
    end

    # Create a new file or replace one wholesale. Held under the path's lock so
    # a concurrent edit_file never sees the file half-written.
    #
    # @param input [Hash] tool arguments
    # @option input [String] "path" file to write (required)
    # @option input [String] "content" the file's new contents
    # @return [Array(String, String, String)] +[summary, "ok", unified_diff]+
    def write_file(input)
      path = require_arg!(input, "path")
      abs = Sandbox.ensure_writable!(path)
      new_content = input["content"].to_s

      old_content, existed = with_file_lock(path) do
        existed = File.exist?(abs)
        old = existed ? File.read(abs) : ""
        File.write(abs, new_content)
        [old, existed]
      end

      d = Diff.unified(path, old_content, new_content)
      diff_info = d.empty? ? nil : d
      label = existed ? "wrote #{path} (#{new_content.bytesize} bytes)" : "created #{path} (#{new_content.bytesize} bytes)"
      [label, "ok", diff_info]
    end

    # Anchored replacement: swap an exact +old_string+ for +new_string+ in an
    # existing file. Keeps payloads small (only the changed snippet) and returns
    # model-actionable errors when the anchor is missing or ambiguous.
    #
    # @param input [Hash] tool arguments
    # @option input [String] "path" file to edit (required)
    # @option input [String] "old_string" exact text to find (required)
    # @option input [String] "new_string" replacement text; empty deletes the
    #   match (required, may be empty)
    # @option input [Boolean] "replace_all" replace every occurrence instead of
    #   requiring a unique match (default false)
    # @return [Array(String, String, String)] +[summary, "ok", unified_diff]+
    # @raise [ArgumentError] if arguments are missing, the file is outside the
    #   project root or absent, or the anchor is not found / not unique
    def edit_file(input)
      path = require_arg!(input, "path")
      old_string = require_arg!(input, "old_string")
      unless input.key?("new_string")
        raise ArgumentError, "new_string is required (use an empty string to delete the matched text)."
      end
      new_string  = input["new_string"].to_s
      replace_all = input["replace_all"] ? true : false

      abs = Sandbox.ensure_writable!(path)
      if old_string == new_string
        raise ArgumentError, "old_string and new_string are identical — nothing to change."
      end

      # The whole read-modify-write happens under the path's lock: two edits to
      # the same file in one turn run concurrently, and without this the second
      # would read stale content and silently drop the first edit.
      old_content, new_content, count = with_file_lock(path) do
        unless File.exist?(abs)
          raise ArgumentError, "#{path} does not exist. Use write_file to create a new file."
        end

        old = File.read(abs)
        n = old.scan(old_string).length
        if n.zero?
          raise ArgumentError,
            "old_string was not found in #{path}. It must match the file exactly, including " \
            "whitespace and indentation. Read the file and copy the snippet verbatim."
        end
        if n > 1 && !replace_all
          raise ArgumentError,
            "old_string matches #{n} places in #{path}. Add surrounding lines to make it " \
            "unique, or set replace_all: true to replace all #{n}."
        end

        updated = replace_all ? old.gsub(old_string, new_string) : old.sub(old_string, new_string)
        File.write(abs, updated)
        [old, updated, n]
      end

      d = Diff.unified(path, old_content, new_content)
      diff_info = d.empty? ? nil : d
      n = replace_all ? count : 1
      ["edited #{path} (#{n} replacement#{"s" if n != 1})", "ok", diff_info]
    end

    # Fetch a required string argument, raising a model-actionable error when
    # the model omits it (weaker models often call tools with +{}+).
    #
    # @param input [Hash] the tool arguments
    # @param key [String] the required argument name
    # @return [String] the argument's non-empty, stringified value
    # @raise [ArgumentError] if the argument is missing or empty
    def require_arg!(input, key)
      val = input[key]
      val = val.to_s if val
      if val.nil? || val.strip.empty?
        raise ArgumentError, "#{key} is required but was missing or empty; call the tool again with a non-empty \"#{key}\"."
      end
      val
    end

    # Run a shell command under the OS sandbox, after any permission check.
    # Fails closed: if no sandbox backend is available the command is refused,
    # never run unconfined.
    #
    # @param cmd [String] the shell command to run
    # @param skip_permission [Boolean] when true, bypasses the user-permission
    #   prompt (used by run_tests, which is a safe, auto-detected test runner).
    # @return [Array(String, String)] +[summary_for_ui, combined_output]+; the
    #   summary is +"ran (sandboxed): …"+, +"blocked (no sandbox): …"+, or
    #   +"denied: …"+
    def run_command(cmd, skip_permission: false)
      # Fail closed: if no sandbox backend is available, refuse before doing
      # anything else (including prompting) — commands are never run unconfined.
      argv, refusal = Sandbox.wrap(cmd)
      return ["blocked (no sandbox): #{cmd}", refusal] if argv.nil?

      # One command at a time, even when a turn issues several: they share a
      # working directory, and their permission prompts share one TUI slot.
      SHELL_MUTEX.synchronize { execute_command(cmd, argv, skip_permission) }
    end

    def execute_command(cmd, argv, skip_permission)
      unless skip_permission || shell_permitted? || auto_allowed?(cmd)
        case request_permission("run_command", cmd)
        when :always
          allow_shell_session!
        when :persist
          Preferences.add_allowed_command(persist_prefix(cmd))
        when :allow
          # one-shot
        else
          return ["denied: #{cmd}", "User denied permission to run this shell command."]
        end
      end

      # Rate limit executions (after permission, so a denied command costs nothing).
      unless rate_limit_ok?
        return ["rate-limited: #{cmd}",
                "Rate limit reached: at most #{MAX_COMMANDS_PER_WINDOW} shell commands may run " \
                "per #{COMMAND_RATE_WINDOW.to_i} seconds. Wait a moment before running more commands."]
      end

      # argv runs directly (no wrapping shell); it is always sandboxed here.
      out, timed_out = capture_with_timeout(argv, COMMAND_TIMEOUT)
      out = out[0, MAX_READ_BYTES]
      out = "(no output)" if out.empty?

      if timed_out
        return ["timed out (#{COMMAND_TIMEOUT.to_i}s): #{cmd}",
                "Command killed after #{COMMAND_TIMEOUT.to_i}s. Partial output below. Re-run " \
                "something narrower (scope the path, add a limit) rather than repeating this.\n\n#{out}"]
      end

      ["ran (sandboxed): #{cmd}", out]
    end

    # Capture stdout+stderr, killing the command if it outlives +timeout+.
    # Own process group, so the kill also takes the sandbox's inner shell; the
    # +ensure+ repeats it on thread kill, which is how `esc` reclaims a command.
    def capture_with_timeout(argv, timeout)
      stdin, out_io, wait_thr = Open3.popen2e(*argv, pgroup: true)
      stdin.close
      pid = wait_thr.pid
      reader = Thread.new { out_io.read.to_s }

      timed_out = wait_thr.join(timeout).nil?
      terminate_group(pid) if timed_out

      # The kill closes the pipe, so the reader finishes either way.
      out = reader.join(5) ? reader.value.to_s : ""
      [out, timed_out]
    ensure
      terminate_group(pid) if pid && wait_thr&.alive?
      reader&.kill
      out_io&.close unless out_io.nil? || out_io.closed?
    end

    # TERM then KILL the whole process group. Every failure mode here means
    # "already gone", so they are all swallowed.
    def terminate_group(pid)
      Process.kill("TERM", -pid)
      sleep 0.2
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM, RangeError
      nil
    end

    # Resolve the project's test command and run it through the same confined
    # path as {run_command} (sandbox + permission + rate limit). A specialized
    # tool rather than raw run_command so the model doesn't have to guess the
    # right runner (e.g. rspec in a minitest repo) — detection picks it.
    #
    # @param input [Hash] tool arguments
    # @option input [String] "path" a single test file/dir to run (optional)
    # @option input [String] "runner" explicit command overriding detection (optional)
    # @return [Array(String, String)] +[summary_for_ui, output]+, matching run_command
    # @raise [ArgumentError] when no runner is given and none can be detected
    def run_tests(input)
      base = resolve_test_command(input["runner"])
      unless base
        raise ArgumentError,
          "could not detect a test command for this project. Pass `runner` explicitly " \
          "(e.g. \"bin/rails test\", \"bundle exec rspec\", or \"pytest\"), set the " \
          "AGENT_TEST_COMMAND environment variable, or add a \"test_command\" to the " \
          "agent-cli preferences file."
      end
      run_command(apply_test_path(base, input["path"]), skip_permission: true)
    end

    # Pick the test command from, in order: an explicit +runner+ argument, the
    # AGENT_TEST_COMMAND env var, the persisted +test_command+ preference, then
    # filesystem auto-detection. Returns nil when nothing matches.
    def resolve_test_command(runner)
      explicit = runner.to_s.strip
      return explicit unless explicit.empty?

      env = ENV["AGENT_TEST_COMMAND"].to_s.strip
      return env unless env.empty?

      pref = Preferences.test_command
      return pref if pref

      detect_test_command
    end

    # Best-effort detection of the project's test runner from marker files in the
    # working directory. Ruby is checked first (RSpec before minitest), then the
    # common runners for other ecosystems. Returns nil when nothing is recognized.
    def detect_test_command
      # Ruby — RSpec (binstub > bundler > bare executable).
      if File.exist?(".rspec") || File.directory?("spec")
        return "bin/rspec" if File.executable?("bin/rspec")
        return "#{bundle_prefix}rspec"
      end
      # Ruby — Rails default (minitest via the rails binstub).
      return "bin/rails test" if File.executable?("bin/rails")
      # Ruby — rake-driven minitest.
      return "#{bundle_prefix}rake test" if File.exist?("Rakefile") && File.directory?("test")
      # JavaScript / TypeScript — a "test" script in package.json.
      return js_test_command if File.exist?("package.json") && package_test_script?
      # Python — pytest.
      if %w[pytest.ini tox.ini pyproject.toml setup.cfg].any? { |f| File.exist?(f) } || File.directory?("tests")
        return "pytest"
      end
      # Go.
      return "go test ./..." if File.exist?("go.mod")
      # Rust.
      return "cargo test" if File.exist?("Cargo.toml")

      nil
    end

    # Append a focused test path to the base command. For go's package spec
    # (+./...+) the path replaces it; for everything else it is appended. Runners
    # that don't take a bare file path (rake, cargo) are better targeted with an
    # explicit +runner+, which is documented on the tool.
    def apply_test_path(base, path)
      p = path.to_s.strip
      return base if p.empty?
      return base.sub(%r{\s*\./\.\.\.\s*\z}, " #{p}") if base.include?("./...")

      "#{base} #{p}"
    end

    # "bundle exec " when the project has a Gemfile (so gem versions resolve),
    # else "" to call the runner directly.
    def bundle_prefix
      File.exist?("Gemfile") ? "bundle exec " : ""
    end

    # Whether package.json declares a "test" script.
    def package_test_script?
      pkg = JSON.parse(File.read("package.json"))
      pkg.is_a?(Hash) && pkg["scripts"].is_a?(Hash) && !pkg["scripts"]["test"].to_s.strip.empty?
    rescue JSON::ParserError, SystemCallError
      false
    end

    # The JS test command, matched to the project's package manager by lockfile.
    def js_test_command
      return "pnpm test" if File.exist?("pnpm-lock.yaml")
      return "yarn test" if File.exist?("yarn.lock")

      "npm test"
    end

    def truncate_for_model(text, limit = MAX_MODEL_OUTPUT_BYTES)
      text = text.to_s
      return text if text.bytesize <= limit

      text[0, limit] +
        "\n…[truncated at #{limit} bytes — re-run narrowed (e.g. a line range) for more]"
    end

    def request_permission(tool, detail)
      return :deny unless approver

      # One outstanding prompt at a time, even with parallel workers.
      APPROVAL_MUTEX.synchronize { approver.call(tool, detail) }
    end

    # Serializes access to one path across the concurrently running tool calls
    # of a turn. Locks are per expanded path, so different files never block.
    def with_file_lock(path, &block)
      key = File.expand_path(path)
      lock = FILE_LOCKS_MUTEX.synchronize { FILE_LOCKS[key] ||= Mutex.new }
      lock.synchronize(&block)
    end
  end
end
