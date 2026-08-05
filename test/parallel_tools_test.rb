# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/agent_cli/agents'

class ParallelToolsTest < Minitest::Test
  class FakeAgent
    include Delegation

    # Keyword names must match the real interface, so they can't be underscored.
    # rubocop:disable Lint/UnusedMethodArgument
    def agent_run(_messages, _events, system:, tools:, depth:)
      # rubocop:enable Lint/UnusedMethodArgument
      sleep 0.05
      "report from depth #{depth}"
    end
  end

  def setup
    @agent = FakeAgent.new
    @events = Queue.new
  end

  def with_slow_tools(delay: 0.05)
    Tools.singleton_class.class_eval { alias_method :orig_call, :call }
    Tools.define_singleton_method(:call) do |name, input|
      sleep delay
      ["#{name} #{input['path']}", 'ok']
    end
    yield
  ensure
    Tools.singleton_class.class_eval do
      remove_method :call
      alias_method :call, :orig_call
      remove_method :orig_call
    end
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

  def call_for(id, name, input = { 'path' => id })
    { id: id, name: name, input: input }
  end

  def test_tool_calls_run_concurrently
    calls = %w[a b c d].map { |id| call_for(id, 'read_file') }

    elapsed = with_slow_tools do
      t = Time.now
      results = @agent.run_tool_batch(calls, @events, 0)
      assert_equal(%w[a b c d], results.map { |r| r[:id] })
      Time.now - t
    end

    assert_operator elapsed, :<, 0.15, "four 0.05s calls should overlap, took #{elapsed}s"
  end

  def test_results_stay_in_call_order
    calls = %w[a b c].map { |id| call_for(id, 'list_files') }

    with_slow_tools do
      results = @agent.run_tool_batch(calls, @events, 0)
      assert_equal(%w[a b c], results.map { |r| r[:id] })
      assert_equal(['ok'] * 3, results.map { |r| r[:result] })
    end
  end

  def test_concurrent_edits_to_one_file_all_land
    in_project do
      File.write('app.rb', (1..8).map { |n| "line #{n}\n" }.join)

      calls = (1..8).map do |n|
        call_for(n.to_s, 'edit_file',
                 { 'path' => 'app.rb', 'old_string' => "line #{n}\n", 'new_string' => "EDITED #{n}\n" })
      end

      results = @agent.run_tool_batch(calls, @events, 0)

      assert_equal ['ok'] * 8, results.map { |r| r[:result] },
                   "every edit should apply: #{results.map { |r| r[:result] }.inspect}"
      body = File.read('app.rb')
      (1..8).each { |n| assert_includes body, "EDITED #{n}" }
    end
  end

  def test_concurrent_write_and_edit_to_one_file_do_not_interleave
    in_project do
      File.write('app.rb', "original\n")

      calls = [
        call_for('1', 'write_file', { 'path' => 'app.rb', 'content' => 'x' * 20_000 }),
        call_for('2', 'edit_file',
                 { 'path' => 'app.rb', 'old_string' => 'original', 'new_string' => 'replaced' })
      ]

      @agent.run_tool_batch(calls, @events, 0)

      body = File.read('app.rb')
      assert(body == 'x' * 20_000 || body == "replaced\n",
             "file should be one whole version or the other, got #{body[0, 40].inspect}")
    end
  end

  def test_edits_to_different_files_run_in_parallel
    in_project do
      3.times { |n| File.write("f#{n}.rb", "old\n") }

      calls = (0..2).map do |n|
        call_for(n.to_s, 'edit_file',
                 { 'path' => "f#{n}.rb", 'old_string' => 'old', 'new_string' => 'new' })
      end

      results = @agent.run_tool_batch(calls, @events, 0)

      assert_equal(['ok'] * 3, results.map { |r| r[:result] })
      3.times { |n| assert_equal "new\n", File.read("f#{n}.rb") }
    end
  end

  def test_shell_commands_never_overlap
    overlaps = 0
    running = 0
    guard = Mutex.new

    Tools.singleton_class.class_eval { alias_method :orig_exec, :execute_command }
    Tools.define_singleton_method(:execute_command) do |cmd, _argv, _skip|
      guard.synchronize do
        overlaps += 1 if running.positive?
        running += 1
      end
      sleep 0.02
      guard.synchronize { running -= 1 }
      ["ran (sandboxed): #{cmd}", 'ok']
    end

    calls = (1..4).map { |n| call_for(n.to_s, 'run_command', { 'command' => "echo #{n}" }) }
    @agent.run_tool_batch(calls, @events, 0)

    assert_equal 0, overlaps, 'shell commands must run one at a time'
  ensure
    Tools.singleton_class.class_eval do
      remove_method :execute_command
      alias_method :execute_command, :orig_exec
      remove_method :orig_exec
    end
  end

  def test_delegates_run_concurrently
    calls = [
      call_for('1', 'delegate', { 'task' => 'one', 'title' => 'one' }),
      call_for('2', 'delegate', { 'task' => 'two', 'title' => 'two' })
    ]

    t = Time.now
    results = @agent.run_tool_batch(calls, @events, 0)
    elapsed = Time.now - t

    assert_equal(%w[1 2], results.map { |r| r[:id] })
    assert_operator elapsed, :<, 0.09, "two 0.05s workers should overlap, took #{elapsed}s"
  end

  def test_batch_survives_a_raising_tool
    Tools.singleton_class.class_eval { alias_method :orig_call, :call }
    Tools.define_singleton_method(:call) do |name, _input|
      raise 'boom' if name == 'list_files'

      [name, 'ok']
    end

    calls = [call_for('1', 'read_file'), call_for('2', 'list_files'), call_for('3', 'read_file')]
    results = @agent.run_tool_batch(calls, @events, 0)

    assert_equal(%w[1 2 3], results.map { |r| r[:id] })
    assert_equal 'ok', results[0][:result]
    assert_match(/boom/, results[1][:result])
    assert_equal 'ok', results[2][:result]
  ensure
    Tools.singleton_class.class_eval do
      remove_method :call
      alias_method :call, :orig_call
      remove_method :orig_call
    end
  end

  def test_unparseable_call_reports_an_error_without_running
    calls = [
      call_for('1', 'read_file'),
      { id: '2', name: 'write_file', parse_error: 'unexpected token' }
    ]

    with_slow_tools do
      results = @agent.run_tool_batch(calls, @events, 0)
      assert_match(/could not parse/, results[1][:result])
    end
  end
end
