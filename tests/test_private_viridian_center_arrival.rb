# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../scripts/repair_private_viridian_center_arrival'

class PrivateViridianCenterArrivalTest < Minitest::Test
  def map_fixture
    map = RPG::Map.allocate
    map.width = 20
    map.height = 15
    map.data = 'untouched private native tiles fixture'
    map.events = {}
    original = RPG::Event.new(2, 2)
    original.id = 1
    original.name = 'Unrelated Center actor'
    map.events[1] = original
    event = RPG::Event.new(8, 7)
    event.id = 11
    event.name = 'SHATTERED_VIRIDIAN:center_first_visit'
    hidden = RPG::Event::Page.new
    autorun = RPG::Event::Page.new
    autorun.trigger = 3
    autorun.condition.switch1_valid = true
    autorun.condition.switch1_id = 993
    autorun.list = [RPG::EventCommand.new(236, 0, [0, 0, 20]),
      RPG::EventCommand.new(355, 0, ['ShatteredViridian.center!(995, 996)']),
      RPG::EventCommand.new(0)]
    done = RPG::Event::Page.new
    done.condition.switch1_valid = true
    done.condition.switch1_id = 995
    event.pages = [hidden, autorun, done]
    map.events[11] = event
    map
  end

  def test_requires_completed_escort_before_center_autorun
    map = map_fixture
    original_tiles = Marshal.dump(map.data)
    original_actor = Marshal.dump(map.events[1])
    assert_equal :installed, ShatteredPrivateViridianCenterArrival.transform!(map)
    assert_equal 994, map.events[11].pages[1].condition.switch1_id
    assert_equal 995, map.events[11].pages[2].condition.switch1_id
    assert_equal original_tiles, Marshal.dump(map.data)
    assert_equal original_actor, Marshal.dump(map.events[1])
    assert_equal :already_installed, ShatteredPrivateViridianCenterArrival.transform!(map)
  end

  def test_rejects_foreign_or_missing_center_event
    map = map_fixture
    map.events[11].pages[1].list[1].parameters[0] = 'pbItemBall(:MASTERBALL)'
    assert_raises(RuntimeError) { ShatteredPrivateViridianCenterArrival.transform!(map) }
    map = map_fixture
    map.events.delete(11)
    assert_raises(RuntimeError) { ShatteredPrivateViridianCenterArrival.transform!(map) }
  end

  def test_rejects_unknown_map_geometry_or_conditions
    map = map_fixture
    map.width = 21
    assert_raises(RuntimeError) { ShatteredPrivateViridianCenterArrival.transform!(map) }
    map = map_fixture
    map.events[11].pages[1].condition.switch1_id = 997
    assert_raises(RuntimeError) { ShatteredPrivateViridianCenterArrival.transform!(map) }
  end

  def test_never_modifies_nonstaged_project
    Dir.mktmpdir do |root|
      assert_raises(RuntimeError) { ShatteredPrivateViridianCenterArrival.install!(root) }
      assert_empty Dir.children(root)
    end
  end
end
