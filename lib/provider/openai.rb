# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "../agent_cli/constants"
require_relative "../agent_cli/tools"
require_relative "../agent_cli/usage"
require_relative "base"

class Provider
  class Openai < Provider
    MODELS = [
      { id: "gpt-4o",      label: "GPT-4o           — most capable vision model" },
      { id: "gpt-4o-mini", label: "GPT-4o mini      — fast, affordable" },
      { id: "o3-mini",     label: "o3-mini          — efficient reasoning" },
      { id: "o1",          label: "o1               — advanced reasoning" }
    ].freeze
    DEFAULT_MODEL = "gpt-4o"

    def self.id = :openai
    def self.label = "openai"
    def self.description = "GPT / o-series via OpenAI API (needs OPENAI_API_KEY)"
    def self.model_picker_title = "Select OpenAI model:"

    def api_key_env
      "OPENAI_API_KEY"
    end

    def build(model_id)
      OpenaiProvider.new(api_key: Settings.require_api_key(api_key_env), model: model_id)
    end
  end
end

# OpenAI Chat Completions API with function calling.
class OpenaiProvider
  SYSTEM = <<~TXT
    You are a coding agent working in the user's current directory.
    Use the provided tools to inspect and modify files and to run commands.
    Prefer reading before writing. Keep prose brief; let the tools do the work.
  TXT

  attr_reader :model

  def initialize(api_key:, model:)
    @api_key = api_key
    @model   = model
    @uri     = URI("https://api.openai.com/v1/chat/completions")
  end

  def label
    "openai"
  end

  def model_label
    @model
  end

  # OpenAI chat completions reject huge max_tokens; keep room for tool loops.
  MAX_OUT_TOKENS = 16_384

  def run_turn(messages, events)
    MAX_STEPS.times do
      resp = post(messages)

      unless resp.is_a?(Hash)
        events << { kind: :error, text: "unexpected response: #{resp.inspect}" }
        return
      end

      if resp["error"]
        events << { kind: :error, text: resp.dig("error", "message") || resp.inspect }
        return
      end

      if (usage = Usage.from_openai(resp["usage"]))
        events << { kind: :usage, usage: usage }
      end

      choice = resp.dig("choices", 0)
      msg    = choice&.dig("message")

      unless msg
        events << { kind: :error, text: "unexpected response: #{resp.inspect}" }
        return
      end

      content = msg["content"]
      events << { kind: :assistant, text: content } if content && !content.strip.empty?

      tool_calls = msg["tool_calls"]
      break unless tool_calls&.any?

      assistant_msg = { "role" => "assistant", "content" => content }
      assistant_msg["tool_calls"] = tool_calls
      messages << assistant_msg

      tool_calls.each do |tc|
        fn   = tc["function"]
        name = fn["name"]
        args = JSON.parse(fn["arguments"]) rescue {}
        events << { kind: :tool, text: "#{name} #{JSON.generate(args)}" }
        summary, result, diff = Tools.call(name, args)
        event = { kind: :tool_result, text: summary }
        event[:diff] = diff if diff
        events << event
        messages << { "role" => "tool", "tool_call_id" => tc["id"], "content" => result.to_s }
      end
    end
  ensure
    events << { kind: :done }
  end

  private

  def post(messages)
    req = Net::HTTP::Post.new(@uri)
    req["authorization"] = "Bearer #{@api_key}"
    req["content-type"]  = "application/json"

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
    parse_response(res.body)
  rescue => e
    { "error" => { "message" => "#{e.class}: #{e.message}" } }
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

    { "error" => { "message" => "unexpected response: #{data.inspect}" } }
  rescue => e
    { "error" => { "message" => "#{e.class}: #{e.message}" } }
  end
end

