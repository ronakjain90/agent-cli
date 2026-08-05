# frozen_string_literal: true

require_relative 'borgator/version'
require_relative 'borgator/constants'
require_relative 'borgator/model'
require_relative 'borgator/preferences'
require_relative 'borgator/prompt_history'
require_relative 'borgator/settings'
require_relative 'borgator/usage'
require_relative 'borgator/commands'
require_relative 'borgator/tools'
require_relative 'borgator/agents'
require_relative 'borgator/http'
require_relative 'borgator/input_drain'
require_relative 'provider'
require_relative 'borgator/agent_app'

module Borgator
  # Translate command-line flags into the env vars the rest of the app reads.
  # Both are read lazily (Tools.shell_permitted?, Http.debug?), so this only has
  # to run before the TUI starts.
  #
  #   --yolo       : skip all permission prompts for shell commands
  #   --debug      : log all provider API requests/responses to log/borgator-<timestamp>.log
  #   --web-fetch  : enable the web_fetch tool (off by default)
  def self.parse_flags!(argv = ARGV)
    ENV['AGENT_ALLOW_SHELL'] = '1' if argv.delete('--yolo')
    ENV['AGENT_DEBUG'] = '1' if argv.delete('--debug')
    ENV['AGENT_ALLOW_WEB_FETCH'] = '1' if argv.delete('--web-fetch')
  end

  # Boot the TUI. Shared by the `borgator` executable and the dev entrypoint.
  def self.start
    parse_flags!
    require 'bubbletea'

    InputDrain.patch!
    runtime_provider, startup_error = Provider.resolve_startup
    Bubbletea.run(
      AgentApp.new(runtime_provider, startup_error: startup_error),
      alt_screen: true,
      bracketed_paste: true
    )
  end
end
