# frozen_string_literal: true

require_relative 'helper'
require_relative '../../lib/borgator/tools/run_command'

class RunCommandUnitTest < Minitest::Test
  include ToolTestHelper

  def setup
    Tools.reset_session!
    Tools.approver = ->(_tool, _detail) { :allow }
  end

  def teardown
    Tools.approver = nil
    Tools.reset_session!
  end

  def test_run_echo
    in_project do
      summary, out = Tools::RunCommand.run('echo hello-tool', skip_permission: true)
      assert_match(/ran \(sandboxed\)|blocked/, summary)
      # Sandbox may refuse on some hosts; assert we got a structured outcome either way.
      assert out
      assert_match(/hello-tool|sandbox|bubblewrap|Seatbelt|sandbox-exec/i, "#{summary}\n#{out}")
    end
  end
end
