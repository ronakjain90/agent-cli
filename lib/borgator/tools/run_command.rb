# frozen_string_literal: true

require 'open3'

require_relative '../preferences'
require_relative '../sandbox'
require_relative 'helpers'
require_relative 'registry'

module Tools
  module RunCommand
    extend Helpers

    NAME = 'run_command'
    DEFINITION = {
      name: NAME,
      description: 'Run a shell command in the working directory and return its output. May require user approval.',
      input_schema: {
        type: 'object',
        properties: { command: { type: 'string' } },
        required: ['command']
      }
    }.freeze

    module_function

    def call(input)
      run(require_arg!(input, 'command'))
    end

    # Run under OS sandbox. Routes through Tools.execute_command so tests can stub it.
    def run(cmd, skip_permission: false)
      argv, refusal = Sandbox.wrap(cmd)
      return ["blocked (no sandbox): #{cmd}", refusal] if argv.nil?

      SHELL_MUTEX.synchronize { Tools.execute_command(cmd, argv, skip_permission) }
    end

    def execute(cmd, argv, skip_permission)
      unless skip_permission || Tools.shell_permitted? || Tools.auto_allowed?(cmd)
        case request_permission('run_command', cmd)
        when :always
          Tools.allow_shell_session!
        when :persist
          Preferences.add_allowed_command(Tools.persist_prefix(cmd))
        when :allow
          # one-shot
        else
          return ["denied: #{cmd}", 'User denied permission to run this shell command.']
        end
      end

      unless Tools.rate_limit_ok?
        return ["rate-limited: #{cmd}",
                "Rate limit reached: at most #{MAX_COMMANDS_PER_WINDOW} shell commands may run " \
                "per #{COMMAND_RATE_WINDOW.to_i} seconds. Wait a moment before running more commands."]
      end

      out, timed_out = capture_with_timeout(argv, COMMAND_TIMEOUT)
      out = out[0, MAX_READ_BYTES]
      out = '(no output)' if out.empty?

      if timed_out
        return ["timed out (#{COMMAND_TIMEOUT.to_i}s): #{cmd}",
                "Command killed after #{COMMAND_TIMEOUT.to_i}s. Partial output below. Re-run " \
                "something narrower (scope the path, add a limit) rather than repeating this.\n\n#{out}"]
      end

      ["ran (sandboxed): #{cmd}", out]
    end

    def capture_with_timeout(argv, timeout)
      stdin, out_io, wait_thr = Open3.popen2e(*argv, pgroup: true)
      stdin.close
      pid = wait_thr.pid
      reader = Thread.new { out_io.read.to_s }

      timed_out = wait_thr.join(timeout).nil?
      terminate_group(pid) if timed_out

      out = reader.join(5) ? reader.value.to_s : ''
      [out, timed_out]
    ensure
      terminate_group(pid) if pid && wait_thr&.alive?
      reader&.kill
      out_io&.close unless out_io.nil? || out_io.closed?
    end

    def terminate_group(pid)
      Process.kill('TERM', -pid)
      sleep 0.2
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH, Errno::EPERM, RangeError
      nil
    end
  end

  Registry.register(RunCommand)
end
