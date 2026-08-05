# frozen_string_literal: true

require_relative 'lib/agent_cli/version'

Gem::Specification.new do |spec|
  spec.name        = 'agent_cli'
  spec.version     = AgentCli::VERSION
  spec.authors     = ['Ronak Gothi']
  spec.email       = ['ronakjain90@gmail.com']

  spec.summary     = 'A minimal terminal coding agent with a Charm Ruby TUI and pluggable LLM providers.'
  spec.description = 'agent-cli is a small coding agent that runs in your terminal. It ships a ' \
                     'Bubble Tea / Lip Gloss TUI and speaks to Anthropic, OpenAI, OpenRouter, ' \
                     'Google, Groq, Ollama, and OpenCode. Run it from inside any project directory.'
  # TODO: set these before publishing; they only produce warnings when left unset.
  # spec.homepage  = "https://github.com/<you>/agent-cli"
  # spec.license   = "MIT"

  spec.required_ruby_version = '>= 3.1'

  # Ship the library, the executable, and the docs. The gem carries no data
  # files loaded relative to itself — AGENTS.md is read from the target project.
  spec.files = Dir['lib/**/*.rb', 'README.md']
  spec.bindir      = 'exe'
  spec.executables = ['agent-cli']
  spec.require_paths = ['lib']

  # Charm Ruby TUI stack.
  spec.add_dependency 'bubbletea', '~> 0.1'
  spec.add_dependency 'lipgloss', '~> 0.2'
  # Required explicitly by the codebase; a bundled gem on Ruby 3.4+.
  spec.add_dependency 'mutex_m', '~> 0.3'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
