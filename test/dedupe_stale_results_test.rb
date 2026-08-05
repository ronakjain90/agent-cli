# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/borgator/agents'

class DedupeStaleResultsTest < Minitest::Test
  def openai_call(id, name, args)
    { 'role' => 'assistant', 'content' => nil,
      'tool_calls' => [{ 'id' => id, 'function' => { 'name' => name, 'arguments' => args } }] }
  end

  def openai_result(id, content)
    { 'role' => 'tool', 'tool_call_id' => id, 'content' => content }
  end

  def anthropic_call(id, name, input)
    { 'role' => 'assistant',
      'content' => [{ 'type' => 'tool_use', 'id' => id, 'name' => name, 'input' => input }] }
  end

  def anthropic_result(id, content)
    { 'role' => 'user',
      'content' => [{ 'type' => 'tool_result', 'tool_use_id' => id, 'content' => content }] }
  end

  def test_keeps_newest_read_and_blanks_the_earlier_one
    messages = [
      { 'role' => 'user', 'content' => 'look at agents.rb' },
      openai_call('a', 'read_file', '{"path": "lib/agents.rb"}'),
      openai_result('a', 'OLD FILE BODY'),
      openai_call('b', 'read_file', '{"path":"lib/agents.rb"}'),
      openai_result('b', 'NEW FILE BODY')
    ]

    Agents.dedupe_stale_results(messages)

    assert_equal Agents::SUPERSEDED_PLACEHOLDER, messages[2]['content']
    assert_equal 'NEW FILE BODY', messages[4]['content']
  end

  def test_mutates_the_caller_array_in_place
    messages = [
      openai_call('a', 'read_file', '{"path": "x.rb"}'),
      openai_result('a', 'old'),
      openai_call('b', 'read_file', '{"path": "x.rb"}'),
      openai_result('b', 'new')
    ]

    assert_same messages, Agents.dedupe_stale_results(messages)
  end

  def test_leaves_distinct_paths_alone
    messages = [
      openai_call('a', 'read_file', '{"path": "a.rb"}'),
      openai_result('a', 'body a'),
      openai_call('b', 'read_file', '{"path": "b.rb"}'),
      openai_result('b', 'body b')
    ]

    Agents.dedupe_stale_results(messages)

    assert_equal 'body a', messages[1]['content']
    assert_equal 'body b', messages[3]['content']
  end

  def test_leaves_repeated_commands_alone
    # A test run before a fix and after it are both meaningful.
    messages = [
      openai_call('a', 'run_tests', '{}'),
      openai_result('a', '3 failures'),
      openai_call('b', 'run_tests', '{}'),
      openai_result('b', '0 failures')
    ]

    Agents.dedupe_stale_results(messages)

    assert_equal '3 failures', messages[1]['content']
    assert_equal '0 failures', messages[3]['content']
  end

  def test_leaves_writes_alone
    messages = [
      openai_call('a', 'write_file', '{"path": "x.rb", "content": "v1"}'),
      openai_result('a', 'wrote x.rb'),
      openai_call('b', 'write_file', '{"path": "x.rb", "content": "v1"}'),
      openai_result('b', 'wrote x.rb')
    ]

    Agents.dedupe_stale_results(messages)

    assert_equal 'wrote x.rb', messages[1]['content']
  end

  def test_every_tool_result_keeps_its_call
    # The pairing the API validates must survive untouched.
    messages = [
      openai_call('a', 'read_file', '{"path": "x.rb"}'),
      openai_result('a', 'old'),
      openai_call('b', 'read_file', '{"path": "x.rb"}'),
      openai_result('b', 'new')
    ]

    Agents.dedupe_stale_results(messages)

    call_ids   = messages.flat_map { |m| Array(m['tool_calls']).map { |tc| tc['id'] } }
    result_ids = messages.select { |m| m['role'] == 'tool' }.map { |m| m['tool_call_id'] }
    assert_equal call_ids.sort, result_ids.sort
  end

  def test_handles_anthropic_tool_use_blocks
    messages = [
      anthropic_call('a', 'read_file', { 'path' => 'lib/agents.rb' }),
      anthropic_result('a', 'OLD FILE BODY'),
      anthropic_call('b', 'read_file', { 'path' => 'lib/agents.rb' }),
      anthropic_result('b', 'NEW FILE BODY')
    ]

    Agents.dedupe_stale_results(messages)

    assert_equal Agents::SUPERSEDED_PLACEHOLDER, messages[1]['content'][0]['content']
    assert_equal 'NEW FILE BODY', messages[3]['content'][0]['content']
  end

  def test_argument_key_order_does_not_defeat_matching
    messages = [
      openai_call('a', 'list_files', '{"path": "lib", "depth": 2}'),
      openai_result('a', 'old listing'),
      openai_call('b', 'list_files', '{"depth": 2, "path": "lib"}'),
      openai_result('b', 'new listing')
    ]

    Agents.dedupe_stale_results(messages)

    assert_equal Agents::SUPERSEDED_PLACEHOLDER, messages[1]['content']
    assert_equal 'new listing', messages[3]['content']
  end

  def test_malformed_arguments_do_not_raise
    messages = [
      openai_call('a', 'read_file', '{"path": "x.rb'),
      openai_result('a', 'old'),
      openai_call('b', 'read_file', '{"path": "x.rb'),
      openai_result('b', 'new')
    ]

    Agents.dedupe_stale_results(messages)

    assert_equal Agents::SUPERSEDED_PLACEHOLDER, messages[1]['content']
  end

  def test_three_reads_leave_only_the_newest
    messages = [
      openai_call('a', 'read_file', '{"path": "x.rb"}'), openai_result('a', 'v1'),
      openai_call('b', 'read_file', '{"path": "x.rb"}'), openai_result('b', 'v2'),
      openai_call('c', 'read_file', '{"path": "x.rb"}'), openai_result('c', 'v3')
    ]

    Agents.dedupe_stale_results(messages)

    assert_equal([Agents::SUPERSEDED_PLACEHOLDER, Agents::SUPERSEDED_PLACEHOLDER, 'v3'],
                 messages.select { |m| m['role'] == 'tool' }.map { |m| m['content'] })
  end

  def test_parallel_reads_in_one_batch_survive
    messages = [
      { 'role' => 'assistant', 'content' => nil, 'tool_calls' => [
        { 'id' => 'a', 'function' => { 'name' => 'read_file', 'arguments' => '{"path": "a.rb"}' } },
        { 'id' => 'b', 'function' => { 'name' => 'read_file', 'arguments' => '{"path": "b.rb"}' } }
      ] },
      openai_result('a', 'body a'),
      openai_result('b', 'body b')
    ]

    Agents.dedupe_stale_results(messages)

    assert_equal 'body a', messages[1]['content']
    assert_equal 'body b', messages[2]['content']
  end
end
