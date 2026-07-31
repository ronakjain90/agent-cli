# frozen_string_literal: true

require "open3"

require_relative "diff"
require_relative "preferences"
require_relative "sandbox"

# Capabilities exposed to the model (anthropic / openai / openrouter / google / groq / ollama providers).
module Tools
  # Serializes user permission prompts so concurrent workers ask one at a time
  # (the TUI can only hold one pending permission request).
  APPROVAL_MUTEX = Mutex.new

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
        "Read a UTF-8 text file relative to the working directory. For large files, pass " \
        "`start_line` and `end_line` (1-indexed, inclusive) to read only that range instead " \
        "of the whole file — do this rather than reading an entire large file.",
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
    }
  ].freeze

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
      input = input || {}
      case name
      when "read_file"
        read_file(input)
      when "write_file"
        path = require_arg!(input, "path")
        abs = Sandbox.ensure_writable!(path)
        new_content = input["content"].to_s
        existed = File.exist?(abs)
        old_content = existed ? File.read(abs) : ""
        File.write(abs, new_content)
        d = Diff.unified(path, old_content, new_content)
        diff_info = d.empty? ? nil : d
        label = existed ? "wrote #{path} (#{new_content.bytesize} bytes)" : "created #{path} (#{new_content.bytesize} bytes)"
        [label, "ok", diff_info]
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
      else
        ["unknown tool #{name}", "Error: unknown tool #{name}"]
      end
    rescue ArgumentError => e
      # Missing/invalid tool arguments: report back so the model can retry correctly.
      ["error in #{name}: #{e.message}", "Error: #{e.message}"]
    rescue => e
      ["error in #{name}: #{e.message}", "Error: #{e.class}: #{e.message}"]
    end

    private

    # Read a file, optionally just a 1-indexed inclusive line range. Ranged
    # reads keep context small on large files (the model asks for the slice it
    # needs instead of the whole file). Returns raw text with no line-number
    # prefixes so snippets stay copy-pasteable into {edit_file} anchors.
    #
    # @param input [Hash] tool arguments
    # @option input [String] "path" file to read (required)
    # @option input [Integer] "start_line" first line, 1-indexed inclusive
    # @option input [Integer] "end_line" last line, 1-indexed inclusive
    # @return [Array(String, String)] +[summary_for_ui, file_contents]+
    # @raise [ArgumentError] if "path" is missing or the range is out of bounds
    def read_file(input)
      path = require_arg!(input, "path")
      body = File.read(path)

      start_line = input["start_line"]
      end_line   = input["end_line"]
      if start_line || end_line
        lines = body.lines
        total = lines.length
        s = (start_line || 1).to_i
        e = (end_line || total).to_i
        s = 1 if s < 1
        e = total if e > total
        if s > e || s > total
          raise ArgumentError,
            "requested lines #{start_line.inspect}..#{end_line.inspect} are out of range for " \
            "#{path} (#{total} lines)."
        end
        slice = lines[(s - 1)...e].join
        header = "# #{path} lines #{s}-#{e} of #{total}\n"
        return ["read #{path} (lines #{s}-#{e})", header + slice]
      end

      body = body[0, 100_000] + "\n…[truncated]" if body.bytesize > 100_000
      ["read #{path}", body]
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
      unless File.exist?(abs)
        raise ArgumentError, "#{path} does not exist. Use write_file to create a new file."
      end
      if old_string == new_string
        raise ArgumentError, "old_string and new_string are identical — nothing to change."
      end

      old_content = File.read(abs)
      count = old_content.scan(old_string).length
      if count.zero?
        raise ArgumentError,
          "old_string was not found in #{path}. It must match the file exactly, including " \
          "whitespace and indentation. Read the file and copy the snippet verbatim."
      end
      if count > 1 && !replace_all
        raise ArgumentError,
          "old_string matches #{count} places in #{path}. Add surrounding lines to make it " \
          "unique, or set replace_all: true to replace all #{count}."
      end

      new_content = replace_all ? old_content.gsub(old_string, new_string) : old_content.sub(old_string, new_string)
      File.write(abs, new_content)

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
    # @return [Array(String, String)] +[summary_for_ui, combined_output]+; the
    #   summary is +"ran (sandboxed): …"+, +"blocked (no sandbox): …"+, or
    #   +"denied: …"+
    def run_command(cmd)
      # Fail closed: if no sandbox backend is available, refuse before doing
      # anything else (including prompting) — commands are never run unconfined.
      argv, refusal = Sandbox.wrap(cmd)
      return ["blocked (no sandbox): #{cmd}", refusal] if argv.nil?

      unless shell_permitted? || auto_allowed?(cmd)
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

      # argv runs directly (no wrapping shell); it is always sandboxed here.
      out, _status = Open3.capture2e(*argv)
      out = out[0, 100_000]
      out = "(no output)" if out.empty?
      ["ran (sandboxed): #{cmd}", out]
    end

    def request_permission(tool, detail)
      return :deny unless approver

      # One outstanding prompt at a time, even with parallel workers.
      APPROVAL_MUTEX.synchronize { approver.call(tool, detail) }
    end
  end
end
