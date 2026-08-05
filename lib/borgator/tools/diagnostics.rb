# frozen_string_literal: true

require 'json'
require 'open3'

require_relative 'helpers'
require_relative 'registry'

module Tools
  module Diagnostics
    extend Helpers

    NAME = 'diagnostics'
    LARGE_RESULT = true
    DEFINITION = {
      name: NAME,
      description:
        'Run available project linters / static checks and return diagnostics (file:line:message). ' \
        'Uses local tools when present (RuboCop, ESLint, go vet, cargo clippy); not a persistent ' \
        'LSP session. Prefer after edits to catch breakages without full test suites. Optional path ' \
        'scopes the check.',
      input_schema: {
        type: 'object',
        properties: {
          path: { type: 'string',
                  description: 'Optional file or directory to check (default: whole project / linter default).' }
        }
      }
    }.freeze

    module_function

    def call(input)
      path = input['path'].to_s.strip
      path = nil if path.empty?
      resolve_project_path!(path) if path

      runners = available_diagnostic_runners
      if runners.empty?
        return ['diagnostics (none)',
                'No supported linter found (looked for rubocop, eslint, go vet, cargo clippy). ' \
                'Install one in the project, or use run_tests / read_file to verify changes.']
      end

      outputs = []
      ran = []
      runners.each do |name, build_argv|
        argv = build_argv.call(path)
        next unless argv

        out, status = Open3.capture2e(*argv)
        body = out.to_s.strip
        body = '(no output)' if body.empty?
        header = "=== #{name} (exit #{status.exitstatus}) ==="
        outputs << "#{header}\n#{body}"
        ran << name
      end

      if outputs.empty?
        return ['diagnostics (unavailable)',
                "Found linter markers (#{runners.map(&:first).join(', ')}) but none could be executed. " \
                'Install the tool (e.g. `gem install rubocop` / `bundle install`) and retry.']
      end

      text = outputs.join("\n\n")
      ["diagnostics (#{ran.join(', ')})", text]
    end

    def available_diagnostic_runners
      list = []
      list << ['rubocop', ->(p) { rubocop_argv(p) }] if command_on_path?('rubocop') || File.exist?('.rubocop.yml')
      list << ['eslint', ->(p) { eslint_argv(p) }] if File.exist?('package.json') && command_on_path?('npx')
      list << ['go vet', ->(p) { go_vet_argv(p) }] if File.exist?('go.mod') && command_on_path?('go')
      list << ['cargo clippy', ->(p) { cargo_clippy_argv(p) }] if File.exist?('Cargo.toml') && command_on_path?('cargo')
      list
    end

    def rubocop_argv(path)
      cmd = if File.exist?('Gemfile') && command_on_path?('bundle')
              %w[bundle exec rubocop]
            elsif command_on_path?('rubocop')
              %w[rubocop]
            else
              return nil
            end
      argv = cmd + ['--format', 'clang', '--force-exclusion']
      argv << path if path
      argv
    end

    def eslint_argv(path)
      return nil unless package_has_eslint?

      argv = %w[npx --no-install eslint --format stylish --max-warnings 999999]
      argv << (path || '.')
      argv
    end

    def go_vet_argv(path)
      ['go', 'vet', path || './...']
    end

    def cargo_clippy_argv(_path)
      %w[cargo clippy --message-format short -- -W clippy::all]
    end

    def package_has_eslint?
      pkg = JSON.parse(File.read('package.json'))
      deps = {}
      %w[dependencies devDependencies].each do |k|
        deps.merge!(pkg[k]) if pkg[k].is_a?(Hash)
      end
      deps.key?('eslint')
    rescue JSON::ParserError, SystemCallError
      false
    end
  end

  Registry.register(Diagnostics)
end
