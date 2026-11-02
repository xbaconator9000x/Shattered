# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../scripts/repair_private_hns_north_warps'

class NativeHNSNorthWarpTests < Minitest::Test
  Repair = ShatteredHNSNorthWarpRepair
  class TileLayer
    def initialize; @tiles = {}; end
    def zsize; 3; end
    def [](*coords); @tiles.fetch(coords, 0); end
    def put(x, y, z, id); @tiles[[x, y, z]] = id; end
  end
  class Passage
    def initialize; @flags = {}; end
    def [](id); @flags[id]; end
    def put(id, flag); @flags[id] = flag; end
  end

  def command(code, args)
    c = RPG::EventCommand.allocate
    c.code, c.indent, c.parameters = code, 0, args
    c
  end
  def event(id, name, x, y, args)
    e = RPG::Event.allocate
    e.id, e.name, e.x, e.y = id, name, x, y
    p = RPG::Event::Page.allocate
    p.trigger, p.through, p.list = 1, true, [command(201, args.dup), command(0, [])]
    e.pages = [p]
    e
  end
  def setup
    @gate = RPG::Map.allocate
    @gate.width, @gate.height = 22, 21
    @gate.events = {
      2 => event(2, 'HnS transfer VictoryRoadKanto_B2F_hns', 11, 1, Repair::ORIGINAL),
      3 => event(3, 'HnS transfer VictoryRoadKanto_B2F_hns', 10, 1, Repair::ORIGINAL)
    }
    @road = RPG::Map.allocate
    @road.width, @road.height, @road.tileset_id = 40, 50, 1
    @road.events = { 1 => event(1, 'HnS transfer ReceptionGate_hns', 30, 47, Repair::RETURN) }
    @road.data = TileLayer.new
    @road.data.put(30, 46, 1, 501)
    @road.data.put(29, 47, 1, 502)
    @passages = Passage.new
    @passages.put(501, 0)
    @passages.put(502, 0)
    tileset = RPG::Tileset.allocate
    tileset.passages = @passages
    @tilesets = [nil, tileset]
  end

  def test_two_north_exits_are_repaired_without_changing_return
    assert_equal :repairable, Repair.validate!(@gate, @road, @tilesets)
    @gate.events[3].pages.first.list.first.parameters = Repair::CORRECTED.dup
    assert_equal :unchanged, Repair.validate!(@gate, @road, @tilesets)
    assert_equal Repair::RETURN, @road.events[1].pages.first.list.first.parameters
  end
  def test_refuses_second_landing_when_blocked
    @passages.put(502, 15)
    assert_raises(RuntimeError) { Repair.validate!(@gate, @road, @tilesets) }
  end
  def test_refuses_destination_overlapping_return_event
    @road.events[1].x, @road.events[1].y = 29, 47
    assert_raises(RuntimeError) { Repair.validate!(@gate, @road, @tilesets) }
  end
  def test_refuses_renamed_event_or_wrong_return
    @gate.events[3].name = 'unreviewed'
    assert_raises(RuntimeError) { Repair.validate!(@gate, @road, @tilesets) }
    @gate.events[3].name = 'HnS transfer VictoryRoadKanto_B2F_hns'
    @road.events[1].pages.first.list.first.parameters = [0, 223, 11, 2, 2, 0]
    assert_raises(RuntimeError) { Repair.validate!(@gate, @road, @tilesets) }
  end
  def test_refuses_event_page_or_unsafe_target_drift
    @gate.events[3].pages.first.list.first.parameters = [0, 224, 32, 47, 8, 0]
    assert_raises(RuntimeError) { Repair.validate!(@gate, @road, @tilesets) }
    @gate.events[3].pages.first.list.first.parameters = Repair::ORIGINAL.dup
    @gate.events[3].pages.first.trigger = 0
    assert_raises(RuntimeError) { Repair.validate!(@gate, @road, @tilesets) }
  end
end
