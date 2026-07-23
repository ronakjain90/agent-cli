# frozen_string_literal: true

require "bubbletea"
require "lipgloss"

require_relative "model"
require_relative "preferences"
require_relative "prompt_history"
require_relative "settings"
require_relative "usage"
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
    @models_error = nil
    @models_loading = false
    @manual_input = ""
    @manual_error = nil
    @api_key_input = ""
    @api_key_error = nil
    @picker_from_chat = false
    @pending_model_id = nil
    @suggest_cursor = 0
    @history = PromptHistory.load
    @history_index = nil
    @history_draft = ""

    @cursor_pos = 0
    @usage = Usage.blank
    @context_tokens = 0
    @pending_permission = nil

    @you    = Lipgloss::Style.new.bold(true).foreground("#7D56F4")
    @bot    = Lipgloss::Style.new
    @tool   = Lipgloss::Style.new.foreground("#2DA44E")
    @toolok = Lipgloss::Style.new.foreground("#656D76")
    @err    = Lipgloss::Style.new.foreground("#CF222E").bold(true)
    @warn   = Lipgloss::Style.new.foreground("#9A6700").bold(true)
    @prompt = Lipgloss::Style.new.foreground("#FAFAFA").background("#7D56F4").padding(0, 1)
    @hint   = Lipgloss::Style.new.foreground("#656D76")
    @cur    = Lipgloss::Style.new.reverse(true)
    # OpenCode-style composer
    @composer_bg     = "#EDEDED"
    @composer_fg     = Lipgloss::Style.new.foreground("#1F2328")
    @composer_accent = Lipgloss::Style.new.foreground("#7D56F4")
    @composer_dim    = Lipgloss::Style.new.foreground("#8B949E")
    @composer_key    = Lipgloss::Style.new.foreground("#1F2328").bold(true)
    @composer_box    = Lipgloss::Style.new
      .background(@composer_bg)
      .foreground("#1F2328")
      .padding(0, 1)
      .border_left(true)
      .border_top(false)
      .border_bottom(false)
      .border_right(false)
      .border_foreground("#7D56F4")
      .border_style(Lipgloss::NORMAL_BORDER)

    # Worker thread blocks here until the TUI answers a permission prompt.
    Tools.approver = method(:ask_tool_permission)
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
      @models_loading = false
      if message.error
        @models_error = message.error
        @model_items = [Model.other]
      else
        @models_error = nil
        @model_items = message.items + [Model.other]
      end
      @menu_cursor = 0
      @menu_scroll = 0
      focus_model(@pending_model_id)
      @pending_model_id = nil
      [self, nil]

    when Poll
      drain_events
      if @thinking || @models_loading || @mode == :permission
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
      when :enter_api_key then update_api_key_entry(message)
      when :permission then update_permission(message)
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
    when :enter_api_key then view_api_key_entry
    when :permission then view_permission
    else view_chat
    end
  end

  # Called from the worker thread via Tools.approver.
  def ask_tool_permission(tool, detail)
    reply = Queue.new
    @events << { kind: :permission_request, tool: tool, detail: detail, reply: reply }
    reply.pop
  end

  def open_providers_picker
    @picker_from_chat = true
    @input = ""
    @cursor_pos = 0
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

  def update_permission(message)
    key = message.to_s
    decision =
      if message.enter? || key == "y" || key == "Y"
        :allow
      elsif key == "a" || key == "A"
        :always
      elsif key == "n" || key == "N" || message.esc?
        :deny
      end
    return [self, nil] unless decision

    reply_permission(decision)
    [self, tick]
  end

  def reply_permission(decision)
    pending = @pending_permission
    @pending_permission = nil
    @mode = :chat
    return unless pending && pending[:reply]

    case decision
    when :allow
      @log << { kind: :tool_result, text: "  allowed once" }
    when :always
      @log << { kind: :tool_result, text: "  allowed for this session" }
    when :deny
      @log << { kind: :tool_result, text: "  denied" }
    end

    pending[:reply] << decision
  end

  def update_chat(message)
    return [self, nil] if @thinking

    if @diffs.any? && @input.empty?
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
        @cursor_pos = @input.length
        return [self, nil]
      end
    elsif message.up?
      history_up
      return [self, nil]
    elsif message.down?
      history_down
      return [self, nil]
    end

    if message.enter?
      submit
    elsif message.left?
      @cursor_pos = [@cursor_pos - 1, 0].max
      @suggest_cursor = 0
      [self, nil]
    elsif message.right?
      @cursor_pos = [@cursor_pos + 1, @input.length].min
      @suggest_cursor = 0
      [self, nil]
    elsif message.backspace?
      if @cursor_pos > 0
        @input = @input[0...@cursor_pos - 1] + (@input[@cursor_pos..] || "")
        @cursor_pos -= 1
      end
      @suggest_cursor = 0
      [self, nil]
    elsif message.space?
      @input = @input[0...@cursor_pos] + " " + (@input[@cursor_pos..] || "")
      @cursor_pos += 1
      @suggest_cursor = 0
      [self, nil]
    elsif (text = typed_text(message))
      @input = @input[0...@cursor_pos] + text + (@input[@cursor_pos..] || "")
      @cursor_pos += text.length
      @suggest_cursor = 0
      [self, nil]
    else
      [self, nil]
    end
  end

  def update_picker(message)
    return [self, nil] if @models_loading

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

    if (text = typed_text(message))
      @manual_input += text
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
    @models_error = nil
    @pending_model_id = model_id

    if @selected_provider.respond_to?(:fetch_models)
      @mode = :pick_model
      @model_items = []
      @menu_cursor = 0
      @menu_scroll = 0
      @models_loading = true
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
    @api_key_input = ""
    @api_key_error = nil
    @messages = []
    @usage = Usage.blank
    @context_tokens = 0
    @picker_error = nil
    @log << ready_message
    unless was_chat
      @log << { kind: :assistant, text: "Ask me to read, write, or run something. Type /providers to switch." }
    end
    [self, nil]
  rescue Settings::MissingApiKeyError => e
    @pending_model_id = model_id
    @mode = :enter_api_key
    @api_key_input = ""
    @api_key_error = nil
    @picker_error = nil
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

  def update_api_key_entry(message)
    if message.esc?
      @mode = :pick_model
      @api_key_input = ""
      @api_key_error = nil
      return [self, nil]
    end

    return confirm_api_key if message.enter?

    if message.backspace?
      @api_key_input = @api_key_input[0...-1] || ""
      @api_key_error = nil
      return [self, nil]
    end

    # Ctrl+V / Cmd often arrives as ctrl+v — pull from system clipboard.
    if message.to_s == "ctrl+v"
      pasted = AgentCli::InputDrain.clipboard_text
      if pasted && !pasted.empty?
        @api_key_input += pasted.gsub(/[\r\n\t]+/, "").strip
        @api_key_error = nil
      else
        @api_key_error = "clipboard empty (try paste, or ctrl+v)"
      end
      return [self, nil]
    end

    if message.space?
      @api_key_input += " "
      @api_key_error = nil
      return [self, nil]
    end

    if (text = typed_text(message))
      @api_key_input += text.gsub(/[\r\n\t]+/, "")
      @api_key_error = nil
      return [self, nil]
    end

    [self, nil]
  end

  # Insertable characters from a key event, including multi-rune clipboard pastes.
  def typed_text(message)
    return nil unless message.is_a?(Bubbletea::KeyMessage)
    return nil if message.ctrl? || message.enter? || message.backspace? || message.esc?
    return nil if message.up? || message.down? || message.left? || message.right?
    return nil if message.tab?

    if message.runes?
      text = message.char.to_s
      return text unless text.empty?
    end

    s = message.to_s
    return s if s.length == 1 && s.match?(/\A[[:print:]]\z/)

    nil
  end

  def confirm_api_key
    key = @api_key_input.strip
    if key.empty?
      @api_key_error = "paste or type your API key"
      return [self, nil]
    end

    env_name = @selected_provider&.api_key_env
    unless env_name
      @api_key_error = "this provider does not need an API key"
      return [self, nil]
    end

    Settings.save_api_key(env_name, key)
    @api_key_input = ""
    activate_provider(@pending_model_id)
  rescue => e
    @api_key_error = e.message
    [self, nil]
  end

  def view_api_key_entry
    env_name = @selected_provider&.api_key_env || "API_KEY"
    masked =
      if @api_key_input.empty?
        @hint.render(" paste key")
      else
        "•" * [@api_key_input.length, 64].min
      end

    lines = [
      @bot.render("Enter #{env_name}:"),
      @hint.render(api_key_help_url(env_name)),
      ""
    ]
    lines << @err.render("! #{@api_key_error}") if @api_key_error
    lines << "#{@prompt.render("key")} #{masked}"
    lines << ""
    lines << @hint.render("paste or ctrl+v · enter save · esc back · ctrl+c quit")
    lines.join("\n")
  end

  def api_key_help_url(env_name)
    case env_name
    when "OPENROUTER_API_KEY" then "https://openrouter.ai/keys  ·  saved to ~/.agent-cli/settings.json"
    when "ANTHROPIC_API_KEY"  then "https://console.anthropic.com/  ·  saved to ~/.agent-cli/settings.json"
    when "OPENAI_API_KEY"     then "https://platform.openai.com/api-keys  ·  saved to ~/.agent-cli/settings.json"
    when "GEMINI_API_KEY"     then "https://aistudio.google.com/apikey  ·  saved to ~/.agent-cli/settings.json"
    when "GROQ_API_KEY"       then "https://console.groq.com/keys  ·  saved to ~/.agent-cli/settings.json"
    else "saved to ~/.agent-cli/settings.json"
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
    @models_error = nil
    @models_loading = false
    @manual_input = ""
    @manual_error = nil
    @api_key_input = ""
    @api_key_error = nil
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
    @models_error = nil
    @models_loading = false
    @manual_input = ""
    @manual_error = nil
    @api_key_input = ""
    @api_key_error = nil
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

    if @mode == :pick_model && @models_loading
      url = @selected_provider&.base_url || "http://127.0.0.1:11434"
      lines << @tool.render("#{SPINNER[@frame]} loading models from #{url}…")
    elsif @mode == :pick_model && @models_error
      lines << @err.render("! #{@models_error}")
      hint = @selected_provider&.respond_to?(:server_hint) ? @selected_provider.server_hint : "check that the server is running"
      lines << @hint.render(hint)
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

  def view_permission
    req = @pending_permission || {}
    lines = visible_log
    detail = req[:detail].to_s
    tool = req[:tool].to_s
    status = @warn.render("allow #{tool}? #{detail}")
    footer = @hint.render("y/enter allow once · a allow session · n/esc deny · ctrl+c quit")
    usage = usage_line

    content = lines + ["", status]
    content << usage if usage
    content << footer

    padding = [@height - content.length, 0].max
    ([""] * padding + content).join("\n")
  end

  def view_chat
    suggestions = view_suggestions
    lines = visible_log

    content = lines
    if suggestions.any?
      content += [""] + suggestions
    end
    content += [""] + composer_lines + [status_bar_line]

    if @diffs.any? && @width >= 80
      layout_with_diff_panel(content)
    else
      padding = [@height - content.length, 0].max
      ([""] * padding + content).join("\n")
    end
  end

  # Gray box with purple left edge: input row + Agent · model · provider.
  def composer_lines
    width = [@width, 40].max
    input =
      if @thinking
        @composer_dim.render("#{SPINNER[@frame]} thinking…")
      else
        ghost = input_ghost_suffix
        placeholder =
          if @input.empty? && slash_suggestions.empty?
            @composer_dim.render("type a request")
          else
            ""
          end
        cell = @input[@cursor_pos]
        cursor = @cur.render(cell || " ")
        after = cell ? (@input[(@cursor_pos + 1)..] || "") : (@input[@cursor_pos..] || "")
        "#{@input[0...@cursor_pos]}#{cursor}#{after}#{ghost}#{placeholder}"
      end

    @composer_box.width(width).render("#{input}\n\n#{composer_meta}").split("\n")
  end

  def composer_meta
    mode = @composer_accent.render("Agent")
    sep = @composer_dim.render(" · ")
    if @provider
      model = @composer_fg.render(@provider.model_label.to_s)
      provider = @composer_dim.render(" #{@provider.label}")
      "#{mode}#{sep}#{model}#{provider}"
    else
      "#{mode}#{sep}#{@composer_dim.render("no model — /providers")}"
    end
  end

  # Left: activity · Right: context meter + command hint (OpenCode-style footer).
  def status_bar_line
    left =
      if @thinking
        @composer_dim.render("#{SPINNER[@frame]}······  esc interrupt")
      else
        ""
      end

    usage = Usage.format_context(display_context_tokens, context_window)
    hint =
      if @diffs.any?
        "#{@composer_key.render("[ ]")} #{@composer_dim.render("diffs")}  #{@composer_key.render("/")} #{@composer_dim.render("commands")}"
      elsif slash_command_active?
        "#{@composer_key.render("tab")} #{@composer_dim.render("complete")}  #{@composer_key.render("enter")} #{@composer_dim.render("run")}"
      else
        "#{@composer_key.render("/")} #{@composer_dim.render("commands")}"
      end

    right = "#{@composer_dim.render(usage)}  #{hint}"
    pad = [@width - strip_ansi(left).length - strip_ansi(right).length, 1].max
    "#{left}#{" " * pad}#{right}"
  end

  # Prefer last API prompt size; otherwise rough-estimate from the in-flight transcript.
  def display_context_tokens
    api = @context_tokens.to_i
    est = estimate_context_tokens
    [api, est].max
  end

  def estimate_context_tokens
    chars = 0
    (@messages || []).each do |m|
      chars += m["content"].to_s.length
      if (tcs = m["tool_calls"]).is_a?(Array)
        tcs.each { |tc| chars += tc.to_s.length }
      end
    end
    chars += @input.to_s.length
    # system prompt + tool schemas travel with every OpenAI-compatible request
    chars += 1_200 if @provider
    (chars / 4.0).ceil
  end

  def context_window
    if @provider.respond_to?(:context_window) && (w = @provider.context_window).to_i > 0
      w.to_i
    else
      Usage::DEFAULT_CONTEXT_WINDOW
    end
  end

  def usage_line
    text = Usage.format(@usage)
    return nil unless text

    @hint.render(text)
  end

  # Chat fills the screen; diff panel overlays the top-right corner.
  def layout_with_diff_panel(content)
    panel_w = [[(@width * 0.42).to_i, 48].max, @width - 24].min
    panel_h = [[(@height * 0.55).to_i, 12].max, @height - 6].min
    chat_w = @width - panel_w - 1

    panel_lines = render_diff_panel(panel_w, panel_h)
    chat_lines = content.map { |line| truncate_display(line.to_s, chat_w) }

    # Pin chat to the bottom of the left column (same as before).
    left_budget = @height
    left = ([""] * [left_budget - chat_lines.length, 0].max) + chat_lines.last(left_budget)

    rows = left.each_with_index.map do |chat_line, i|
      if i < panel_lines.length
        left_pad = truncate_display(chat_line, chat_w).ljust(chat_w)
        "#{left_pad} #{panel_lines[i]}"
      else
        truncate_display(chat_line, @width)
      end
    end

    rows.join("\n")
  end

  def render_diff_panel(width, height)
    return [] if @diffs.empty?

    diff = @diffs[@diff_cursor] || @diffs.last
    header_style = Lipgloss::Style.new.foreground("#7D56F4").bold(true)
    add_style    = Lipgloss::Style.new.foreground("#5AF78E")
    del_style    = Lipgloss::Style.new.foreground("#FF6B6B")
    hunk_style   = Lipgloss::Style.new.foreground("#66D9EF")
    dim_style    = Lipgloss::Style.new.foreground("#555555")
    border_style = Lipgloss::Style.new.foreground("#444444")

    title =
      if @diffs.length > 1
        "diff #{@diff_cursor + 1}/#{@diffs.length}  [ / ]"
      else
        "diff  [ / ]"
      end

    raw = diff.split("\n")
    body = raw.first([height - 2, 1].max).map do |line|
      clipped = line.byteslice(0, width - 2).to_s
      styled =
        if line.start_with?("@@")
          hunk_style.render(clipped)
        elsif line.start_with?("+") && !line.start_with?("+++")
          add_style.render(clipped)
        elsif line.start_with?("-") && !line.start_with?("---")
          del_style.render(clipped)
        elsif line.start_with?("---") || line.start_with?("+++")
          header_style.render(clipped)
        else
          dim_style.render(clipped)
        end
      "#{border_style.render("│")}#{styled}"
    end

    top = "#{border_style.render("┌")}#{header_style.render(" #{title} ".ljust([width - 1, 0].max))}"
    [top] + body
  end

  # Strip ANSI for length checks, keep rendered string otherwise.
  def truncate_display(str, width)
    return "" if width <= 0
    return str if strip_ansi(str).length <= width

    # Prefer cutting the raw string when no ANSI; otherwise leave as-is.
    if str == strip_ansi(str)
      str[0, width]
    else
      str
    end
  end

  def strip_ansi(str)
    str.gsub(/\e\[[0-9;]*m/, "")
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
    overhead += 3 if @mode == :pick_model && (@models_loading || @models_error)
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

  def history_up
    return if @history.empty?

    if @history_index.nil?
      @history_draft = @input
      @history_index = @history.length - 1
    elsif @history_index > 0
      @history_index -= 1
    else
      return
    end

    @input = @history[@history_index]
    @cursor_pos = @input.length
    @suggest_cursor = 0
  end

  def history_down
    return if @history_index.nil?

    if @history_index < @history.length - 1
      @history_index += 1
      @input = @history[@history_index]
    else
      @history_index = nil
      @input = @history_draft
    end

    @cursor_pos = @input.length
    @suggest_cursor = 0
  end

  def remember_prompt(text)
    @history = PromptHistory.append(@history, text)
    @history_index = nil
    @history_draft = ""
  end

  def submit
    text = @input.strip
    return [self, nil] if text.empty?

    remember_prompt(text)

    if text.start_with?("/") && !text.include?(" ")
      matches = Commands.matching(text)
      if matches.empty?
        @log << { kind: :error, text: "unknown command #{text.inspect} — type /help" }
        @input = ""
        @cursor_pos = 0
        @suggest_cursor = 0
        return [self, nil]
      end

      chosen = matches.find { |cmd| cmd[:name] == text } || matches[@suggest_cursor] || matches.first
      @input = ""
      @cursor_pos = 0
      @suggest_cursor = 0
      return Commands.run(chosen[:name], self)
    end

    unless @provider
      @log << { kind: :error, text: "no provider connected — type /providers" }
      @input = ""
      @cursor_pos = 0
      return [self, nil]
    end

    @log << { kind: :user, text: text }
    @messages << { "role" => "user", "content" => text }
    @input = ""
    @cursor_pos = 0
    @thinking = true
    @diffs = []
    @diff_cursor = -1

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
      when :done
        if @pending_permission
          reply_permission(:deny)
        end
        @thinking = false
      when :usage
        Usage.add!(@usage, ev[:usage])
        # Latest prompt size ≈ current context fill for the meter.
        @context_tokens = ev[:usage][:input].to_i if ev[:usage]
      when :permission_request
        @pending_permission = ev
        @mode = :permission
        @log << { kind: :tool_result, text: "  needs permission: #{ev[:detail]}" }
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
    # blank + composer (3) + status bar
    bottom = 5

    rendered = @log.map do |e|
      case e[:kind]
      when :user        then "#{@you.render("you")} #{e[:text]}"
      when :assistant   then @bot.render(e[:text])
      when :tool        then @tool.render("→ #{e[:text]}")
      when :tool_result then @toolok.render("  #{e[:text]}")
      when :error       then @err.render("! #{e[:text]}")
      end
    end.flat_map { |s| s.to_s.split("\n") }

    budget = [@height - bottom - extra, 5].max
    rendered.last(budget)
  end
end