# frozen_string_literal: true

require_relative '../agent_cli/model'
require_relative '../agent_cli/preferences'
require_relative '../agent_cli/settings'

# Metadata + factory for each provider kind.
class Provider
  class << self
    def all
      @all ||= [Anthropic.new, Openai.new, Openrouter.new, Google.new, Groq.new, Ollama.new, Opencode.new]
    end

    def find(id)
      id = :google if id.to_s == 'gemini'
      all.find { |p| p.id == id.to_sym }
    end

    def picker_bypassed?
      provider = ENV.fetch('AGENT_PROVIDER', nil)
      model = ENV.fetch('AGENT_MODEL', nil)
      !(provider.nil? || provider.empty?) || !(model.nil? || model.empty?)
    end

    def from_env
      kind = env_or('AGENT_PROVIDER', 'anthropic')
      provider = find(kind.to_sym)
      unless provider
        abort "Unknown AGENT_PROVIDER #{ENV['AGENT_PROVIDER'].inspect} (expected 'anthropic', " \
              "'openai', 'openrouter', 'google', 'groq', 'ollama', or 'opencode')."
      end

      attach_worker(provider.build_from_env, kind.to_sym)
    rescue StandardError => e
      abort e.message
    end

    def from_preferences
      prefs = Preferences.load
      return nil unless prefs

      provider = find(prefs[:provider])
      return nil unless provider

      attach_worker(provider.build(prefs[:model]), prefs[:provider])
    end

    # Build the configured worker provider (its own model, possibly its own
    # provider/API key) and attach it to the manager. On any problem — no
    # worker configured, unknown provider, missing key, or a provider that
    # can't run our loop (opencode) — workers simply reuse the manager's model.
    def attach_worker(manager, default_provider_id)
      return manager unless manager.respond_to?(:worker_provider=)

      provider_id, model_id = worker_target(default_provider_id)
      return manager if model_id.nil? || model_id.to_s.empty?

      meta = find(provider_id)
      return manager unless meta

      worker = meta.build(model_id)
      return manager unless worker.respond_to?(:agent_run)
      return manager if same_target?(manager, worker)

      manager.worker_provider = worker
      manager
    rescue StandardError
      manager
    end

    # Worker [provider_id, model_id] from env (AGENT_WORKER_PROVIDER /
    # AGENT_WORKER_MODEL) or preferences. Provider defaults to the manager's.
    def worker_target(default_provider_id)
      env_model = ENV.fetch('AGENT_WORKER_MODEL', nil)
      unless env_model.nil? || env_model.empty?
        env_prov = ENV.fetch('AGENT_WORKER_PROVIDER', nil)
        pid = env_prov.nil? || env_prov.empty? ? default_provider_id : env_prov.to_sym
        return [pid, env_model]
      end

      prefs = Preferences.load
      if prefs && prefs[:worker_model]
        return [prefs[:worker_provider] || prefs[:provider] || default_provider_id, prefs[:worker_model]]
      end

      [nil, nil]
    end

    # True when the worker resolves to the same provider + model as the manager.
    def same_target?(manager, worker)
      manager.label == worker.label && manager.model_label == worker.model_label
    end

    # Returns [runtime_provider, startup_error_message]
    def resolve_startup
      return [from_env, nil] if picker_bypassed?

      [from_preferences, nil]
    rescue StandardError => e
      [nil, e.message]
    end

    # Treat an unset OR exported-but-empty env var as absent.
    def env_or(name, default)
      v = ENV.fetch(name, nil)
      v.nil? || v.empty? ? default : v
    end
  end

  def id
    self.class.id
  end

  def label
    self.class.label
  end

  def description
    self.class.description
  end

  def model_picker_title
    self.class.model_picker_title
  end

  def menu_entry
    { id: id, label: label, desc: description }
  end

  def models
    self.class::MODELS.map { |m| Model.new(id: m[:id], label: m[:label]) }
  end

  def build(_model_id)
    raise NotImplementedError
  end

  def build_from_env
    build(self.class.env_or('AGENT_MODEL', self.class::DEFAULT_MODEL))
  end

  def resolve_manual_input(input, _model_list)
    input.strip
  end

  def manual_entry_hint
    'model id'
  end

  def show_model_id_in_picker?
    false
  end

  # Env var name for this provider's API key, or nil if none needed.
  def api_key_env
    nil
  end

  def env_or(name, default)
    self.class.env_or(name, default)
  end
end
