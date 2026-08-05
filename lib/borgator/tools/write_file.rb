# frozen_string_literal: true

require_relative '../diff'
require_relative '../sandbox'
require_relative 'helpers'
require_relative 'registry'

module Tools
  module WriteFile
    extend Helpers

    NAME = 'write_file'
    DEFINITION = {
      name: NAME,
      description:
        "Create a NEW file, or completely replace a file's contents. For changing part " \
        'of an existing file, prefer `edit_file` — it needs far less text and is less ' \
        'error-prone.',
      input_schema: {
        type: 'object',
        properties: { path: { type: 'string' }, content: { type: 'string' } },
        required: %w[path content]
      }
    }.freeze

    module_function

    def call(input)
      path = require_arg!(input, 'path')
      abs = Sandbox.ensure_writable!(path)
      new_content = input['content'].to_s

      old_content, existed = with_file_lock(path) do
        existed = File.exist?(abs)
        old = existed ? File.read(abs) : ''
        File.write(abs, new_content)
        [old, existed]
      end

      d = Diff.unified(path, old_content, new_content)
      diff_info = d.empty? ? nil : d
      verb = existed ? 'wrote' : 'created'
      label = "#{verb} #{path} (#{new_content.bytesize} bytes)"
      [label, 'ok', diff_info]
    end
  end

  Registry.register(WriteFile)
end
