# frozen_string_literal: true

require_relative 'helpers'
require_relative 'registry'

module Tools
  module ReadFile
    extend Helpers

    NAME = 'read_file'
    LARGE_RESULT = true
    DEFINITION = {
      name: NAME,
      description:
        'Read a UTF-8 text file relative to the working directory. Omit ' \
        '`start_line`/`end_line` to read the whole file — do that unless you already know ' \
        'the exact region you need, or are resuming a read that came back truncated. A ' \
        'truncated read tells you the line to resume from.',
      input_schema: {
        type: 'object',
        properties: {
          path: { type: 'string' },
          start_line: { type: 'integer', description: 'First line to read (1-indexed, inclusive). Optional.' },
          end_line: { type: 'integer', description: 'Last line to read (1-indexed, inclusive). Optional.' }
        },
        required: ['path']
      }
    }.freeze

    module_function

    def call(input)
      path = require_arg!(input, 'path')
      body = with_file_lock(path) { File.read(path) }

      start_line = input['start_line']
      end_line   = input['end_line']
      ranged     = !(start_line.nil? && end_line.nil?)

      lines = body.lines
      total = lines.length
      s = (start_line || 1).to_i
      e = (end_line || total).to_i
      s = 1 if s < 1
      e = total if e > total
      if ranged && (s > e || s > total)
        raise ArgumentError,
              "requested lines #{start_line.inspect}..#{end_line.inspect} are out of range for " \
              "#{path} (#{total} lines)."
      end

      kept, last = take_within_budget(lines[(s - 1)...e] || [], s)
      truncated  = last < e

      return ["read #{path}", kept.join] unless ranged || truncated

      text = "# #{path} lines #{s}-#{last} of #{total}\n" + kept.join
      if truncated
        text += "\n" unless text.end_with?("\n")
        text += "…[truncated to fit: this read stopped at line #{last} of #{total}. " \
                "Call read_file again with start_line: #{last + 1} to continue.]"
      end
      ["read #{path} (lines #{s}-#{last}#{', truncated' if truncated})", text]
    end

    def take_within_budget(lines, first_line)
      budget = MAX_FILE_RESULT_BYTES - 512
      bytes  = 0
      kept   = []
      lines.each do |line|
        bytes += line.bytesize
        break if bytes > budget && !kept.empty?

        kept << line
      end
      [kept, first_line + kept.length - 1]
    end
  end

  Registry.register(ReadFile)
end
