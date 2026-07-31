# frozen_string_literal: true

require_relative "constants"

# Safety guard for LLM-generated AGENTS.md content before it is written.
# AGENTS.md is auto-loaded into every session, so a poisoned file is a
# persistent prompt-injection vector. Patterns target unambiguous attack
# shapes only, to avoid false positives on legitimate fenced code.
module AgentsGuard
  module_function

  # [regex, reason surfaced to the user] pairs.
  DANGEROUS_PATTERNS = [
    [/\bignore\s+(?:all\s+)?(?:the\s+)?(?:previous|prior|above|preceding)\b/i,
     "prompt-injection phrasing (\"ignore previous instructions\")"],
    [/\bdisregard\s+(?:all\s+)?(?:previous|prior|above|preceding|earlier)\b/i,
     "prompt-injection phrasing (\"disregard prior instructions\")"],
    [/\b(?:curl|wget)\b[^\n|]*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|python[0-9.]*)\b/i,
     "pipe-to-shell installer (curl/wget … | sh)"],
    [%r{\brm\s+-[rfRch]*[rf][rfRch]*\s+(?:-[^\s]+\s+)*(?:/|~|\$HOME|\*)},
     "destructive recursive delete (rm -rf on / ~ or *)"],
    [/\b(?:AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID|(?:GH|GITHUB)_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY)\b/,
     "embedded credential / secret token"],
    [/-----BEGIN\s+(?:RSA\s+|EC\s+|OPENSSH\s+|DSA\s+)?PRIVATE KEY-----/,
     "embedded private key"],
  ].freeze

  # Reasons the content looks unsafe to persist; empty means it passed.
  def flagged(content)
    text = content.to_s
    DANGEROUS_PATTERNS.each_with_object([]) do |(re, reason), reasons|
      reasons << reason if text.match?(re)
    end
  end

  # Safe to write: no danger patterns and within the size cap.
  def safe?(content)
    flagged(content).empty? && content.to_s.bytesize <= MAX_READ_BYTES
  end
end
