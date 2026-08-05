# frozen_string_literal: true

require_relative '../diff'
require_relative '../sandbox'
require_relative 'helpers'
require_relative 'registry'

module Tools
  module EditFile
    extend Helpers

    NAME = 'edit_file'
    DEFINITION = {
      name: NAME,
      description:
        'Edit an existing file by replacing an exact snippet. Provide `old_string` copied ' \
        'VERBATIM from the file (including indentation and whitespace) and `new_string` to ' \
        'replace it with. `old_string` must be unique in the file — include a few surrounding ' \
        'lines for context if needed — or set `replace_all` to replace every occurrence. Use ' \
        'an empty `new_string` to delete the snippet. Prefer this over `write_file` for ' \
        'changes to existing files: you only send the changed lines, not the whole file.',
      input_schema: {
        type: 'object',
        properties: {
          path: { type: 'string' },
          old_string: { type: 'string', description: 'Exact text to find, copied verbatim from the file.' },
          new_string: { type: 'string', description: 'Replacement text. Empty string deletes the match.' },
          replace_all: { type: 'boolean',
                         description: 'Replace every occurrence instead of requiring a unique match. Default false.' }
        },
        required: %w[path old_string new_string]
      }
    }.freeze

    module_function

    def call(input)
      path = require_arg!(input, 'path')
      old_string = require_arg!(input, 'old_string')
      unless input.key?('new_string')
        raise ArgumentError, 'new_string is required (use an empty string to delete the matched text).'
      end

      new_string  = input['new_string'].to_s
      replace_all = input['replace_all'] ? true : false

      abs = Sandbox.ensure_writable!(path)
      raise ArgumentError, 'old_string and new_string are identical — nothing to change.' if old_string == new_string

      old_content, new_content, count = with_file_lock(path) do
        raise ArgumentError, "#{path} does not exist. Use write_file to create a new file." unless File.exist?(abs)

        old = File.read(abs)
        n = old.scan(old_string).length
        if n.zero?
          raise ArgumentError,
                "old_string was not found in #{path}. It must match the file exactly, including " \
                'whitespace and indentation. Read the file and copy the snippet verbatim.'
        end
        if n > 1 && !replace_all
          raise ArgumentError,
                "old_string matches #{n} places in #{path}. Add surrounding lines to make it " \
                "unique, or set replace_all: true to replace all #{n}."
        end

        updated = replace_all ? old.gsub(old_string, new_string) : old.sub(old_string, new_string)
        File.write(abs, updated)
        [old, updated, n]
      end

      d = Diff.unified(path, old_content, new_content)
      diff_info = d.empty? ? nil : d
      n = replace_all ? count : 1
      ["edited #{path} (#{n} replacement#{'s' if n != 1})", 'ok', diff_info]
    end
  end

  Registry.register(EditFile)
end
