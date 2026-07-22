# frozen_string_literal: true

require "json"
require "fileutils"

# Persists the last chosen provider and model between sessions.
class Preferences
  PATH = File.expand_path("~/.config/agent-cli/preferences.json")

  def self.load
    return nil unless File.exist?(PATH)

    data = JSON.parse(File.read(PATH))
    provider = data["provider"]&.to_sym
    model = data["model"]
    return nil if provider.nil? || model.nil? || model.empty?

    { provider: provider, model: model }
  rescue JSON::ParserError, Errno::ENOENT
    nil
  end

  def self.save(provider_id, model_id)
    FileUtils.mkdir_p(File.dirname(PATH))
    File.write(PATH, JSON.pretty_generate(
      "provider" => provider_id.to_s,
      "model" => model_id.to_s
    ))
  end
end
