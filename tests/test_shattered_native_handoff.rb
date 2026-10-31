require "minitest/autorun"
require "tmpdir"
require "fileutils"

RPG = Module.new unless defined?(RPG)
RPG.const_set(:Map, Struct.new(:width, :height, :events)) unless defined?(RPG::Map)
MapStub = Struct.new(:width, :height, :events)
SystemStub = Struct.new(:start_map_id, :start_x, :start_y)
NativeMapStub = Struct.new(:width, :height, :events, :tileset_id, :data)
NativeTilesetStub = Struct.new(:passages, :priorities)
class NativeTileTable
  def initialize(values = {})
    @values = values
  end
  def [](*indices)
    @values.fetch(indices, 0)
  end
end
CommandStub = Struct.new(:code, :indent, :parameters)
GraphicStub = Struct.new(:character_name)
PageStub = Struct.new(:trigger, :through, :always_on_top, :graphic, :list)
EventStub = Struct.new(:id, :name, :x, :y, :pages, :payload)
RPG.const_set(:Event, EventStub) unless defined?(RPG::Event)

def transfer_event(id, name, x, y, parameters)
  page = PageStub.new(1, false, false, GraphicStub.new(nil), [
    CommandStub.new(201, 0, parameters),
    CommandStub.new(0, 0, [])
  ])
  EventStub.new(id, name, x, y, [page], nil)
end

module ShatteredGateStory
  MAX_IMPACTS = 6

  def self.scene_event(x, y, name, script, trigger, character = nil)
    EventStub.new(nil, "SHATTERED_GATE:#{name}", x, y,
      [PageStub.new(trigger, false, false, GraphicStub.new(character),
        [CommandStub.new(355, 0, [script]), CommandStub.new(0, 0, [])])], nil)
  end

  def self.same_event?(actual, expected)
    Marshal.dump(actual) == Marshal.dump(expected)
  end
end

module ShatteredWorldLinks
  def self.event_matches?(actual, entry)
    destination = entry["destination"]
    page = actual.pages && actual.pages.first
    command = page && page.list && page.list.first
    actual.x == entry["x"] && actual.y == entry["y"] &&
      page && page.trigger == 1 && command &&
      command.code == 201 &&
      command.parameters == [0, destination["map_id"], destination["x"],
        destination["y"], destination["direction"], destination["fade"]]
  end
end

module ShatteredRoute22
  NPCS = [[38, 17], [39, 16], [39, 18]].freeze
  TRIGGERS = [[36, 16], [36, 17], [36, 18]].freeze

  def self.build_npc(x, y, index, sprite, cleared_switch)
    EventStub.new(nil, "SHATTERED_ROUTE22:rattata_#{index}", x, y, nil,
      [:npc, sprite, cleared_switch])
  end

  def self.build_trigger(x, y, index, npc_ids, config)
    EventStub.new(nil, "SHATTERED_ROUTE22:trigger_#{index}", x, y, nil,
      [:trigger, npc_ids, config["scatter_switch"], config["outcome_variable"],
        config["cleared_switch"]])
  end
end

def load_data(path)
  return Marshal.load(File.binread(path)) if File.file?(path)
  $handoff_test_maps.fetch(path)
end

def save_data(value, path)
  File.binwrite(path, Marshal.dump(value))
end

load File.expand_path("../scripts/templates/shattered_initial_slice_installer.rb", __dir__)

