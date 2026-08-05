# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/provider/openai'
require_relative '../lib/provider/anthropic'

class StepLimitTest < Minitest::Test
  class LoopingOpenai < OpenaiProvider
    attr_reader :posts

    def initialize
      @posts = 0
    end

    def post(_messages)
      @posts += 1
      {
        'choices' => [{ 'message' => {
          'content' => nil,
          'tool_calls' => [{ 'id' => "call_#{@posts}", 'type' => 'function',
                             'function' => { 'name' => 'read_file', 'arguments' => '{"path":"a.rb"}' } }]
        } }]
      }
    end
  end

  class LoopingAnthropic < AnthropicProvider
    attr_reader :posts

    def initialize
      @posts = 0
    end

    def post(_messages, _system, _tools)
      @posts += 1
      {
        'stop_reason' => 'tool_use',
        'content' => [
          { 'type' => 'text', 'text' => 'still looking' },
          { 'type' => 'tool_use', 'id' => "tu_#{@posts}", 'name' => 'read_file', 'input' => { 'path' => 'a.rb' } }
        ]
      }
    end
  end

  def setup
    @events = Queue.new
    @ran = []
    Tools.singleton_class.class_eval { alias_method :orig_call, :call }
    ran = @ran
    Tools.define_singleton_method(:call) do |name, input|
      ran << [name, input]
      ["#{name} ok", 'file body']
    end
  end

  def teardown
    Tools.singleton_class.class_eval do
      remove_method :call
      alias_method :call, :orig_call
      remove_method :orig_call
    end
  end

  def drain
    events = []
    events << @events.pop until @events.empty?
    events
  end

  def run_agent(provider, messages)
    provider.agent_run(messages, @events, system: 'sys', tools: [], depth: 0)
  end

  def test_openai_reports_the_step_limit_instead_of_stopping_silently
    provider = LoopingOpenai.new
    run_agent(provider, [{ 'role' => 'user', 'content' => 'go' }])

    assert_equal MAX_STEPS, provider.posts
    limit = drain.select { |e| e[:kind] == :error }
    assert_equal 1, limit.length
    assert_match(/step limit reached/, limit.first[:text])
  end

  # An unanswered tool_call is a 400 on the next request.
  def test_openai_leaves_every_recorded_tool_call_answered
    messages = [{ 'role' => 'user', 'content' => 'go' }]
    run_agent(LoopingOpenai.new, messages)

    requested = messages.flat_map { |m| Array(m['tool_calls']).map { |tc| tc['id'] } }
    answered  = messages.select { |m| m['role'] == 'tool' }.map { |m| m['tool_call_id'] }

    assert_equal requested.sort, answered.sort
    refute_empty requested
  end

  def test_openai_does_not_run_tools_it_cannot_report
    run_agent(LoopingOpenai.new, [{ 'role' => 'user', 'content' => 'go' }])

    assert_equal MAX_STEPS - 1, @ran.length
  end

  def test_anthropic_reports_the_step_limit
    provider = LoopingAnthropic.new
    run_agent(provider, [{ 'role' => 'user', 'content' => 'go' }])

    assert_equal MAX_STEPS, provider.posts
    limit = drain.select { |e| e[:kind] == :error }
    assert_equal 1, limit.length
    assert_match(/step limit reached/, limit.first[:text])
  end

  def test_anthropic_leaves_every_recorded_tool_use_answered
    messages = [{ 'role' => 'user', 'content' => 'go' }]
    run_agent(LoopingAnthropic.new, messages)

    blocks = messages.flat_map { |m| m['content'].is_a?(Array) ? m['content'] : [] }
    requested = blocks.select { |b| b['type'] == 'tool_use' }.map { |b| b['id'] }
    answered  = blocks.select { |b| b['type'] == 'tool_result' }.map { |b| b['tool_use_id'] }

    assert_equal requested.sort, answered.sort
    refute_empty requested
  end

  def test_anthropic_keeps_the_final_text_without_the_pending_tool_use
    messages = [{ 'role' => 'user', 'content' => 'go' }]
    run_agent(LoopingAnthropic.new, messages)

    last = messages.last
    assert_equal 'assistant', last['role']
    assert_equal [{ 'type' => 'text', 'text' => 'still looking' }], last['content']
  end

  def test_manager_turn_through_run_turn_reports_the_step_limit
    provider = LoopingOpenai.new
    provider.run_turn([{ 'role' => 'user', 'content' => 'go' }], @events)

    events = drain
    limit = events.select { |e| e[:kind] == :error }

    assert_equal 1, limit.length
    assert_equal 0, limit.first[:depth]
    assert_match(/this turn used all #{MAX_STEPS} tool-loop steps/, limit.first[:text])
    assert_equal :done, events.last[:kind]
    assert_operator events.index(limit.first), :<, events.index(events.last)
  end

  def test_anthropic_manager_turn_through_run_turn_reports_the_step_limit
    provider = LoopingAnthropic.new
    provider.run_turn([{ 'role' => 'user', 'content' => 'go' }], @events)

    limit = drain.select { |e| e[:kind] == :error }

    assert_equal 1, limit.length
    assert_equal 0, limit.first[:depth]
    assert_match(/this turn used all/, limit.first[:text])
  end

  def test_manager_transcript_stays_resumable_after_the_cap
    messages = [{ 'role' => 'user', 'content' => 'go' }]
    LoopingOpenai.new.run_turn(messages, @events)
    messages << { 'role' => 'user', 'content' => 'continue' }

    pending = messages.each_with_object([]) do |m, ids|
      Array(m['tool_calls']).each { |tc| ids << tc['id'] }
      ids.delete(m['tool_call_id']) if m['role'] == 'tool'
    end

    assert_empty pending, 'unanswered tool_calls would 400 the follow-up request'
    assert_equal 'user', messages.last['role']
  end

  def test_a_normal_turn_reports_no_step_limit
    provider = LoopingOpenai.new
    def provider.post(_messages)
      { 'choices' => [{ 'message' => { 'content' => 'done', 'tool_calls' => nil } }] }
    end

    assert_equal 'done', run_agent(provider, [{ 'role' => 'user', 'content' => 'go' }])
    assert_empty(drain.select { |e| e[:kind] == :error })
  end
end
