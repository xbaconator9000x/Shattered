# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../scripts/verify_private_opening_walkability'

class PrivateOpeningWalkabilityTest < Minitest::Test
  V = ShatteredOpeningWalkability

  def table(*values)
    Table._load([1, values.size, 1, 1, values.size].pack('L<5') + values.pack('s<*'))
  end

  def synthetic_map(width, height, tiles)
    data = Table._load([3, width, height, 3, width * height * 3].pack('L<5') +
      (tiles + Array.new(width * height * 2, 0)).pack('s<*'))
    map = RPG::Map.allocate
    map.instance_variable_set(:@width, width)
    map.instance_variable_set(:@height, height)
    map.instance_variable_set(:@data, data)
    tileset = RPG::Tileset.allocate
    [:@passages, :@priorities, :@terrain_tags].zip([
      table(0, 0, 15, 2, 16), table(0, 0, 0, 0, 1), table(0, 0, 0, 0, 0)
    ]).each { |key, value| tileset.instance_variable_set(key, value) }
    [map, tileset]
  end

  def test_native_table_roundtrip_header_and_indexing
    t = table(0, 3, 16)
    assert_equal 3, t[1]
    assert_nil t[3]
    assert_raises(RuntimeError) { Table._load('garbled') }
  end

  def test_directional_passage_checks_both_ends
    map, tileset = synthetic_map(3, 1, [1, 3, 1])
    assert V.tile_passable?(map, tileset, 0, 0, 6)
    refute V.tile_passable?(map, tileset, 1, 0, 4)
    assert_equal 1, V.traverse(map, tileset, [0, 0]).length
  end

  def test_native_blocked_tile_and_event_obstacle
    map, tileset = synthetic_map(3, 1, [1, 2, 1])
    refute V.tile_passable?(map, tileset, 1, 0, 6)
    assert_equal 1, V.traverse(map, tileset, [0, 0]).length
    map, tileset = synthetic_map(3, 1, [1, 1, 1])
    assert_equal 3, V.traverse(map, tileset, [0, 0]).length
    assert_equal 1, V.traverse(map, tileset, [0, 0], blocked: [[1, 0]]).length
  end

  def test_star_priority_layer_does_not_short_circuit_lower_collision
    map, tileset = synthetic_map(1, 1, [2])
    map.instance_variable_set(:@data,
      Table._load([3, 1, 1, 3, 3].pack('L<5') + [2, 0, 4].pack('s<*')))
    refute V.tile_passable?(map, tileset, 0, 0, 2)
  end

  def test_refuses_unstaged_and_missing_engine
    Dir.mktmpdir do |dir|
      assert_raises(RuntimeError) { V.check!(dir) }
      File.write(File.join(dir, 'SHATTERED_STAGING_REPORT.json'), '{}')
      assert_raises(RuntimeError) { V.check!(dir) }
    end
  end

  def test_real_private_native_candidate_when_explicitly_supplied
    project = ENV['SHATTERED_PRIVATE_PROJECT']
    skip 'Private game assets deliberately absent from public CI' unless project && File.directory?(project)
    report = V.check!(project)
    assert_equal 'native_hns_gate_directional_navigation_preflight', report.fetch('kind')
    assert report.fetch('south_rock_blocks_after_collapse')
    assert report.fetch('distinct_b2f_landings_passable')
    refute report.fetch('actual_gameplay_verified')
  end
end
