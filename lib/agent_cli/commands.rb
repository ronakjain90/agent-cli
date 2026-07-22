# frozen_string_literal: true

# Slash commands available in chat.
module Commands
  ALL = [
    { name: "/providers", desc: "switch provider and model" },
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
    when "/help"
      app.show_command_help
    end
  end
end
