# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../scripts/upgrade_private_viridian_escort'
require_relative '../essentials/Plugins/Shattered Viridian/001_Entry'

module ShatteredRoute22
  def self.cleared?; true; end
end

class EscortActor
  attr_reader :x, :y
  def initialize(x, y); @x = x; @y = y; end
  def moveto(x, y); @x = x; @y = y; end
end

class PrivateViridianEscortTest < Minitest::Test
  def setup
    $PokemonGlobal = Object.new
    $game_switches = Hash.new(false)
  end

  def test_native_guard_and_nidoran_routes_are_cardinal_and_end_at_center
    e = ShatteredPrivateViridianEscort
    assert_equal [25, 27], final(e::GUARD_START, e::GUARD_STEPS)
    assert_equal [24, 27], final(e::NIDORAN_START, e::NIDORAN_STEPS)
    assert_equal 10, e::GUARD_STEPS.length
    assert_equal 8, e::NIDORAN_STEPS.length
    assert_equal 4, e::DELTA.size
    route = e.move_route(e::GUARD_STEPS)
    refute route.repeat
    assert route.skippable
    assert_equal e::GUARD_STEPS + [0], route.list.map(&:code)
  end

  def test_event_pages_swap_from_escort_to_persistent_center_guards
    e = ShatteredPrivateViridianEscort
    guard = e.actor(25, 'guard', [24, 20], 'NPC 07', '', 'Follow me')
    nidoran = e.actor(26, 'nidoran', [23, 20], 'POKEMON_NidoranMale', '')
    finished = e.finish_actor(27, 'center', [25, 27], 'NPC 07', 'Safe now')
    assert_equal 'NPC 07', guard.pages[0].graphic.character_name
    assert_equal '', guard.pages[1].graphic.character_name
    assert_equal 'POKEMON_NidoranMale', nidoran.pages[0].graphic.character_name
    assert_equal '', finished.pages[0].graphic.character_name
    assert_equal 'NPC 07', finished.pages[1].graphic.character_name
    assert_equal 994, finished.pages[1].condition.switch1_id
    assert finished.pages[1].condition.switch1_valid
    assert [guard, nidoran, finished].all? { |event| event.pages.all?(&:through) }
  end

  def test_tile_collision_and_existing_event_conflicts_reject_escort_routes
    e = ShatteredPrivateViridianEscort
    map = RPG::Map.new
    map.width = 50; map.height = 40; map.tileset_id = 1
    map.data = Object.new
    map.data.define_singleton_method(:[]) do |x, y, z|
      z == 0 ? ([24, 22] == [x, y] ? 2 : 1) : 0
    end
    tileset = RPG::Tileset.new
    tileset.passages = Object.new
    tileset.passages.define_singleton_method(:[]) { |tile| tile == 2 ? 15 : 0 }
    assert_raises(RuntimeError) do
      e.path!(e::GUARD_START, e::GUARD_STEPS, e::GUARD_FINISH, map, [nil, tileset], [])
    end
    assert_raises(RuntimeError) do
      e.path!(e::GUARD_START, e::GUARD_STEPS, e::GUARD_FINISH, map, [nil, tileset], [[24, 21]])
    end
  end

  def test_arrival_requires_both_actors_and_persists_after_save_reload
    e = ShatteredPrivateViridianEscort
    guard = EscortActor.new(*e::GUARD_START)
    nidoran = EscortActor.new(*e::NIDORAN_START)
    $game_map = Struct.new(:events).new({25 => guard, 26 => nidoran})
    assert ShatteredViridian.start!(993, 996)
    refute ShatteredViridian.complete_route!(25, 26, e::GUARD_START, e::NIDORAN_START,
      e::GUARD_FINISH, e::NIDORAN_FINISH, 993, 996)
    refute ShatteredViridian.state[:arrived]
    refute $game_switches[994]
    assert_equal e::GUARD_START, [guard.x, guard.y]
    guard.moveto(*e::GUARD_FINISH)
    nidoran.moveto(*e::NIDORAN_FINISH)
    assert ShatteredViridian.complete_route!(25, 26, e::GUARD_START, e::NIDORAN_START,
      e::GUARD_FINISH, e::NIDORAN_FINISH, 993, 996)
    assert ShatteredViridian.arrive!(994)
    assert $game_switches[994]
    $PokemonGlobal = Marshal.load(Marshal.dump($PokemonGlobal))
    $game_switches[994] = false
    ShatteredViridian.sync!({started: 993, arrived: 994, center: 995, rain: 996})
    assert $game_switches[994]
    assert $game_switches[996]
    assert ShatteredViridian.center!(995, 996)
    refute $game_switches[996]
  ensure
    $game_map = nil
  end

  def test_refuses_nonstaged_project_without_modifying_input
    Dir.mktmpdir do |path|
      assert_raises(RuntimeError) { ShatteredPrivateViridianEscort.install!(path) }
      assert_empty Dir.children(path)
    end
  end

  private

  def final(start, steps)
    steps.reduce(start.dup) do |position, step|
      dx, dy = ShatteredPrivateViridianEscort::DELTA.fetch(step)
      [position[0] + dx, position[1] + dy]
    end
  end
end