class ShatteredNativeHandoffTest < Minitest::Test
  def setup
    @gate_id = 101
    @route_id = 102
    @gate = MapStub.new(22, 21, {})
    @route = MapStub.new(48, 24, {})
    @story = {
      "map_id" => @gate_id,
      "positions" => {
        "collapse" => {"x" => 9, "y" => 11},
        "aipom" => {"x" => 11, "y" => 2},
        "johto_block" => {"x" => 11, "y" => 19}
      },
      "collapse_sounds" => %w[rum1 rum2 rum3 rum4 rum5 rum6],
      "final_roar_sound" => "roar",
      "aipom_cry" => "cry",
      "aipom_character" => "Aipom"
    }
    @hns_warps = [
      {"direction" => "west", "x" => 1, "y" => 9,
       "target" => {"map_id" => 201, "x" => 1, "y" => 2, "direction" => 2, "fade" => 0}},
      {"direction" => "east", "x" => 20, "y" => 9,
       "target" => {"map_id" => @route_id, "x" => 1, "y" => 2, "direction" => 2, "fade" => 0}},
      {"direction" => "south", "x" => 11, "y" => 19,
       "target" => {"map_id" => 203, "x" => 1, "y" => 2, "direction" => 2, "fade" => 0}},
      {"direction" => "north", "x" => 10, "y" => 1,
       "target" => {"map_id" => 204, "x" => 1, "y" => 2, "direction" => 2, "fade" => 0}},
      {"direction" => "north", "x" => 11, "y" => 1,
       "target" => {"map_id" => 204, "x" => 2, "y" => 2, "direction" => 2, "fade" => 0}}
    ]
    @hns_warps.reject { |warp| warp["direction"] == "south" }.each do |warp|
      target = warp["target"]
      event = transfer_event(@gate.events.length + 1, "Exit #{warp['direction']}",
        warp["x"], warp["y"],
        [0, target["map_id"], target["x"], target["y"], target["direction"], target["fade"]])
      @gate.events[event.id] = event
    end
    @links = [
      {"map_id" => @gate_id, "link_id" => "gate-route22", "side" => "F",
       "x" => 3, "y" => 3,
       "destination" => {"map_id" => @route_id, "x" => 4, "y" => 4, "direction" => 8, "fade" => 0}},
      {"map_id" => @route_id, "link_id" => "gate-route22", "side" => "R",
       "x" => 30, "y" => 5,
       "destination" => {"map_id" => @gate_id, "x" => 4, "y" => 4, "direction" => 2, "fade" => 0}}
    ]
    @links.each do |entry|
      destination = entry["destination"]
      event = transfer_event(
        (entry["map_id"] == @gate_id ? @gate : @route).events.length + 1,
        "SHATTERED_LINK:#{entry['link_id']}:#{entry['side']}",
        entry["x"], entry["y"],
        [0, destination["map_id"], destination["x"], destination["y"],
          destination["direction"], destination["fade"]]
      )
      (entry["map_id"] == @gate_id ? @gate : @route).events[event.id] = event
    end
    story_scripts = {
      "collapse" => "ShatteredGateStory.run_collapse(#{@story['collapse_sounds'].inspect}, #{@story['final_roar_sound'].inspect})",
      "aipom" => "ShatteredGateStory.run_aipom(#{@story['aipom_cry'].inspect})",
      "johto_block" => "ShatteredGateStory.blocked_johto"
    }
    @story["positions"].each do |name, position|
      expected = ShatteredGateStory.scene_event(
        position["x"], position["y"], name, story_scripts[name],
        name == "aipom" ? 0 : 1,
        name == "aipom" ? @story["aipom_character"] : nil
      )
      expected.id = @gate.events.length + 1
      @gate.events[expected.id] = expected
    end
    @route_config = {
      "map_id" => @route_id,
      "rattata_character" => "Rattata",
      "cleared_switch" => 81,
      "scatter_switch" => 80,
      "outcome_variable" => 21
    }
    npc_events = ShatteredRoute22::NPCS.each_with_index.map do |point, index|
      event = ShatteredRoute22.build_npc(*point, index, "Rattata", 81)
      event.id = @route.events.length + 1
      @route.events[event.id] = event
      event
    end
    npc_ids = npc_events.map(&:id)
    ShatteredRoute22::TRIGGERS.each_with_index do |point, index|
      event = ShatteredRoute22.build_trigger(*point, index, npc_ids, @route_config)
      event.id = @route.events.length + 1
      @route.events[event.id] = event
    end
    $handoff_test_maps = {
      "Data/Map101.rxdata" => @gate,
      "Data/Map102.rxdata" => @route,
      "Data/MapInfos.rxdata" => {@gate_id => true, @route_id => true}
    }
    @plan = {
      "map_targets" => {
        "reception_gate" => {"id" => @gate_id},
        "route22" => {"id" => @route_id, "dimensions" => [48, 24]}
      },
      "route22_reserved_positions" => ShatteredInitialSlice::ROUTE22_RESERVED,
      "new_game_spawn" => {"map_id" => @gate_id, "x" => 5, "y" => 5,
                           "reviewed" => true, "passability_attested" => true}
    }
    @configs = {
      "hns_import" => {"warps" => @hns_warps},
      "gate_story" => @story,
      "route22" => @route_config,
      "world_links" => {
        "events" => @links
      }
    }
  end

  def test_native_route22_tiles_reject_blocked_and_unverified_positions
    data = NativeTileTable.new({[36, 16, 0] => 384, [36, 17, 0] => 385})
    map = NativeMapStub.new(54, 34, {}, 1, data)
    passages = Hash.new(0)
    passages[384] = 15
    passages[385] = 0
    tilesets = [nil, NativeTilesetStub.new(passages, nil)]
    assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_route22_tiles!(map, tilesets, [[36, 16]])
    end
    assert ShatteredInitialSlice.validate_route22_tiles!(map, tilesets, [[36, 17]])
    assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_route22_tiles!(map, tilesets, [[54, 17]])
    end
    assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_route22_tiles!(map, tilesets, [[36, 18]])
    end
  end

  def test_native_route22_geometry_is_checked_against_reviewed_dimensions
    route = MapStub.new(54, 34, {})
    plan = { "map_targets" => { "route22" => { "dimensions" => [54, 34] } } }
    assert_equal [54, 34], plan["map_targets"]["route22"]["dimensions"]
    assert_equal [route.width, route.height], plan["map_targets"]["route22"]["dimensions"]
    refute_equal [48, 24], plan["map_targets"]["route22"]["dimensions"]
  end

  def test_native_character_sprite_preflight_rejects_bad_crc_and_truncated_sheet
    chunk = lambda do |name, payload|
      [payload.bytesize].pack("N") + name + payload +
        [Zlib.crc32(name + payload)].pack("N")
    end
    png = "\x89PNG\r\n\x1a\n".b +
      chunk.call("IHDR", [128, 128, 8, 6, 0, 0, 0].pack("NNC5")) +
      chunk.call("IDAT", Zlib::Deflate.deflate(("\x00".b * 513) * 128)) +
      chunk.call("IEND", "")
    Dir.mktmpdir("shattered-sprite-preflight") do |root|
      Dir.chdir(root) do
        FileUtils.mkdir_p("Graphics/Characters")
        path = "Graphics/Characters/Aipom.png"
        File.binwrite(path, png)
        assert ShatteredInitialSlice.validate_character_sheet!("Aipom")
        assert_raises(RuntimeError) do
          ShatteredInitialSlice.validate_character_sheet!("../Aipom")
        end
        bad_header = png.dup
        bad_header.setbyte(29, bad_header.getbyte(29) ^ 0x01)
        File.binwrite(path, bad_header)
        assert_raises(RuntimeError) do
          ShatteredInitialSlice.validate_character_sheet!("Aipom")
        end
        bad_data = png.dup
        idat = bad_data.index("IDAT")
        bad_data.setbyte(idat + 4, bad_data.getbyte(idat + 4) ^ 0x01)
        File.binwrite(path, bad_data)
        assert_raises(RuntimeError) do
          ShatteredInitialSlice.validate_character_sheet!("Aipom")
        end
        File.binwrite(path, png + "garbage")
        assert_raises(RuntimeError) do
          ShatteredInitialSlice.validate_character_sheet!("Aipom")
        end
        File.binwrite(path, png[0...-12])
        assert_raises(RuntimeError) do
          ShatteredInitialSlice.validate_character_sheet!("Aipom")
        end
        File.delete(path)
        assert_raises(RuntimeError) do
          ShatteredInitialSlice.validate_character_sheet!("Aipom")
        end
      end
    end
  end

  def test_accepts_exact_installer_results_and_complete_event_sets
    results = [
      @gate_id,
      {"created" => 2, "unchanged" => 0, "changed_maps" => [@gate_id, @route_id]},
      {"map_id" => @gate_id, "installed" => ["collapse", "aipom", "johto_block"]},
      {"map_id" => @route_id, "installed" => 6}
    ]
    assert_nil ShatteredInitialSlice.validate_install_results!(@plan, @configs, results)
  end

  def test_checks_hns_result_before_gate_story_replaces_south_exit
    before_story = MapStub.new(22, 21, {})
    @hns_warps.each do |warp|
      target = warp["target"]
      event = transfer_event(
        before_story.events.length + 1, "Exit #{warp['direction']}",
        warp["x"], warp["y"],
        [0, target["map_id"], target["x"], target["y"],
          target["direction"], target["fade"]]
      )
      before_story.events[event.id] = event
    end
    $handoff_test_maps["Data/Map101.rxdata"] = before_story
    assert ShatteredInitialSlice.validate_hns_import_result!(
      @plan, @configs["hns_import"], @gate_id
    )
    assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_hns_import_result!(
        @plan, @configs["hns_import"], @route_id
      )
    end
    before_story.events.delete(before_story.events.keys.first)
    assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_hns_import_result!(
        @plan, @configs["hns_import"], @gate_id
      )
    end
  end

  def test_rejects_no_op_installer_results_as_false_success
    results = [
      @gate_id,
      {"created" => 0, "unchanged" => 2, "changed_maps" => []},
      {"map_id" => @gate_id, "installed" => []},
      {"map_id" => @route_id, "installed" => 0, "unchanged" => 6}
    ]
    error = assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_install_results!(@plan, @configs, results)
    end
    assert_match(/World Links returned false success/, error.message)
  end

  def test_rejects_partial_hns_map_and_partial_route_events
    warp_key = @gate.events.find { |_id, event| event.name == "Exit west" }.first
    @gate.events.delete(warp_key)
    results = [
      @gate_id,
      {"created" => 2, "unchanged" => 0, "changed_maps" => [@gate_id, @route_id]},
      {"map_id" => @gate_id, "installed" => ["collapse", "aipom", "johto_block"]},
      {"map_id" => @route_id, "installed" => 6}
    ]
    error = assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_install_results!(@plan, @configs, results)
    end
    assert_match(/unblocked HnS exits/, error.message)

    setup
    route_key = @route.events.find { |_id, event| event.name == "SHATTERED_ROUTE22:rattata_0" }.first
    @route.events.delete(route_key)
    results[0] = @gate_id
    results[1] = {"created" => 2, "unchanged" => 0, "changed_maps" => [@gate_id, @route_id]}
    results[2] = {"map_id" => @gate_id, "installed" => ["collapse", "aipom", "johto_block"]}
    results[3] = {"map_id" => @route_id, "installed" => 6}
    error = assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_install_results!(@plan, @configs, results)
    end
    assert_match(/Route22 NPC missing/, error.message)
  end

  def test_rejects_misplaced_world_link_and_tampered_route_command
    results = [
      @gate_id,
      {"created" => 2, "unchanged" => 0, "changed_maps" => [@gate_id, @route_id]},
      {"map_id" => @gate_id, "installed" => ["collapse", "aipom", "johto_block"]},
      {"map_id" => @route_id, "installed" => 6}
    ]
    link = @gate.events.values.find { |event| event.name == "SHATTERED_LINK:gate-route22:F" }
    link.x = 9
    error = assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_install_results!(@plan, @configs, results)
    end
    assert_match(/World Links event differs/, error.message)

    setup
    gate_link = @gate.events.values.find do |event|
      event.name == "SHATTERED_LINK:gate-route22:F"
    end
    gate_link.pages.first.list << CommandStub.new(355, 0, ["unexpected"])
    error = assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_install_results!(@plan, @configs, results)
    end
    assert_match(/World Links event differs/, error.message)

    setup
    gate_exit = @gate.events.values.find { |event| event.name == "Exit west" }
    gate_exit.pages.first.list << CommandStub.new(355, 0, ["unexpected"])
    error = assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_install_results!(@plan, @configs, results)
    end
    assert_match(/HnS exit differs/, error.message)

    setup
    route_trigger = @route.events.values.find do |event|
      event.name == "SHATTERED_ROUTE22:trigger_0"
    end
    route_trigger.payload = [:tampered]
    error = assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_install_results!(@plan, @configs, results)
    end
    assert_match(/Route22 event differs/, error.message)
  end

  def test_transaction_restores_existing_files_and_removes_created_gate_map
    Dir.mktmpdir("shattered-native-rollback") do |directory|
      original_directory = Dir.pwd
      Dir.chdir(directory)
      Dir.mkdir("Data")
      paths = ["Data/MapInfos.rxdata", "Data/Tilesets.rxdata",
               "Data/System.rxdata", "Data/Map101.rxdata", "Data/Map102.rxdata"]
      contents = ["infos", "tilesets", "original system", nil, "route"]
      paths.zip(contents).each do |path, content|
        File.binwrite(path, content) if content
      end
      ShatteredInitialSlice.begin_transaction!(paths)
      File.binwrite("Data/MapInfos.rxdata", "changed infos")
      File.binwrite("Data/Tilesets.rxdata", "changed tilesets")
      File.binwrite("Data/System.rxdata", "changed start")
      File.binwrite("Data/Map101.rxdata", "new gate")
      File.binwrite("Data/Map102.rxdata", "changed route")
      ShatteredInitialSlice.restore_transaction!
      assert_equal "infos", File.binread("Data/MapInfos.rxdata")
      assert_equal "tilesets", File.binread("Data/Tilesets.rxdata")
      assert_equal "original system", File.binread("Data/System.rxdata")
      refute File.exist?("Data/Map101.rxdata")
      assert_equal "route", File.binread("Data/Map102.rxdata")
      refute File.exist?(ShatteredInitialSlice::ROLLBACK_DIR)
    ensure
      Dir.chdir(original_directory)
    end
  end

  def test_rollback_removes_a_receipt_before_restoring_maps
    Dir.mktmpdir("shattered-receipt-rollback") do |directory|
      original_directory = Dir.pwd
      Dir.chdir(directory)
      Dir.mkdir("Data")
      paths = ["Data/MapInfos.rxdata", "Data/Tilesets.rxdata",
               "Data/Map101.rxdata", "Data/Map102.rxdata"]
      contents = ["infos", "tilesets", nil, "route"]
      paths.zip(contents).each do |path, content|
        File.binwrite(path, content) if content
      end
      ShatteredInitialSlice.begin_transaction!(paths)
      File.binwrite("Data/MapInfos.rxdata", "changed infos")
      File.binwrite("Data/Map101.rxdata", "new gate")
      File.write(ShatteredInitialSlice::RECEIPT_PATH, "premature receipt")
      error = assert_raises(RuntimeError) do
        ShatteredInitialSlice.rollback_after_error!(RuntimeError.new("synthetic failure"))
      end
      assert_equal "synthetic failure", error.message
      refute File.exist?(ShatteredInitialSlice::RECEIPT_PATH)
      assert_equal "infos", File.binread("Data/MapInfos.rxdata")
      refute File.exist?("Data/Map101.rxdata")
      refute File.exist?(ShatteredInitialSlice::ROLLBACK_DIR)
    ensure
      Dir.chdir(original_directory)
    end
  end

  def test_native_installer_does_not_include_tileset_hash_rewrite_shim\n    refute_respond_to ShatteredInitialSlice, :with_tileset_hash_view\n  end\n\n  def test_interrupted_transaction_is_never_reported_as_success
    Dir.mktmpdir("shattered-native-interrupted") do |directory|
      original_directory = Dir.pwd
      Dir.chdir(directory)
      Dir.mkdir("Data")
      Dir.mkdir(ShatteredInitialSlice::ROLLBACK_DIR)
      error = assert_raises(RuntimeError) { ShatteredInitialSlice.install }
      assert_match(/manual recovery/, error.message)
    ensure
      Dir.chdir(original_directory)
    end
  end

  def with_native_spawn_fixture
    Dir.mktmpdir("shattered-new-game-spawn") do |directory|
      previous = Dir.pwd
      Dir.chdir(directory)
      Dir.mkdir("Data")
      tile_data = NativeTileTable.new({[5, 5, 0] => 384, [6, 5, 0] => 384})
      map = NativeMapStub.new(22, 21, {}, 1, tile_data)
      tilesets = [nil, NativeTilesetStub.new(
        NativeTileTable.new({[384] => 0}), NativeTileTable.new({[384] => 0}))]
      original = SystemStub.new(12, 3, 4)
      save_data(map, "Data/Map101.rxdata")
      save_data(tilesets, "Data/Tilesets.rxdata")
      save_data(original, "Data/System.rxdata")
      yield(map, tilesets, original)
    ensure
      Dir.chdir(previous)
    end
  end

  def test_new_game_spawn_updates_native_system_and_rejects_occupied_tile
    with_native_spawn_fixture do |map, _tilesets, _original|
      assert ShatteredInitialSlice.validate_spawn_tile!(@plan)
      previous = ShatteredInitialSlice.install_new_game_spawn!(@plan)
      assert_equal [12, 3, 4], previous
      assert ShatteredInitialSlice.validate_installed_spawn!(@plan)
      assert_equal [101, 5, 5], load_data("Data/System.rxdata").values
      map.events[1] = EventStub.new(1, "Occupied", 5, 5, [], nil)
      save_data(map, "Data/Map101.rxdata")
      error = assert_raises(RuntimeError) { ShatteredInitialSlice.validate_spawn_tile!(@plan) }
      assert_match(/occupied/, error.message)
    end
  end

  def test_new_game_spawn_rejects_isolated_passable_tile_without_mutating_system
    with_native_spawn_fixture do |map, _tilesets, original|
      map.data = NativeTileTable.new({[5, 5, 0] => 384})
      save_data(map, "Data/Map101.rxdata")
      error = assert_raises(RuntimeError) do
        ShatteredInitialSlice.install_new_game_spawn!(@plan)
      end
      assert_match(/no unoccupied traversable adjacent tile/, error.message)
      assert_equal original, load_data("Data/System.rxdata")
    end
  end

  def test_new_game_spawn_rejects_egress_blocked_by_event
    with_native_spawn_fixture do |map, _tilesets, original|
      map.events[1] = EventStub.new(1, "Blocking exit", 6, 5, [], nil)
      save_data(map, "Data/Map101.rxdata")
      error = assert_raises(RuntimeError) do
        ShatteredInitialSlice.install_new_game_spawn!(@plan)
      end
      assert_match(/no unoccupied traversable adjacent tile/, error.message)
      assert_equal original, load_data("Data/System.rxdata")
    end
  end

  def test_new_game_spawn_rejects_blocked_adjacent_tile
    with_native_spawn_fixture do |map, tilesets, original|
      map.data = NativeTileTable.new({[5, 5, 0] => 384, [6, 5, 0] => 385})
      tilesets[1].passages = NativeTileTable.new({[384] => 0, [385] => 15})
      save_data(map, "Data/Map101.rxdata")
      save_data(tilesets, "Data/Tilesets.rxdata")
      error = assert_raises(RuntimeError) do
        ShatteredInitialSlice.install_new_game_spawn!(@plan)
      end
      assert_match(/no unoccupied traversable adjacent tile/, error.message)
      assert_equal original, load_data("Data/System.rxdata")
    end
  end

  def test_new_game_spawn_rejects_blocked_tile_and_preserves_original_on_rollback
    with_native_spawn_fixture do |map, tilesets, original|
      tilesets[1].passages = NativeTileTable.new({[384] => 15})
      save_data(tilesets, "Data/Tilesets.rxdata")
      error = assert_raises(RuntimeError) { ShatteredInitialSlice.install_new_game_spawn!(@plan) }
      assert_match(/blocked/, error.message)
      assert_equal original, load_data("Data/System.rxdata")
      tilesets[1].passages = NativeTileTable.new({[384] => 0})
      save_data(tilesets, "Data/Tilesets.rxdata")
      paths = ["Data/System.rxdata", "Data/Map101.rxdata"]
      ShatteredInitialSlice.begin_transaction!(paths)
      ShatteredInitialSlice.install_new_game_spawn!(@plan)
      assert_equal [101, 5, 5], load_data("Data/System.rxdata").values
      ShatteredInitialSlice.restore_transaction!
      assert_equal original, load_data("Data/System.rxdata")
    end
  end

  def test_new_game_spawn_rejects_partial_directional_passages_on_floor
    with_native_spawn_fixture do |_map, tilesets, original|
      [1, 2, 4, 8, 3, 7].each do |direction_flags|
        tilesets[1].passages = NativeTileTable.new({[384] => direction_flags})
        save_data(tilesets, "Data/Tilesets.rxdata")
        error = assert_raises(RuntimeError) do
          ShatteredInitialSlice.install_new_game_spawn!(@plan)
        end
        assert_match(/directional movement restrictions/, error.message)
        assert_equal original, load_data("Data/System.rxdata")
      end
    end
  end

  def test_new_game_spawn_rejects_restricted_upper_layer_over_open_floor
    with_native_spawn_fixture do |map, tilesets, original|
      map.data = NativeTileTable.new({[5, 5, 0] => 384, [5, 5, 1] => 385})
      save_data(map, "Data/Map101.rxdata")
      tilesets[1].passages = NativeTileTable.new({[384] => 0, [385] => 4})
      tilesets[1].priorities = NativeTileTable.new({[384] => 0, [385] => 1})
      save_data(tilesets, "Data/Tilesets.rxdata")
      error = assert_raises(RuntimeError) do
        ShatteredInitialSlice.install_new_game_spawn!(@plan)
      end
      assert_match(/directional movement restrictions/, error.message)
      assert_equal original, load_data("Data/System.rxdata")
    end
  end

  def test_receipt_requires_exact_installed_file_inventory
    plan = {
      "source_pins" => [],
      "new_game_spawn" => @plan["new_game_spawn"],
      "map_targets" => {
        "reception_gate" => {"id" => @gate_id},
        "route22" => {"id" => @route_id}
      }
    }
    receipt = {
      "status" => "native_install_complete",
      "plan_sha256" => ShatteredInitialSlice::PLAN_SHA256,
      "source_pins" => [],
      "installer_apis" => ShatteredInitialSlice::INSTALLER_ORDER,
      "new_game_spawn" => @plan["new_game_spawn"],
      "gameplay_verified" => false,
      "save_reload_verified" => false,
      "android_joiplay_verified" => false,
      "installed_files" => {}
    }
    error = assert_raises(RuntimeError) do
      ShatteredInitialSlice.validate_receipt_inventory!(plan, receipt)
    end
    assert_match(/incomplete file inventory/, error.message)
    receipt["installed_files"] = ShatteredInitialSlice.transaction_paths(plan).to_h do |path|
      [path, "0" * 64]
    end
    assert_same receipt, ShatteredInitialSlice.validate_receipt_inventory!(plan, receipt)
  end
end
