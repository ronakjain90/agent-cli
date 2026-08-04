# frozen_string_literal: true

require_relative "agent_cli/version"
require_relative "agent_cli/constants"
require_relative "agent_cli/model"
require_relative "agent_cli/preferences"
require_relative "agent_cli/prompt_history"
require_relative "agent_cli/settings"
require_relative "agent_cli/usage"
require_relative "agent_cli/commands"
require_relative "agent_cli/errors"
require_relative "agent_cli/tools"
require_relative "agent_cli/agents"
require_relative "agent_cli/http"
require_relative "agent_cli/input_drain"
require_relative "provider"
require_relative "agent_cli/agent_app"

module AgentCli
  # Translate command-line flags into the env vars the rest of the app reads.
  # Both are read lazily (Tools.shell_permitted?, Http.debug?), so this only has
  # to run before the TUI starts.
  #
  #   --yolo  : skip all permission prompts for shell commands
  #   --debug : log all provider API requests/responses to log/agent-cli-<timestamp>.log
  def self.parse_flags!(argv = ARGV)
    ENV["AGENT_ALLOW_SHELL"] = "1" if argv.delete("--yolo")
    ENV["AGENT_DEBUG"] = "1" if argv.delete("--debug")
  end

  # Boot the TUI. Shared by the `agent-cli` executable and the dev entrypoint.
  def self.start
    parse_flags!
    require "bubbletea"

    InputDrain.patch!
    runtime_provider, startup_error = Provider.resolve_startup
    Bubbletea.run(
      AgentApp.new(runtime_provider, startup_error: startup_error),
      alt_screen: true,
      bracketed_paste: true
    )
  end
end
