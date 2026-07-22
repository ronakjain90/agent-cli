# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "../agent_cli/model"
require_relative "../agent_cli/usage"
require_relative "base"

class Provider
  class Opencode < Provider
    DEFAULT_MODEL = "anthropic/claude-opus-4-8"

    def self.id = :opencode
    def self.label = "opencode"
    def self.description = "local OpenCode server — run `opencode serve` first"
    def self.model_picker_title = "Select OpenCode model:"

    def models
      []
    end

    def fetch_models
      base = URI(base_url)
      uri = base.dup
      uri.path = "/config/providers"

      req = Net::HTTP::Get.new(uri)
      password = ENV["OPENCODE_SERVER_PASSWORD"]
      req.basic_auth("opencode", password) if password

      res = Net::HTTP.start(uri.host, uri.port, read_timeout: 3, open_timeout: 3) do |http|
        http.request(req)
      end

      raise "HTTP #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)

      data = res.body.to_s.empty? ? {} : JSON.parse(res.body)
      flatten_providers(data)
    end

    def build(model_id)
      provider_id, mid = parse_model_spec(model_id)
      OpencodeProvider.new(base_url: base_url, provider_id: provider_id, model_id: mid)
    end

    def resolve_manual_input(input, model_list)
      spec = input.strip
      return spec if spec.include?("/")

      items = model_list.reject(&:other?)
      exact = items.find { |item| item.label.casecmp?(spec) }
      return exact.id if exact

      partial = items.select { |item| item.label.downcase.include?(spec.downcase) }
      return partial.first.id if partial.length == 1

      spec
    end

    def manual_entry_hint
      "model (providerID/modelID, or pick a name from the list)"
    end

    def show_model_id_in_picker?
      true
    end

    def base_url
      env_or("OPENCODE_URL", "http://127.0.0.1:4096")
    end

    def parse_model_spec(spec)
      provider_id, model_id = spec.split("/", 2)
      if model_id.nil? || model_id.empty?
        raise 'AGENT_MODEL for opencode must be "providerID/modelID" ' \
              "(got #{spec.inspect})."
      end
      [provider_id, model_id]
    end

    private

    def flatten_providers(data)
      items = []
      providers = data["providers"] || data

      case providers
      when Hash
        providers.each do |pid, prov|
          next unless prov.is_a?(Hash)

          provider_id = prov["id"] || prov["providerID"] || pid.to_s
          append_models(items, provider_id, prov["models"])
        end
      when Array
        providers.each do |prov|
          next unless prov.is_a?(Hash)

          provider_id = prov["id"] || prov["providerID"] || prov["provider"]
          append_models(items, provider_id, prov["models"])
        end
      end

      items.sort_by(&:id)
    end

    def append_models(items, provider_id, models)
      return if provider_id.nil? || provider_id.to_s.empty?
      return if models.nil?

      case models
      when Hash
        models.each { |key, model| append_model_entry(items, provider_id, key, model) }
      else
        Array(models).each do |model|
          if model.is_a?(Array) && model.length == 2
            append_model_entry(items, provider_id, model[0], model[1])
          else
            append_model_entry(items, provider_id, nil, model)
          end
        end
      end
    end

    def append_model_entry(items, provider_id, key, model)
      pid = provider_id.to_s
      return if pid.empty?

      case model
      when Hash
        mid = model["id"] || model["modelID"] || model["model"] || key.to_s
        pid = model["providerID"] || model["providerId"] || pid
        label = model["name"] || model["label"] || model["title"] || "#{pid}/#{mid}"
      when String
        mid = key.to_s
        label = model
      else
        mid = key.to_s
        return if mid.empty?

        label = mid
      end

      return if mid.nil? || mid.to_s.empty?

      items << Model.new(id: "#{pid}/#{mid}", label: label)
    end
  end
end

