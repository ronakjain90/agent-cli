# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "../agent_cli/constants"
require_relative "../agent_cli/tools"
require_relative "base"
require_relative "openai"

class Provider
  class Openrouter < Provider
    # Prefer free tool-calling models for smoke-testing; paid models work with credits.
    # Free IDs change over time — use "other…" or OpenRouter's model list if one 404s.
    MODELS = [
      { id: "openrouter/auto",                        label: "Auto                    — OpenRouter picks a model" },
      { id: "openai/gpt-oss-20b:free",                label: "GPT-OSS 20B (free)      — free, tool-calling" },
      { id: "tencent/hy3:free",                       label: "Hy3 (free)              — free, 295B MoE coding" },
      { id: "google/gemma-4-31b-it:free",              label: "Gemma 4 31B (free)      — free, large context" },
      { id: "cohere/north-mini-code:free",            label: "North Mini Code (free)  — free, coding-focused" },
      { id: "nvidia/nemotron-3-super-120b-a12b:free", label: "Nemotron 3 Super (free) — free, strong general" },
      { id: "anthropic/claude-sonnet-4.5",            label: "Claude Sonnet 4.5       — paid via OpenRouter" },
      { id: "openai/gpt-4o-mini",                     label: "GPT-4o mini             — paid via OpenRouter" },
      { id: "google/gemini-2.5-flash",                label: "Gemini 2.5 Flash        — paid via OpenRouter" }
    ].freeze
    DEFAULT_MODEL = "openai/gpt-oss-20b:free"

    def self.id = :openrouter
    def self.label = "openrouter"
    def self.description = "OpenRouter gateway — free + paid models (needs OPENROUTER_API_KEY)"
    def self.model_picker_title = "Select OpenRouter model:"

    def api_key_env
      "OPENROUTER_API_KEY"
    end

    def build(model_id)
      OpenrouterProvider.new(api_key: Settings.require_api_key(api_key_env), model: model_id)
    end

    def show_model_id_in_picker?
      true
    end

    def manual_entry_hint
      "model id (e.g. openai/gpt-oss-20b:free)"
    end
  end
end

# OpenRouter Chat Completions API (OpenAI-compatible) with function calling.
class OpenrouterProvider < OpenaiProvider
  ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
  # OpenRouter / free models often reject huge max_tokens.
  MAX_OUT_TOKENS = 8192

  def initialize(api_key:, model:)
    @api_key = Settings.sanitize_api_key(api_key)
    @model   = model
    @uri     = URI(ENDPOINT)
    @site_url  = env_blank("OPENROUTER_SITE_URL", "https://github.com/local/agent-cli")
    @site_name = env_blank("OPENROUTER_SITE_NAME", "agent-cli")
  end

  def label
    "openrouter"
  end

  private

  def env_blank(name, default)
    v = ENV[name]
    v.nil? || v.empty? ? default : v
  end

  def post(messages)
    key = @api_key.to_s.strip
    if key.empty?
      return { "error" => { "message" => "OPENROUTER_API_KEY is empty — re-enter it via /providers" } }
    end

    req = Net::HTTP::Post.new(@uri)
    req["Authorization"] = "Bearer #{key}"
    req["Content-Type"]  = "application/json"
    req["HTTP-Referer"]  = @site_url
    req["X-Title"]       = @site_name

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
