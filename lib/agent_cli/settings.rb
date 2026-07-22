# frozen_string_literal: true

require "json"
require "fileutils"

# Persisted settings (API keys, etc.) under ~/.agent-cli/settings.json
class Settings
  PATH = File.expand_path("~/.agent-cli/settings.json")

  class MissingApiKeyError < StandardError
    attr_reader :env_name

    def initialize(env_name)
      @env_name = env_name
      super("API key required — enter your #{env_name}")
    end
  end

  def self.load
    return {} unless File.exist?(PATH)

    data = JSON.parse(File.read(PATH))
    data.is_a?(Hash) ? data : {}
  rescue JSON::ParserError, Errno::ENOENT
    {}
  end

  def self.save(data)
    FileUtils.mkdir_p(File.dirname(PATH))
    File.write(PATH, JSON.pretty_generate(data))
  end

  # Strip terminal bracketed-paste markers that sometimes leak into pasted text.
  def self.sanitize_api_key(value)
    key = value.to_s
    key = key.gsub(/\e\[200~/, "").gsub(/\e\[201~/, "")
    key = key.gsub(/\[200~/, "").gsub(/\[201~/, "")
    key.strip
  end

  # Env var wins; otherwise read from settings.json → api_keys[ENV_NAME]
  def self.api_key(env_name)
    from_env = ENV[env_name]
    unless from_env.nil? || from_env.empty?
      cleaned = sanitize_api_key(from_env)
      return cleaned unless cleaned.empty?
    end

    cleaned = sanitize_api_key(load.dig("api_keys", env_name))
    cleaned.empty? ? nil : cleaned
  end

  def self.save_api_key(env_name, value)
    key = sanitize_api_key(value)
    raise ArgumentError, "API key cannot be empty" if key.empty?

    data = load
    data["api_keys"] ||= {}
    data["api_keys"][env_name] = key
    save(data)
    key
  end

  def self.require_api_key(env_name)
    key = api_key(env_name)
    raise MissingApiKeyError, env_name if key.nil? || key.empty?

    key
  end
end
