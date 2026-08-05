# frozen_string_literal: true

require 'open3'

require_relative 'support'

# Shared helpers used by modular tool implementations under Tools::*.
module Tools
  module Helpers
    module_function

    # Fetch a required string argument, raising a model-actionable error when
    # the model omits it (weaker models often call tools with +{}+).
    def require_arg!(input, key)
      val = input[key]
      val = val.to_s if val
      if val.nil? || val.strip.empty?
        raise ArgumentError,
              "#{key} is required but was missing or empty; call the tool again with a non-empty \"#{key}\"."
      end

      val
    end

    def truncate_for_model(text, limit = MAX_MODEL_OUTPUT_BYTES)
      text = text.to_s
      return text if text.bytesize <= limit

      text[0, limit] +
        "\n…[truncated at #{limit} bytes — re-run narrowed (e.g. a line range) for more]"
    end

    # Serializes access to one path across the concurrently running tool calls
    # of a turn. Locks are per expanded path, so different files never block.
    def with_file_lock(path, &)
      key = File.expand_path(path)
      lock = FILE_LOCKS_MUTEX.synchronize { FILE_LOCKS[key] ||= Mutex.new }
      lock.synchronize(&)
    end

    def truthy?(val)
      val == true || val.to_s.strip.downcase == 'true' || val.to_s == '1'
    end

    def resolve_project_path!(path)
      full = File.expand_path(path, Sandbox.root)
      probe = full
      probe = File.dirname(probe) while !File.exist?(probe) && probe != File.dirname(probe)
      resolved = begin
        File.realpath(probe)
      rescue StandardError
        probe
      end
      unless Sandbox.within?(resolved)
        raise ArgumentError,
              "path #{path.inspect} is outside the project directory (#{Sandbox.root})."
      end

      full
    end

    def relative_to_project(abs_path)
      root = Sandbox.root
      abs = File.expand_path(abs_path)
      return abs.delete_prefix(root + File::SEPARATOR) if abs.start_with?(root + File::SEPARATOR)
      return '.' if abs == root

      abs_path.to_s
    end

    def ensure_git_repo!
      _, status = Open3.capture2e('git', 'rev-parse', '--is-inside-work-tree')
      return if status.success?

      raise ArgumentError, 'not a git repository (git rev-parse failed).'
    end

    def safe_git_rev?(rev)
      # Allow typical revision names: sha, branch, tag, HEAD, HEAD~n, origin/main, etc.
      # Reject anything that looks like a flag or shell/path list.
      rev.match?(%r{\A[A-Za-z0-9][A-Za-z0-9._/@~^-]*\z}) && !rev.start_with?('-')
    end

    def command_on_path?(name)
      system('sh', '-c', 'command -v "$1" >/dev/null', 'command', name)
    end

    def request_permission(tool, detail)
      Tools.request_permission(tool, detail)
    end
  end
end
