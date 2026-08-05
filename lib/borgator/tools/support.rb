# frozen_string_literal: true

require_relative '../constants'
require_relative '../preferences'
require_relative '../sandbox'

# Shared runtime for modular tools. Safe to load without the rest of the
# harness — each tool file requires this (via helpers/registry) so it can be
# required and tested on its own.
module Tools
  APPROVAL_MUTEX = Mutex.new unless const_defined?(:APPROVAL_MUTEX, false)
  RATE_MUTEX     = Mutex.new unless const_defined?(:RATE_MUTEX, false)

  DEFAULT_ALLOWED = [
    'git status', 'git log', 'git diff', 'git show', 'git branch',
    'git remote', 'git rev-parse', 'git describe', 'git blame',
    'git ls-files', 'git shortlog', 'git tag', 'git stash list',
    'git config --get', 'git config --list'
  ].freeze unless const_defined?(:DEFAULT_ALLOWED, false)

  SUBCOMMAND_TOOLS = %w[git gh npm yarn pnpm bundle cargo go docker kubectl].freeze \
    unless const_defined?(:SUBCOMMAND_TOOLS, false)

  SHELL_METACHARS = /[;&|`><\n]|\$\(/ unless const_defined?(:SHELL_METACHARS, false)

  SAFE_TEST_RUNNERS = %w[
    bin/rspec rspec bin/rails bundle rake test pytest go cargo test npm npx yarn pnpm ruby
  ].freeze unless const_defined?(:SAFE_TEST_RUNNERS, false)

  COMMAND_ALIASES = %w[shell bash sh zsh run_shell run_bash execute exec terminal command].freeze \
    unless const_defined?(:COMMAND_ALIASES, false)

  # Not frozen: registry of per-path mutexes filled at runtime.
  FILE_LOCKS = {} unless const_defined?(:FILE_LOCKS, false) # rubocop:disable Style/MutableConstant
  FILE_LOCKS_MUTEX = Mutex.new unless const_defined?(:FILE_LOCKS_MUTEX, false)
  SHELL_MUTEX = Mutex.new unless const_defined?(:SHELL_MUTEX, false)

  SEARCH_SKIP_DIRS = %w[
    .git node_modules vendor tmp log .bundle .ruby-lsp .idea vendor/bundle
  ].freeze unless const_defined?(:SEARCH_SKIP_DIRS, false)

  class << self
    attr_accessor :approver unless method_defined?(:approver)

    def session_shell?
      @session_shell
    end

    def allow_shell_session!
      @session_shell = true
    end

    def reset_session!
      @session_shell = false
      RATE_MUTEX.synchronize { @command_times = [] }
    end

    def web_fetch_enabled?
      ENV['AGENT_ALLOW_WEB_FETCH'] == '1'
    end

    def rate_limit_ok?(now = Time.now.to_f)
      RATE_MUTEX.synchronize do
        @command_times ||= []
        cutoff = now - COMMAND_RATE_WINDOW
        @command_times.reject! { |t| t < cutoff }
        return false if @command_times.length >= MAX_COMMANDS_PER_WINDOW

        @command_times << now
        true
      end
    end

    def shell_permitted?
      ENV['AGENT_ALLOW_SHELL'] == '1' || session_shell?
    end

    def auto_allowed?(cmd)
      norm = cmd.to_s.strip
      return false if norm.empty? || norm.match?(SHELL_METACHARS)

      allowlist.any? { |prefix| norm == prefix || norm.start_with?("#{prefix} ") }
    end

    def allowlist
      DEFAULT_ALLOWED + Preferences.allowed_commands
    end

    def persist_prefix(cmd)
      tokens = cmd.to_s.strip.split(/\s+/)
      return cmd.to_s.strip if tokens.empty?

      count = SUBCOMMAND_TOOLS.include?(tokens[0]) ? 2 : 1
      tokens.first(count).join(' ')
    end

    # Used by RunCommand; stubs on Tools intercept here for tests.
    def execute_command(cmd, argv, skip_permission)
      raise NameError, 'Tools::RunCommand is not loaded' unless const_defined?(:RunCommand)

      RunCommand.execute(cmd, argv, skip_permission)
    end

    def request_permission(tool, detail)
      return :deny unless approver

      APPROVAL_MUTEX.synchronize { approver.call(tool, detail) }
    end
  end
end
