# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "../agent_cli/constants"
require_relative "../agent_cli/model"
require_relative "../agent_cli/tools"
require_relative "base"
require_relative "openai"

class Provider
  class Ollama < Provider
    DEFAULT_MODEL = "llama3.1"

    def self.id = :ollama
    def self.label = "ollama"
    def self.description = "local Ollama server — run `ollama serve` first"
    def self.model_picker_title = "Select Ollama model:"

    def models
      []
    end

    def fetch_models
      uri = URI.join(base_url.end_with?("/") ? base_url : "#{base_url}/", "api/tags")

      req = Net::HTTP::Get.new(uri)
      res = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 3,
        read_timeout: 5
      ) { |http| http.request(req) }

      raise "HTTP #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)

      data = res.body.to_s.empty? ? {} : JSON.parse(res.body)
      models = Array(data["models"])
      raise "no models found — run: ollama pull llama3.1" if models.empty?

      models
        .map { |m| model_entry(m) }
        .compact
        .sort_by { |m| m.label.downcase }
    end

    def build(model_id)
      OllamaProvider.new(base_url: base_url, model: model_id)
    end

    def show_model_id_in_picker?
      true
    end

    def manual_entry_hint
      "model name (e.g. llama3.1, qwen2.5-coder)"
    end

    def base_url
      env_or("OLLAMA_URL", "http://127.0.0.1:11434")
    end

    def server_hint
      "start the server: ollama serve  ·  pull a model: ollama pull llama3.1"
    end

    private

    def model_entry(raw)
      return nil unless raw.is_a?(Hash)

      name = raw["name"] || raw["model"]
      return nil if name.nil? || name.to_s.empty?

      details = raw["details"].is_a?(Hash) ? raw["details"] : {}
      size = details["parameter_size"].to_s
      family = details["family"].to_s
      bits = [family, size].reject(&:empty?).join(" · ")
      label = bits.empty? ? name.to_s : "#{name}  —  #{bits}"

      Model.new(id: name.to_s, label: label)
    end
  end
end

# Ollama OpenAI-compatible Chat Completions API with function calling.
class OllamaProvider < OpenaiProvider
  # Local models often need more wall-clock time than cloud APIs.
  READ_TIMEOUT = 300
  MAX_OUT_TOKENS = 16_384

  def initialize(base_url:, model:)
    @model = model
    base = base_url.to_s.sub(%r{/+\z}, "")
    @uri = URI("#{base}/v1/chat/completions")
  end

  def label
    "ollama"
  end

  private

  def post(messages)
    req = Net::HTTP::Post.new(@uri)
    req["Content-Type"] = "application/json"
    # Ollama ignores the key locally; some reverse proxies still expect a value.
    req["Authorization"] = "Bearer ollama"

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

    res = Net::HTTP.start(
      @uri.host, @uri.port,
      use_ssl: @uri.scheme == "https",
      open_timeout: 5,
      read_timeout: READ_TIMEOUT
    ) { |http| http.request(req) }
    parse_response(res.body)
  rescue => e
    { "error" => { "message" => "#{e.class}: #{e.message}" } }
  end
end
