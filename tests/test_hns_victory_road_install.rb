require "fileutils"
require "json"
require "minitest/autorun"
require "minitest/mock"
require "tmpdir"

class Table
  def initialize(*dimensions)
    @dimensions = dimensions
    @values = Hash.new(0)
  end
  def [](*coordinates); @values[coordinates]; end
  def []=(*args); value = args.pop; @values[args] = value; end
end
module RPG
  class Map
    attr_accessor :width, :height, :tileset_id, :data, :events
    def initialize(w, h); @width, @height = w, h; end
  end
  class Event
    attr_accessor :id, :name, :pages
    def initialize(x, y); @x, @y = x, y; end
    class Page; attr_accessor :trigger, :list; end
  end
  class EventCommand
    attr_reader :code, :indent, :parameters
    def initialize(code, indent, parameters)
      @code, @indent, @parameters = code, indent, parameters
    end
  end
  class MapInfo; attr_accessor :name, :parent_id, :order; end
end
class FakeTileset
  attr_accessor :name, :tileset_name, :autotile_names, :passages, :priorities, :terrain_tags
end

def load_data(path); Marshal.load(File.binread(path)); end
def save_data(obj, path); File.binwrite(path, Marshal.dump(obj)); end

load File.expand_path("../scripts/install_hns_victory_road.rb", __dir__)

