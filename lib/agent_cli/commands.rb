# frozen_string_literal: true

# Slash commands available in chat.
module Commands
  ALL = [
    { name: "/providers", desc: "switch provider and model" },
    { name: "/worker",    desc: "set the model workers use" },
    { name: "/agents",    desc: "explain the manager → worker flow" },
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
    when "/agents"
      app.show_agents_help
    when "/help"
      app.show_command_help
    end
  end
end
