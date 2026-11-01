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
end
