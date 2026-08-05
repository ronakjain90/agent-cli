# frozen_string_literal: true

module Commands
  # The /worker command: pick which of the already-configured provider+model
  # pairs sub-agents should run on. Mixed into AgentApp, so it works on the
  # app's state (@provider, @mode, @menu_cursor, @log, …) like the other
  # pickers, and reuses its list-picker helpers.
  module Worker
    def open_worker_picker
      unless @provider
        @log << { kind: :error, text: 'connect a provider first — type /providers' }
        return [self, nil]
      end

      unless @provider.respond_to?(:worker_provider=)
        @log << { kind: :error, text: "#{@provider.label} manages its own sub-agents" }
        return [self, nil]
      end

      entries = worker_picker_entries
      @worker_picker_items = entries
      @mode = :worker_picker
      @menu_cursor = current_worker_index(entries)
      @menu_scroll = 0
      ensure_list_scroll(entries)
      [self, nil]
    end

    def update_worker_picker(message)
      update_list_picker(message, @worker_picker_items) { confirm_worker_selection }
    end

    def view_worker_picker
      lines = [@bot.render('Worker Model')]
      lines << @hint.render('  pick which configured model sub-agents run on')

      # The manager entry is always present, so one entry means nothing to pick.
      lines << @hint.render('  no other configured models  -  add one with /providers') if @worker_picker_items.one?

      visible = @worker_picker_items[@menu_scroll, list_menu_budget] || []
      current = @provider.worker_provider

      visible.each_with_index do |entry, i|
        selected = (@menu_scroll + i) == @menu_cursor
        prefix = selected ? '> ' : '  '

        if entry[:manager]
          text = "manager model  —  #{@provider.label}:#{@provider.model_label}"
          text << '  · current' if current.nil?
        else
          text = "#{entry[:label]}:#{entry[:model]}"
          text << "  (#{entry[:name]})" if entry[:name]
          text << '  · current' if same_worker_target?(entry, current)
        end

        lines << (selected ? @you.render("#{prefix}#{text}") : @hint.render("#{prefix}#{text}"))
      end

      lines << ''
      lines << @hint.render('up/down move | enter apply | esc back | ctrl+c quit')
      lines.join("\n")
    end

    private

    # Configured pairs — canonicalised through Provider so aliases collapse into
    # one row — minus the manager's own pair, plus a "use the manager model"
    # entry that clears the override.
    def worker_picker_entries
      pairs = Preferences.configured_pairs.filter_map do |pair|
        meta = Provider.find(pair[:provider])
        next if meta.nil? || same_worker_target?(pair, @provider)

        pair.merge(provider: meta.id.to_s, label: meta.label)
      end

      pairs.uniq { |pair| [pair[:provider], pair[:model]] } + [{ manager: true }]
    end

    def same_worker_target?(pair, target)
      return false if target.nil? || pair[:manager]

      meta = Provider.find(pair[:provider])
      meta && meta.label == target.label && pair[:model].to_s == target.model_label.to_s
    end

    # Falls back to the manager entry, which is always last.
    def current_worker_index(entries)
      worker = @provider.worker_provider
      return entries.length - 1 unless worker

      entries.index { |entry| same_worker_target?(entry, worker) } || (entries.length - 1)
    end

    def confirm_worker_selection
      item = @worker_picker_items[@menu_cursor]
      return [self, nil] unless item

      @mode = :chat
      @worker_picker_items = []

      item[:manager] ? use_manager_model : apply_worker(item[:provider], item[:model])
    end

    def use_manager_model
      @provider.worker_provider = nil
      Preferences.clear_worker
      @log << { kind: :assistant, text: "Workers will use the manager model (#{@provider.model_label})." }
      [self, nil]
    end

    def apply_worker(provider_id, model_id)
      meta = Provider.find(provider_id)
      unless meta
        @log << { kind: :error, text: "provider #{provider_id.inspect} not found" }
        return [self, nil]
      end

      worker = meta.build(model_id)
      unless worker.respond_to?(:agent_run)
        @log << { kind: :error, text: "#{meta.label} can't run worker agents" }
        return [self, nil]
      end
      return use_manager_model if Provider.same_target?(@provider, worker)

      @provider.worker_provider = worker
      Preferences.save_worker(meta.id, model_id)
      @log << { kind: :assistant, text: "Workers will use #{meta.label} · #{worker.model_label}." }
      [self, nil]
    rescue Settings::MissingApiKeyError => e
      @log << { kind: :error, text: "worker model needs an API key — #{e.message}" }
      [self, nil]
    rescue StandardError => e
      @log << { kind: :error, text: "failed to apply worker model: #{e.message}" }
      [self, nil]
    end
  end
end
