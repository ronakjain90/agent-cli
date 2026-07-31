# frozen_string_literal: true

require "json"
require "fileutils"

# Persists the chosen provider/model between sessions, plus an optional separate
# provider/model for worker (sub-)agents.
class Preferences
  PATH = File.expand_path("~/.config/agent-cli/preferences.json")

  # Returns { provider:, model:, worker_provider?:, worker_model?: } or nil.
  def self.load
    data = read_raw
    provider = data["provider"]&.to_sym
    model = data["model"]
    return nil if provider.nil? || model.nil? || model.empty?

    result = { provider: provider, model: model }
    wp = data["worker_provider"]
    wm = data["worker_model"]
    result[:worker_provider] = wp.to_sym if wp && !wp.to_s.empty?
    result[:worker_model] = wm if wm && !wm.to_s.empty?
    result
  end

  # Save the manager provider/model, preserving any worker settings.
  def self.save(provider_id, model_id)
    data = read_raw
    data["provider"] = provider_id.to_s
    data["model"] = model_id.to_s
    write(data)
  end

  # Save the provider/model that worker agents should use.
  def self.save_worker(provider_id, model_id)
    data = read_raw
    data["worker_provider"] = provider_id.to_s
    data["worker_model"] = model_id.to_s
    write(data)
  end

  # Remove the worker override; workers then reuse the manager's model.
  def self.clear_worker
    data = read_raw
    data.delete("worker_provider")
    data.delete("worker_model")
    write(data)
  end

  # Command prefixes the user has chosen to always allow without prompting.
  def self.allowed_commands
    data = read_raw
    list = data["allowed_commands"]
    list.is_a?(Array) ? list.select { |c| c.is_a?(String) && !c.empty? } : []
  end

  # Persist a command prefix so future matching commands skip the approval prompt.
  def self.add_allowed_command(prefix)
    prefix = prefix.to_s.strip
    return if prefix.empty?

    data = read_raw
    list = data["allowed_commands"]
    list = [] unless list.is_a?(Array)
    return if list.include?(prefix)

    list << prefix
    data["allowed_commands"] = list
    write(data)
  end

  def self.read_raw
    return {} unless File.exist?(PATH)

    data = JSON.parse(File.read(PATH))
    data.is_a?(Hash) ? data : {}
  rescue JSON::ParserError, Errno::ENOENT
    {}
  end

  def self.write(data)
    FileUtils.mkdir_p(File.dirname(PATH))
    File.write(PATH, JSON.pretty_generate(data))
  end
end