class VictoryRoadInstallTest < Minitest::Test
  IDS = ShatteredHNSVictoryRoadInstall::IDS
  DIMENSIONS = ShatteredHNSVictoryRoadInstall::DIMENSIONS

  def setup
    @root = Dir.mktmpdir("shattered-vr-install-")
    FileUtils.mkdir_p([File.join(@root, "Data"), File.join(@root, "Graphics/Tilesets")])
    File.write(File.join(@root, "SHATTERED_STAGING_REPORT.json"), JSON.generate("engine" => "Essentials 21.1"))
    File.binwrite(File.join(@root, "Graphics/Tilesets/ReviewedCave.png"),
                  "\x89PNG\r\n\x1a\n".b + ("\0" * 4) + "IHDR" + [256, 64].pack("NN") + ("\0" * 4))
    infos = {1 => RPG::MapInfo.new, 2 => RPG::MapInfo.new}
    File.binwrite(File.join(@root, "Data/MapInfos.rxdata"), Marshal.dump(infos))
    File.binwrite(File.join(@root, "Data/Tilesets.rxdata"), Marshal.dump([nil, FakeTileset.new]))
    [1, 2].each do |id|
      File.binwrite(File.join(@root, format("Data/Map%03d.rxdata", id)), Marshal.dump(RPG::Map.new(20, 20)))
    end
    @reviewed_tileset_sha = Digest::SHA256.file(File.join(@root, "Graphics/Tilesets/ReviewedCave.png")).hexdigest
    @original = %w[Data/MapInfos.rxdata Data/Tilesets.rxdata].to_h do |name|
      [name, File.binread(File.join(@root, name))]
    end
    @bundle = {"format" => ShatteredHNSVictoryRoadInstall::FORMAT,
               "format_version" => 1,
               "source_revision" => ShatteredHNSVictoryRoadInstall::REVISION,
               "source_repository" => "PokemonHnS-Development/pokehns-expansion",
               "floors" => []}
    DIMENSIONS.each_with_index do |(w, h), i|
      @bundle["floors"] << {
        "source_map_id" => IDS[i],
        "dimensions" => {"width" => w, "height" => h, "tile_pixels" => 32},
        "target" => {"map_id" => 300 + i, "tileset_template_id" => 1,
                     "tileset_name" => "ReviewedCave", "tileset_image" => "ReviewedCave.png",
                     "tileset_sha256" => @reviewed_tileset_sha},
        "layers" => [Array.new(w * h, 384), Array.new(w * h, 0), Array.new(w * h, 0)],
        "source_collision" => Array.new(w * h, 0),
        "tileset_tables" => {"0" => [0, 0, 0], "384" => [0, 0, 0]},
        "warps" => []
      }
    end
    ShatteredHNSVictoryRoadInstall::SOURCE_WARPS.each_with_index do |warps, i|
      warps.each_with_index do |(x, y, dest, dest_index), j|
        target_map_id = case dest
                        when IDS[0] then 300
                        when IDS[1] then 301
                        when IDS[2] then 302
                        when "MAP_ROUTE23_HNS" then 1
                        when "MAP_RECEPTION_GATE_HNS" then 2
                        end
        landing_x, landing_y = if IDS.include?(dest)
          source_warp = ShatteredHNSVictoryRoadInstall::SOURCE_WARPS[IDS.index(dest)][dest_index]
          [source_warp[0] + 1, source_warp[1]] # reviewed cardinal neighbour, not warp tile
        else
          [1, 1] # external destination validation is separate
        end
        @bundle["floors"][i]["warps"] << {
          "source_warp_index" => j, "x" => x, "y" => y,
          "source_destination" => dest,
          "source_destination_warp_id" => dest_index.to_s,
          "target" => {"map_id" => target_map_id, "x" => landing_x, "y" => landing_y,
                       "direction" => 2, "fade" => 0}
        }
      end
    end
    @bundle_path = File.join(@root, "victory_road.json")
    write_bundle
  end

  def teardown
    FileUtils.remove_entry(@root) if File.exist?(@root)
  end

  def write_bundle
    File.write(@bundle_path, JSON.generate(@bundle))
  end

  def install
    Dir.chdir(@root) { ShatteredHNSVictoryRoadInstall.install(@bundle_path) }
  end

  def assert_unchanged
    @original.each { |path, bytes| assert_equal bytes, File.binread(File.join(@root, path)) }
    (300..302).each { |id| refute File.exist?(File.join(@root, format("Data/Map%03d.rxdata", id))) }
  end

  def artifacts
    Dir.glob(File.join(@root, "Data", "*.shattered-vr-install.*")) +
      Dir.glob(File.join(@root, "Data", ".shattered-victory-road-install.lock"))
  end

  def test_native_import_writes_three_floors_with_correct_tiles_and_warps
    assert_equal [300, 301, 302], install
    tilesets = load_data(File.join(@root, "Data/Tilesets.rxdata"))
    infos = load_data(File.join(@root, "Data/MapInfos.rxdata"))
    DIMENSIONS.each_with_index do |(w, h), i|
      map = load_data(File.join(@root, format("Data/Map%03d.rxdata", 300 + i)))
      assert_equal [w, h], [map.width, map.height]
      assert_equal 384, map.data[0, 0, 0]
      assert_equal i + 2, map.tileset_id
      assert_equal @bundle["floors"][i]["warps"].size, map.events.size
      assert_equal 0, tilesets[map.tileset_id].passages[384]
      assert_match(/Victory Road/, infos[300 + i].name)
    end
    assert_equal [0, 301, 6, 2, 2, 0], load_data(File.join(@root, "Data/Map300.rxdata")).events[2].pages[0].list[0].parameters
    assert_empty artifacts
  end

  def test_requires_private_staging_marker
    File.delete(File.join(@root, "SHATTERED_STAGING_REPORT.json"))
    assert_raises(RuntimeError) { install }
    assert_unchanged
  end

  def test_missing_external_destination_refused
    @bundle["floors"][2]["warps"][0]["target"]["map_id"] = 99
    write_bundle
    assert_raises(RuntimeError) { install }
    assert_unchanged
  end

  def test_existing_map_id_collision_refused
    @bundle["floors"][0]["target"]["map_id"] = 1
    write_bundle
    assert_raises(RuntimeError) { install }
    assert_unchanged
  end

  def test_missing_reviewed_tileset_hash_is_rejected
    @bundle["floors"][1]["target"].delete("tileset_sha256")
    write_bundle
    error = assert_raises(RuntimeError) { install }
    assert_match(/Missing reviewed tileset SHA-256/, error.message)
    assert_unchanged
  end

  def test_private_tileset_image_tampering_is_rejected
    File.open(File.join(@root, "Graphics/Tilesets/ReviewedCave.png"), "ab") { |f| f.write("tampered") }
    error = assert_raises(RuntimeError) { install }
    assert_match(/Tileset PNG differs from reviewed SHA-256/, error.message)
    assert_unchanged
  end

  def test_tiles_outside_supplied_png_refused
    @bundle["floors"][0]["layers"][0][0] = 400
    @bundle["floors"][0]["tileset_tables"]["400"] = [15, 0, 0]
    write_bundle
    assert_raises(RuntimeError) { install }
    assert_unchanged
  end

  def test_native_import_rejects_tampered_internal_landing_far_from_source_warp
    @bundle["floors"][0]["warps"][1]["target"]["x"] = 20
    write_bundle
    error = assert_raises(RuntimeError) { install }
    assert_match(/Internal landing must be adjacent/, error.message)
    assert_unchanged
  end

  def test_native_import_rejects_internal_landing_on_player_touch_warp
    @bundle["floors"][0]["warps"][1]["target"]["x"] = 5
    write_bundle
    error = assert_raises(RuntimeError) { install }
    assert_match(/Internal landing must be adjacent/, error.message)
    assert_unchanged
  end

  def test_native_import_rejects_internal_landing_on_blocked_tile
    landing = @bundle["floors"][0]["warps"][1]["target"]
    floor = @bundle["floors"][1]
    index = landing["y"] * DIMENSIONS[1][0] + landing["x"]
    floor["layers"][0][index] = 385
    floor["tileset_tables"]["385"] = [15, 0, 0]
    write_bundle
    error = assert_raises(RuntimeError) { install }
    assert_match(/Internal landing blocked/, error.message)
    assert_unchanged
  end

  def test_upper_passable_tile_cannot_hide_blocked_ground_landing
    landing = @bundle["floors"][0]["warps"][1]["target"]
    floor = @bundle["floors"][1]
    index = landing["y"] * DIMENSIONS[1][0] + landing["x"]
    floor["layers"][1][index] = 385
    floor["tileset_tables"]["385"] = [0, 1, 0]
    floor["tileset_tables"]["384"] = [15, 0, 0]
    write_bundle
    error = assert_raises(RuntimeError) { install }
    assert_match(/Internal landing blocked/, error.message)
    assert_unchanged
  end

  def test_wrong_internal_warp_destination_refused
    @bundle["floors"][0]["warps"][1]["target"]["map_id"] = 302
    write_bundle
    assert_raises(RuntimeError) { install }
    assert_unchanged
  end

  def test_rename_failure_restores_original_and_removes_new_maps
    original_rename = File.method(:rename)
    calls = 0
    File.stub(:rename, lambda { |from, to|
      calls += 1
      raise IOError, "injected failure" if calls == 5
      original_rename.call(from, to)
    }) do
      assert_raises(IOError) { install }
    end
    assert_unchanged
    assert_empty artifacts
  end

  def test_every_commit_rename_failure_restores_originals
    [false, true].each do |fail_after_rename|
      1.upto(7) do |failure_number|
        original_rename = File.method(:rename)
        calls = 0
        File.stub(:rename, lambda { |from, to|
          calls += 1
          raise IOError, "injected failure" if calls == failure_number && !fail_after_rename
          result = original_rename.call(from, to)
          raise IOError, "injected failure after rename" if calls == failure_number && fail_after_rename
          result
        }) do
          assert_raises(IOError) { install }
        end
        assert_unchanged
        assert_empty artifacts
      end
    end
  end

  def test_pinned_source_warp_cannot_be_moved_or_renumbered
    @bundle["floors"][2]["warps"][0]["x"] = 29
    write_bundle
    error = assert_raises(RuntimeError) { install }
    assert_match(/Pinned source warp record mismatch/, error.message)
    assert_unchanged
  end

  def test_pinned_source_warp_cannot_be_removed
    @bundle["floors"][1]["warps"].pop
    write_bundle
    error = assert_raises(RuntimeError) { install }
    assert_match(/Wrong pinned source warp count/, error.message)
    assert_unchanged
  end


  def test_internal_landing_blocked_by_original_gba_collision
    # First floor warp 1 targets B1F source warp 1 at (5,2), landing (6,2).
    @bundle["floors"][1]["source_collision"][2 * 60 + 6] = 1
    write_bundle
    error = assert_raises(RuntimeError) { install }
    assert_match(/GBA source collision/, error.message)
    assert_unchanged
  end

  def test_missing_source_collision_grid_rejected
    @bundle["floors"][1].delete("source_collision")
    write_bundle
    error = assert_raises(RuntimeError) { install }
    assert_match(/source collision grid/, error.message)
    assert_unchanged
  end

  def test_stale_transaction_backup_refused_without_overwrite
    backup = File.join(@root, "Data/Tilesets.rxdata.shattered-vr-install.bak")
    File.write(backup, "preserve me")
    assert_raises(RuntimeError) { install }
    assert_equal "preserve me", File.read(backup)
    assert_unchanged
  end
end
