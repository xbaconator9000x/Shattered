# frozen_string_literal: true
require "minitest/autorun"
require "ostruct"

# Test the actual plugin registration and the saved quest / RMXP switch
# reconciliation without pretending to boot the Essentials engine.
module EventHandlers
  @handlers = {}
  def self.add(event, name, handler)
    (@handlers[event] ||= {})[name] = handler
  end
  def self.fire(event, name)
    @handlers.fetch(event).fetch(name).call
  end
  def self.registered?(event, name)
    @handlers.fetch(event, {}).key?(name)
  end
end

load File.expand_path("../essentials/Plugins/Shattered Route22/001_Route22.rb", __dir__)

class Route22MapSetupTest < Minitest::Test
  def setup
    $PokemonGlobal = Object.new
    $game_switches = Hash.new(false)
    $game_map = OpenStruct.new(:map_id => 16, :need_refresh => false)
  end

  def fire
    EventHandlers.fire(:on_game_map_setup, :shattered_route22_reconcile)
  end

  def test_registration
    assert EventHandlers.registered?(:on_game_map_setup, :shattered_route22_reconcile)
  end

  def test_completed_save_refreshes_native_event_pages
    ShatteredRoute22.state[:cleared] = true
    refute $game_switches[992]
    assert_equal true, fire
    assert $game_switches[992]
    assert $game_map.need_refresh
  end

  def test_stale_win_switch_cannot_skip_mandatory_battle
    $game_switches[992] = true
    assert_equal false, fire
    refute $game_switches[992]
    assert $game_map.need_refresh
  end

  def test_unrelated_map_does_not_initialise_save_or_mutate_switch
    $game_map.map_id = 223
    $game_switches[992] = true
    assert_equal false, fire
    assert $game_switches[992]
    refute $PokemonGlobal.instance_variable_defined?(:@shattered_route22_rattata)
  end

  def test_missing_global_data_is_safe
    $PokemonGlobal = nil
    assert_equal false, fire
    refute $game_map.need_refresh
  end

  def test_corrupt_saved_state_fails_closed
    $PokemonGlobal.instance_variable_set(:@shattered_route22_rattata,
      { :version => 2, :cleared => true })
    $game_switches[992] = true
    assert_raises(RuntimeError) { fire }
    assert $game_switches[992]
  end

  # Essentials v21.1 normal Continue restores the saved MapFactory directly,
  # skipping Game_Map#setup. Scene_Map#createSpritesets fires this event.
  def continue_scene
    EventHandlers.fire(:on_map_or_spriteset_change, :shattered_route22_reconcile_on_continue)
  end

  def test_continue_scene_hook_is_registered
    assert EventHandlers.registered?(:on_map_or_spriteset_change, :shattered_route22_reconcile_on_continue)
  end

  def test_continue_repairs_saved_victory_with_stale_switch
    ShatteredRoute22.state[:cleared] = true
    refute $game_switches[992]
    assert continue_scene
    assert $game_switches[992]
    assert $game_map.need_refresh
  end

  def test_continue_repairs_stale_switch_that_would_skip_mandatory_battle
    $game_switches[992] = true
    refute continue_scene
    refute $game_switches[992]
    assert $game_map.need_refresh
    refute ShatteredRoute22.cleared?
  end

  def test_continue_does_not_mutate_unrelated_map_or_uninitialized_save
    $game_map.map_id = 223
    $game_switches[992] = true
    refute continue_scene
    assert $game_switches[992]
    refute $PokemonGlobal.instance_variable_defined?(:@shattered_route22_rattata)
    $game_map.map_id = 16
    $PokemonGlobal = nil
    refute continue_scene
  end

  def test_continue_and_map_setup_callbacks_are_idempotent
    ShatteredRoute22.state[:cleared] = true
    assert continue_scene
    assert fire
    assert continue_scene
    assert $game_switches[992]
  end

  def test_continue_rejects_corrupted_save_without_overwriting_it
    $PokemonGlobal.instance_variable_set(:@shattered_route22_rattata,
      { :version => 9, :cleared => true })
    $game_switches[992] = true
    assert_raises(RuntimeError) { continue_scene }
    assert $game_switches[992]
  end
end
