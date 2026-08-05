# frozen_string_literal: true

require 'open3'

require_relative 'helpers'
require_relative 'registry'

module Tools
  module GitStatus
    extend Helpers

    NAME = 'git_status'
    LARGE_RESULT = true
    DEFINITION = {
      name: NAME,
      description:
        'Read-only git status for the project (branch + porcelain short status). ' \
        'Prefer this over run_command for git status — always safe, no permission prompt.',
      input_schema: {
        type: 'object',
        properties: {}
      }
    }.freeze

    module_function

    def call(_input = {})
      ensure_git_repo!
      out, status = Open3.capture2e('git', 'status', '--porcelain=v1', '-b')
      raise ArgumentError, "git status failed: #{out.to_s.strip}" unless status.success?

      text = out.to_s
      text = text.strip.empty? ? '(clean — no output)' : text
      lines = text.lines
      ["git_status (#{[lines.length - 1, 0].max} path#{'s' if lines.length != 2})", text]
    end
  end

  Registry.register(GitStatus)
end
