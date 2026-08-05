# frozen_string_literal: true

require_relative 'helper'
require_relative '../../lib/borgator/tools/search_code'

class SearchCodeUnitTest < Minitest::Test
  include ToolTestHelper

  def setup
    Tools.instance_variable_set(:@rg_available, false)
  end

  def teardown
    Tools.instance_variable_set(:@rg_available, nil)
  end

  def test_finds_literal
    in_project do
      File.write('app.rb', "def hello\n  world\nend\n")
      _s, body = Tools::SearchCode.call('query' => 'world', 'fixed_string' => true)
      assert_match(/app\.rb:2:.*world/, body)
    end
  end

  def test_respects_glob
    in_project do
      File.write('a.rb', "token_xyz\n")
      File.write('a.txt', "token_xyz\n")
      _s, body = Tools::SearchCode.call(
        'query' => 'token_xyz', 'glob' => '*.rb', 'fixed_string' => true
      )
      assert_match(/a\.rb/, body)
      refute_match(/a\.txt/, body)
    end
  end

  def test_rejects_outside_path
    in_project do
      err = assert_raises(ArgumentError) do
        Tools::SearchCode.call('query' => 'x', 'path' => '/tmp')
      end
      assert_match(/outside the project/i, err.message)
    end
  end
end
