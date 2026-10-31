require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/install_private_route22_native"

class PrivateNativeRoute22Test < Minitest::Test
  def test_rgss_table_roundtrip_preserves_native_bytes
    raw = [3, 2, 2, 1, 4].pack("V5") + [384, 385, 0, 2].pack("s<*")
    table = Table._load(raw)
    assert_equal [2, 2, 1], table.shape
    assert_equal 385, table[1, 0, 0]
    assert_equal raw, Marshal.load(Marshal.dump(table))._dump
  end

  def test_rgss_tone_color_roundtrip_preserves_native_bytes
    raw = [0.0, 10.0, -10.0, 128.0].pack("E4")
    [Tone, Color].each do |klass|
      value = klass._load(raw)
      assert_equal raw, Marshal.load(Marshal.dump(value))._dump
    end
  end

  def test_new_native_event_has_required_rgss_page_fields
    event = RPG::Event.new(27, 17)
    event.id = 8
    page = event.pages.first
    assert_equal 0, page.trigger
    assert_equal false, page.through
    assert_equal true, page.walk_anime
    assert_equal "A", page.condition.self_switch_ch
    assert_equal 0, page.list.first.code
    assert_equal 0, Marshal.load(Marshal.dump(event)).pages.first.list.first.code
    assert_equal [:"@condition", :"@graphic", :"@move_type", :"@move_speed", :"@move_frequency", :"@walk_anime", :"@step_anime", :"@direction_fix", :"@through", :"@always_on_top", :"@trigger", :"@list", :"@move_route"], page.instance_variables
    assert_equal [:"@switch1_valid", :"@switch2_valid", :"@variable_valid", :"@self_switch_valid", :"@switch1_id", :"@switch2_id", :"@variable_id", :"@variable_value", :"@self_switch_ch"], page.condition.instance_variables
  end

  def test_reserved_ids_are_not_legacy_kanto_parcel_switches
    cfg = ShatteredPrivateRoute22.config("Rattata")
    assert_equal [991, 992], [cfg["scatter_switch"], cfg["cleared_switch"]]
    assert_equal 991, cfg["outcome_variable"]
    assert_equal ShatteredPrivateRoute22::SOURCE_MAP_SHA, cfg["expected_map_sha256"]
    refute_includes [80, 81], cfg["scatter_switch"]
    refute_includes [80, 81], cfg["cleared_switch"]
  end

  def test_native_page_conditions_and_commands_conflict_fail_closed
    map = RPG::Map.allocate
    event = RPG::Event.new(3, 3)
    event.id = 1
    map.instance_variable_set(:@events, { 1 => event })
    assert_empty ShatteredPrivateRoute22.event_id_conflicts(map)
    event.pages.first.condition.switch1_valid = true
    event.pages.first.condition.switch1_id = 991
    refute_empty ShatteredPrivateRoute22.event_id_conflicts(map)
    event.pages.first.condition.switch1_valid = false
    event.pages.first.list = [RPG::EventCommand.new(121, 0, [990, 995, 0])]
    refute_empty ShatteredPrivateRoute22.event_id_conflicts(map)
    event.pages.first.list = [RPG::EventCommand.new(355, 0, ["$game_variables[991] = 1"])]
    refute_empty ShatteredPrivateRoute22.event_id_conflicts(map)
  end

  def test_original_script_archive_pin_and_reserved_id_scan
    assert_equal "38d9b59fb41a8b0d2449134cf1e316a3297a3f5eceac3a281f40ad80dc4c0b05",
      ShatteredPrivateRoute22::SOURCE_SCRIPTS_SHA
    scripts = Array.new(ShatteredPrivateRoute22::SOURCE_SCRIPT_COUNT) do |index|
      [index, "core_#{index}", Zlib::Deflate.deflate("$game_switches[80] = true")]
    end
    assert_empty ShatteredPrivateRoute22.original_script_id_conflicts(scripts)
    scripts[24] = [24, "conflict", Zlib::Deflate.deflate("$game_variables [ 991 ] = 1")]
    assert_equal [[24, "conflict"]], ShatteredPrivateRoute22.original_script_id_conflicts(scripts)
    scripts[24] = [24, "conflict", Zlib::Deflate.deflate("$game_switches[992] = true")]
    assert_equal [[24, "conflict"]], ShatteredPrivateRoute22.original_script_id_conflicts(scripts)
    scripts[24] = [24, "corrupt", "not a compressed script"]
    assert_raises(RuntimeError) { ShatteredPrivateRoute22.original_script_id_conflicts(scripts) }
    assert_raises(RuntimeError) { ShatteredPrivateRoute22.original_script_id_conflicts(scripts.take(401)) }
  end

  def test_unmarked_or_modified_private_project_is_rejected
    Dir.mktmpdir do |dir|
      assert_raises(RuntimeError) do
        ShatteredPrivateRoute22.preflight!(Pathname(dir), "Rattata")
      end
      File.write(File.join(dir, "SHATTERED_NATIVE_CANDIDATE.json"),
        '{"source_sha":"0000000000000000000000000000000000000000"}')
      assert_raises(RuntimeError) do
        ShatteredPrivateRoute22.preflight!(Pathname(dir), "Rattata")
      end
      assert_raises(RuntimeError) do
        ShatteredPrivateRoute22.preflight!(Pathname(dir), "../bad")
      end
    end
  end
end
