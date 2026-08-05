# frozen_string_literal: true

require 'json'
require 'open3'

require_relative 'constants'
require_relative 'diff'
require_relative 'preferences'
require_relative 'sandbox'
require_relative 'tools/support'
require_relative 'tools/helpers'
require_relative 'tools/registry'

# Capabilities exposed to the model. Each tool lives in lib/borgator/tools/<name>.rb
# and registers itself via {Tools::Registry}. Tools are individually require-able —
# see test/tools/* for isolated tests.
module Tools
  class << self
    # Tool schemas exposed to the model for this session (optional tools only when enabled).
    def definitions
      Registry.definitions
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
      [summary, Helpers.truncate_for_model(result, cap_for(name)), diff]
    end

    # --- entry points kept for existing tests via Tools.send(...) ---

    def run_command(cmd, skip_permission: false)
      RunCommand.run(cmd, skip_permission: skip_permission)
    end

    def detect_test_command
      RunTests.detect_test_command
    end

    def resolve_test_command(runner)
      RunTests.resolve_test_command(runner)
    end

    def apply_test_path(base, path)
      RunTests.apply_test_path(base, path)
    end

    def safe_test_runner?(command)
      RunTests.safe_test_runner?(command)
    end

    def cap_for(name)
      handler = Registry[name]
      return MAX_FILE_RESULT_BYTES if handler&.const_defined?(:LARGE_RESULT) && handler::LARGE_RESULT

      MAX_MODEL_OUTPUT_BYTES
    end

    private

    def dispatch(name, input)
      input ||= {}
      name = 'run_command' if COMMAND_ALIASES.include?(name)
      handler = Registry[name]
      unless handler
        valid = definitions.map { |d| d[:name] }.join(', ')
        return ["unknown tool #{name}",
                "Error: unknown tool `#{name}`. Available tools: #{valid}. " \
                'To run a shell command, call `run_command` with a `command` argument.']
      end

      handler.call(input)
    rescue ArgumentError => e
      ["error in #{name}: #{e.message}", "Error: #{e.message}"]
    rescue StandardError => e
      ["error in #{name}: #{e.message}", "Error: #{e.class}: #{e.message}"]
    end
  end

  # Load modular tool implementations (order = definition order for the model).
  # Each file is also require-able on its own for unit tests.
  require_relative 'tools/read_file'
  require_relative 'tools/write_file'
  require_relative 'tools/edit_file'
  require_relative 'tools/list_files'
  require_relative 'tools/run_command'
  require_relative 'tools/run_tests'
  require_relative 'tools/search_code'
  require_relative 'tools/git_status'
  require_relative 'tools/git_diff'
  require_relative 'tools/diagnostics'
  require_relative 'tools/web_fetch'
end
