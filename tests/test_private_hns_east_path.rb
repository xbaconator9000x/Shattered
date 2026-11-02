# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../scripts/verify_private_hns_east_path'

class HnSEastWalkwayTest < Minitest::Test
  V = ShatteredHnSEastWalkway

  def table(width, height = 1, depth = 1, initial = 0)
    count = width * height * depth
    Table._load([3, width, height, depth, count].pack('V5') +
                Array.new(count, initial).pack('s<*'))
  end

  def map_and_tilesets
    map = RPG::Map.allocate
    map.instance_variable_set(:@width, 22)
    map.instance_variable_set(:@height, 21)
    map.instance_variable_set(:@tileset_id, 1)
    data = table(22, 21, 3, 384)
    # The real HnS map has a blocked central void: the direct y=9 shortcut
    # cannot be opened without changing a source-anchored wall/void tile.
    bytes = data.instance_variable_get(:@bytes).dup
    offset = 20 + 2 * (13 + 22 * (9 + 21 * 2))
    bytes[offset, 2] = [385].pack('s<')
    map.instance_variable_set(:@data, Table._load(bytes))
    events = {}
    {6 => [11, 7], 7 => [20, 9]}.each do |id, (x, y)|
      event = RPG::Event.allocate
      event.instance_variable_set(:@x, x)
      event.instance_variable_set(:@y, y)
      events[id] = event
    end
    map.instance_variable_set(:@events, events)
    tileset = RPG::Tileset.allocate
    passages = table(512)
    pbytes = passages.instance_variable_get(:@bytes).dup
    pbytes[20 + 385 * 2, 2] = [15].pack('s<')
    tileset.instance_variable_set(:@passages, Table._load(pbytes))
    tileset.instance_variable_set(:@priorities, table(512))
    tileset.instance_variable_set(:@terrain_tags, table(512))
    [map, [nil, tileset]]
  end

  def test_northern_route_reaches_east_door_without_opening_void
    map, tilesets = map_and_tilesets
    result = V.audit!(map, tilesets)
    assert_equal 11, result['steps']
    assert_equal [11, 8], result['path_from_post_aipom'].first
    assert_equal [19, 9], result['path_from_post_aipom'].last
    assert result['direct_shortcut_12_9_to_13_9_blocked']
    refute result['native_gameplay_verified']
  end

  def test_actual_shortcut_remains_blocked
    map, tilesets = map_and_tilesets
    refute V.step_passable?(map, tilesets[1], [12, 9], [13, 9])
  end

  def test_breaking_one_upper_walkway_tile_fails_closed
    map, tilesets = map_and_tilesets
    bytes = map.instance_variable_get(:@data).instance_variable_get(:@bytes).dup
    offset = 20 + 2 * (16 + 22 * (7 + 21 * 2))
    bytes[offset, 2] = [385].pack('s<')
    map.instance_variable_set(:@data, Table._load(bytes))
    assert_raises(RuntimeError) { V.audit!(map, tilesets) }
  end

  def test_moved_aipom_or_door_fails_closed
    map, tilesets = map_and_tilesets
    map.instance_variable_get(:@events)[6].instance_variable_set(:@x, 12)
    assert_raises(RuntimeError) { V.audit!(map, tilesets) }
  end
end
