# frozen_string_literal: true

# Slash commands available in chat.
module Commands
  ALL = [
    { name: "/providers", desc: "switch provider and model" },
    { name: "/worker",    desc: "set the model workers use" },
    { name: "/models",    desc: "manage saved model sets" },
    { name: "/init",      desc: "read or create AGENTS.md (references CLAUDE.md if present)" },
    { name: "/help",      desc: "list available commands" }
  ].freeze

  module_function

  def matching(prefix)
    return ALL.dup if prefix == "/"

    ALL.select { |cmd| cmd[:name].start_with?(prefix) }
  end

  def run(name, app)
    case name
    when "/providers"
      app.open_providers_picker
    when "/worker"
      app.open_worker_picker
    when "/models"
      app.open_models_picker
    when "/init"
      app.handle_init
    when "/help"
      app.show_command_help
    end
  end
end