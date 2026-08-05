# frozen_string_literal: true

require 'json'

require_relative '../preferences'
require_relative 'helpers'
require_relative 'registry'
require_relative 'run_command'

module Tools
  module RunTests
    NAME = 'run_tests'
    DEFINITION = {
      name: NAME,
      description:
        "Run the project's test suite and return its output. Prefer this over " \
        'run_command for running tests: the runner is auto-detected for the ' \
        'project (RSpec, Rails/minitest, rake, pytest, jest/npm, go test, cargo). ' \
        'Pass `path` to run a single test file or directory instead of the whole ' \
        'suite, or `runner` to override the detected command. Runs sandboxed and ' \
        'may require user approval, exactly like run_command.',
      input_schema: {
        type: 'object',
        properties: {
          path: { type: 'string',
                  description: 'Optional test file or directory to run instead of the whole suite ' \
                               '(appended to the runner; best for rspec/minitest/pytest).' },
          runner: { type: 'string',
                    description: 'Optional explicit test command to use instead of auto-detection, ' \
                                 'e.g. "bin/rails test" or "bundle exec rspec".' }
        }
      }
    }.freeze

    module_function

    def call(input)
      base = resolve_test_command(input['runner'])
      unless base
        raise ArgumentError,
              'could not detect a test command for this project. Pass `runner` explicitly ' \
              '(e.g. "bin/rails test", "bundle exec rspec", or "pytest"), set the ' \
              'AGENT_TEST_COMMAND environment variable, or add a "test_command" to the ' \
              'borgator preferences file.'
      end
      command = apply_test_path(base, input['path'])
      if safe_test_runner?(command)
        RunCommand.run(command, skip_permission: true)
      else
        RunCommand.run(command)
      end
    end

    def resolve_test_command(runner)
      explicit = runner.to_s.strip
      return explicit unless explicit.empty?

      env = ENV['AGENT_TEST_COMMAND'].to_s.strip
      return env unless env.empty?

      pref = Preferences.test_command
      return pref if pref

      detect_test_command
    end

    def safe_test_runner?(command)
      return false if command.nil? || command.strip.empty?
      return false if command.match?(SHELL_METACHARS)

      first_token = command.strip.split(/\s+/).first.to_s
      SAFE_TEST_RUNNERS.include?(first_token)
    end

    def detect_test_command
      if File.exist?('.rspec') || File.directory?('spec')
        return 'bin/rspec' if File.executable?('bin/rspec')

        return "#{bundle_prefix}rspec"
      end
      return 'bin/rails test' if File.executable?('bin/rails')
      return "#{bundle_prefix}rake test" if File.exist?('Rakefile') && File.directory?('test')
      if File.exist?('Gemfile') && File.directory?('test')
        return "#{bundle_prefix}ruby -Itest -e 'Dir[\"test/**/*_test.rb\"].each { |f| require_relative f }'"
      end
      return js_test_command if File.exist?('package.json') && package_test_script?
      if %w[pytest.ini tox.ini pyproject.toml setup.cfg].any? { |f| File.exist?(f) } || File.directory?('tests')
        return 'pytest'
      end
      return 'go test ./...' if File.exist?('go.mod')
      return 'cargo test' if File.exist?('Cargo.toml')

      nil
    end

    def apply_test_path(base, path)
      p = path.to_s.strip
      return base if p.empty?
      return base.sub(%r{\s*\./\.\.\.\s*\z}, " #{p}") if base.include?('./...')

      "#{base} #{p}"
    end

    def bundle_prefix
      File.exist?('Gemfile') ? 'bundle exec ' : ''
    end

    def package_test_script?
      pkg = JSON.parse(File.read('package.json'))
      pkg.is_a?(Hash) && pkg['scripts'].is_a?(Hash) && !pkg['scripts']['test'].to_s.strip.empty?
    rescue JSON::ParserError, SystemCallError
      false
    end

    def js_test_command
      return 'pnpm test' if File.exist?('pnpm-lock.yaml')
      return 'yarn test' if File.exist?('yarn.lock')

      'npm test'
    end
  end

  Registry.register(RunTests)
end
