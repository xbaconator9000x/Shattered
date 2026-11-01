# frozen_string_literal: true
# Native map restoration hooks are source-tested here; a real Essentials
# Continue and weather/escort playthrough remain mandatory release gates.
require "minitest/autorun"

module EventHandlers
  @callbacks = {}
  def self.add(event, name, callback)
    (@callbacks[event] ||= {})[name] = callback
  end
  def self.call(event)
    (@callbacks[event] || {}).each_value { |callback| callback.call }
  end
  def self.registered?(event, name)
    (@callbacks[event] || {}).key?(name)
  end
end

load File.expand_path("../essentials/Plugins/Shattered Viridian/001_Entry.rb", __dir__)

class ViridianMapRestoreTest < Minitest::Test
  FakeMap = Struct.new(:map_id, :need_refresh)

  def setup
    $PokemonGlobal = Object.new
    $game_switches = Hash.new(false)
    $game_map = FakeMap.new(10, false)
  end

  def teardown
    $PokemonGlobal = nil
    $game_switches = nil
    $game_map = nil
  end

  def test_callbacks_cover_both_map_setup_and_continue
    assert EventHandlers.registered?(:on_game_map_setup, :shattered_viridian_restore)
    assert EventHandlers.registered?(:on_map_or_spriteset_change, :shattered_viridian_continue)
  end

  def test_restore_escort_after_continue_and_refresh_event_pages
    ShatteredViridian.start!(993, 996)
    ShatteredViridian.arrive!(994)
    $PokemonGlobal = Marshal.load(Marshal.dump($PokemonGlobal))
    [993, 994, 995, 996].each { |id| $game_switches[id] = false }
    EventHandlers.call(:on_map_or_spriteset_change)
    assert $game_switches[993]
    assert $game_switches[994]
    refute $game_switches[995]
    assert $game_switches[996]
    assert $game_map.need_refresh
  end

  def test_center_reentry_remains_dry_and_complete
    ShatteredViridian.start!(993, 996)
    ShatteredViridian.arrive!(994)
    ShatteredViridian.center!(995, 996)
    $PokemonGlobal = Marshal.load(Marshal.dump($PokemonGlobal))
    $game_map.map_id = 11
    [993, 994, 995, 996].each { |id| $game_switches[id] = false }
    $game_switches[996] = true
    EventHandlers.call(:on_game_map_setup)
    assert $game_switches[993]
    assert $game_switches[994]
    assert $game_switches[995]
    refute $game_switches[996]
    assert $game_map.need_refresh
  end

  def test_stale_arrival_switch_cannot_skip_escort
    $game_switches[994] = true
    assert ShatteredViridian.reconcile_on_map_restore
    refute $game_switches[994]
    assert $game_map.need_refresh
  end

  def test_unrelated_maps_and_unready_saves_are_untouched
    $game_switches[994] = true
    $game_map.map_id = 16
    refute ShatteredViridian.reconcile_on_map_restore
    assert $game_switches[994]
    $game_map.map_id = 10
    $PokemonGlobal = nil
    refute ShatteredViridian.reconcile_on_map_restore
    assert $game_switches[994]
  end

  def test_repeated_callback_is_idempotent
    ShatteredViridian.start!(993, 996)
    $game_switches[993] = false
    assert ShatteredViridian.reconcile_on_map_restore
    assert $game_map.need_refresh
    $game_map.need_refresh = false
    assert ShatteredViridian.reconcile_on_map_restore
    refute $game_map.need_refresh
  end

  def test_corrupted_save_fails_closed_without_switch_mutation
    $PokemonGlobal.instance_variable_set(:@shattered_viridian_entry, { version: 999 })
    $game_switches[994] = true
    assert_raises(RuntimeError) { ShatteredViridian.reconcile_on_map_restore }
    assert $game_switches[994]
  end
end
