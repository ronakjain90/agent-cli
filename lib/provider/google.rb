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
  class Google < Provider
    MODELS = [
      { id: "gemini-3.6-flash",      label: "Gemini 3.6 Flash      — free tier, fast (recommended)" },
      { id: "gemini-2.5-flash",      label: "Gemini 2.5 Flash      — free tier, large context" },
      { id: "gemini-2.5-flash-lite", label: "Gemini 2.5 Flash-Lite — free tier, cheapest/fastest" },
      { id: "gemini-2.5-pro",        label: "Gemini 2.5 Pro        — stronger reasoning (paid/trial)" }
    ].freeze
    DEFAULT_MODEL = "gemini-3.6-flash"

    def self.id = :google
    def self.label = "google"
    def self.description = "Gemini via AI Studio (needs GEMINI_API_KEY)"
    def self.model_picker_title = "Select Gemini model:"

    def api_key_env
      "GEMINI_API_KEY"
    end

    def build(model_id)
      key = Settings.api_key(api_key_env) || Settings.api_key("GOOGLE_API_KEY")
      raise Settings::MissingApiKeyError, api_key_env if key.nil? || key.empty?

      GoogleProvider.new(api_key: key, model: model_id)
    end

    def show_model_id_in_picker?
      true
    end

    def manual_entry_hint
      "model id (e.g. gemini-3.6-flash)"
    end
  end
end

# Google Gemini via AI Studio's OpenAI-compatible Chat Completions endpoint.
class GoogleProvider < OpenaiProvider
  ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
  MAX_OUT_TOKENS = 8192

  def initialize(api_key:, model:)
    @api_key = Settings.sanitize_api_key(api_key)
    @model   = model
    @uri     = URI(ENDPOINT)
  end

  def label
    "google"
  end

  private

  def post(messages)
    key = @api_key.to_s.strip
    if key.empty?
      return { "error" => { "message" => "GEMINI_API_KEY is empty — re-enter it via /providers" } }
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
