# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "../agent_cli/constants"
require_relative "../agent_cli/tools"
require_relative "../agent_cli/settings"
require_relative "base"
require_relative "openai"

class Provider
  class Groq < Provider
    MODELS = [
      { id: "llama-3.3-70b-versatile", label: "Llama 3.3 70B        — strong general + tool calling" },
      { id: "llama-3.1-8b-instant",    label: "Llama 3.1 8B Instant — fastest / cheapest" },
      { id: "openai/gpt-oss-120b",     label: "GPT-OSS 120B         — strong reasoning + tools" },
      { id: "openai/gpt-oss-20b",      label: "GPT-OSS 20B          — compact, very fast" },
      { id: "qwen/qwen3.6-27b",        label: "Qwen3.6 27B          — preview, reasoning + tools" }
    ].freeze
    DEFAULT_MODEL = "llama-3.3-70b-versatile"

    def self.id = :groq
    def self.label = "groq"
    def self.description = "Groq LPU inference — fast open models (needs GROQ_API_KEY)"
    def self.model_picker_title = "Select Groq model:"

    def api_key_env
      "GROQ_API_KEY"
    end

    def build(model_id)
      GroqProvider.new(api_key: Settings.require_api_key(api_key_env), model: model_id)
    end

    def show_model_id_in_picker?
      true
    end

    def manual_entry_hint
      "model id (e.g. llama-3.3-70b-versatile)"
    end
  end
end

# Groq Chat Completions API (OpenAI-compatible) with function calling.
class GroqProvider < OpenaiProvider
  ENDPOINT = "https://api.groq.com/openai/v1/chat/completions"
  # Groq models cap completion tokens well below our global MAX_TOKENS.
  MAX_OUT_TOKENS = 8192

  def initialize(api_key:, model:)
    @api_key = Settings.sanitize_api_key(api_key)
    @model   = model
    @uri     = URI(ENDPOINT)
  end

  def label
    "groq"
  end

  private

  def post(messages)
    key = @api_key.to_s.strip
    if key.empty?
      return { "error" => { "message" => "GROQ_API_KEY is empty — re-enter it via /providers" } }
    end

    req = Net::HTTP::Post.new(@uri)
    req["Authorization"] = "Bearer #{key}"
    req["Content-Type"]  = "application/json"

    openai_tools = Tools::DEFINITIONS.map do |t|
      {
        type: "function",
        function: {
          name: t[:name],
          description: t[:description],
          parameters: t[:input_schema]
        }
      }
    end

    req.body = JSON.generate(
      model: @model,
      max_tokens: [MAX_TOKENS, MAX_OUT_TOKENS].min,
      messages: [{ role: "system", content: SYSTEM }] + messages,
      tools: openai_tools,
      tool_choice: "auto"
    )

    res = Net::HTTP.start(@uri.host, @uri.port, use_ssl: true, read_timeout: 120) do |http|
      http.request(req)
    end
    JSON.parse(res.body)
  rescue => e
    { "error" => { "message" => "#{e.class}: #{e.message}" } }
  end
end
