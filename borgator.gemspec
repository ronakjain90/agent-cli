# frozen_string_literal: true

require_relative 'lib/borgator/version'

Gem::Specification.new do |spec|
  spec.name        = 'borgator'
  spec.version     = Borgator::VERSION
  spec.authors     = ['Ronak Gothi']
  spec.email       = ['ronakjain90@gmail.com']

  spec.summary     = 'A minimal terminal coding agent with a Charm Ruby TUI and pluggable LLM providers.'
  spec.description = 'Borgator is a small coding agent that runs in your terminal. It ships a ' \
                     'Bubble Tea / Lip Gloss TUI and speaks to Anthropic, OpenAI, OpenRouter, ' \
                     'Google, Groq, Ollama, and OpenCode. Run it from inside any project directory.'
  spec.homepage    = 'https://github.com/ronakjain90/borgator'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 3.1'

  # Ship the library, the executable, and the docs. The gem carries no data
  # files loaded relative to itself — AGENTS.md is read from the target project.
  spec.files = Dir['lib/**/*.rb', 'README.md', 'LICENSE']
  spec.bindir      = 'exe'
  spec.executables = ['borgator']
  spec.require_paths = ['lib']

  # Charm Ruby TUI stack.
  spec.add_dependency 'bubbletea', '~> 0.1'
  spec.add_dependency 'lipgloss', '~> 0.2'
  # Required explicitly by the codebase; a bundled gem on Ruby 3.4+.
  spec.add_dependency 'mutex_m', '~> 0.3'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
