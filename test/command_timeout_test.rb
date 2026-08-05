# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/agent_cli/tools'

class CommandTimeoutTest < Minitest::Test
  def with_timeout(seconds)
    original = COMMAND_TIMEOUT
    silently { Object.const_set(:COMMAND_TIMEOUT, seconds) }
    yield
  ensure
    silently { Object.const_set(:COMMAND_TIMEOUT, original) }
  end

  def silently
    warn_level = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = warn_level
  end

  def in_project
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        Sandbox.instance_variable_set(:@root, File.realpath(dir))
        yield dir
      end
    end
  ensure
    Sandbox.instance_variable_set(:@root, nil)
  end

  def test_a_runaway_command_is_killed_and_reported
    skip 'no sandbox backend on this host' unless Sandbox.active?

    in_project do
      elapsed = nil
      summary, output = with_timeout(1.0) do
        t = Time.now
        result = Tools.send(:run_command, 'sleep 30', skip_permission: true)
        elapsed = Time.now - t
        result
      end

      assert_operator elapsed, :<, 10, "should give up near the timeout, took #{elapsed}s"
      assert_match(/timed out/, summary)
      assert_match(/killed after/, output)
    end
  end

  def test_partial_output_survives_the_kill
    skip 'no sandbox backend on this host' unless Sandbox.active?

    in_project do
      _summary, output = with_timeout(1.5) do
        Tools.send(:run_command, 'echo before-the-hang; sleep 30', skip_permission: true)
      end

      assert_match(/before-the-hang/, output)
    end
  end

  def test_the_child_process_does_not_outlive_the_timeout
    skip 'no sandbox backend on this host' unless Sandbox.active?

    in_project do |dir|
      marker = File.join(dir, 'still-alive')
      with_timeout(1.0) do
        Tools.send(:run_command, "(sleep 3; touch #{marker}) & wait", skip_permission: true)
      end

      sleep 4
      refute File.exist?(marker), "the killed command's descendants kept running"
    end
  end

  def test_a_fast_command_is_unaffected
    skip 'no sandbox backend on this host' unless Sandbox.active?

    in_project do
      summary, output = Tools.send(:run_command, 'echo hello', skip_permission: true)

      assert_match(/ran \(sandboxed\)/, summary)
      assert_equal 'hello', output.strip
    end
  end
end
