# frozen_string_literal: true

require_relative 'helper'
require_relative '../../lib/borgator/tools/read_file'

class ReadFileUnitTest < Minitest::Test
  include ToolTestHelper

  def read(input)
    Tools::ReadFile.call(input)
  end

  def write_lines(path, count)
    File.write(path, (1..count).map { |i| "line #{i} #{'x' * 40}\n" }.join)
  end

  def test_definition_present
    assert_equal 'read_file', Tools::ReadFile::NAME
    assert Tools::ReadFile::DEFINITION[:input_schema]
  end

  def test_whole_file_within_budget
    in_project do
      write_lines('app.rb', 50)
      summary, body = read('path' => 'app.rb')
      assert_equal File.read('app.rb'), body
      assert_equal 'read app.rb', summary
    end
  end

  def test_ranged_read
    in_project do
      File.write('a.rb', "one\ntwo\nthree\n")
      _s, body = read('path' => 'a.rb', 'start_line' => 2, 'end_line' => 2)
      assert_match(/lines 2-2/, body)
      assert_match(/^two$/, body.lines.last.chomp)
    end
  end

  def test_missing_path_raises_model_error
    in_project do
      assert_raises(ArgumentError) { read({}) }
    end
  end
end
