# frozen_string_literal: true

require "fileutils"

# Persists submitted prompts so up/down can recall them across sessions.
class PromptHistory
  PATH  = File.expand_path("~/.config/agent-cli/history")
  LIMIT = 1000

  def self.load
    return [] unless File.exist?(PATH)

    File.readlines(PATH, chomp: true).reject(&:empty?).last(LIMIT)
  rescue Errno::ENOENT
    []
  end

  def self.save(entries)
    FileUtils.mkdir_p(File.dirname(PATH))
    lines = entries.last(LIMIT)
    File.write(PATH, lines.empty? ? "" : "#{lines.join("\n")}\n")
  end

  def self.append(entries, text)
    text = text.to_s.gsub(/[\r\n]+/, " ").strip
    return entries if text.empty?
    return entries if entries.last == text

    updated = (entries + [text]).last(LIMIT)
    save(updated)
    updated
  end
end
