# frozen_string_literal: true
# Tests the actual merged Core v0.2.3 and Beedrill raid together.
# Essentials API doubles are intentionally narrow: this is NOT native runtime evidence.
require "minitest/autorun"

class Pokemon
  attr_reader :species, :level
  def initialize(species, level = 5)
    @species, @level = species, level
  end
  def able?
    true
  end
end

module GameData
  class Species
    def self.exists?(species)
      [:HUMAN, :BEEDRILL].include?(species)
    end
  end
end

module EventHandlers
  @handlers = {}
  def self.add(event, key, handler)
    @handlers[[event, key]] = handler
  end
  def self.handler(event, key)
    @handlers[[event, key]]
  end
end

module WildBattle
  class << self
    attr_accessor :calls, :result, :during_battle
    def start(species, level)
      self.calls ||= []
      calls << [species, level]
      during_battle.call if during_battle
      $game_variables[77] = result
    end
  end
end

$rules = []
def setBattleRule(*args)
  $rules << args
end

load File.expand_path("../essentials/Plugins/Shattered Core/001_Core.rb", __dir__)
load File.expand_path("../essentials/Plugins/Shattered Raid/001_Raid.rb", __dir__)

class RaidMergedCoreIntegrationTest < Minitest::Test
  def setup
    $PokemonGlobal = Object.new
    $player = Struct.new(:party) do
      def able_pokemon_count
        party.count { |pkmn| pkmn.respond_to?(:able?) && pkmn.able? }
      end
    end.new([])
    $game_variables = Hash.new(0)
    $game_switches = Hash.new(false)
    $game_map = Struct.new(:map_id).new(301)
    $rules = []
    WildBattle.calls = []
    WildBattle.result = 1
    WildBattle.during_battle = nil
  end

  def config
    {
      "map_id" => 301, "outcome_variable_id" => 77,
      "events" => (0..2).map { |i| {"index" => i, "level" => 5 + i, "switch_id" => 81 + i} }
    }
  end

  def test_real_core_human_gate_blocks_missing_and_imposter_party_members
    refute ShatteredRaid.trigger(0, config)
    $player.party << Struct.new(:species).new(:HUMAN)
    refute ShatteredRaid.trigger(0, config),
      "A HUMAN-looking stub must not pass Core's genuine Pokemon identity check"
    assert_empty WildBattle.calls
    $player.party.clear
    $player.party << Pokemon.new(:HUMAN)
    assert Shattered.human?($player.party.first)
    assert ShatteredRaid.trigger(0, config)
    assert_equal [[:BEEDRILL, 5]], WildBattle.calls
    assert_equal [["disablePokeBalls"], ["canLose"], ["outcome", 77]], $rules
  end

  def test_save_restore_retries_flee_and_keeps_completed_encounters_cleared
    $player.party << Pokemon.new(:HUMAN)
    WildBattle.result = 3
    refute ShatteredRaid.trigger(0, config)
    assert_equal 0, ShatteredRaid.progression
    WildBattle.result = 1
    assert ShatteredRaid.trigger(0, config)
    $PokemonGlobal = Marshal.load(Marshal.dump($PokemonGlobal))
    $game_switches[81] = false
    $game_switches[82] = true
    assert EventHandlers.handler(:on_game_map_setup, :shattered_raid_switch_sync).call(301, nil, nil)
    assert $game_switches[81]
    refute $game_switches[82]
    refute ShatteredRaid.trigger(0, config)
    assert ShatteredRaid.trigger(1, config)
    assert_equal 2, ShatteredRaid.progression
  end

  def test_nested_raid_cannot_launch_second_battle
    $player.party << Pokemon.new(:HUMAN)
    nested = []
    WildBattle.during_battle = proc { nested << ShatteredRaid.trigger(0, config) }
    assert ShatteredRaid.trigger(0, config)
    assert_equal [false], nested
    assert_equal 1, WildBattle.calls.length
  end
end
