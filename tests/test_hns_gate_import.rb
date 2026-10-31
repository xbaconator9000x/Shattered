require "fileutils"
require "json"
require "digest"
require "minitest/autorun"
require "minitest/mock"
require "tmpdir"

class Table
  def initialize(*dimensions)
    @values = Hash.new(0)
    @dimensions = dimensions
  end

  def [](*coordinates)
    @values[coordinates]
  end

  def []=(*arguments)
    value = arguments.pop
    @values[arguments] = value
  end
end

module RPG
  class Map
    attr_accessor :width, :height, :tileset_id, :data, :events

    def initialize(width, height)
      @width, @height = width, height
    end
  end

  class Event
    attr_accessor :id, :name, :pages

    def initialize(x, y)
      @x, @y = x, y
    end

    class Page
      attr_accessor :trigger, :list
    end
  end

  class EventCommand
    attr_reader :code, :indent, :parameters

    def initialize(code, indent, parameters)
      @code, @indent, @parameters = code, indent, parameters
    end
  end

  class MapInfo
    attr_accessor :name, :parent_id, :order
  end
end

class FakeTileset
  attr_accessor :name, :tileset_name, :autotile_names, :passages, :priorities, :terrain_tags
end

def load_data(path)
  Marshal.load(File.binread(path))
end

def save_data(object, path)
  File.binwrite(path, Marshal.dump(object))
end

load File.expand_path("../essentials/Plugins/Shattered HnS Gate/001_Import.rb", __dir__)

class ShatteredHNSGateImportTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("se013-import-test-")
    @plugin_dir = File.join(@root, "Plugins", "Shattered HnS Gate")
    FileUtils.mkdir_p([File.join(@root, "Data"), File.join(@root, "Graphics", "Tilesets"), @plugin_dir])
    File.write(File.join(@root, "SHATTERED_STAGING_REPORT.json"),
               JSON.generate("engine" => "Essentials 21.1"))
    File.binwrite(File.join(@root, "Graphics", "Tilesets", "Gate.png"),
                  "\x89PNG\r\n\x1A\n".b + ("\0" * 4) + "IHDR" +
                    [256, 32].pack("NN") + ("\0" * 4))
    @image_sha = Digest::SHA256.file(File.join(@root, "Graphics", "Tilesets", "Gate.png")).hexdigest
    File.write(File.join(@plugin_dir, "reception_gate.json"), JSON.generate(bundle))

    map_infos = { 1 => RPG::MapInfo.new }
    tilesets = [nil, FakeTileset.new]
    target_map = RPG::Map.new(10, 10)
    File.binwrite(File.join(@root, "Data", "MapInfos.rxdata"), Marshal.dump(map_infos))
    File.binwrite(File.join(@root, "Data", "Tilesets.rxdata"), Marshal.dump(tilesets))
    File.binwrite(File.join(@root, "Data", "Map001.rxdata"), Marshal.dump(target_map))
    @originals = %w[Data/Tilesets.rxdata Data/MapInfos.rxdata Data/Map001.rxdata].to_h do |path|
      [path, File.binread(File.join(@root, path))]
    end
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def bundle
    {
      "format" => "shattered-hns-rmxp-map",
      "format_version" => 1,
      "map_name" => "Heart & Soul League Reception Gate",
      "dimensions" => { "width" => 22, "height" => 21 },
      "target" => {
        "map_id" => 300,
        "tileset_template_id" => 1,
        "tileset_name" => "Gate",
        "tileset_image" => "Gate.png",
        "tileset_sha256" => @image_sha
      },
      "layers" => [
        Array.new(462, 384),
        Array.new(462, 0),
        Array.new(462, 0)
      ],
      "tileset_tables" => {
        "0" => [0, 0, 0],
        "384" => [15, 0, 0]
      },
      "warps" => [
        warp("west", 1, 9),
        warp("east", 20, 9),
        warp("south", 11, 19),
        warp("north", 10, 1),
        warp("north", 11, 1)
      ]
    }
  end

  def warp(direction, x, y)
    {
      "direction" => direction,
      "x" => x,
      "y" => y,
      "target" => {
        "map_id" => 1,
        "x" => 4,
        "y" => 5,
        "direction" => 2,
        "fade" => 0
      }
    }
  end

  def import
    Dir.chdir(@root) { ShatteredHNSGateImport.install(@plugin_dir) }
  end

  def assert_original_project_unchanged
    @originals.each do |path, bytes|
      assert_equal bytes, File.binread(File.join(@root, path)), path
    end
    refute File.exist?(File.join(@root, "Data", "Map300.rxdata"))
  end

  def transaction_artifacts
    Dir.glob(File.join(@root, "Data", "*.se013-import.*")) +
      Dir.glob(File.join(@root, "Data", ".shattered-hns-gate-import.lock"))
  end

  def test_rejects_modified_gate_art_before_writing
    File.binwrite(File.join(@root, "Graphics", "Tilesets", "Gate.png"), "modified image")
    assert_raises(RuntimeError) { import }
    assert_original_project_unchanged
    assert_empty transaction_artifacts
  end

  def test_rejects_substituted_valid_header_gate_art
    image = File.join(@root, "Graphics", "Tilesets", "Gate.png")
    File.open(image, "ab") { |f| f.write("changed but valid header") }
    error = assert_raises(RuntimeError) { import }
    assert_match(/SHA-256 mismatch/, error.message)
    assert_original_project_unchanged
    assert_empty transaction_artifacts
  end

  def test_import_requires_staging_marker_before_writing
    File.delete(File.join(@root, "SHATTERED_STAGING_REPORT.json"))
    assert_raises(RuntimeError) { import }
    assert_original_project_unchanged
    assert_empty transaction_artifacts
  end

  def test_preflight_requires_complete_collision_tables_for_every_used_tile
    config_path = File.join(@plugin_dir, "reception_gate.json")
    config = JSON.parse(File.read(config_path))
    config["tileset_tables"].delete("384")
    File.write(config_path, JSON.generate(config))
    assert_raises(RuntimeError) { import }
    assert_original_project_unchanged
    assert_empty transaction_artifacts
  end

  def test_preflight_rejects_incomplete_table_values
    config_path = File.join(@plugin_dir, "reception_gate.json")
    config = JSON.parse(File.read(config_path))
    config["tileset_tables"]["384"] = [15, 0]
    File.write(config_path, JSON.generate(config))
    assert_raises(RuntimeError) { import }
    assert_original_project_unchanged
    assert_empty transaction_artifacts
  end

  def test_preflight_rejects_bad_destination_before_writing
    config_path = File.join(@plugin_dir, "reception_gate.json")
    config = JSON.parse(File.read(config_path))
    config["warps"][0]["target"]["x"] = 10
    File.write(config_path, JSON.generate(config))
    assert_raises(RuntimeError) { import }
    assert_original_project_unchanged
    assert_empty transaction_artifacts
  end

  def test_stale_backup_is_rejected_without_clobbering_it
    backup = File.join(@root, "Data", "Tilesets.rxdata.se013-import.bak")
    File.binwrite(backup, "recoverable previous backup")
    assert_raises(RuntimeError) { import }
    assert_original_project_unchanged
    assert_equal "recoverable previous backup", File.binread(backup)
    assert_equal [backup], transaction_artifacts
  end

  def test_successful_import_writes_all_native_objects
    assert_equal 300, import
    map = load_data(File.join(@root, "Data", "Map300.rxdata"))
    tilesets = load_data(File.join(@root, "Data", "Tilesets.rxdata"))
    map_infos = load_data(File.join(@root, "Data", "MapInfos.rxdata"))
    assert_equal [22, 21], [map.width, map.height]
    assert_equal 5, map.events.length
    assert_equal "Heart & Soul League Reception Gate", map_infos[300].name
    assert_equal 15, tilesets[2].passages[384]
    assert_equal 0, tilesets[2].passages[0]
    assert_empty transaction_artifacts
  end

  def test_each_commit_rename_failure_restores_every_original
    [false, true].each do |after_mutation|
      1.upto(5) do |failure_number|
        teardown
        setup
        original_rename = File.method(:rename)
        calls = 0
        failed_at = nil
        injected_rename = lambda do |source, destination|
          calls += 1
          if calls == 1
            temporary_files = %w[
              Data/Tilesets.rxdata.se013-import.tmp
              Data/Map300.rxdata.se013-import.tmp
              Data/MapInfos.rxdata.se013-import.tmp
            ]
            assert temporary_files.all? { |path| File.file?(File.join(@root, path)) }
          end
          if calls == failure_number && !after_mutation
            failed_at = calls
            raise IOError, "injected rename failure #{failure_number}"
          end
          result = original_rename.call(source, destination)
          if calls == failure_number && after_mutation
            failed_at = calls
            raise IOError, "injected rename failure #{failure_number} after rename"
          end
          result
        end
        File.stub(:rename, injected_rename) do
          error = assert_raises(IOError) { import }
          assert_match(/injected rename failure/, error.message)
        end
        assert_equal failure_number, failed_at
        assert_original_project_unchanged
        assert_empty transaction_artifacts
      end
    end
  end
end
