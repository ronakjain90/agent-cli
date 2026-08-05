# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'uri'
require_relative '../lib/borgator/tools'
require_relative '../lib/borgator/agents'
require_relative '../lib/borgator'

class ExploreToolsTest < Minitest::Test
  def setup
    Tools.instance_variable_set(:@rg_available, false)
    ENV.delete('AGENT_ALLOW_WEB_FETCH')
  end

  def teardown
    Tools.instance_variable_set(:@rg_available, nil)
    ENV.delete('AGENT_ALLOW_WEB_FETCH')
    Sandbox.instance_variable_set(:@root, nil)
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

  def call(name, input = {})
    Tools.call(name, input)
  end

  def test_definitions_include_explore_tools_without_web_fetch
    names = Tools.definitions.map { |d| d[:name] }
    assert_includes names, 'search_code'
    assert_includes names, 'git_status'
    assert_includes names, 'git_diff'
    assert_includes names, 'diagnostics'
    refute_includes names, 'web_fetch'
  end

  def test_web_fetch_registered_when_enabled
    ENV['AGENT_ALLOW_WEB_FETCH'] = '1'
    names = Tools.definitions.map { |d| d[:name] }
    assert_includes names, 'web_fetch'
  end

  def test_web_fetch_flag_parsed
    argv = %w[borgator --web-fetch --debug]
    Borgator.parse_flags!(argv)
    assert_equal '1', ENV['AGENT_ALLOW_WEB_FETCH']
    assert_equal '1', ENV['AGENT_DEBUG']
    refute_includes argv, '--web-fetch'
  ensure
    ENV.delete('AGENT_ALLOW_WEB_FETCH')
    ENV.delete('AGENT_DEBUG')
  end

  def test_agents_tools_include_search_and_delegate
    names = Agents.tools_for(0).map { |d| d[:name] }
    assert_includes names, 'search_code'
    assert_includes names, 'delegate'
  end

  def test_search_code_finds_literal
    in_project do
      File.write('app.rb', "def hello\n  world\nend\n")
      File.write('other.rb', "nope\n")
      _summary, result = call('search_code', 'query' => 'world', 'fixed_string' => true)
      assert_match(/app\.rb:2:.*world/, result)
      refute_match(/other\.rb/, result)
    end
  end

  def test_search_code_respects_glob_and_max
    in_project do
      File.write('a.rb', "token_xyz\n")
      File.write('a.txt', "token_xyz\n")
      _s, result = call('search_code',
                       'query' => 'token_xyz',
                       'glob' => '*.rb',
                       'fixed_string' => true,
                       'max_matches' => 1)
      assert_match(/a\.rb/, result)
      refute_match(/a\.txt/, result)
    end
  end

  def test_search_code_rejects_path_outside_project
    in_project do
      _s, result = call('search_code', 'query' => 'x', 'path' => '/tmp')
      assert_match(/Error:.*outside the project/i, result)
    end
  end

  def test_git_status_and_diff
    in_project do
      system('git', 'init', '-q', out: File::NULL, err: File::NULL)
      system('git', 'config', 'user.email', 't@example.com', out: File::NULL, err: File::NULL)
      system('git', 'config', 'user.name', 't', out: File::NULL, err: File::NULL)
      File.write('tracked.rb', "one\n")
      system('git', 'add', 'tracked.rb', out: File::NULL, err: File::NULL)
      system('git', 'commit', '-qm', 'init', out: File::NULL, err: File::NULL)

      File.write('tracked.rb', "two\n")
      File.write('untracked.rb', "u\n")

      _s, status_body = call('git_status')
      assert_match(/## /, status_body)
      assert_match(/tracked\.rb/, status_body)
      assert_match(/untracked\.rb/, status_body)

      _s, diff_body = call('git_diff', 'path' => 'tracked.rb')
      assert_match(/-one/, diff_body)
      assert_match(/\+two/, diff_body)

      system('git', 'add', 'tracked.rb', out: File::NULL, err: File::NULL)
      _s, staged = call('git_diff', 'staged' => true, 'path' => 'tracked.rb')
      assert_match(/\+two/, staged)
    end
  end

  def test_git_diff_rejects_unsafe_base
    in_project do
      system('git', 'init', '-q', out: File::NULL, err: File::NULL)
      _s, result = call('git_diff', 'base' => '--output=/tmp/x')
      assert_match(/Error:.*unsafe base/i, result)
    end
  end

  def test_git_status_without_repo
    in_project do
      _s, result = call('git_status')
      assert_match(/Error:.*not a git/i, result)
    end
  end

  def test_diagnostics_without_linter
    in_project do
      File.write('hello.rb', "puts 1\n")
      _s, result = call('diagnostics')
      assert_match(/No supported linter|none could be executed|rubocop/i, result)
    end
  end

  def test_web_fetch_disabled_by_default
    _s, result = call('web_fetch', 'url' => 'https://example.com')
    assert_match(/Error:.*disabled/i, result)
  end

  def test_web_fetch_blocks_localhost
    ENV['AGENT_ALLOW_WEB_FETCH'] = '1'
    _s, result = call('web_fetch', 'url' => 'http://127.0.0.1/')
    assert_match(/Error:.*(local|private|reserved)/i, result)
  end

  def test_web_fetch_returns_body_when_enabled
    ENV['AGENT_ALLOW_WEB_FETCH'] = '1'
    Tools::WebFetch.singleton_class.class_eval do
      alias_method :__orig_fetch_url, :fetch_url
      define_method(:fetch_url) do |_uri, _max|
        ['hello-from-fetch', URI('https://example.com/docs'), 'text/plain']
      end
    end

    _s, result = call('web_fetch', 'url' => 'https://example.com/docs')
    assert_match(/hello-from-fetch/, result)
    assert_match(%r{Content-Type: text/plain}, result)
    assert_match(%r{URL: https://example.com/docs}, result)
  ensure
    Tools::WebFetch.singleton_class.class_eval do
      if private_method_defined?(:__orig_fetch_url) || method_defined?(:__orig_fetch_url)
        alias_method :fetch_url, :__orig_fetch_url
        remove_method :__orig_fetch_url
      end
    end
  end
end
