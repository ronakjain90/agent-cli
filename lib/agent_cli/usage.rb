# frozen_string_literal: true

# Normalize and accumulate provider token-usage hashes for the TUI footer.
module Usage
  EMPTY = { input: 0, output: 0, cache_read: 0, cache_write: 0 }.freeze

  module_function

  def blank
    EMPTY.dup
  end

  def from_anthropic(raw)
    return nil unless raw.is_a?(Hash)

    {
      input: raw["input_tokens"].to_i,
      output: raw["output_tokens"].to_i,
      cache_read: raw["cache_read_input_tokens"].to_i,
      cache_write: raw["cache_creation_input_tokens"].to_i
    }
  end

  def from_openai(raw)
    return nil unless raw.is_a?(Hash)

    {
      input: raw["prompt_tokens"].to_i,
      output: raw["completion_tokens"].to_i,
      cache_read: raw.dig("prompt_tokens_details", "cached_tokens").to_i,
      cache_write: 0
    }
  end

  # OpenCode response shapes vary; accept a few common layouts.
  def from_opencode(resp)
    return nil unless resp.is_a?(Hash)

    info = resp["info"] || resp
    tokens = info["tokens"] || info["usage"] || resp["tokens"] || resp["usage"]
    return from_openai(tokens) if tokens.is_a?(Hash) && tokens.key?("prompt_tokens")
    return from_anthropic(tokens) if tokens.is_a?(Hash) && tokens.key?("input_tokens")

    return nil unless tokens.is_a?(Hash)

    cache = tokens["cache"]
    cache = {} unless cache.is_a?(Hash)

    {
      input: (tokens["input"] || tokens["in"]).to_i,
      output: (tokens["output"] || tokens["out"]).to_i,
      cache_read: (cache["read"] || tokens["cache_read"]).to_i,
      cache_write: (cache["write"] || tokens["cache_write"]).to_i
    }
  end

  def add!(totals, delta)
    return totals unless delta.is_a?(Hash)

    totals[:input] += delta[:input].to_i
    totals[:output] += delta[:output].to_i
    totals[:cache_read] += delta[:cache_read].to_i
    totals[:cache_write] += delta[:cache_write].to_i
    totals
  end

  def any?(totals)
    totals && totals.values_at(:input, :output, :cache_read, :cache_write).any? { |n| n.to_i > 0 }
  end

  def format(totals)
    return nil unless any?(totals)

    parts = [
      "in #{commas(totals[:input])}",
      "out #{commas(totals[:output])}"
    ]
    parts << "cache read #{commas(totals[:cache_read])}" if totals[:cache_read].to_i > 0
    parts << "cache write #{commas(totals[:cache_write])}" if totals[:cache_write].to_i > 0
    parts.join(" · ")
  end

  def commas(n)
    n.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
  end
end
