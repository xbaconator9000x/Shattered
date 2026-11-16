require 'minitest/autorun'
require 'ostruct'

module ShatteredViridian
  def self.state; {center: $sheltered}; end
end
module Shattered
  def self.human?(pokemon); pokemon.species == :HUMAN; end
  def self.restore_stamina(pokemon); pokemon.stamina = 60; end
end
module GameData
  class Item
    def self.exists?(id); [:CAMPINGKIT, :KNIFE, :SHATTEREDSUPPLYLIST].include?(id); end
  end
end
module ItemHandlers
  module UseInField
    def self.add(id, value); (@handlers ||= {})[id] = value; end
    def self.trigger(id); @handlers.fetch(id).call(id); end
  end
end
def pbMessage(text); ($messages ||= []) << text; end
def pbConfirmMessage(_text); $confirm; end

require_relative '../essentials/Plugins/Shattered Viridian/003_Quest'

class ViridianQuestTest < Minitest::Test
  Q = ShatteredViridianQuest
  Pokemon = Struct.new(:species, :hp, :stamina) do
    def heal; self.hp = 100; end
  end
  class Bag
    attr_accessor :full
    attr_reader :items
    def initialize; @items = []; end
    def add(item, quantity)
      return false if @full
      @items.concat([item] * quantity)
      true
    end
    def remove(item, quantity)
      quantity.times { @items.delete_at(@items.index(item)) }
      true
    end
  end
  def setup
    $PokemonGlobal = Object.new
    $player = OpenStruct.new(name: 'Wade', has_running_shoes: false,
      party: [Pokemon.new(:HUMAN, 1, 0), Pokemon.new(:AIPOM, 2, nil)])
    $bag = Bag.new
    $sheltered = false
    $messages = []
    $confirm = true
    $game_map = nil
    $game_self_switches = {}
    @dialogue = %w[hana morning council request accepted reminder thanks bag_full tools_full].to_h { |key| [key, [key + ' {PLAYER}']] }
    @dialogue['tour'] = Array.new(9) { |i| ["tour #{i}"] }
  end
  def reload
    $PokemonGlobal = Marshal.load(Marshal.dump($PokemonGlobal))
  end
  def test_native_event_flow_rest_tour_supply_and_retryable_reward
    refute Q.run_rest(@dialogue)
    refute Q.collect!('wood_1')
    $sheltered = true
    assert Q.run_rest(@dialogue)
    assert_equal [100, 100], $player.party.map(&:hp)
    assert_equal 60, $player.party.first.stamina
    reload
    assert Q.run_tour(@dialogue)
    assert_equal 9, Q.state[:tour_index]
    refute Q.tour_step!(8)
    assert Q.run_mara(@dialogue)
    Q.resource_ids.each do |id|
      assert Q.run_supply(id)
      refute Q.collect!(id)
      reload
    end
    $bag.full = true
    refute Q.run_mara(@dialogue)
    assert_equal :reward_pending, Q.state[:stage]
    assert_equal [:KNIFE, :SHATTEREDSUPPLYLIST], $bag.items
    reload
    $bag.full = false
    assert Q.run_mara(@dialogue)
    assert_equal :supplied, Q.state[:stage]
    assert_equal [:KNIFE, :SHATTEREDSUPPLYLIST, :CAMPINGKIT], $bag.items
    3.times { Q.run_mara(@dialogue); refute Q.claim_kit! }
    assert_equal [:KNIFE, :SHATTEREDSUPPLYLIST, :CAMPINGKIT], $bag.items
  end
  def test_cancel_rest_and_mission_preserves_progress
    $sheltered = true
    $confirm = false
    refute Q.run_rest(@dialogue)
    assert_equal :shelter, Q.state[:stage]
    assert_equal 1, $player.party.first.hp
    $confirm = true
    Q.rest!
    9.times { |i| Q.tour_step!(i) }
    $confirm = false
    refute Q.run_mara(@dialogue)
    assert_equal :tour, Q.state[:stage]
    refute Q.collect!('berry_1')
  end
  def test_corrupt_save_cannot_skip_tour_or_supplies
    Q.state[:stage] = :reward_pending
    assert_raises(Q::InvalidState) { Q.state }
    $PokemonGlobal = Object.new
    Q.state[:collected] = ['berry_1', 'berry_1']
    assert_raises(Q::InvalidState) { Q.state }
  end
  def test_saved_pickups_restore_native_self_switches
    $sheltered = true
    Q.rest!
    9.times { |i| Q.tour_step!(i) }
    Q.accept_supplies!
    Q.collect!('wood_1')
    $game_map = OpenStruct.new(map_id: 24, need_refresh: false,
      events: {31 => OpenStruct.new(name: 'SHATTERED_SUPPLY:wood_1'),
               32 => OpenStruct.new(name: 'SHATTERED_SUPPLY:berry_1')})
    $game_self_switches[[24, 32, 'A']] = true
    assert Q.reconcile_supplies
    assert $game_self_switches[[24, 31, 'A']]
    refute $game_self_switches[[24, 32, 'A']]
    assert $game_map.need_refresh
  end
  def test_camping_kit_field_handler_heals_and_respects_cancel
    $confirm = false
    refute ItemHandlers::UseInField.trigger(:CAMPINGKIT)
    assert_equal 1, $player.party.first.hp
    $confirm = true
    assert ItemHandlers::UseInField.trigger(:CAMPINGKIT)
    assert_equal 100, $player.party.first.hp
    assert_equal 60, $player.party.first.stamina
  end
end
