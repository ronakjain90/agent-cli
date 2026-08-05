# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require 'open3'

# Each tool file must load on its own without pulling the full tool set
# (except intentional deps, e.g. run_tests → run_command).
class ToolLoadIsolationTest < Minitest::Test
  # basename => permitted registered names after requiring that file alone
  EXPECTED = {
    'read_file' => %w[read_file],
    'write_file' => %w[write_file],
    'edit_file' => %w[edit_file],
    'list_files' => %w[list_files],
    'run_command' => %w[run_command],
    'run_tests' => %w[run_command run_tests],
    'search_code' => %w[search_code],
    'git_status' => %w[git_status],
    'git_diff' => %w[git_diff],
    'diagnostics' => %w[diagnostics],
    'web_fetch' => %w[web_fetch]
  }.freeze

  ROOT = File.expand_path('../..', __dir__)
  TOOLS_DIR = File.join(ROOT, 'lib/borgator/tools')

  EXPECTED.each do |basename, expected_names|
    define_method(:"test_#{basename}_requires_in_isolation") do
      path = File.join(TOOLS_DIR, "#{basename}.rb")
      assert File.file?(path), "missing #{path}"

      script = <<~RUBY
        $LOAD_PATH.unshift(#{File.join(ROOT, 'lib').inspect})
        require #{path.inspect}
        names = Tools::Registry.registered_names
        expected = #{expected_names.inspect}
        unless names == expected
          abort "after requiring #{basename}: got \#{names.inspect}, expected \#{expected.inspect}"
        end
        mod_name = #{basename.split('_').map(&:capitalize).join.inspect}
        abort "Tools::\#{mod_name} missing" unless Tools.const_defined?(mod_name)
      RUBY

      out, err, status = Open3.capture3(RbConfig.ruby, '-e', script)
      assert status.success?, "isolated load of #{basename} failed:\n#{out}#{err}"
    end
  end
end
