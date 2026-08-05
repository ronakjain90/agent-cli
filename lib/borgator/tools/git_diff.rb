# frozen_string_literal: true

require 'open3'

require_relative 'helpers'
require_relative 'registry'

module Tools
  module GitDiff
    extend Helpers

    NAME = 'git_diff'
    LARGE_RESULT = true
    DEFINITION = {
      name: NAME,
      description:
        'Read-only git diff for the project. Prefer this over run_command for inspecting ' \
        'changes. Defaults to unstaged worktree changes; set staged true for the index; ' \
        'optionally pass path to scope one file/dir, or base for `git diff base`.',
      input_schema: {
        type: 'object',
        properties: {
          path: { type: 'string',
                  description: 'Optional file or directory to diff.' },
          staged: { type: 'boolean',
                    description: 'If true, show staged (index) changes via --cached. Default false.' },
          base: { type: 'string',
                  description: 'Optional revision/base to diff against (e.g. "HEAD~1" or "main"). ' \
                               'Must look like a git revision name — no flags or paths with spaces.' }
        }
      }
    }.freeze

    module_function

    def call(input)
      ensure_git_repo!
      argv = ['git', 'diff', '--no-ext-diff', '--no-color', '--find-renames']
      argv << '--cached' if truthy?(input['staged'])

      base = input['base'].to_s.strip
      unless base.empty?
        raise ArgumentError, "unsafe base revision: #{base.inspect}" unless safe_git_rev?(base)

        argv << base
      end

      path = input['path'].to_s.strip
      unless path.empty?
        resolve_project_path!(path)
        argv << '--' << path
      end

      out, status = Open3.capture2e(*argv)
      raise ArgumentError, "git diff failed: #{out.to_s.strip[0, 500]}" unless status.success?

      text = out.to_s
      return ['git_diff (empty)', 'No differences for this scope.'] if text.strip.empty?

      ["git_diff (#{text.lines.length} lines)", text]
    end
  end

  Registry.register(GitDiff)
end
