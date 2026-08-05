# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

require_relative '../agent_cli/constants'
require_relative '../agent_cli/tools'
require_relative '../agent_cli/settings'
require_relative 'base'
require_relative 'openai'

class Provider
  class Groq < Provider
    MODELS = [
      { id: 'llama-3.3-70b-versatile', label: 'Llama 3.3 70B        — strong general + tool calling' },
      { id: 'llama-3.1-8b-instant',    label: 'Llama 3.1 8B Instant — fastest / cheapest' },
      { id: 'openai/gpt-oss-120b',     label: 'GPT-OSS 120B         — strong reasoning + tools' },
      { id: 'openai/gpt-oss-20b',      label: 'GPT-OSS 20B          — compact, very fast' },
      { id: 'qwen/qwen3.6-27b',        label: 'Qwen3.6 27B          — preview, reasoning + tools' }
    ].freeze
    DEFAULT_MODEL = 'llama-3.3-70b-versatile'

    def self.id = :groq
    def self.label = 'groq'
    def self.description = 'Groq LPU inference — fast open models (needs GROQ_API_KEY)'
    def self.model_picker_title = 'Select Groq model:'

    def api_key_env
      'GROQ_API_KEY'
    end

    def build(model_id)
      GroqProvider.new(api_key: Settings.require_api_key(api_key_env), model: model_id, debug: HTTP.debug_enabled)
    end

    def show_model_id_in_picker?
      true
    end

    def manual_entry_hint
      'model id (e.g. llama-3.3-70b-versatile)'
    end
  end
end

# Groq Chat Completions API (OpenAI-compatible) with function calling.
class GroqProvider < OpenaiProvider
  ENDPOINT = 'https://api.groq.com/openai/v1/chat/completions'
  # Groq models cap completion tokens well below our global MAX_TOKENS.
  MAX_OUT_TOKENS = 8192

  def initialize(api_key:, model:, debug: false)
    @api_key = Settings.sanitize_api_key(api_key)
    @model   = model
    @uri     = URI(ENDPOINT)
    @log_handle = HTTP.open_log if debug
  end

  def label
    'groq'
  end

  private

  def post(messages)
    key = @api_key.to_s.strip
    return { 'error' => { 'message' => 'GROQ_API_KEY is empty — re-enter it via /providers' } } if key.empty?

    body = JSON.generate(
      model: @model,
      max_tokens: [MAX_TOKENS, MAX_OUT_TOKENS].min,
      messages: [{ role: 'system', content: active_system }] + messages,
      tools: openai_tool_schemas,
      tool_choice: 'auto'
    )
    headers = {
      'Authorization' => "Bearer #{key}",
      'Content-Type' => 'application/json'
    }

    res = HTTP.request(@uri, body: body, headers: headers, read_timeout: 120,
                             log_label: 'Groq POST', log_handle: @log_handle)
    parse_response(res.body)
  rescue StandardError => e
    { 'error' => { 'message' => "#{e.class}: #{e.message}" } }
  end
end
