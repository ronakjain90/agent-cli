#!/usr/bin/env ruby
# frozen_string_literal: true

# A minimal coding agent with a Charm Ruby (Bubble Tea) front-end.
#
#   The TUI   -> bubbletea + lipgloss render the chat log, prompt, spinner.
#   The brain -> a pluggable "provider". Three are built in:
#
#     * anthropic — Anthropic Messages API tool-use loop
#     * openai    — OpenAI Chat Completions with function calling
#     * opencode  — local OpenCode server (`opencode serve`)
#
# Setup:
#   gem install bubbletea lipgloss
#
#   ruby agent-cli.rb
#   # Type /providers to connect and pick a model (remembers your last choice).
#
#   # Skip the picker with env vars:
#   export ANTHROPIC_API_KEY=sk-ant-...
#   AGENT_PROVIDER=anthropic AGENT_MODEL=claude-opus-4-8 ruby agent-cli.rb
#
#   opencode serve --port 4096
#   AGENT_PROVIDER=opencode AGENT_MODEL=anthropic/claude-opus-4-8 ruby agent-cli.rb
#
# Shell execution (anthropic / openai) is OFF by default:
#   AGENT_ALLOW_SHELL=1 ruby agent-cli.rb
#
# Keys (chat):  type a request, Enter to send · /providers to switch · ctrl+c quit
# Keys (picker): ↑/↓ move · enter select · esc back · ctrl+c quit

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "agent_cli"
require "bubbletea"

runtime_provider, startup_error = Provider.resolve_startup
Bubbletea.run(AgentApp.new(runtime_provider, startup_error: startup_error), alt_screen: true)
