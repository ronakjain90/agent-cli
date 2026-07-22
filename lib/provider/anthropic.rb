# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "../agent_cli/constants"
require_relative "../agent_cli/tools"
require_relative "base"

class Provider
  class Anthropic < Provider
    MODELS = [
      { id: "claude-opus-4-8", label: "Claude Opus 4.8   — most capable, best for agentic coding" },
      { id: "claude-sonnet-5", label: "Claude Sonnet 5   — near-Opus quality, faster and cheaper" },
      { id: "claude-haiku-4-5", label: "Claude Haiku 4.5  — fastest and most cost-effective" },
      { id: "claude-fable-5",  label: "Claude Fable 5    — frontier reasoning / long-horizon work" },
      { id: "claude-opus-4-7", label: "Claude Opus 4.7   — previous-generation Opus" }
    ].freeze
    DEFAULT_MODEL = "claude-opus-4-8"

    def self.id = :anthropic
    def self.label = "anthropic"
    def self.description = "Claude via Anthropic API (needs ANTHROPIC_API_KEY)"
    def self.model_picker_title = "Select Claude model:"

    def build(model_id)
      key = ENV["ANTHROPIC_API_KEY"]
      raise "Set ANTHROPIC_API_KEY for the anthropic provider. Export it and try again." if key.nil? || key.empty?

      AnthropicProvider.new(api_key: key, model: model_id)
    end
  end
end

# Anthropic Messages API tool-use loop.
class AnthropicProvider
  SYSTEM = <<~TXT
    You are a coding agent working in the user's current directory.
    Use the provided tools to inspect and modify files and to run commands.
    Prefer reading before writing. Keep prose brief; let the tools do the work.
  TXT

  attr_reader :model

  def initialize(api_key:, model:)
    @api_key = api_key
    @model   = model
    @uri     = URI("https://api.anthropic.com/v1/messages")
  end

  def label
    "anthropic"
  end

  def model_label
    @model
  end

  def run_turn(messages, events)
    MAX_STEPS.times do
      resp = post(messages)

      if resp["type"] == "error"
        events << { kind: :error, text: resp.dig("error", "message") || resp.inspect }
        return
      end

      tool_uses = []
      Array(resp["content"]).each do |block|
        case block["type"]
        when "text"     then events << { kind: :assistant, text: block["text"] }
        when "tool_use" then tool_uses << block
        end
      end

      messages << { "role" => "assistant", "content" => resp["content"] }

      break if resp["stop_reason"] != "tool_use"

      results = tool_uses.map do |tu|
        events << { kind: :tool, text: "#{tu["name"]} #{JSON.generate(tu["input"])}" }
        summary, result, diff = Tools.call(tu["name"], tu["input"] || {})
        event = { kind: :tool_result, text: summary }
        event[:diff] = diff if diff
        events << event
        { "type" => "tool_result", "tool_use_id" => tu["id"], "content" => result.to_s }
      end

      messages << { "role" => "user", "content" => results }
    end
  ensure
    events << { kind: :done }
  end

  private

  def post(messages)
    req = Net::HTTP::Post.new(@uri)
    req["x-api-key"]         = @api_key
    req["anthropic-version"] = "2023-06-01"
    req["content-type"]      = "application/json"
    req.body = JSON.generate(
      model: @model,
      max_tokens: MAX_TOKENS,
      system: SYSTEM,
      tools: Tools::DEFINITIONS,
      messages: messages
    )

    res = Net::HTTP.start(@uri.host, @uri.port, use_ssl: true, read_timeout: 120) do |http|
      http.request(req)
    end
    JSON.parse(res.body)
  rescue => e
    { "type" => "error", "error" => { "message" => "#{e.class}: #{e.message}" } }
  end
end
