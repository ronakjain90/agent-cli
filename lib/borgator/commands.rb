# frozen_string_literal: true

require_relative 'commands/worker'

# Slash commands available in chat.
module Commands
  ALL = [
    { name: '/providers', desc: 'switch provider and model' },
    { name: '/worker',    desc: 'choose which worker model to use' },
    { name: '/models',    desc: 'manage saved model sets' },
    { name: '/init',      desc: 'read or create AGENTS.md (references CLAUDE.md if present)' },
    { name: '/agents',    desc: 'show multi-agent manager/worker help' },
    { name: '/help',      desc: 'list available commands' }
  ].freeze

  module_function

  def matching(prefix)
    return ALL.dup if prefix == '/'

    ALL.select { |cmd| cmd[:name].start_with?(prefix) }
  end

  def run(name, app, _arg = nil)
    case name
    when '/providers'
      app.open_providers_picker
    when '/worker'
      app.open_worker_picker
    when '/models'
      app.open_models_picker
    when '/init'
      app.handle_init
    when '/agents'
      app.show_agents_help
    when '/help'
      app.show_command_help
    end
  end
end
