# frozen_string_literal: true

# Raised when a tool execution fails (e.g. a shell command fails, a file can't
# be read or written, etc.). Inherits from StandardError so callers can rescue
# it distinctly from programming bugs (LogicError, NameError, etc.) and, more
# importantly, do *not* accidentally catch SystemExit / Interrupt /
# SignalException which a bare `rescue => e` would swallow.
class Errors < StandardError
  attr_reader :tool_name

  def initialize(message, tool_name: nil)
    super(message)
    @tool_name = tool_name
  end
end
