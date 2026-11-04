# frozen_string_literal: true
require 'minitest/autorun'

module EventHandlers
  @handlers = {}
  def self.add(event, key, callback)
    @handlers[[event, key]] = callback
  end
  def self.callback(event, key)
    @handlers.fetch([event, key])
  end
end

require_relative '../essentials/Plugins/Shattered Gate Story/001_GateStory'

class HNSDebrisSaveStateTest < Minitest::Test
  FakeEvent = Struct.new(:name)
  FakeMap = Struct.new(:map_id, :events, :need_refresh)

  def setup
    $PokemonGlobal = Object.new
    $game_switches = {}
    $game_map = FakeMap.new(223, {
      1 => FakeEvent.new('SHATTERED_HNS:1'),
      8 => FakeEvent.new('SHATTERED_HNS_DEBRIS:8'),
      9 => FakeEvent.new('SHATTERED_HNS_DEBRIS:9')
    }, false)
  end

  def teardown
    $PokemonGlobal = nil
    $game_switches = nil
    $game_map = nil
    $game_screen = nil
  end

  def test_before_collapse_clears_stale_rock_switch
    $game_switches[997] = true
    assert ShatteredGateStory.reconcile_debris
    refute $game_switches[997]
    assert $game_map.need_refresh
  end

  def test_completed_collapse_restores_rocks_on_continue
    ShatteredGateStory.state[:impacts] = 6
    $game_switches[997] = false
    assert ShatteredGateStory.reconcile_debris
    assert $game_switches[997]
    assert $game_map.need_refresh
    $game_map.need_refresh = false
    EventHandlers.callback(:on_map_or_spriteset_change,
                           :shattered_hns_debris_continue).call
    assert $game_switches[997]
    assert $game_map.need_refresh
  end

  def test_map_setup_hook_and_unrelated_maps
    ShatteredGateStory.state[:impacts] = 6
    $game_map.map_id = 16
    refute EventHandlers.callback(:on_game_map_setup,
                                  :shattered_hns_debris_map_setup).call
    refute $game_switches.key?(997)
    $game_map.map_id = 223
    assert EventHandlers.callback(:on_game_map_setup,
                                  :shattered_hns_debris_map_setup).call
    assert $game_switches[997]
  end

  def test_old_private_candidate_without_debris_still_loads
    $game_map.events.delete(8)
    refute ShatteredGateStory.reconcile_debris
    refute $game_switches.key?(997)
  end

  def test_rejects_changed_native_event_identity
    $game_map.events[9].name = 'UNRELATED'
    assert_raises(ShatteredGateStory::InvalidState) do
      ShatteredGateStory.reconcile_debris
    end
  end

  def test_sixth_collapse_beat_activates_physical_rocks
    $game_screen = Object.new
    $game_screen.define_singleton_method(:start_shake) { |*args| nil }
    ShatteredGateStory.define_singleton_method(:pbSEPlay) { |_name| nil }
    ShatteredGateStory.define_singleton_method(:pbWait) { |_frames| nil }
    ShatteredGateStory.define_singleton_method(:pbMessage) { |_text| nil }
    ShatteredGateStory.define_singleton_method(:_INTL) { |text| text }
    assert ShatteredGateStory.run_collapse(
      ['Cries/TYRANITAR', 'Mining collapse'] * 3, 'Cries/TYRANITAR')
    assert_equal 6, ShatteredGateStory.state[:impacts]
    assert $game_switches[997]
    assert $game_map.need_refresh
  end
end
