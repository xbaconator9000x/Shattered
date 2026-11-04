require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"
require_relative "../scripts/install_private_viridian_mentor"

class PrivateViridianMentorTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("shattered-mentor-")
    FileUtils.mkdir_p(File.join(@root, "Data"))
    FileUtils.mkdir_p(File.join(@root, "Graphics/Characters"))
    File.write(File.join(@root, "SHATTERED_STAGING_REPORT.json"), "{}")
    File.write(File.join(@root, "Graphics/Characters/trainer_AROMALADY.png"), "private fixture")
    @map_path = File.join(@root, "Data/Map015.rxdata")
    @tilesets_path = File.join(@root, "Data/Tilesets.rxdata")
    map = RPG::Map.allocate
    map.width = 20
    map.height = 15
    map.tileset_id = 1
    teacher = RPG::Event.new(6, 2)
    teacher.id = 1
    teacher.name = "Teacher"
    teacher.pages.first.graphic.character_name = "trainer_AROMALADY"
    map.events = { 1 => teacher }
    map.data = table(20, 15, 3, 384)
    tileset = RPG::Tileset.allocate
    tileset.passages = table(1024, 1, 1, 0)
    save_data(map, @map_path)
    save_data([nil, tileset], @tilesets_path)
    @original_teacher = Marshal.dump(teacher)
    @original_tiles = Marshal.dump(map.data)
    @original_sha = ShatteredPrivateViridianMentor::MAP_SHA256
    @original_tileset_sha = ShatteredPrivateViridianMentor::TILESETS_SHA256
    pin(:MAP_SHA256, Digest::SHA256.file(@map_path).hexdigest)
    pin(:TILESETS_SHA256, Digest::SHA256.file(@tilesets_path).hexdigest)
  end

  def teardown
    pin(:MAP_SHA256, @original_sha)
    pin(:TILESETS_SHA256, @original_tileset_sha)
    FileUtils.remove_entry(@root)
  end

  def table(width, height, depth, value)
    cells = width * height * depth
    Table._load([depth == 1 ? 1 : 3, width, height, depth, cells].pack("V5") +
      Array.new(cells, value).pack("s<*"))
  end

  def pin(name, value)
    mod = ShatteredPrivateViridianMentor
    mod.send(:remove_const, name)
    mod.const_set(name, value)
  end

  def test_real_native_event_written_and_idempotent
    result = ShatteredPrivateViridianMentor.install!(@root)
    assert_equal "installed", result.fetch("status")
    assert_equal 15, result.fetch("map_id")
    map = load_data(@map_path)
    event = map.events.fetch(2)
    assert_equal [6, 5], [event.x, event.y]
    assert_equal "SHATTERED_DOJO:questionnaire", event.name
    assert_equal "trainer_AROMALADY", event.pages.first.graphic.character_name
    assert_equal [355, 0], event.pages.first.list.map(&:code)
    assert_equal ["ShatteredDojo.run_quiz"], event.pages.first.list.first.parameters
    assert_equal @original_teacher, Marshal.dump(map.events.fetch(1))
    assert_equal @original_tiles, Marshal.dump(map.data)
    bytes = File.binread(@map_path)
    assert_equal "unchanged", ShatteredPrivateViridianMentor.install!(@root).fetch("status")
    assert_equal bytes, File.binread(@map_path)
  end

  def test_map_drift_rejected_without_modification
    File.open(@map_path, "ab") { |f| f.write("drift") }
    bytes = File.binread(@map_path)
    assert_raises(RuntimeError) { ShatteredPrivateViridianMentor.install!(@root) }
    assert_equal bytes, File.binread(@map_path)
  end

  def test_missing_sprite_refused
    File.delete(File.join(@root, "Graphics/Characters/trainer_AROMALADY.png"))
    assert_raises(RuntimeError) { ShatteredPrivateViridianMentor.install!(@root) }
  end

  def test_wrong_teacher_identity_refused
    map = load_data(@map_path)
    map.events.fetch(1).name = "Unknown"
    save_data(map, @map_path)
    assert_raises(RuntimeError) { ShatteredPrivateViridianMentor.install!(@root) }
  end

  def test_unreviewed_tileset_refused
    File.open(@tilesets_path, "ab") { |f| f.write("drift") }
    assert_raises(RuntimeError) { ShatteredPrivateViridianMentor.install!(@root) }
  end

  def test_event_drift_detected_on_reinstall
    ShatteredPrivateViridianMentor.install!(@root)
    map = load_data(@map_path)
    map.events.fetch(2).x = 7
    save_data(map, @map_path)
    assert_raises(RuntimeError) { ShatteredPrivateViridianMentor.install!(@root) }
  end
end
