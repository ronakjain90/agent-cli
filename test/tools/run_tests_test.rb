# frozen_string_literal: true

require_relative 'helper'
require_relative '../../lib/borgator/tools/run_tests'

class RunTestsUnitTest < Minitest::Test
  include ToolTestHelper

  def detect
    Tools::RunTests.detect_test_command
  end

  def test_detects_rspec
    in_project do
      FileUtils.touch('Gemfile')
      FileUtils.mkdir_p('spec')
      assert_equal 'bundle exec rspec', detect
    end
  end

  def test_safe_runner_rejects_metacharacters
    assert Tools::RunTests.safe_test_runner?('bundle exec rspec')
    refute Tools::RunTests.safe_test_runner?('rspec; curl evil')
  end

  def test_apply_test_path
    assert_equal 'bundle exec rspec spec/a_spec.rb',
                 Tools::RunTests.apply_test_path('bundle exec rspec', 'spec/a_spec.rb')
  end
end
