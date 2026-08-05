# frozen_string_literal: true

require_relative 'helper'
require_relative '../../lib/borgator/tools/list_files'

class ListFilesUnitTest < Minitest::Test
  include ToolTestHelper

  def test_lists_entries
    in_project do
      FileUtils.mkdir_p('sub')
      File.write('a.rb', '1')
      File.write('sub/b.rb', '2')
      summary, body = Tools::ListFiles.call('path' => '.')
      assert_equal 'list .', summary
      assert_includes body, 'a.rb'
      assert_includes body, 'sub/'
    end
  end
end
