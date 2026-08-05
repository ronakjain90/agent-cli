# frozen_string_literal: true

require_relative 'helper'
require_relative '../../lib/borgator/tools/write_file'
require_relative '../../lib/borgator/tools/edit_file'

class WriteEditFileUnitTest < Minitest::Test
  include ToolTestHelper

  def test_write_creates_file
    in_project do
      summary, result, diff = Tools::WriteFile.call('path' => 'new.rb', 'content' => "hi\n")
      assert_match(/created new\.rb/, summary)
      assert_equal 'ok', result
      assert_equal "hi\n", File.read('new.rb')
      assert diff
    end
  end

  def test_edit_replaces_unique_snippet
    in_project do
      File.write('x.rb', "a\nb\nc\n")
      Sandbox.instance_variable_set(:@root, File.realpath('.'))
      summary, result = Tools::EditFile.call(
        'path' => 'x.rb', 'old_string' => 'b', 'new_string' => 'B'
      )
      assert_match(/edited/, summary)
      assert_equal 'ok', result
      assert_equal "a\nB\nc\n", File.read('x.rb')
    end
  end

  def test_edit_requires_unique_match
    in_project do
      File.write('x.rb', "a\na\n")
      err = assert_raises(ArgumentError) do
        Tools::EditFile.call('path' => 'x.rb', 'old_string' => 'a', 'new_string' => 'z')
      end
      assert_match(/2 places/, err.message)
    end
  end
end
