# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "../agent_cli/constants"
require_relative "../agent_cli/tools"
require_relative "../agent_cli/agents"
require_relative "../agent_cli/usage"
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

    def api_key_env
      "ANTHROPIC_API_KEY"
    end

    def build(model_id)
      api_key = Settings.require_api_key(api_key_env)
      AnthropicProvider.new(api_key: api_key, model: model_id, debug: HTTP.debug_enabled)
    end
  end
end

# Anthropic Messages API tool-use loop.
class AnthropicProvider
  include Delegation

  attr_reader :model

  def initialize(api_key:, model:, debug: false)
    @api_key = api_key
    @model   = model
    @uri     = URI("https://api.anthropic.com/v1/messages")
    @log_handle = HTTP.open_log if debug
  end

  def label
    "anthropic"
  end

  def model_label
    @model
  end

  # Top-level user turn: run the manager agent, then signal completion.
  def run_turn(messages, events)
    agent_run(messages, events, system: Agents.system_for(0), tools: Agents.tools_for(0), depth: 0)
  ensure
    @log_handle&.close
    events << { kind: :done }
  end

  # One agent (manager at depth 0, worker at depth >= 1). Returns the final
  # assistant text so a manager can read a worker's report.
  def agent_run(messages, events, system:, tools:, depth:)
    final_text = nil

    MAX_STEPS.times do
      resp = post(messages, system, tools)

      if resp["type"] == "error"
        events << { kind: :error, text: resp.dig("error", "message") || resp.inspect, depth: depth }
        break
      end

      if (usage = Usage.from_anthropic(resp["usage"]))
        events << { kind: :usage, usage: usage }
      end

      tool_uses = []
      Array(resp["content"]).each do |block|
        case block["type"]
        when "text"
          final_text = block["text"]
          events << { kind: :assistant, text: block["text"], depth: depth }
        when "tool_use"
          tool_uses << block
        end
      end

      messages << { "role" => "assistant", "content" => resp["content"] }

      break if resp["stop_reason"] != "tool_use"

      calls = tool_uses.map { |tu| { id: tu["id"], name: tu["name"], input: tu["input"] } }
      results = run_tool_batch(calls, events, depth).map do |r|
        { "type" => "tool_result", "tool_use_id" => r[:id], "content" => r[:result] }
      end

      messages << { "role" => "user", "content" => results }
    end

    final_text
  end

  private

  def post(messages, system, tools)
    body = JSON.generate(
      model: @model,
      max_tokens: MAX_TOKENS,
      system: system,
      tools: tools,
      messages: messages,
      context_management: CONTEXT_MANAGEMENT
    )
    headers = {
      "x-api-key" => @api_key,
      "anthropic-version" => "2023-06-01",
      "anthropic-beta" => CONTEXT_MANAGEMENT_BETA,
      "content-type" => "application/json"
    }

    res = HTTP.request(@uri, body: body, headers: headers, read_timeout: 120,
                            log_label: "Anthropic POST", log_handle: @log_handle)
    JSON.parse(res.body)
  rescue => e
    { "type" => "error", "error" => { "message" => "#{e.class}: #{e.message}" } }
  end
end
