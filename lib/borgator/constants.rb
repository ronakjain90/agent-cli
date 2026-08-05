# frozen_string_literal: true

# Total token budget for the agent's context window.
MAX_TOKENS      = 1_000_000
# Safety cap on tool-loop iterations per turn.
MAX_STEPS       = 25
MAX_READ_BYTES  = 100_000
MAX_MODEL_OUTPUT_BYTES = 4_096
MAX_FILE_RESULT_BYTES  = 65_536
TICK_INTERVAL   = 0.08
MAX_OUT_TOKENS  = 16_384
MAX_LCS_LINES   = 5_000

# search_code: default / hard caps on match lines returned to the model.
SEARCH_DEFAULT_MAX_MATCHES = 40
SEARCH_MAX_MATCHES_CAP     = 100

# web_fetch (off unless AGENT_ALLOW_WEB_FETCH=1 / --web-fetch).
WEB_FETCH_TIMEOUT   = 15
WEB_FETCH_MAX_BYTES = 48_000
WEB_FETCH_MAX_REDIRECTS = 3

# run_command rate limit: max commands per trailing window (seconds), per session.
COMMAND_RATE_WINDOW     = 60.0
MAX_COMMANDS_PER_WINDOW = 60
COMMAND_TIMEOUT = 120.0
