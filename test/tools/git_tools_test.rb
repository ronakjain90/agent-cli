# frozen_string_literal: true

require_relative 'helper'
require_relative '../../lib/borgator/tools/git_status'
require_relative '../../lib/borgator/tools/git_diff'

class GitToolsUnitTest < Minitest::Test
  include ToolTestHelper

  def init_repo
    system('git', 'init', '-q', out: File::NULL, err: File::NULL)
    system('git', 'config', 'user.email', 't@example.com', out: File::NULL, err: File::NULL)
    system('git', 'config', 'user.name', 't', out: File::NULL, err: File::NULL)
  end

  def test_status_and_diff
    in_project do
      init_repo
      File.write('tracked.rb', "one\n")
      system('git', 'add', 'tracked.rb', out: File::NULL, err: File::NULL)
      system('git', 'commit', '-qm', 'init', out: File::NULL, err: File::NULL)
      File.write('tracked.rb', "two\n")

      _s, status = Tools::GitStatus.call
      assert_match(/## /, status)
      assert_match(/tracked\.rb/, status)

      _s, diff = Tools::GitDiff.call('path' => 'tracked.rb')
      assert_match(/-one/, diff)
      assert_match(/\+two/, diff)
    end
  end

  def test_diff_rejects_unsafe_base
    in_project do
      init_repo
      err = assert_raises(ArgumentError) do
        Tools::GitDiff.call('base' => '--output=/tmp/x')
      end
      assert_match(/unsafe base/i, err.message)
    end
  end
end
