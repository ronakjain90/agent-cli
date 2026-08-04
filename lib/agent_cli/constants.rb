# frozen_string_literal: true

# Total token budget for the agent's context window.
MAX_TOKENS      = 1_000_000
# Safety cap on tool-loop iterations per turn.
MAX_STEPS       = 25
MAX_READ_BYTES  = 100_000
MAX_MODEL_OUTPUT_BYTES = 4_096
TICK_INTERVAL   = 0.08
MAX_OUT_TOKENS  = 16_384
MAX_LCS_LINES   = 5_000

# run_command rate limit: max commands per trailing window (seconds), per session.
COMMAND_RATE_WINDOW     = 60.0
MAX_COMMANDS_PER_WINDOW = 60
