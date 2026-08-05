# frozen_string_literal: true

require_relative 'helper'
require_relative '../../lib/borgator/tools/diagnostics'

class DiagnosticsUnitTest < Minitest::Test
  include ToolTestHelper

  def test_none_when_no_linter
    in_project do
      File.write('hello.rb', "puts 1\n")
      summary, body = Tools::Diagnostics.call({})
      assert_match(/diagnostics/, summary)
      assert_match(/No supported linter|none could be executed|rubocop/i, body)
    end
  end
end
