# frozen_string_literal: true
require 'minitest/autorun'
require 'ostruct'

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
end
