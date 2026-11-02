# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../scripts/install_private_viridian_beedrill'

class PrivateViridianBeedrillTest < Minitest::Test
  B = ShatteredPrivateViridianBeedrill

  def test_three_native_encounters_are_sequential_and_player_touch
    events = 3.times.map { |i| B.event(i) }
    assert_equal B::EVENT_IDS, events.map(&:id)
    assert_equal B::POSITIONS, events.map { |e| [e.x, e.y] }
    assert_equal [2, 3, 3], events.map { |e| e.pages.length }
    events.each_with_index do |e, i|
      active = e.pages[-2]
      assert_equal 'Beedrill', active.graphic.character_name
      assert_equal 2, active.trigger
      refute active.through
      assert active.step_anime
      # All three encounters stay hidden until the first Center visit.
      if i.zero?
        assert_equal B::CENTER_SWITCH, active.condition.switch1_id
        assert active.condition.switch1_valid
      else
        assert_equal B::CENTER_SWITCH, active.condition.switch2_id
        assert active.condition.switch2_valid
      end
      assert_equal 355, active.list.first.code
      assert_includes active.list.first.parameters.first, "ShatteredRaid.trigger(#{i}, "
      assert_includes active.list.first.parameters.first, "\"switch_id\"=>#{B::SWITCHES[i]}"
      assert e.pages.last.through
      assert_equal B::SWITCHES[i], e.pages.last.condition.switch1_id
      assert e.pages.last.condition.switch1_valid
      if i > 0
        assert e.pages.first.through
        assert_equal '', e.pages.first.graphic.character_name
        assert_equal B::SWITCHES[i-1], active.condition.switch1_id
        assert active.condition.switch1_valid
      end
    end
  end

  def test_raid_switches_do_not_reuse_gate_or_other_opening_switches
    assert_equal [1001, 1002, 1003], B::SWITCHES
    assert_equal [997, 998, 999], B::LEGACY_SWITCHES
    assert_empty B::SWITCHES & (992..999).to_a
    assert_equal 995, B::CENTER_SWITCH
    refute_includes B::SWITCHES, B::CENTER_SWITCH
    B::EVENT_IDS.each_with_index do |id, index|
      active = B.event(index).pages[-2]
      assert_match(/"switch_id"=>#{B::SWITCHES[index]}/, active.list.first.parameters.first)
    end
  end

  def test_exact_legacy_events_upgrade_without_touching_unrelated_map_content
    map, tilesets = fixture
    3.times { |index| map.events[B::EVENT_IDS[index]] = B.event(index, B::LEGACY_SWITCHES, center_gate: false) }
    old_tiles = Marshal.dump(map.data)
    old_events = (1..28).to_h { |id| [id, Marshal.dump(map.events.fetch(id))] }
    assert_equal :migrated, B.migrate_legacy!(map)
    assert_equal old_tiles, Marshal.dump(map.data)
    old_events.each { |id, bytes| assert_equal bytes, Marshal.dump(map.events.fetch(id)) }
    assert_equal :already_installed, B.transform!(map, tilesets)
    B::EVENT_IDS.each_with_index do |id, index|
      assert_equal Marshal.dump(B.event(index)), Marshal.dump(map.events.fetch(id))
    end
  end

  def test_pinned_pre_center_candidate_upgrades_without_modifying_original_events
    map, tilesets = fixture
    3.times { |index| map.events[B::EVENT_IDS[index]] = B.event(index, B::SWITCHES, center_gate: false) }
    old_tiles = Marshal.dump(map.data)
    old_events = (1..28).to_h { |id| [id, Marshal.dump(map.events.fetch(id))] }
    assert_equal :migrated, B.migrate_pre_center_gate!(map)
    assert_equal old_tiles, Marshal.dump(map.data)
    old_events.each { |id, bytes| assert_equal bytes, Marshal.dump(map.events.fetch(id)) }
    assert_equal :already_installed, B.transform!(map, tilesets)
    B::EVENT_IDS.each_with_index do |id, index|
      assert_equal Marshal.dump(B.event(index)), Marshal.dump(map.events.fetch(id))
    end
  end

  def test_pre_center_upgrade_rejects_tampered_events_without_mutating_map
    map, _tilesets = fixture
    3.times { |index| map.events[B::EVENT_IDS[index]] = B.event(index, B::SWITCHES, center_gate: false) }
    map.events[31].pages[-2].list.first.parameters[0] = 'unsafe'
    before = Marshal.dump(map)
    assert_raises(RuntimeError) { B.migrate_pre_center_gate!(map) }
    assert_equal before, Marshal.dump(map)
  end

  def test_partial_legacy_event_migration_is_rejected
    map, _tilesets = fixture
    3.times { |index| map.events[B::EVENT_IDS[index]] = B.event(index, B::LEGACY_SWITCHES) }
    map.events[30].pages[-2].list.first.parameters[0] = 'tampered'
    before = Marshal.dump(map)
    assert_raises(RuntimeError) { B.migrate_legacy!(map) }
    assert_equal before, Marshal.dump(map)
  end

  def test_map_install_preserves_all_unrelated_events_and_tiles
    map, tilesets = fixture
    original_events = map.events.transform_values { |e| Marshal.dump(e) }
    original_tiles = Marshal.dump(map.data)
    assert_equal :installed, B.transform!(map, tilesets)
    assert_equal (1..31).to_a, map.events.keys.sort
    assert_equal original_tiles, Marshal.dump(map.data)
    original_events.each { |id, bytes| assert_equal bytes, Marshal.dump(map.events.fetch(id)) }
    assert_equal :already_installed, B.transform!(map, tilesets)
  end

  def test_occupied_and_blocked_tiles_are_rejected_before_changes
    map, tilesets = fixture
    event = RPG::Event.new(*B::POSITIONS[0]); event.id = 9; map.events[9] = event
    assert_raises(RuntimeError) { B.transform!(map, tilesets) }
    assert_equal (1..28).to_a, map.events.keys.sort
    map, tilesets = fixture(blocked: B::POSITIONS[1])
    assert_raises(RuntimeError) { B.transform!(map, tilesets) }
    assert_equal (1..28).to_a, map.events.keys.sort
  end

  def test_tampered_or_partial_raid_events_fail_closed
    map, tilesets = fixture
    B.transform!(map, tilesets)
    map.events[30].pages[-2].list.first.parameters[0] = 'ShatteredRaid.trigger(999, {})'
    assert_raises(RuntimeError) { B.transform!(map, tilesets) }
    map, tilesets = fixture
    map.events[29] = B.event(0)
    assert_raises(RuntimeError) { B.transform!(map, tilesets) }
  end

  def test_rejects_unstaged_projects
    require 'tmpdir'
    Dir.mktmpdir do |dir|
      assert_raises(RuntimeError) { B.install!(dir) }
    end
  end

  private

  def table(width, height, depth, values)
    count = width * height * depth
    Table._load([depth == 1 ? 1 : 3, width, height, depth, count].pack('V5') + values.pack('v*'))
  end

  def fixture(blocked: nil)
    map = RPG::Map.allocate
    map.width = 50; map.height = 40; map.tileset_id = 1
    map.events = (1..28).to_h do |id|
      e = RPG::Event.new(0, 0); e.id = id; e.name = "Existing #{id}"; [id, e]
    end
    map.events[23].name = 'SHATTERED: Viridian arrival'
    map.events[23].x = 25; map.events[23].y = 20
    tiles = Array.new(50 * 40 * 3, 0)
    (0...50 * 40).each { |i| tiles[i] = 1 }
    tiles[blocked[0] + 50 * blocked[1]] = 2 if blocked
    map.data = table(50, 40, 3, tiles)
    t = RPG::Tileset.allocate
    t.passages = table(3, 1, 1, [15, 0, 15])
    [map, [nil, t]]
  end
end