# Talks to a local `opencode serve` HTTP server.
class OpencodeProvider
  def initialize(base_url:, provider_id:, model_id:)
    @base       = URI(base_url)
    @provider_id = provider_id
    @model_id    = model_id
    @password    = ENV["OPENCODE_SERVER_PASSWORD"]
    @session_id  = nil
  end

  def label
    "opencode"
  end

  def model_label
    "#{@provider_id}/#{@model_id}"
  end

  def run_turn(messages, events)
    ensure_session

    last = messages.reverse.find { |m| m["role"] == "user" }
    text = last && last["content"].to_s
    unless text && !text.empty?
      events << { kind: :error, text: "no user message to send" }
      return
    end

    resp = http(:post, "/session/#{@session_id}/message", {
      model: { providerID: @provider_id, modelID: @model_id },
      parts: [{ type: "text", text: text }]
    })

    if (usage = Usage.from_opencode(resp))
      events << { kind: :usage, usage: usage }
    end

    Array(resp["parts"]).each do |part|
      case part["type"]
      when "text"
        body = part["text"].to_s
        events << { kind: :assistant, text: body } unless body.strip.empty?
      when "tool"
        name   = part["tool"] || part.dig("state", "title") || "tool"
        status = part.dig("state", "status")
        events << { kind: :tool, text: [name, status].compact.join(" · ") }
      when "patch"
        files = Array(part["files"])
        events << { kind: :tool_result, text: "patched #{files.join(", ")}" } if files.any?
      end
    end

    # OpenCode owns its own write/edit tools — pull the session diff for the panel.
    # /session/:id/diff wants the *user* message id; assistant responses expose it as parentID.
    info = resp["info"] || {}
    user_message_id =
      if info["role"] == "assistant"
        info["parentID"]
      else
        info["id"]
      end
    emit_session_diffs(events, user_message_id)
  rescue => e
    events << { kind: :error, text: "opencode: #{e.class}: #{e.message}" }
  ensure
    events << { kind: :done }
  end

  private

  def emit_session_diffs(events, message_id = nil)
    query = {}
    query[:messageID] = message_id if message_id && !message_id.to_s.empty?

    diffs = http(:get, "/session/#{@session_id}/diff", nil, query)
    Array(diffs).each do |item|
      next unless item.is_a?(Hash)

      patch = item["patch"].to_s
      next if patch.empty?

      path = item["file"] || item["path"] || "file"
      # Ensure headers so the panel can style --- / +++ lines.
      unless patch.start_with?("---") || patch.include?("\n--- ")
        patch = "--- a/#{path}\n+++ b/#{path}\n#{patch}"
      end

      events << {
        kind: :tool_result,
        text: "diff #{path} (+#{item["additions"] || 0}/-#{item["deletions"] || 0})",
        diff: patch
      }
    end
  rescue => e
    events << { kind: :tool_result, text: "diff unavailable: #{e.message}" }
  end

  def ensure_session
    return if @session_id

    resp = http(:post, "/session", { title: "agent-cli" })
    @session_id = resp["id"] or raise "session create returned no id: #{resp.inspect}"
  end

  def http(method, path, body = nil, query = nil)
    uri = @base.dup
    uri.path = path
    if query && !query.empty?
      uri.query = URI.encode_www_form(query)
    end

    req =
      case method
      when :post then Net::HTTP::Post.new(uri)
      when :get  then Net::HTTP::Get.new(uri)
      else raise ArgumentError, "unsupported method #{method}"
      end

    req["content-type"] = "application/json"
    req.basic_auth("opencode", @password) if @password
    req.body = JSON.generate(body) if body

    res = Net::HTTP.start(uri.host, uri.port, read_timeout: 300) do |http|
      http.request(req)
    end

    raise "HTTP #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)

    # Raw text responses (e.g. some diff endpoints) — return as-is string wrapped.
    content_type = res["content-type"].to_s
    if content_type.include?("json") || res.body.to_s.strip.start_with?("{", "[")
      res.body.to_s.empty? ? {} : JSON.parse(res.body)
    else
      res.body.to_s
    end
  end
end
