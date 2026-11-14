# frozen_string_literal: true
require 'minitest/autorun'

class Pokemon
  attr_accessor :species, :level, :calc_count
  def initialize(species, level)
    @species = species
    @level = level
    @calc_count = 0
  end
  def calc_stats
    @calc_count += 1
  end
end

module Shattered
  def self.human?(pokemon)
    pokemon.is_a?(Pokemon) && pokemon.species == :HUMAN
  end
end

module GameData
  class Move
    Entry = Struct.new(:type)
    TYPES = { :QUICKATTACK => 10, :EMBER => 10, :KARATECHOP => 1 }.freeze
    def self.try_get(id)
      type = TYPES[id]
      type && Entry.new(type)
    end
  end
end

$gameplay_payload = {
  'classes' => [
    {'name' => 'Starting HUMAN', 'types' => [9, 9], 'moves' => [[1, 33, 'Tackle']]},
    {'name' => 'Firebreather', 'types' => [9, 10], 'path_a' => 1, 'path_b' => 2,
     'moves' => [[1, 98, 'Quick Attack'], [20, 52, 'Ember'], [31, 2, 'Karate Chop']]},
    {'name' => 'Martial Artist', 'types' => [9, 1], 'path_a' => 1, 'path_b' => 2},
    {'name' => 'Flame Monk', 'types' => [9, 10], 'path_a' => 1, 'path_b' => 2}
  ]
}
def load_data(_path)
  $gameplay_payload
end

require_relative '../essentials/Plugins/Shattered Gameplay/001_Gameplay'

class ShatteredGameplayMigrationTest < Minitest::Test
  def setup
    ShatteredGameplay.instance_variable_set(:@data, nil)
  end

  def test_legacy_primary_path_migrates_to_matching_curriculum_record
    human = Pokemon.new(:HUMAN, 30)
    human.instance_variable_set(:@shattered_specialisation,
      {:version => 1, :primary => :FIREBREATHER, :advanced => nil})
    state = ShatteredGameplay.state(human)
    assert_equal 1, state[:class_id]
    assert_equal 1, state[:secondary_id]
    assert_equal 'Firebreather', ShatteredGameplay.class_record(state[:class_id])['name']
  end

  def test_legacy_combination_prefers_matching_advanced_curriculum_record
    human = Pokemon.new(:HUMAN, 55)
    human.instance_variable_set(:@shattered_specialisation,
      {:version => 1, :primary => :FIREBREATHER, :advanced => :FLAMEMONK})
    assert_equal 3, ShatteredGameplay.state(human)[:class_id]
    assert_equal 1, ShatteredGameplay.state(human)[:secondary_id]
  end

  def test_unknown_legacy_value_falls_back_to_starting_human
    human = Pokemon.new(:HUMAN, 30)
    human.instance_variable_set(:@shattered_specialisation,
      {:version => 1, :primary => :UNKNOWN, :advanced => nil})
    assert_equal 0, ShatteredGameplay.state(human)[:class_id]
    assert_nil ShatteredGameplay.state(human)[:secondary_id]
  end

  def test_tampered_curriculum_state_is_rejected
    human = Pokemon.new(:HUMAN, 30)
    human.instance_variable_set(ShatteredGameplay::STATE_IVAR,
      {:version => 2, :class_id => 99, :secondary_id => nil, :known => [], :trials => []})
    assert_raises(ArgumentError) { ShatteredGameplay.state(human) }
  end

  def test_study_uses_authenticated_extractor_moves_schema_and_level_gate
    human = Pokemon.new(:HUMAN, 20)
    human.instance_variable_set(ShatteredGameplay::STATE_IVAR,
      {:version => 2, :class_id => 1, :secondary_id => nil, :known => [], :trials => []})
    assert_equal [:QUICKATTACK, :EMBER], ShatteredGameplay.study!(human)
    assert_equal [:QUICKATTACK, :EMBER], ShatteredGameplay.state(human)[:known]
  end

  def test_qualifying_moves_use_essentials_move_type_registry
    human = Pokemon.new(:HUMAN, 30)
    human.instance_variable_set(ShatteredGameplay::STATE_IVAR,
      {:version => 2, :class_id => 0, :secondary_id => nil,
       :known => [:QUICKATTACK, :EMBER, :KARATECHOP], :trials => []})
    assert_equal [:QUICKATTACK, :EMBER], ShatteredGameplay.qualifying_moves(human, 1)
    ShatteredGameplay.record_trial!(human, 1)
    assert ShatteredGameplay.can_choose_primary?(human, 1)
  end
end
