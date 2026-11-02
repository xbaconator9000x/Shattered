# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../scripts/verify_private_hns_east_path'

class HnSEastWalkwayTest < Minitest::Test
  V = ShatteredHnSEastWalkway

  # audit_native_project intentionally defines only empty Marshal-compatible
  # RMXP classes. Use raw ivars, just as actual native deserialization does.
  def command_fixture(code, indent, parameters)
    command = RPG::EventCommand.allocate
    command.instance_variable_set(:@code, code)
    command.instance_variable_set(:@indent, indent)
    command.instance_variable_set(:@parameters, parameters)
    command
  end

  def page_fixture(trigger, commands, through: false, graphic: '')
    page = RPG::Event::Page.allocate
    page.instance_variable_set(:@trigger, trigger)
    page.instance_variable_set(:@through, through)
    page.instance_variable_set(:@list, commands)
    sprite = RPG::Event::Page::Graphic.allocate
    sprite.instance_variable_set(:@character_name, graphic)
    page.instance_variable_set(:@graphic, sprite)
    page
  end

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
      if id == 6
        page = page_fixture(0, [
          command_fixture(355, 0,
            ['ShatteredGateStory.run_aipom("Cries/AIPOM", get_character(0))']),
          command_fixture(0, 0, [])
        ])
      else
        page = page_fixture(0, [
          command_fixture(111, 0, [12, 'ShatteredGateStory.key_obtained?']),
          command_fixture(101, 1, ['The eastern Kanto door unlocks.']),
          command_fixture(201, 1, [0, 16, 14, 10, 2, 0]),
          command_fixture(411, 0, []),
          command_fixture(101, 1,
            ['The eastern Route 22 door is locked. You need the key.']),
          command_fixture(412, 0, []),
          command_fixture(0, 0, [])
        ], graphic: 'doors1')
      end
      event.instance_variable_set(:@pages, [page])
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

  def route22_and_tilesets
    _, tilesets = map_and_tilesets
    route = RPG::Map.allocate
    route.instance_variable_set(:@width, 54)
    route.instance_variable_set(:@height, 34)
    route.instance_variable_set(:@tileset_id, 1)
    route.instance_variable_set(:@data, table(54, 34, 3, 384))
    door = RPG::Event.allocate
    door.instance_variable_set(:@name, 'Plateau Gate Door')
    door.instance_variable_set(:@x, 14)
    door.instance_variable_set(:@y, 9)
    page = page_fixture(1, [
      command_fixture(201, 0, [0, 223, 19, 9, 4, 0]),
      command_fixture(0, 0, [])
    ])
    door.instance_variable_set(:@pages, [page])
    route.instance_variable_set(:@events, { 1 => door })
    [route, tilesets]
  end

  def test_route22_landing_and_reciprocal_gate_door
    route, tilesets = route22_and_tilesets
    assert V.verify_route22_landing!(route, tilesets)
    route.instance_variable_get(:@events)[1].instance_variable_get(:@pages).first.instance_variable_get(:@list).first.instance_variable_get(:@parameters)[1] = 222
    assert_raises(RuntimeError) { V.verify_route22_landing!(route, tilesets) }
  end

  def test_route22_wrong_return_trigger_and_blocked_landing_fail_closed
    route, tilesets = route22_and_tilesets
    door = route.instance_variable_get(:@events)[1].instance_variable_get(:@pages).first
    door.instance_variable_set(:@trigger, 0)
    assert_raises(RuntimeError) { V.verify_route22_landing!(route, tilesets) }
    door.instance_variable_set(:@trigger, 1)
    passage = tilesets[1].instance_variable_get(:@passages)
    bytes = passage.instance_variable_get(:@bytes).dup
    bytes[20 + 384 * 2, 2] = [15].pack('s<')
    tilesets[1].instance_variable_set(:@passages, Table._load(bytes))
    assert_raises(RuntimeError) { V.verify_route22_landing!(route, tilesets) }
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

  def test_wrong_route22_destination_or_unguarded_key_fails_closed
    map, tilesets = map_and_tilesets
    door = map.instance_variable_get(:@events)[7].instance_variable_get(:@pages).first
    door.instance_variable_get(:@list)[2].instance_variable_get(:@parameters)[1] = 10
    assert_raises(RuntimeError) { V.audit!(map, tilesets) }
    door.instance_variable_get(:@list)[2].instance_variable_get(:@parameters)[1] = 16
    door.instance_variable_get(:@list)[0].instance_variable_get(:@parameters)[1] = 'true'
    assert_raises(RuntimeError) { V.audit!(map, tilesets) }
  end

  def test_east_door_must_be_solid_action_button_with_locked_response
    map, tilesets = map_and_tilesets
    door = map.instance_variable_get(:@events)[7].instance_variable_get(:@pages).first
    door.instance_variable_set(:@trigger, 1)
    assert_raises(RuntimeError) { V.audit!(map, tilesets) }
    door.instance_variable_set(:@trigger, 0)
    door.instance_variable_set(:@through, true)
    assert_raises(RuntimeError) { V.audit!(map, tilesets) }
    door.instance_variable_set(:@through, false)
    door.instance_variable_get(:@list)[4].instance_variable_set(:@parameters, ['Door is open.'])
    assert_raises(RuntimeError) { V.audit!(map, tilesets) }
  end

  def test_aipom_must_retain_actual_key_award_interaction
    map, tilesets = map_and_tilesets
    aipom = map.instance_variable_get(:@events)[6].instance_variable_get(:@pages).first
    aipom.instance_variable_get(:@list)[0].instance_variable_set(:@parameters, ['pbMessage("placeholder")'])
    assert_raises(RuntimeError) { V.audit!(map, tilesets) }
  end
end
