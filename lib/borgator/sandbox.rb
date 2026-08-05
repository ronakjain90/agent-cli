# frozen_string_literal: true

require 'rbconfig'

# Filesystem confinement for the agent.
#
# Goal: writes are limited to the directory the agent was launched from (the
# "project root"). Reads and network stay open so toolchains keep working.
#
# Two layers cooperate:
#   * Tools#write_file / #edit_file call Sandbox.ensure_writable! — an in-process
#     guard that refuses paths resolving outside the root (cross-platform, always
#     on; the only protection for the in-process file tools).
#   * Tools#run_command wraps the shell in an OS sandbox via Sandbox.wrap:
#       - macOS  -> sandbox-exec (Seatbelt) with a deny-file-write profile
#       - Linux  -> bubblewrap (bwrap), project bound rw, system dirs ro
#     so arbitrary commands physically cannot write outside the root.
#
# Confinement is mandatory: there is intentionally no switch to disable it and
# no way to widen the root beyond the launch directory.
module Sandbox
  module_function

  # The project root: the directory the agent was launched from, resolved
  # through symlinks. Memoized on first use (there is no chdir tool, so pwd
  # stays the launch dir). Always the launch dir — never overridable or
  # disableable.
  #
  # @return [String] absolute, symlink-resolved path to the project root
  def root
    @root ||= begin
      File.realpath(Dir.pwd)
    rescue StandardError
      File.expand_path(Dir.pwd)
    end
  end

  # The host operating-system family, used to pick a sandbox backend.
  #
  # @return [Symbol] +:macos+, +:linux+, or +:other+
  def host
    case RbConfig::CONFIG['host_os']
    when /darwin/ then :macos
    when /linux/  then :linux
    else :other
    end
  end

  # --- Layer 1: in-process write guard ------------------------------------

  # Assert that +path+ resolves inside the project root, for the in-process
  # file tools. Resolves symlinks on the nearest existing ancestor so a symlink
  # inside the root can't redirect a write outside it.
  #
  # @param path [String] path to validate (absolute, or relative to {root})
  # @return [String] the expanded absolute path, safe to write
  # @raise [ArgumentError] if the path resolves outside the project root
  def ensure_writable!(path)
    full = File.expand_path(path, root)

    probe = full
    probe = File.dirname(probe) while !File.exist?(probe) && probe != File.dirname(probe)
    ancestor = begin
      File.realpath(probe)
    rescue StandardError
      probe
    end
    resolved = if File.exist?(full)
                 begin
                   File.realpath(full)
                 rescue StandardError
                   full
                 end
               else
                 full
               end

    unless within?(resolved) && within?(ancestor)
      raise ArgumentError,
            "refusing to write outside the project directory.\n  " \
            "project: #{root}\n  " \
            "target:  #{path}\n" \
            'Only paths inside the project directory can be modified.'
    end
    full
  end

  # Whether +path+ is the project root or lives inside it.
  #
  # @param path [String] an absolute, symlink-resolved path
  # @return [Boolean]
  def within?(path)
    path == root || path.start_with?(root + File::SEPARATOR)
  end

  # --- Layer 2: OS sandbox wrapper for shell commands ---------------------

  # Wrap a shell command for confined execution — fail closed. Commands are
  # never run unconfined: when no sandbox backend is available the command is
  # refused instead.
  #
  # @param cmd [String] the shell command to run
  # @return [Array(Array<String>, nil)] the argv to execute (which runs
  #   WITHOUT a wrapping shell) and +nil+, when a backend is available
  # @return [Array(nil, String)] +nil+ and a human-readable refusal reason,
  #   when no backend is available
  def wrap(cmd)
    case host
    when :macos
      if command_exist?('sandbox-exec')
        [['sandbox-exec', '-p', seatbelt_profile, '/bin/sh', '-c', cmd], nil]
      else
        [nil, 'Refusing to run: sandbox-exec (macOS Seatbelt) is unavailable, so shell ' \
              'commands cannot be confined to this project.']
      end
    when :linux
      if command_exist?('bwrap')
        [bwrap_argv(cmd), nil]
      else
        [nil,
         'Refusing to run: bubblewrap (bwrap) is not installed, so shell commands cannot be ' \
         "confined to this project. Install it and retry:\n    " \
         "Debian/Ubuntu: sudo apt-get install bubblewrap\n    " \
         "Fedora/RHEL:   sudo dnf install bubblewrap\n    " \
         'Arch:          sudo pacman -S bubblewrap']
      end
    else
      [nil, 'Refusing to run: shell-command sandboxing is not supported on ' \
            "#{RbConfig::CONFIG['host_os']}, so commands cannot be confined to this project."]
    end
  end

  # Whether {wrap} would actually confine a command right now (i.e. the host's
  # sandbox backend is present).
  #
  # @return [Boolean]
  def active?
    (host == :macos && command_exist?('sandbox-exec')) ||
      (host == :linux && command_exist?('bwrap'))
  end

  # Build the macOS Seatbelt (SBPL) profile: allow everything, then deny all
  # file writes except inside the project root and the temp/dev paths tools
  # legitimately need.
  #
  # @return [String] an SBPL profile suitable for +sandbox-exec -p+
  def seatbelt_profile
    writable = [root]
    # Allow the *specific* per-user temp dir (not the whole /private/var/folders
    # tree, which holds every app's temp and the project's own siblings when it
    # happens to live under temp). Plus the shared /tmp and /dev tools rely on.
    tmp = ENV.fetch('TMPDIR', nil)
    if tmp && !tmp.empty?
      writable << begin
        File.realpath(tmp)
      rescue StandardError
        tmp
      end
    end
    writable += ['/private/tmp', '/dev']

    allows = writable.uniq.map { |p| "  (subpath #{sbpl_quote(p)})" }.join("\n")
    <<~PROFILE
      (version 1)
      (allow default)
      (deny file-write*)
      (allow file-write*
      #{allows})
    PROFILE
  end

  # Build the Linux bubblewrap argv: project bound read-write, system dirs
  # read-only, fresh /tmp, network shared. Writes outside the project fail.
  # ro-binds add no exposure beyond the user's own read permissions; --dev /dev
  # already supplies null/zero/random/urandom.
  #
  # @param cmd [String] the shell command to run inside the sandbox
  # @return [Array<String>] a +bwrap+ argv ending in +/bin/sh -c cmd+
  def bwrap_argv(cmd)
    [
      'bwrap',
      '--die-with-parent',
      # Isolate namespaces but keep the network shared (fetch/install still work).
      '--unshare-pid',
      '--unshare-ipc',
      '--unshare-uts',
      '--unshare-cgroup-try',
      '--new-session', # own session: blocks TIOCSTI keystroke injection
      '--proc', '/proc',
      '--dev', '/dev',
      '--tmpfs', '/tmp',
      '--ro-bind', '/usr', '/usr',
      '--ro-bind-try', '/bin', '/bin',
      '--ro-bind-try', '/sbin', '/sbin',
      '--ro-bind-try', '/lib', '/lib',
      '--ro-bind-try', '/lib64', '/lib64',
      '--ro-bind-try', '/etc', '/etc',
      '--ro-bind-try', '/opt', '/opt',
      '--bind', root, root,
      '--chdir', root,
      '--setenv', 'HOME', root,
      '/bin/sh', '-c', cmd
    ]
  end

  # --- helpers ------------------------------------------------------------

  # Whether an executable named +name+ exists on +PATH+.
  #
  # @param name [String] executable base name (e.g. +"bwrap"+)
  # @return [Boolean]
  def command_exist?(name)
    ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? do |dir|
      next false if dir.empty?

      full = File.join(dir, name)
      File.executable?(full) && !File.directory?(full)
    end
  end

  # Quote a path as an SBPL string literal (escaping backslashes and quotes).
  #
  # @param path [String] the path to quote
  # @return [String] the path wrapped in double quotes, safe for SBPL
  def sbpl_quote(path)
    %("#{path.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}")
  end
end
