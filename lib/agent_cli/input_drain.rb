# frozen_string_literal: true

require "open3"

# Bubbletea's Program#poll_event only parses the first key from each raw read and
# discards the rest — so clipboard pastes become 1–2 characters. This patch drains
# the full buffer into a queue of key events.
module AgentCli
  module InputDrain
    KEY_RUNES     = -1
    KEY_ESC       = 27
    KEY_BACKSPACE = 127
    KEY_TAB       = 9
    KEY_ENTER     = 13
    KEY_SPACE     = -25
    KEY_UP        = -2
    KEY_DOWN      = -3
    KEY_RIGHT     = -4
    KEY_LEFT      = -5
    KEY_HOME      = -6
    KEY_END       = -7
    KEY_DELETE    = -10

    module_function

    def patch!
      return if defined?(@patched) && @patched

      Bubbletea::Program.class_eval do
        alias_method :__agent_cli_poll_event_orig, :poll_event

        def poll_event(timeout_ms)
          @__agent_cli_event_q ||= []
          return @__agent_cli_event_q.shift unless @__agent_cli_event_q.empty?

          raw = read_raw_input(timeout_ms)
          return nil if raw.nil? || raw.empty?

          @__agent_cli_event_q.concat(AgentCli::InputDrain.parse_all(raw))
          @__agent_cli_event_q.shift
        end
      end

      @patched = true
    end

    def parse_all(raw)
      data = raw.to_s.dup.force_encoding(Encoding::BINARY)
      events = []
      i = 0

      while i < data.bytesize
        # Bracketed paste: ESC [ 200 ~ … ESC [ 201 ~
        if data.byteslice(i, 6) == "\e[200~"
          close = data.index("\e[201~", i + 6)
          if close
            content = utf8(data.byteslice(i + 6, close - (i + 6)))
            content = content.gsub(/\r\n?/, "\n")
            events << rune_event(content) unless content.empty?
            i = close + 6
            next
          end
        end

        b = data.getbyte(i)

        if b == 0x1b
          ev, consumed = parse_escape(data, i)
          events << ev if ev
          i += consumed
          next
        end

        if b == 0x7f || b == 0x08
          events << key_event(KEY_BACKSPACE, "backspace")
          i += 1
          next
        end

        if b == 0x09
          events << key_event(KEY_TAB, "tab")
          i += 1
          next
        end

        if b == 0x0d || b == 0x0a
          events << key_event(KEY_ENTER, "enter")
          i += 1
          next
        end

        if b < 32
          name = b == 22 ? "ctrl+v" : "ctrl+#{(b + 96).chr}"
          events << key_event(b, name)
          i += 1
          next
        end

        # Batch consecutive printable bytes (clipboard pastes arrive this way).
        start = i
        i += 1 while i < data.bytesize && printable_byte?(data.getbyte(i))
        chunk = utf8(data.byteslice(start, i - start))
        # Orphaned bracketed-paste markers (ESC consumed separately).
        if chunk.start_with?("[200~")
          chunk = chunk.delete_prefix("[200~")
          if (close = chunk.index("[201~"))
            chunk = chunk.byteslice(0, close).to_s
          else
            chunk = chunk.delete_suffix("[201~")
          end
        end
        chunk = chunk.gsub(/\[201~/, "")
        next if chunk.empty?

        if chunk == " "
          events << key_event(KEY_SPACE, "space", [0x20])
        else
          events << rune_event(chunk)
        end
      end

      events
    end

    def printable_byte?(b)
      b >= 32 && b != 0x7f
    end

    def utf8(bytes)
      s = bytes.to_s.force_encoding(Encoding::UTF_8)
      s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    def parse_escape(data, i)
      rest = data.byteslice(i..-1).to_s

      case rest
      when /\A\e\[A/  then return [key_event(KEY_UP, "up"), 3]
      when /\A\e\[B/  then return [key_event(KEY_DOWN, "down"), 3]
      when /\A\e\[C/  then return [key_event(KEY_RIGHT, "right"), 3]
      when /\A\e\[D/  then return [key_event(KEY_LEFT, "left"), 3]
      when /\A\e\[H/  then return [key_event(KEY_HOME, "home"), 3]
      when /\A\e\[F/  then return [key_event(KEY_END, "end"), 3]
      when /\A\e\[1~/ then return [key_event(KEY_HOME, "home"), 4]
      when /\A\e\[4~/ then return [key_event(KEY_END, "end"), 4]
      when /\A\e\[3~/ then return [key_event(KEY_DELETE, "delete"), 4]
      when /\A\e\[Z/  then return [key_event(-24, "shift+tab"), 3]
      end

      if rest.bytesize >= 2 && rest.getbyte(1).between?(32, 126)
        r = rest.getbyte(1)
        return [rune_event(r.chr, alt: true), 2]
      end

      [key_event(KEY_ESC, "esc"), 1]
    end

    def rune_event(text, alt: false)
      text = text.to_s
      {
        "type" => "key",
        "key_type" => KEY_RUNES,
        "runes" => text.unpack("U*"),
        "alt" => alt,
        "name" => alt ? "alt+#{text}" : text
      }
    end

    def key_event(key_type, name, runes = nil)
      {
        "type" => "key",
        "key_type" => key_type,
        "runes" => runes,
        "alt" => false,
        "name" => name
      }
    end

    def clipboard_text
      [
        %w[pbpaste],
        %w[wl-paste -n],
        %w[xclip -selection clipboard -o]
      ].each do |cmd|
        out, status = Open3.capture2(*cmd)
        text = out.to_s
        return text if status.success? && !text.empty?
      rescue Errno::ENOENT, Errno::EACCES
        next
      end
      nil
    end
  end
end
