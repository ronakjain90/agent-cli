# frozen_string_literal: true

require "bubbletea"
require "lipgloss"

require_relative "model"
require_relative "preferences"
require_relative "commands"

class Poll < Bubbletea::Message; end

class FetchDone < Bubbletea::Message
  attr_reader :items, :error

  def initialize(items: nil, error: nil)
    @items = items
    @error = error
  end
end

# Elm-architecture TUI: init / update / view.
class AgentApp
  include Bubbletea::Model

  SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

  def initialize(provider = nil, startup_error: nil)
    @provider = provider
    @mode = :chat
    @startup_error = startup_error
    @messages = []
    @log      = []
    @input    = ""
    @thinking = false
    @frame    = 0
    @events   = Queue.new
    @worker   = nil
    @height   = 24
    @width    = 80
    @diffs       = []
    @diff_cursor = -1

    @selected_provider = nil
    @model_items = []
    @menu_cursor = 0
    @menu_scroll = 0
    @picker_error = nil
    @opencode_error = nil
    @opencode_loading = false
    @manual_input = ""
    @manual_error = nil
    @picker_from_chat = false
    @pending_model_id = nil
    @suggest_cursor = 0

    @you    = Lipgloss::Style.new.bold(true).foreground("#7D56F4")
    @bot    = Lipgloss::Style.new.foreground("#DFDBDD")
    @tool   = Lipgloss::Style.new.foreground("#5AF78E")
    @toolok = Lipgloss::Style.new.foreground("#666666")
    @err    = Lipgloss::Style.new.foreground("#FF6B6B").bold(true)
    @prompt = Lipgloss::Style.new.foreground("#FAFAFA").background("#7D56F4").padding(0, 1)
    @hint   = Lipgloss::Style.new.foreground("#666666")
  end

  def init
    if @startup_error
      @log << { kind: :error, text: @startup_error }
      @log << { kind: :assistant, text: "Type /providers to choose a provider and model." }
    elsif @provider
      @log << ready_message
      @log << { kind: :assistant, text: "Ask me to read, write, or run something. Type /providers to switch." }
    else
      @log << { kind: :assistant, text: "Type /providers to choose a provider and model." }
    end
    [self, nil]
  end

  def update(message)
    case message
    when Bubbletea::WindowSizeMessage
      @height = message.height
      @width  = message.width if message.respond_to?(:width)
      clamp_menu_scroll
      [self, nil]

    when FetchDone
      @opencode_loading = false
      if message.error
        @opencode_error = message.error
        @model_items = [Model.other]
      else
        @opencode_error = nil
        @model_items = message.items + [Model.other]
      end
      @menu_cursor = 0
      @menu_scroll = 0
      focus_model(@pending_model_id)
      @pending_model_id = nil
      [self, nil]

    when Poll
      drain_events
      if @thinking || @opencode_loading
        @frame = (@frame + 1) % SPINNER.length
        [self, tick]
      else
        [self, nil]
      end

    when Bubbletea::KeyMessage
      return [self, Bubbletea.quit] if message.to_s == "ctrl+c"

      case @mode
      when :pick_provider, :pick_model then update_picker(message)
      when :manual_model then update_manual_entry(message)
      else update_chat(message)
      end
    else
      [self, nil]
    end
  end

  def view
    case @mode
    when :pick_provider, :pick_model then view_picker
    when :manual_model then view_manual_entry
    else view_chat
    end
  end

  def open_providers_picker
    @picker_from_chat = true
    @input = ""
    @suggest_cursor = 0
    prefs = Preferences.load
    if prefs && Provider.find(prefs[:provider])
      select_provider(prefs[:provider], model_id: prefs[:model])
    else
      @mode = :pick_provider
      @menu_cursor = 0
      @menu_scroll = 0
      @picker_error = nil
      [self, nil]
    end
  end

  def show_command_help
    @log << { kind: :assistant, text: "Available commands:" }
    Commands::ALL.each do |cmd|
      @log << { kind: :tool_result, text: "  #{cmd[:name]}  —  #{cmd[:desc]}" }
    end
    [self, nil]
  end

  private

  def ready_message
    { kind: :assistant, text: "Coding agent ready — provider: #{@provider.label} · model: #{@provider.model_label}" }
  end

  def update_chat(message)
    return [self, nil] if @thinking

    if @diffs.any?
      if message.to_s == "["
        @diff_cursor = (@diff_cursor - 1) % @diffs.length
        return [self, nil]
      end
      if message.to_s == "]"
        @diff_cursor = (@diff_cursor + 1) % @diffs.length
        return [self, nil]
      end
    end

    suggestions = slash_suggestions

    if suggestions.any?
      if message.up?
        @suggest_cursor = (@suggest_cursor - 1) % suggestions.length
        return [self, nil]
      end

      if message.down?
        @suggest_cursor = (@suggest_cursor + 1) % suggestions.length
        return [self, nil]
      end

      if message.tab? || message.right?
        @input = suggestions[@suggest_cursor][:name]
        return [self, nil]
      end
    end

    if message.enter?
      submit
    elsif message.backspace?
      @input = @input[0...-1] || ""
      @suggest_cursor = 0
      [self, nil]
    elsif message.space?
      @input += " "
      @suggest_cursor = 0
      [self, nil]
    elsif message.to_s.length == 1
      @input += message.to_s
      @suggest_cursor = 0
      [self, nil]
    else
      [self, nil]
    end
  end

  def update_picker(message)
    return [self, nil] if @opencode_loading

    if message.esc?
      if @mode == :pick_model
        reset_to_provider_picker
      elsif @picker_from_chat
        cancel_picker_to_chat
      end
      return [self, nil]
    end

    items = current_menu_items
    return [self, nil] if items.empty?

    if message.up? || message.to_s == "k"
      @menu_cursor = (@menu_cursor - 1) % items.length
      ensure_cursor_visible
      return [self, nil]
    end

    if message.down? || message.to_s == "j"
      @menu_cursor = (@menu_cursor + 1) % items.length
      ensure_cursor_visible
      return [self, nil]
    end

    if message.to_s.match?(/\A[1-9]\z/)
      idx = message.to_s.to_i - 1
      if idx < items.length
        @menu_cursor = idx
        ensure_cursor_visible
        return confirm_menu_selection
      end
      return [self, nil]
    end

    return confirm_menu_selection if message.enter?

    [self, nil]
  end

  def update_manual_entry(message)
    if message.esc?
      @mode = :pick_model
      @manual_input = ""
      @manual_error = nil
      return [self, nil]
    end

    return confirm_manual_model if message.enter?

    if message.backspace?
      @manual_input = @manual_input[0...-1] || ""
      @manual_error = nil
      return [self, nil]
    end

    if message.space?
      @manual_input += " "
      @manual_error = nil
      return [self, nil]
    end

    if message.to_s.length == 1
      @manual_input += message.to_s
      @manual_error = nil
      return [self, nil]
    end

    [self, nil]
  end

  def confirm_menu_selection
    items = current_menu_items
    item = items[@menu_cursor]
    return [self, nil] unless item

    case @mode
    when :pick_provider
      select_provider(item[:id])
    when :pick_model
      if item.other?
        @mode = :manual_model
        @manual_input = ""
        @manual_error = nil
        [self, nil]
      else
        activate_provider(item.id)
      end
    else
      [self, nil]
    end
  end

  def select_provider(provider_id, model_id: nil)
    @selected_provider = Provider.find(provider_id)
    return [self, nil] unless @selected_provider

    @picker_error = nil
    @opencode_error = nil
    @pending_model_id = model_id

    if @selected_provider.is_a?(Provider::Opencode)
      @mode = :pick_model
      @model_items = []
      @menu_cursor = 0
      @menu_scroll = 0
      @opencode_loading = true
      provider = @selected_provider
      [self, Bubbletea.batch(
        tick,
        lambda {
          begin
            items = provider.fetch_models
            FetchDone.new(items: items)
          rescue => e
            FetchDone.new(error: "#{e.class}: #{e.message}")
          end
        }
      )]
    else
      @model_items = @selected_provider.models + [Model.other]
      @mode = :pick_model
      @menu_cursor = 0
      @menu_scroll = 0
      focus_model(@pending_model_id)
      @pending_model_id = nil
      [self, nil]
    end
  end

  def activate_provider(model_id)
    @provider = @selected_provider.build(model_id)
    Preferences.save(@selected_provider.id, model_id)
    was_chat = @picker_from_chat
    @mode = :chat
    @picker_from_chat = false
    @pending_model_id = nil
    @messages = []
    @picker_error = nil
    @log << ready_message
    unless was_chat
      @log << { kind: :assistant, text: "Ask me to read, write, or run something. Type /providers to switch." }
    end
    [self, nil]
  rescue => e
    @picker_error = e.message
    if @picker_from_chat
      @mode = :pick_model
      [self, nil]
    else
      reset_to_provider_picker
    end
  end

  def confirm_manual_model
    spec = @manual_input.strip
    if spec.empty?
      @manual_error = "enter a model id"
      return [self, nil]
    end

    if @selected_provider.is_a?(Provider::Opencode)
      spec = @selected_provider.resolve_manual_input(spec, @model_items)
      begin
        @selected_provider.parse_model_spec(spec)
      rescue => e
        @manual_error = "#{e.message}  (e.g. deepseek/deepseek-v4-flash)"
        return [self, nil]
      end
    end

    activate_provider(spec)
  end

  def reset_to_provider_picker
    @mode = :pick_provider
    @selected_provider = nil
    @model_items = []
    @menu_cursor = provider_menu_index(Preferences.load&.dig(:provider))
    @menu_scroll = 0
    @opencode_error = nil
    @opencode_loading = false
    @manual_input = ""
    @manual_error = nil
    @pending_model_id = nil
    [self, nil]
  end

  def cancel_picker_to_chat
    @mode = :chat
    @picker_from_chat = false
    @selected_provider = nil
    @model_items = []
    @menu_cursor = 0
    @menu_scroll = 0
    @opencode_error = nil
    @opencode_loading = false
    @manual_input = ""
    @manual_error = nil
    @picker_error = nil
    @pending_model_id = nil
    [self, nil]
  end

  def slash_suggestions
    return [] unless @input.start_with?("/")
    return [] if @input.include?(" ")

    Commands.matching(@input)
  end

  def slash_command_active?
    slash_suggestions.any?
  end

  def input_ghost_suffix
    suggestions = slash_suggestions
    return "" if suggestions.empty?

    match = suggestions[@suggest_cursor]
    return "" unless match[:name].start_with?(@input) && match[:name].length > @input.length

    @hint.render(match[:name][@input.length..])
  end

  def view_suggestions
    suggestions = slash_suggestions
    @suggest_cursor = 0 if @suggest_cursor >= suggestions.length

    suggestions.map.with_index do |cmd, i|
      prefix = i == @suggest_cursor ? "> " : "  "
      line = "#{prefix}#{cmd[:name]}  —  #{cmd[:desc]}"
      i == @suggest_cursor ? @you.render(line) : @hint.render(line)
    end
  end

  def focus_model(model_id)
    return if model_id.nil? || model_id.empty?

    idx = @model_items.index { |m| m.id == model_id }
    @menu_cursor = idx if idx
    ensure_cursor_visible if idx
  end

  def provider_menu_index(provider_id)
    return 0 unless provider_id

    idx = Provider.all.index { |p| p.id == provider_id }
    idx || 0
  end

  def current_menu_items
    case @mode
    when :pick_provider then Provider.all.map(&:menu_entry)
    when :pick_model then @model_items
    else []
    end
  end

  def view_picker
    lines = []
    lines << @bot.render(picker_title)

    if @picker_error
      lines << @err.render("! #{@picker_error}")
      lines << ""
    end

    if @mode == :pick_model && @opencode_loading
      url = @selected_provider&.base_url || "http://127.0.0.1:4096"
      lines << @tool.render("#{SPINNER[@frame]} loading models from #{url}…")
    elsif @mode == :pick_model && @opencode_error
      lines << @err.render("! #{@opencode_error}")
      lines << @hint.render("start the server: opencode serve --port 4096")
      lines << ""
    end

    items = current_menu_items
    visible = visible_menu_items(items)
    show_ids = @selected_provider&.show_model_id_in_picker?
    visible.each_with_index do |item, i|
      idx = @menu_scroll + i
      selected = idx == @menu_cursor
      prefix = selected ? "> " : "  "
      text =
        if item.is_a?(Hash) && item[:desc]
          "#{item[:label]}  —  #{item[:desc]}"
        elsif item.is_a?(Model)
          item.display_line(show_id: show_ids)
        else
          item.to_s
        end
      lines << (selected ? @you.render("#{prefix}#{text}") : @hint.render("#{prefix}#{text}"))
    end

    lines << ""
    lines << @hint.render(picker_hint)
    lines.join("\n")
  end

  def picker_hint
    if @mode == :pick_provider && @picker_from_chat
      "↑/↓ move · enter select · esc cancel · ctrl+c quit"
    else
      "↑/↓ move · enter select · esc back · ctrl+c quit"
    end
  end

  def view_manual_entry
    hint = @selected_provider&.manual_entry_hint || "model id"
    lines = [
      @bot.render("Enter #{hint}:"),
      ""
    ]
    lines << @err.render("! #{@manual_error}") if @manual_error
    lines << "#{@prompt.render("model")} #{@manual_input}#{@manual_input.empty? ? @hint.render(" type model id") : ""}"
    lines << ""
    lines << @hint.render("enter confirm · esc back · ctrl+c quit")
    lines.join("\n")
  end

  def view_chat
    suggestions = view_suggestions
    lines = visible_log
    status =
      if @thinking
        @tool.render("#{SPINNER[@frame]} thinking…")
      else
        ghost = input_ghost_suffix
        placeholder = @input.empty? && suggestions.empty? ? @hint.render("type a request") : ""
        "#{@prompt.render("you")} #{@input}#{ghost}#{placeholder}"
      end

    footer_hint =
      if @diffs.any?
        "enter send · / commands · [ / ] diffs · ctrl+c quit"
      elsif slash_command_active?
        "↑/↓ select · tab complete · enter run · ctrl+c quit"
      else
        "enter send · / for commands · ctrl+c quit"
      end
    footer = @hint.render(footer_hint)

    content = lines
    if suggestions.any?
      content += [""] + suggestions
    end
    content += ["", status, footer]

    if @diffs.any? && @width >= 100
      layout_side_by_side(content)
    else
      padding = [@height - content.length, 0].max
      ([""] * padding + content).join("\n")
    end
  end

  def layout_side_by_side(content)
    diff_view = render_diff_panel
    diff_lines = diff_view.split("\n")
    diff_width = [60, (@width * 0.38).to_i].min
    chat_width = @width - diff_width - 3
    max_lines = [content.length, diff_lines.length].max
    padded_chat = content + [""] * [max_lines - content.length, 0].max
    padded_diff = diff_lines + [""] * [max_lines - diff_lines.length, 0].max
    sep = @toolok.render(" #{""} ")

    combined = padded_chat.each_with_index.map do |chat_line, i|
      chat_trimmed = chat_line.to_s[0, chat_width].ljust(chat_width)
      diff_trimmed = padded_diff[i].to_s[0, diff_width].ljust(diff_width)
      "#{chat_trimmed}#{sep}#{diff_trimmed}"
    end

    visible = combined.last(@height)
    ([""] * [@height - visible.length, 0].max + visible).join("\n")
  end

  def render_diff_panel
    return "" if @diffs.empty?

    diff = @diffs[@diff_cursor] || @diffs.last
    header_style = Lipgloss::Style.new.foreground("#7D56F4").bold(true)
    add_style    = Lipgloss::Style.new.foreground("#5AF78E")
    del_style    = Lipgloss::Style.new.foreground("#FF6B6B")
    hunk_style   = Lipgloss::Style.new.foreground("#66D9EF")
    dim_style    = Lipgloss::Style.new.foreground("#666666")

    title = @diffs.length > 1 ? "diff #{@diff_cursor + 1}/#{@diffs.length}" : "diff"
    lines = [header_style.render(title)]

    diff.split("\n").each do |line|
      if line.start_with?("@@")
        lines << hunk_style.render(line)
      elsif line.start_with?("+")
        lines << add_style.render(line)
      elsif line.start_with?("-")
        lines << del_style.render(line)
      elsif line.start_with?("---") || line.start_with?("+++")
        lines << header_style.render(line)
      else
        lines << dim_style.render(line)
      end
    end

    lines.join("\n")
  end

  def picker_title
    case @mode
    when :pick_provider then "Select provider:"
    when :pick_model then @selected_provider&.model_picker_title || "Select model:"
    else ""
    end
  end

  def visible_menu_items(items)
    return [] if items.empty?

    budget = menu_visible_budget
    if items.length <= budget
      @menu_scroll = 0 if @menu_scroll > [items.length - budget, 0].max
      return items
    end

    clamp_menu_scroll
    items[@menu_scroll, budget] || []
  end

  def menu_visible_budget
    overhead = 4
    overhead += 2 if @picker_error
    overhead += 3 if @mode == :pick_model && (@opencode_loading || @opencode_error)
    [@height - overhead, 3].max
  end

  def ensure_cursor_visible
    budget = menu_visible_budget
    items = current_menu_items
    return if items.empty?

    if @menu_cursor < @menu_scroll
      @menu_scroll = @menu_cursor
    elsif @menu_cursor >= @menu_scroll + budget
      @menu_scroll = @menu_cursor - budget + 1
    end
    clamp_menu_scroll
  end

  def clamp_menu_scroll
    items = current_menu_items
    return if items.empty?

    max_scroll = [items.length - menu_visible_budget, 0].max
    @menu_scroll = [[@menu_scroll, 0].max, max_scroll].min
  end

  def submit
    text = @input.strip
    return [self, nil] if text.empty?

    if text.start_with?("/") && !text.include?(" ")
      matches = Commands.matching(text)
      if matches.empty?
        @log << { kind: :error, text: "unknown command #{text.inspect} — type /help" }
        @input = ""
        @suggest_cursor = 0
        return [self, nil]
      end

      chosen = matches.find { |cmd| cmd[:name] == text } || matches[@suggest_cursor] || matches.first
      @input = ""
      @suggest_cursor = 0
      return Commands.run(chosen[:name], self)
    end

    unless @provider
      @log << { kind: :error, text: "no provider connected — type /providers" }
      @input = ""
      return [self, nil]
    end

    @log << { kind: :user, text: text }
    @messages << { "role" => "user", "content" => text }
    @input = ""
    @thinking = true

    @worker = Thread.new(@messages, @events) do |msgs, events|
      @provider.run_turn(msgs, events)
    end

    [self, tick]
  end

  def tick
    Bubbletea.tick(0.08) { Poll.new }
  end

  def drain_events
    until @events.empty?
      ev = @events.pop(true) rescue break
      case ev[:kind]
      when :done then @thinking = false
      else
        @log << ev
        if ev[:diff]
          @diffs << ev[:diff]
          @diff_cursor = @diffs.length - 1
        end
      end
    end
  end

  def visible_log
    suggestions = slash_suggestions
    extra = suggestions.empty? ? 0 : suggestions.length + 1

    rendered = @log.map do |e|
      case e[:kind]
      when :user        then "#{@you.render("you")} #{e[:text]}"
      when :assistant   then @bot.render(e[:text])
      when :tool        then @tool.render("→ #{e[:text]}")
      when :tool_result then @toolok.render("  #{e[:text]}")
      when :error       then @err.render("! #{e[:text]}")
      end
    end.flat_map { |s| s.to_s.split("\n") }

    budget = [@height - 4 - extra, 5].max
    rendered.last(budget)
  end
end
