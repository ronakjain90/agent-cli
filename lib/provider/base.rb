# frozen_string_literal: true

require_relative "../agent_cli/model"
require_relative "../agent_cli/preferences"
require_relative "../agent_cli/settings"

# Metadata + factory for each provider kind.
class Provider
  class << self
    def all
      @all ||= [Anthropic.new, Openai.new, Openrouter.new, Opencode.new]
    end

    def find(id)
      all.find { |p| p.id == id }
    end

    def picker_bypassed?
      provider = ENV["AGENT_PROVIDER"]
      model = ENV["AGENT_MODEL"]
      !(provider.nil? || provider.empty?) || !(model.nil? || model.empty?)
    end

    def from_env
      kind = env_or("AGENT_PROVIDER", "anthropic")
      provider = find(kind.to_sym)
      abort "Unknown AGENT_PROVIDER #{ENV["AGENT_PROVIDER"].inspect} (expected 'anthropic', 'openai', 'openrouter', or 'opencode')." unless provider

      provider.build_from_env
    rescue => e
      abort e.message
    end

    def from_preferences
      prefs = Preferences.load
      return nil unless prefs

      provider = find(prefs[:provider])
      return nil unless provider

      provider.build(prefs[:model])
    end

    # Returns [runtime_provider, startup_error_message]
    def resolve_startup
      return [from_env, nil] if picker_bypassed?

      [from_preferences, nil]
    rescue => e
      [nil, e.message]
    end

    # Treat an unset OR exported-but-empty env var as absent.
    def env_or(name, default)
      v = ENV[name]
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
    build(self.class.env_or("AGENT_MODEL", self.class::DEFAULT_MODEL))
  end

  def resolve_manual_input(input, _model_list)
    input.strip
  end

  def manual_entry_hint
    "model id"
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
