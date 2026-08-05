# frozen_string_literal: true

require 'open3'

require_relative '../sandbox'
require_relative 'helpers'
require_relative 'registry'

module Tools
  module SearchCode
    extend Helpers

    NAME = 'search_code'
    LARGE_RESULT = true
    DEFINITION = {
      name: NAME,
      description:
        'Search the codebase for a string or regex. Prefer this over run_command + grep: ' \
        'it returns path:line hits with short context (not whole files). Use results to ' \
        'decide which files to open with read_file (ideally a line range around the hit).',
      input_schema: {
        type: 'object',
        properties: {
          query: { type: 'string',
                   description: 'Pattern to search for. Treated as a regex unless fixed_string is true.' },
          path: { type: 'string',
                  description: "Subdirectory or file to search under (default '.')." },
          glob: { type: 'string',
                  description: 'Optional glob filter, e.g. "*.rb" or "**/*_test.rb".' },
          fixed_string: { type: 'boolean',
                          description: 'If true, treat query as a literal string, not a regex. Default false.' },
          case_insensitive: { type: 'boolean',
                              description: 'Case-insensitive search. Default false.' },
          max_matches: { type: 'integer',
                         description: "Max matching lines to return (default #{SEARCH_DEFAULT_MAX_MATCHES}, " \
                                      "cap #{SEARCH_MAX_MATCHES_CAP})." }
        },
        required: ['query']
      }
    }.freeze

    module_function

    def call(input)
      query = require_arg!(input, 'query')
      path  = (input['path'] || '.').to_s
      resolve_project_path!(path)

      max = input['max_matches']
      max = max.nil? ? SEARCH_DEFAULT_MAX_MATCHES : max.to_i
      max = SEARCH_DEFAULT_MAX_MATCHES if max < 1
      max = SEARCH_MAX_MATCHES_CAP if max > SEARCH_MAX_MATCHES_CAP

      fixed = truthy?(input['fixed_string'])
      ignore_case = truthy?(input['case_insensitive'])
      glob = input['glob'].to_s.strip
      glob = nil if glob.empty?

      hits, backend = if rg_available?
                        search_with_rg(query, path, max, fixed, ignore_case, glob)
                      else
                        [search_with_ruby(query, path, max, fixed, ignore_case, glob), 'ruby']
                      end

      if hits.empty?
        return ["search_code (#{backend}): no matches",
                "No matches for #{query.inspect} under #{path}" \
                "#{glob ? " (glob: #{glob})" : ''}."]
      end

      body = hits.join("\n")
      note = hits.length >= max ? "\n…[hit max_matches=#{max}; narrow query/path/glob for more]" : ''
      ["search_code (#{backend}): #{hits.length} hit#{'s' if hits.length != 1}", body + note]
    end

    def search_with_rg(query, path, max, fixed, ignore_case, glob)
      argv = ['rg', '--line-number', '--no-heading', '--color', 'never',
              '--max-count', max.to_s]
      argv << '--fixed-strings' if fixed
      argv << '--ignore-case' if ignore_case
      argv += ['--glob', glob] if glob
      argv += ['--max-filesize', '1M', '--', query, path]

      out, status = Open3.capture2e(*argv)
      lines = out.to_s.lines.map(&:chomp).reject(&:empty?)
      if !status.success? && status.exitstatus.to_i > 1 && lines.empty?
        raise ArgumentError, "ripgrep failed: #{out.to_s.strip[0, 500]}"
      end

      [lines.first(max), 'rg']
    end

    def search_with_ruby(query, path, max, fixed, ignore_case, glob)
      pattern = if fixed
                  Regexp.new(Regexp.escape(query), ignore_case ? Regexp::IGNORECASE : 0)
                else
                  Regexp.new(query, ignore_case ? Regexp::IGNORECASE : 0)
                end
      root = File.expand_path(path, Sandbox.root)
      hits = []
      each_search_file(root, glob) do |file, rel|
        File.foreach(file).with_index(1) do |line, n|
          next unless line.valid_encoding? && line.match?(pattern)

          hits << "#{rel}:#{n}:#{line.chomp}"
          return hits if hits.length >= max
        end
      rescue ArgumentError, Encoding::InvalidByteSequenceError, SystemCallError
        next
      end
      hits
    rescue RegexpError => e
      raise ArgumentError, "invalid search regex: #{e.message}"
    end

    def each_search_file(root, glob)
      if File.file?(root)
        rel = relative_to_project(root)
        yield root, rel if glob.nil? || File.fnmatch?(glob, rel, File::FNM_PATHNAME | File::FNM_EXTGLOB)
        return
      end

      Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH) do |file|
        next unless File.file?(file)
        next if search_skip_path?(file)

        rel = relative_to_project(file)
        next if glob && !File.fnmatch?(glob, rel, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
        next if File.size(file) > 1_000_000

        yield file, rel
      end
    end

    def search_skip_path?(path)
      parts = path.split(File::SEPARATOR)
      parts.any? { |p| SEARCH_SKIP_DIRS.include?(p) }
    end

    def rg_available?
      return Tools.instance_variable_get(:@rg_available) unless Tools.instance_variable_get(:@rg_available).nil?

      available = system('rg', '--version', out: File::NULL, err: File::NULL)
      Tools.instance_variable_set(:@rg_available, available)
      available
    end
  end

  Registry.register(SearchCode)
end
