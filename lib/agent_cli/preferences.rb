# frozen_string_literal: true
require "json"
require "fileutils"

# Persists the chosen provider/model between sessions, plus an optional separate
# provider/model for worker (sub-)agents, and named "model sets" the user can
# switch between quickly via the /models command.
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

  # Returns an array of saved model sets. Each entry is a hash like:
  #   { "name" => "gemini+mixtral", "provider" => "google", "model" => "gemini-2.5-flash",
  #     "worker_provider" => "openrouter", "worker_model" => "nvidia/nemotron" }
  def self.saved_models
    data = read_raw
    list = data["saved_models"]
    return [] unless list.is_a?(Array)

    list.select { |entry| entry.is_a?(Hash) && entry["name"] && entry["provider"] && entry["model"] }
  end

  # Save or overwrite a named model set. When name is nil/empty, derives a
  # name from the provider and model id (e.g. "claude:haiku", "or:nemotron").
  def self.save_model_set(name, provider_id, model_id, worker_provider: nil, worker_model: nil)
    data = read_raw
    list = data["saved_models"]
    list = [] unless list.is_a?(Array)

    name = generate_model_set_name(provider_id, model_id) if name.nil? || name.strip.empty?
    name = name.strip

    # Replace existing entry with the same name (case-insensitive).
    list.reject! { |e| e.is_a?(Hash) && e["name"].to_s.casecmp(name).zero? }

    entry = {
      "name" => name,
      "provider" => provider_id.to_s,
      "model" => model_id.to_s
    }
    if worker_model && !worker_model.to_s.empty?
      entry["worker_provider"] = (worker_provider || provider_id).to_s
      entry["worker_model"] = worker_model.to_s
    end
    list << entry

    data["saved_models"] = list
    write(data)
    entry
  end

  # Delete a saved model set by name.
  def self.delete_model_set(name)
    return false if name.nil? || name.strip.empty?

    data = read_raw
    list = data["saved_models"]
    return false unless list.is_a?(Array)

    before = list.length
    list.reject! { |e| e.is_a?(Hash) && e["name"].to_s.casecmp(name.strip).zero? }
    if list.length < before
      data["saved_models"] = list
      write(data)
      true
    else
      false
    end
  end

  # Load a saved model set into the active provider/worker config.
  def self.apply_model_set(entry)
    return false unless entry.is_a?(Hash)
    return false unless entry["provider"] && entry["model"]

    data = read_raw
    data["provider"] = entry["provider"].to_s
    data["model"] = entry["model"].to_s
    if entry["worker_model"] && !entry["worker_model"].to_s.empty?
      data["worker_provider"] = entry["worker_provider"].to_s
      data["worker_model"] = entry["worker_model"].to_s
    else
      data.delete("worker_provider")
      data.delete("worker_model")
    end
    write(data)
    true
  end

  def self.generate_model_set_name(provider_id, model_id)
    m = model_id.to_s
    # Take the model's own name: drop any vendor path prefix ("nvidia/…")
    # and any ":free"/tag suffix, leaving a clean slug like "laguna-s-2.1".
    slug = m.split("/").last.to_s.split(":").first.to_s
    slug = m if slug.empty?
    slug[0, 32]
  end

  # An explicit test command to pin for this project, overriding auto-detection
  # (the run_tests tool falls back to detection when this is unset). Set by
  # hand in the preferences file or via the AGENT_TEST_COMMAND env var.
  def self.test_command
    cmd = read_raw["test_command"]
    cmd.is_a?(String) && !cmd.strip.empty? ? cmd.strip : nil
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
