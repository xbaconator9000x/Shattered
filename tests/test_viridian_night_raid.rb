require 'minitest/autorun'
require 'ostruct'

module Shattered
  def self.human?(pokemon); pokemon.species == :HUMAN; end
  def self.restore_stamina(pokemon); pokemon.stamina = 60; end
end
module ShatteredViridianQuest
  def self.state; {stage: $chapter_stage}; end
  def self.heal_party!; $heal_count += 1; true; end
  def self.say(lines); lines.each { |line| pbMessage(line) }; end
end
class Pokemon
  attr_accessor :species, :level, :moves, :iv, :stamina, :personalID
  def initialize(species, level)
    @species, @level, @moves, @iv = species, level, [], {HP: 0, ATTACK: 0}
  end
  def learn_move(move); @moves << move; end
  def calc_stats; $calculated = true; end
  def able?; true; end
end
module WildBattle
  def self.start(foe)
    $foes << foe
    raise 'battle setup failed' if $battle_error
    $during_battle.call if $during_battle
    $game_variables[990] = $decision
    true # A skipped/lost battle's return value must never grant rescue credit.
  end
end
def load_data(_path); $raid_data; end
def pbMessage(message); $messages << message; end
def pbConfirmMessage(_message); $confirm; end
def setBattleRule(*rule); $rules << rule; end
require_relative '../essentials/Plugins/Shattered Viridian/005_NightRaid'

class ViridianNightRaidTest < Minitest::Test
  Q = ShatteredViridianNightRaid
  def setup
    $PokemonGlobal = Object.new
    $player = OpenStruct.new(party: [Pokemon.new(:HUMAN, 8)])
    $game_variables, $game_self_switches, $rules, $messages, $foes = {}, {}, [], [], []
    $chapter_stage, $confirm, $decision = :supplied, true, 1
    $heal_count, $calculated, $battle_error, $during_battle = 0, false, false, nil
    $game_map = OpenStruct.new(map_id: 10, need_refresh: false,
      events: Q::IDS.each_with_index.to_h { |id, i| [30+i, OpenStruct.new(name: Q::EVENT_PREFIX+id)] })
    $game_temp = OpenStruct.new
    def $game_temp.clear_battle_rules; $rules.clear; end
    $raid_data = {'encounters' => Q::IDS.each_with_index.map { |id, index|
      {'id' => id, 'species' => index < 3 ? 'BEEDRILL' : 'RAIDER', 'level' => index < 2 ? 6 : 8,
       'moves' => %w[POUND LEER FOCUSENERGY QUICKATTACK], 'iv' => 15, 'personality' => 0x23456789,
       'dialogue' => {'intro' => [id+' intro'], 'won' => [id+' won'], 'lost' => [id+' lost']}}
    }}
  end
  def reload
    $PokemonGlobal = Marshal.load(Marshal.dump($PokemonGlobal))
  end
  def test_full_native_event_sequence_with_save_restoration
    refute Q.trigger('ren')
    assert Q.run_rest
    assert_equal :active, Q.state[:stage]
    assert $game_self_switches[[10, 30, 'A']]
    # Rescues are independent: source order need not be forced on the player.
    Q::IDS.reverse.each do |id|
      assert Q.trigger(id)
      refute Q.trigger(id)
      reload
      $game_self_switches.clear
      Q.reconcile
      refute $game_self_switches[[10, 30+Q::IDS.index(id), 'A']]
    end
    assert_equal :cleared, Q.state[:stage]
    assert_equal 5, $foes.length
    assert_equal [:RAIDER, :RAIDER, :BEEDRILL, :BEEDRILL, :BEEDRILL], $foes.map(&:species)
    assert_equal [8, 8, 8, 6, 6], $foes.map(&:level)
    assert $foes.all? { |foe| foe.moves == [:POUND, :LEER, :FOCUSENERGY, :QUICKATTACK] }
    assert $foes.all? { |foe| foe.iv.values == [15, 15] && foe.personalID == 0x23456789 }
    assert $calculated
    assert_includes $rules, ['disablePokeBalls']
    assert_includes $rules, ['cannotRun']
    assert Q.run_rest
    assert_equal :rested, Q.state[:stage]
    reload
    refute Q.run_rest
    assert_equal 2, $heal_count
  end
  def test_losses_escape_and_skipped_battles_never_advance
    Q.run_rest
    [0, 2, 3, 4, 5].each do |decision|
      $decision = decision
      refute Q.trigger('ren')
      assert_empty Q.state[:rescued]
      assert_equal :active, Q.state[:stage]
    end
    assert_equal 60, $player.party.first.stamina
    assert_includes $messages, 'ren lost'
    $decision = 1
    assert Q.trigger('ren')
  end
  def test_exception_cleans_battle_rules_and_allows_retry
    Q.run_rest
    $battle_error = true
    assert_raises(RuntimeError) { Q.trigger('mara') }
    assert_empty Q.state[:rescued]
    assert_empty $rules
    $battle_error = false
    assert Q.trigger('mara')
  end
  def test_reentrant_event_does_not_launch_second_battle
    Q.run_rest
    $during_battle = proc { refute Q.trigger('cook') }
    assert Q.trigger('ren')
    assert_equal 1, $foes.length
    assert_equal ['ren'], Q.state[:rescued]
  end
  def test_prerequisites_decline_and_wrong_map
    $chapter_stage = :supplies
    refute Q.run_rest
    $chapter_stage = :supplied
    $confirm = false
    refute Q.run_rest
    assert_equal :dormant, Q.state[:stage]
    $confirm = true
    Q.run_rest
    $game_map.map_id = 11
    refute Q.trigger('ren')
    $game_map.map_id = 10
    $player.party.unshift(Pokemon.new(:AIPOM, 8))
    refute Q.trigger('ren')
    assert_empty $foes
  end
  def test_corrupt_save_cannot_mark_raid_complete
    Q.state[:stage] = :cleared
    assert_raises(RuntimeError) { Q.state }
    $PokemonGlobal = Object.new
    Q.state[:rescued] = ['ren', 'ren']
    assert_raises(RuntimeError) { Q.state }
    assert_raises(ArgumentError) { Q.trigger('missing') }
  end
end
