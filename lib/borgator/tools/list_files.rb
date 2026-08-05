# frozen_string_literal: true

require_relative 'helpers'
require_relative 'registry'

module Tools
  module ListFiles
    NAME = 'list_files'
    DEFINITION = {
      name: NAME,
      description: "List files and directories under a path (default '.').",
      input_schema: {
        type: 'object',
        properties: { path: { type: 'string' } }
      }
    }.freeze

    module_function

    def call(input)
      path = input['path'] || '.'
      entries = Dir.children(path).sort.map do |e|
        File.directory?(File.join(path, e)) ? "#{e}/" : e
      end
      ["list #{path}", entries.join("\n")]
    end
  end

  Registry.register(ListFiles)
end
