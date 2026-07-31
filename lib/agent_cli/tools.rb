# frozen_string_literal: true

require_relative "diff"
require_relative "preferences"

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
      description: "Read a UTF-8 text file relative to the working directory.",
      input_schema: {
        type: "object",
        properties: { path: { type: "string" } },
        required: ["path"]
      }
    },
    {
      name: "write_file",
      description: "Create or overwrite a text file with the given content.",
      input_schema: {
        type: "object",
        properties: { path: { type: "string" }, content: { type: "string" } },
        required: ["path", "content"]
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

    # Returns [summary_for_ui, result_string_for_model] or a 3-tuple with a diff.
    def call(name, input)
      case name
      when "read_file"
        path = input["path"]
        body = File.read(path)
        body = body[0, 100_000] + "\n…[truncated]" if body.bytesize > 100_000
        ["read #{path}", body]
      when "write_file"
        path = input["path"]
        new_content = input["content"].to_s
        existed = File.exist?(path)
        old_content = existed ? File.read(path) : ""
        File.write(path, new_content)
        d = Diff.unified(path, old_content, new_content)
        diff_info = d.empty? ? nil : d
        label = existed ? "wrote #{path} (#{new_content.bytesize} bytes)" : "created #{path} (#{new_content.bytesize} bytes)"
        [label, "ok", diff_info]
      when "list_files"
        path = input["path"] || "."
        entries = Dir.children(path).sort.map do |e|
          File.directory?(File.join(path, e)) ? "#{e}/" : e
        end
        ["list #{path}", entries.join("\n")]
      when "run_command"
        run_command(input["command"])
      else
        ["unknown tool #{name}", "Error: unknown tool #{name}"]
      end
    rescue => e
      ["error in #{name}: #{e.message}", "Error: #{e.class}: #{e.message}"]
    end

    private

    def run_command(cmd)
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

      out = `#{cmd} 2>&1`
      ["ran: #{cmd}", out.empty? ? "(no output)" : out[0, 100_000]]
    end

    def request_permission(tool, detail)
      return :deny unless approver

      # One outstanding prompt at a time, even with parallel workers.
      APPROVAL_MUTEX.synchronize { approver.call(tool, detail) }
    end
  end
end
