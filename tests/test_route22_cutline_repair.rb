require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"
require_relative "../scripts/repair_private_route22_cutline"

class Route22CutlineRepairTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("route22-cutline-test")
    FileUtils.mkdir_p(File.join(@dir, "Data"))
    FileUtils.mkdir_p(File.join(@dir, "Plugins", "Shattered Route22"))
    File.write(File.join(@dir, "SHATTERED_STAGING_REPORT.json"), "{}")
    File.write(File.join(@dir, "Plugins", "Shattered Route22", "001_Route22.rb"),
      'module ShatteredRoute22; setBattleRule("canLose"); end')
    map = RPG::Map.allocate
    map.width = 54
    map.height = 34
    table_bytes = [3, 54, 34, 3, 54 * 34 * 3].pack("V5") + "\0" * (2 * 54 * 34 * 3)
    map.data = Table._load(table_bytes)
    map.events = {}
    [[1, "Door", 14, 9], [2, "Sign", 13, 16],
     [3, "SHATTERED: Rattata ambush", 30, 17],
     [4, "SHATTERED: Viridian gate", 32, 17]].each do |id, name, x, y|
      event = RPG::Event.new(x, y)
      event.id = id
      event.name = name
      event.pages = [RPG::Event::Page.new]
      map.events[id] = event
    end
    ambush = map.events[3]
    ambush.pages[0].trigger = 3
    ambush.pages[0].through = true
    ambush.pages[0].list = [
      RPG::EventCommand.new(355, 0, ["WildBattle.start(:RATTATA,5)"]),
      RPG::EventCommand.new(123, 0, ["A", 0]),
      RPG::EventCommand.new
    ]
    ambush.pages << RPG::Event::Page.new
    warp = map.events[4]
    warp.pages[0].trigger = 1
    warp.pages[0].through = true
    warp.pages[0].list = [
      RPG::EventCommand.new(101, 0, ["Guards wave"]),
      RPG::EventCommand.new(201, 0, ShatteredPrivateRoute22Cutline::TRANSFER.dup),
      RPG::EventCommand.new
    ]
    @path = File.join(@dir, "Data", "Map016.rxdata")
    File.binwrite(@path, Marshal.dump(map))
    @before = File.binread(@path)
    @tile_before = Marshal.dump(map.data)
    @other_before = [1, 2].map { |id| Marshal.dump(map.events[id]) }
    # Synthetic test fixture has different bytes; substitute only pinned
    # constants in this isolated process. Production pins are fixed in source.
    @original_constants = {}
    {"SOURCE_SHA" => Digest::SHA256.hexdigest(@before),
     "AMBUSH_SHA" => Digest::SHA256.hexdigest(Marshal.dump(ambush)),
     "WARP_SHA" => Digest::SHA256.hexdigest(Marshal.dump(warp))}.each do |name, value|
      @original_constants[name] = ShatteredPrivateRoute22Cutline.const_get(name)
      ShatteredPrivateRoute22Cutline.send(:remove_const, name)
      ShatteredPrivateRoute22Cutline.const_set(name, value)
    end
  end

  def teardown
    @original_constants.each do |name, value|
      ShatteredPrivateRoute22Cutline.send(:remove_const, name)
      ShatteredPrivateRoute22Cutline.const_set(name, value)
    end
    FileUtils.remove_entry(@dir)
  end

  def test_patches_native_events_without_touching_tiles_or_unrelated_events
    receipt = ShatteredPrivateRoute22Cutline.repair!(@dir)
    assert_equal true, receipt["viridian_transfer_guarded"]
    map = Marshal.load(File.binread(@path))
    assert_equal @tile_before, Marshal.dump(map.data)
    assert_equal @other_before, [1, 2].map { |id| Marshal.dump(map.events[id]) }
    assert_equal 1, map.events[3].pages.length
    assert_equal 1, map.events[3].pages[0].trigger
    refute map.events[3].pages[0].list.any? { |c| c.code == 123 }
    assert_includes map.events[3].pages[0].list[0].parameters[0], "ShatteredRoute22.encounter(991, 992)"
    assert_equal [111, 101, 201, 411, 355, 412, 0], map.events[4].pages[0].list.map(&:code)
    assert_equal [0, 10, 25, 20, 2, 0], map.events[4].pages[0].list[2].parameters
    assert_equal 1, map.events[4].pages[0].list[2].indent
    assert_equal File.binread(@path), Marshal.dump(map)
    refute File.exist?(@path + ".shattered_cutline.bak")
  end

  def test_fails_closed_on_tampering_and_refuses_repeat
    File.binwrite(@path, @before + "tampered")
    assert_raises(RuntimeError) { ShatteredPrivateRoute22Cutline.repair!(@dir) }
    assert_equal @before + "tampered", File.binread(@path)
    File.binwrite(@path, @before)
    ShatteredPrivateRoute22Cutline.repair!(@dir)
    patched = File.binread(@path)
    assert_raises(RuntimeError) { ShatteredPrivateRoute22Cutline.repair!(@dir) }
    assert_equal patched, File.binread(@path)
  end

  def test_rejects_nonstaged_project_without_modifying_map
    File.delete(File.join(@dir, "SHATTERED_STAGING_REPORT.json"))
    assert_raises(RuntimeError) { ShatteredPrivateRoute22Cutline.repair!(@dir) }
    assert_equal @before, File.binread(@path)
  end

  def test_stale_transaction_refused_before_mutation
    File.write(@path + ".shattered_cutline.bak", "original-backup")
    assert_raises(RuntimeError) { ShatteredPrivateRoute22Cutline.repair!(@dir) }
    assert_equal @before, File.binread(@path)
  end
end
