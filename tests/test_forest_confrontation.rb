# frozen_string_literal: true
require 'minitest/autorun'
require 'ostruct'

module Shattered
  def self.human?(pokemon)
    pokemon.species == :HUMAN
  end
end

class Pokemon
  attr_accessor :personalID, :moves
  attr_reader :species, :level, :iv
  def initialize(species, level)
    @species, @level, @moves = species, level, []
    @iv = { :HP => 0, :ATTACK => 0 }
  end
  def learn_move(move); @moves << move; end
  def calc_stats; true; end
end

def pbConfirmMessage(_message); $forest_confirm; end
def pbMessage(message); $forest_messages << message; end
def setBattleRule(*rule); $forest_rules << rule; end
def load_data(_path); $forest_payload; end

module WildBattle
  def self.start(foe)
    $forest_foe = foe
    $game_variables[ShatteredForestConfrontation::OUTCOME_VARIABLE] = $forest_outcome
  end
end

module ShatteredViridianQuest
  def self.state
    { :stage => $forest_stage }
  end
end

class ForestEvent
  attr_reader :name, :moves
  def initialize(name)
    @name = name
    @moves = []
  end

  def move_straight(direction)
    @moves << direction
    true
  end
end

require_relative '../essentials/Plugins/Shattered Viridian/006_ForestConfrontation'

class ForestConfrontationTest < Minitest::Test
  Q = ShatteredForestConfrontation

  def setup
    $PokemonGlobal = Object.new
    $forest_stage = :supplies
    $game_self_switches = {}
    @control = ForestEvent.new('SHATTERED_FOREST:confrontation')
    @left = ForestEvent.new('SHATTERED_FOREST_ACTOR:left')
    @right = ForestEvent.new('SHATTERED_FOREST_ACTOR:right')
    @top = ForestEvent.new('SHATTERED_FOREST_ACTOR:top')
    $game_map = OpenStruct.new(:map_id => Q::MAP_ID, :need_refresh => false,
      :events => { 20 => @control, 21 => @left, 22 => @right, 23 => @top })
    $forest_confirm = true
    $forest_messages = []
    $forest_rules = []
    $forest_outcome = 1
    $game_variables = Hash.new(0)
    $game_temp = Object.new
    $game_temp.define_singleton_method(:clear_battle_rules) { $forest_rules << [:cleared] }
    human = OpenStruct.new(:species => :HUMAN)
    human.define_singleton_method(:able?) { true }
    $player = OpenStruct.new(:party => [human])
    $forest_payload = {
      'foe' => { 'species' => 'RAIDER', 'level' => 7, 'personality' => 42,
                 'moves' => ['TACKLE'], 'iv' => 12 },
      'dialogue' => { 'choice' => ['choice'], 'intro' => ['intro'],
                      'won' => ['won'], 'lost' => ['lost'], 'after' => ['after'] }
    }
  end

  def test_reconcile_restores_and_hides_control_and_staging_actors
    assert Q.reconcile
    [20, 21, 22, 23].each do |id|
      assert_equal true, $game_self_switches[[Q::MAP_ID, id, 'A']]
    end
    assert $game_map.need_refresh

    Q.state[:resolved] = true
    $game_map.need_refresh = false
    assert Q.reconcile
    [20, 21, 22, 23].each do |id|
      assert_equal false, $game_self_switches[[Q::MAP_ID, id, 'A']]
    end
    assert $game_map.need_refresh
  end

  def test_choreography_uses_deterministic_bounded_steps
    assert Q.play_choreography(:approach)
    assert_equal [6], @left.moves
    assert_equal [4], @right.moves
    assert_equal [2], @top.moves

    assert Q.play_choreography(:retreat)
    assert_equal [6, 4], @left.moves
    assert_equal [4, 6], @right.moves
    assert_equal [2, 8], @top.moves
  end

  def test_trigger_runs_private_payload_battle_and_persists_win
    assert Q.trigger
    assert_equal :RAIDER, $forest_foe.species
    assert_equal 42, $forest_foe.personalID
    assert_equal [:TACKLE], $forest_foe.moves
    assert_equal true, Q.state[:resolved]
    assert_equal true, Q.state[:won]
    assert_equal false, $game_self_switches[[Q::MAP_ID, 20, 'A']]
    assert_includes $forest_rules, ['disablePokeBalls']
    assert_includes $forest_rules, ['cannotRun']
    assert_includes $forest_rules, [:cleared]
    assert_equal ['choice', 'intro', 'won', 'after'], $forest_messages
  end
end
