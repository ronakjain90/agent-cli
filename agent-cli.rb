#!/usr/bin/env ruby
# frozen_string_literal: true

# A minimal coding agent with a Charm Ruby (Bubble Tea) front-end.
#
#   The TUI   -> bubbletea + lipgloss render the chat log, prompt, spinner.
#   The brain -> a pluggable "provider". Built in:
#
#     * anthropic  — Anthropic Messages API tool-use loop
#     * openai     — OpenAI Chat Completions with function calling
#     * openrouter — OpenRouter gateway (free + paid models, OpenAI-compatible)
#     * google     — Google Gemini via AI Studio (OpenAI-compatible)
#     * groq       — Groq LPU inference (OpenAI-compatible)
#     * ollama     — local Ollama server (`ollama serve`)
#     * opencode   — local OpenCode server (`opencode serve`)
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
#   # API keys: env vars still work, or enter them in the TUI (saved to ~/.agent-cli/settings.json)
#   export OPENROUTER_API_KEY=sk-or-...
#   AGENT_PROVIDER=openrouter AGENT_MODEL=openai/gpt-oss-20b:free ruby agent-cli.rb
#
#   export GEMINI_API_KEY=...
#   AGENT_PROVIDER=google AGENT_MODEL=gemini-3.6-flash ruby agent-cli.rb
#
#   export GROQ_API_KEY=...
#   AGENT_PROVIDER=groq AGENT_MODEL=llama-3.3-70b-versatile ruby agent-cli.rb
#
#   ollama serve
#   ollama pull llama3.1
#   AGENT_PROVIDER=ollama AGENT_MODEL=llama3.1 ruby agent-cli.rb
#
#   opencode serve --port 4096
#   AGENT_PROVIDER=opencode AGENT_MODEL=anthropic/claude-opus-4-8 ruby agent-cli.rb
#
# Shell execution (anthropic / openai / openrouter / google / groq / ollama) asks for permission
# by default (y once · a session · n deny). Skip prompts with:
#   AGENT_ALLOW_SHELL=1 ruby agent-cli.rb
#
# Keys (chat):  type a request, Enter to send · /providers to switch · ctrl+c quit
# Keys (picker): ↑/↓ move · enter select · esc back · ctrl+c quit
# Keys (permission): y/enter allow once · a allow session · n/esc deny · ctrl+c quit

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "agent_cli"
require "bubbletea"

AgentCli::InputDrain.patch!

runtime_provider, startup_error = Provider.resolve_startup
Bubbletea.run(
  AgentApp.new(runtime_provider, startup_error: startup_error),
  alt_screen: true,
  bracketed_paste: true
)
