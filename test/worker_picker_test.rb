# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/borgator'

# /worker shows the provider+model pairs the user already configured and lets
# them pick one, instead of silently re-applying whatever is in preferences.
class WorkerPickerTest < Minitest::Test
  PREFS = {
    'provider' => 'openrouter',
    'model' => 'poolside/laguna-s-2.1:free',
    'saved_models' => [
      { 'name' => 'laguna', 'provider' => 'openrouter', 'model' => 'poolside/laguna-s-2.1:free',
        'worker_provider' => 'openrouter', 'worker_model' => 'nvidia/nemotron:free' },
      { 'name' => 'ling', 'provider' => 'openrouter', 'model' => 'inclusionai/ling-3.0-flash:free' }
    ],
    'worker_provider' => 'openrouter',
    'worker_model' => 'nvidia/nemotron:free'
  }.freeze

  class FakeProvider
    attr_accessor :worker_provider

    def initialize(model = 'poolside/laguna-s-2.1:free')
      @model = model
    end

    def label = 'openrouter'
    def model_label = @model
    def agent_run(*) = nil
  end

  # Provider metadata, so building a worker needs no API key.
  class FakeMeta
    def id = :openrouter
    def label = 'openrouter'
    def build(model_id) = FakeProvider.new(model_id)
  end

  class Key
    def initialize(name) = @name = name
    def to_s = @name
    def esc? = @name == 'esc'
    def up? = @name == 'up'
    def down? = @name == 'down'
    def enter? = @name == 'enter'
  end

  def setup
    @written = nil
    written = ->(data) { @written = data }
    Preferences.singleton_class.class_eval do
      alias_method :orig_read_raw, :read_raw
      alias_method :orig_write, :write
      define_method(:read_raw) { Marshal.load(Marshal.dump(PREFS)) }
      define_method(:write) { |data| written.call(data) }
    end

    Provider.singleton_class.class_eval do
      alias_method :orig_find, :find
      define_method(:find) { |id| id.to_s == 'openrouter' ? FakeMeta.new : nil }
    end
  end

  def teardown
    Preferences.singleton_class.class_eval do
      alias_method :read_raw, :orig_read_raw
      alias_method :write, :orig_write
    end

    Provider.singleton_class.class_eval { alias_method :find, :orig_find }
  end

  def open_picker(worker_model: 'nvidia/nemotron:free')
    manager = FakeProvider.new
    manager.worker_provider = FakeProvider.new(worker_model) if worker_model
    app = AgentApp.new(manager)
    app.open_worker_picker
    [app, manager]
  end

  def items(app)
    app.instance_variable_get(:@worker_picker_items)
  end

  def test_opens_a_picker_listing_configured_pairs_without_the_manager_model
    app, = open_picker

    assert_equal :worker_picker, app.instance_variable_get(:@mode)
    models = items(app).reject { |i| i[:manager] }.map { |i| i[:model] }
    assert_equal ['nvidia/nemotron:free', 'inclusionai/ling-3.0-flash:free'], models
    assert items(app).last[:manager], 'expected a trailing manager-model entry'
  end

  def test_cursor_starts_on_the_worker_currently_in_effect
    app, = open_picker(worker_model: 'inclusionai/ling-3.0-flash:free')

    assert_equal 1, app.instance_variable_get(:@menu_cursor)
  end

  def test_cursor_starts_on_the_manager_entry_when_no_worker_is_set
    app, = open_picker(worker_model: nil)

    assert_equal items(app).length - 1, app.instance_variable_get(:@menu_cursor)
  end

  def test_selecting_a_pair_applies_and_persists_it
    app, manager = open_picker
    app.update_worker_picker(Key.new('down')) # move to the ling entry
    app.update_worker_picker(Key.new('enter'))

    assert_equal :chat, app.instance_variable_get(:@mode)
    assert_equal 'inclusionai/ling-3.0-flash:free', manager.worker_provider.model_label
    assert_equal 'inclusionai/ling-3.0-flash:free', @written['worker_model']
    assert_equal 'openrouter', @written['worker_provider']
  end

  def test_selecting_the_manager_entry_clears_the_worker_override
    app, manager = open_picker
    app.instance_variable_set(:@menu_cursor, items(app).length - 1)
    app.update_worker_picker(Key.new('enter'))

    assert_nil manager.worker_provider
    refute @written.key?('worker_model')
    refute @written.key?('worker_provider')
  end

  def test_esc_leaves_the_worker_unchanged
    app, manager = open_picker
    app.update_worker_picker(Key.new('esc'))

    assert_equal :chat, app.instance_variable_get(:@mode)
    assert_equal 'nvidia/nemotron:free', manager.worker_provider.model_label
    assert_nil @written
  end

  def test_requires_a_connected_provider
    app = AgentApp.new(nil)
    app.open_worker_picker

    assert_equal :chat, app.instance_variable_get(:@mode)
    last = app.instance_variable_get(:@log).last
    assert_equal :error, last[:kind]
    assert_includes last[:text], '/providers'
  end
end
