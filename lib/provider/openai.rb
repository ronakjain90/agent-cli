# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

require_relative '../borgator/constants'
require_relative '../borgator/tools'
require_relative '../borgator/agents'
require_relative '../borgator/usage'
require_relative 'base'

class Provider
  class Openai < Provider
    MODELS = [
      { id: 'gpt-4o',      label: 'GPT-4o           — most capable vision model' },
      { id: 'gpt-4o-mini', label: 'GPT-4o mini      — fast, affordable' },
      { id: 'o3-mini',     label: 'o3-mini          — efficient reasoning' },
      { id: 'o1',          label: 'o1               — advanced reasoning' }
    ].freeze
    DEFAULT_MODEL = 'gpt-4o'

    def self.id = :openai
    def self.label = 'openai'
    def self.description = 'GPT / o-series via OpenAI API (needs OPENAI_API_KEY)'
    def self.model_picker_title = 'Select OpenAI model:'

    def api_key_env
      'OPENAI_API_KEY'
    end

    def build(model_id)
      OpenaiProvider.new(api_key: Settings.require_api_key(api_key_env), model: model_id, debug: HTTP.debug_enabled)
    end
  end
end

# OpenAI Chat Completions API with function calling.
class OpenaiProvider
  include Delegation

  # Default system prompt when no agent role is active (kept for compatibility).
  SYSTEM = Agents::MANAGER_SYSTEM

  DEFAULT_ENDPOINT = 'https://api.openai.com/v1/chat/completions'

  # OpenAI's largest models cap completions at 16k tokens; subclasses override
  # with lower limits for models that can't handle that.
  MAX_OUT_TOKENS = 16_384

  attr_reader :model, :uri

  def initialize(api_key:, model:, debug: false)
    @api_key = api_key
    @model   = model
    @uri     = URI(DEFAULT_ENDPOINT)
    @log_handle = HTTP.open_log if debug
  end

  def label
    'openai'
  end

  def model_label
    @model
  end

  # OpenAI context windows differ by model; 200k is a safe default that covers
  # the o1/o3-mini/gpt-4o family.
  def context_window
    case @model
    when 'o1', 'o3-mini', 'gpt-4o', 'gpt-4o-mini' then 128_000
    else 200_000
    end
  end

  # Top-level user turn: run the manager agent, then signal completion.
  def run_turn(messages, events)
    agent_run(messages, events, system: Agents.system_for(0), tools: Agents.tools_for(0), depth: 0)
  ensure
    events << { kind: :done }
  end

  # One agent (manager at depth 0, worker at depth >= 1). Returns the final
  # assistant text so a manager can read a worker's report. `post` reads the
  # active system/tools set here (subclasses keep a single-arg `post`).
  def agent_run(messages, events, system:, tools:, depth:)
    final_text = nil
    steps_left = MAX_STEPS

    while steps_left.positive?
      steps_left -= 1
      # Thread-local so parallel workers (possibly at different depths) don't
      # clobber each other's system prompt / tool set through shared state.
      Thread.current[:agent_active_system] = system
      Thread.current[:agent_active_tools]  = tools
      resp = post(messages)

      unless resp.is_a?(Hash)
        events << { kind: :error, text: "unexpected response: #{resp.inspect}", depth: depth }
        break
      end

      if resp['error']
        events << { kind: :error, text: resp.dig('error', 'message') || resp.inspect, depth: depth }
        break
      end

      if (usage = Usage.from_openai(resp['usage']))
        events << { kind: :usage, usage: usage }
      end

      choice = resp.dig('choices', 0)
      msg    = choice&.dig('message')

      unless msg
        events << { kind: :error, text: "unexpected response: #{resp.inspect}", depth: depth }
        break
      end

      content = msg['content']
      if content && !content.strip.empty?
        final_text = content
        events << { kind: :assistant, text: content, depth: depth }
      end

      tool_calls = msg['tool_calls']
      break unless tool_calls&.any?

      # Recording these calls would leave them unanswered, which the API rejects
      # on every later request too.
      if steps_left.zero?
        events << Agents.step_limit_event(depth)
        break
      end

      assistant_msg = { 'role' => 'assistant', 'content' => content }
      assistant_msg['tool_calls'] = tool_calls
      messages << assistant_msg

      calls = tool_calls.map do |tc|
        fn  = tc['function'] || {}
        raw = fn['arguments'].to_s
        parsed = raw.strip.empty? ? {} : JSON.parse(raw)
        { id: tc['id'], name: fn['name'], input: parsed }
      rescue JSON::ParserError => e
        # Weak models often emit malformed JSON for large payloads (e.g. a
        # write_file `content` full of code). Don't swallow it into `{}` — that
        # silently drops the edit. Surface it so the model re-issues valid JSON.
        fn = tc['function'] || {}
        { id: tc['id'], name: fn['name'], parse_error: e.message }
      end
      run_tool_batch(calls, events, depth).each do |r|
        messages << { 'role' => 'tool', 'tool_call_id' => r[:id], 'content' => r[:result] }
      end
      messages = Agents.trim_messages(messages)
    end

    final_text
  end

  # System prompt / tool schemas for the current agent_run step. `post`
  # overrides in subclasses read these so every provider shares role handling.
  def active_system
    Thread.current[:agent_active_system] || SYSTEM
  end

  def active_tools
    Thread.current[:agent_active_tools] || Tools.definitions
  end

  def openai_tool_schemas
    active_tools.map do |t|
      {
        type: 'function',
        function: {
          name: t[:name],
          description: t[:description],
          parameters: t[:input_schema]
        }
      }
    end
  end

  private

  # Hook for subclasses to set a log-friendly name in HTTP traces.
  def log_label
    'OpenAI POST'
  end

  # Build the auth + content-type headers. Subclasses add provider-specific
  # headers (e.g. OpenRouter's HTTP-Referer / X-Title) by overriding this.
  def build_headers
    {
      'authorization' => "Bearer #{auth_token}",
      'content-type' => 'application/json'
    }
  end

  # The API key to send (sanitized, stripped). Defaults to @api_key.
  def auth_token
    @api_key.to_s.strip
  end

  # Default per-request read timeout for all OpenAI-compatible providers.
  def read_timeout
    120
  end

  def post(messages)
    body = JSON.generate(
      model: @model,
      max_tokens: [MAX_TOKENS, MAX_OUT_TOKENS].min,
      messages: [{ role: 'system', content: active_system }] + messages,
      tools: openai_tool_schemas,
      tool_choice: 'auto'
    )
    headers = build_headers

    res = HTTP.request(@uri, body: body, headers: headers, read_timeout: read_timeout,
                             log_label: log_label, log_handle: @log_handle)
    parse_response(res.body)
  rescue StandardError => e
    { 'error' => { 'message' => "#{e.class}: #{e.message}" } }
  end

  def parse_response(body)
    data = JSON.parse(body.to_s)
    if data.is_a?(String)
      begin
        nested = JSON.parse(data)
        data = nested if nested.is_a?(Hash)
      rescue JSON::ParserError
        # keep the original string value
      end
    end
    return data if data.is_a?(Hash)

    { 'error' => { 'message' => "unexpected response: #{data.inspect}" } }
  rescue StandardError => e
    { 'error' => { 'message' => "#{e.class}: #{e.message}" } }
  end
end
