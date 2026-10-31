# frozen_string_literal: true
# The standalone Victory Road test supplies native RMXP class fixtures and
# a pinned three-floor bundle. Its tests also run when this file is executed.
require_relative "test_hns_victory_road_install"
require_relative "../scripts/install_hns_gate_victory_road"

class HNSWorldInstallTest < Minitest::Test
  def setup
    fixture = VictoryRoadInstallTest.new("test_native_import_writes_three_floors_with_correct_tiles_and_warps")
    fixture.setup
    @root = fixture.instance_variable_get(:@root)
    @road = fixture.instance_variable_get(:@bundle)
    @road_path = fixture.instance_variable_get(:@bundle_path)
    @original = fixture.instance_variable_get(:@original)

    # B2F source warp zero points back to gate source warp index 2.
    @road["floors"][2]["warps"][0]["target"]["map_id"] = 303
    @road["floors"][2]["warps"][0]["target"]["x"] = 10
    @road["floors"][2]["warps"][0]["target"]["y"] = 2
    @road["floors"].each do |floor|
      w, h = floor["dimensions"].values_at("width", "height")
      floor["source_collision"] = Array.new(w * h, 0)
    end
    File.write(@road_path, JSON.generate(@road))

    image = File.join(@root, "Graphics/Tilesets/Gate.png")
    File.binwrite(image, "\x89PNG\r\n\x1a\n".b + ("\0" * 4) +
                        "IHDR" + [256, 32].pack("NN") + ("\0" * 4))
    image_sha = Digest::SHA256.file(image).hexdigest
    @gate = {
      "format" => ShatteredHNSGateImport::FORMAT,
      "format_version" => 1,
      "map_name" => "Heart & Soul League Reception Gate",
      "dimensions" => {"width" => 22, "height" => 21},
      "target" => {"map_id" => 303, "tileset_template_id" => 1,
                   "tileset_name" => "Gate", "tileset_image" => "Gate.png",
                   "tileset_sha256" => image_sha},
      "layers" => [Array.new(462, 384), Array.new(462, 0), Array.new(462, 0)],
      "source_collision" => Array.new(462, 0),
      "tileset_tables" => {"0" => [0, 0, 0], "384" => [0, 0, 0]},
      "warps" => [
        warp("west", 1, 9, 1, 4, 5),
        warp("east", 20, 9, 1, 4, 5),
        warp("north", 10, 1, 302, 30, 46, "MAP_VICTORY_ROAD_KANTO_B2F_HNS"),
        warp("north", 11, 1, 302, 31, 47, "MAP_VICTORY_ROAD_KANTO_B2F_HNS"),
        warp("south", 11, 19, 1, 4, 5)
      ]
    }
    @gate_path = File.join(@root, "reception_gate.json")
    write_gate
  end

  def warp(direction, x, y, id, tx, ty, source = "MAP_ROUTE22_HNS")
    {"direction" => direction, "x" => x, "y" => y,
     "source_destination" => source,
     "target" => {"map_id" => id, "x" => tx, "y" => ty,
                  "direction" => 2, "fade" => 0}}
  end

  def write_gate
    File.write(@gate_path, JSON.generate(@gate))
  end

  def write_road
    File.write(@road_path, JSON.generate(@road))
  end

  def install_world
    Dir.chdir(@root) { ShatteredHNSWorldInstall.install(@gate_path, @road_path) }
  end

  def artifacts
    Dir.glob(File.join(@root, "Data", "*.shattered-hns-world.*")) +
      [ShatteredHNSWorldInstall::LOCK, ShatteredHNSGateImport::LOCK_PATH,
     ShatteredHNSVictoryRoadInstall::LOCK].select do |path|
      File.exist?(File.join(@root, path))
    end.map { |path| File.join(@root, path) }
  end

  def assert_unchanged
    @original.each { |path, bytes| assert_equal bytes, File.binread(File.join(@root, path)) }
    (300..303).each do |id|
      refute File.exist?(File.join(@root, format("Data/Map%03d.rxdata", id)))
    end
    assert_empty artifacts
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def test_circular_dependency_blocks_both_standalone_installers
    Dir.chdir(@root) do
      assert_raises(RuntimeError) { ShatteredHNSGateImport.preflight!(@gate) }
      assert_raises(RuntimeError) { ShatteredHNSVictoryRoadInstall.preflight!(@road) }
    end
    assert_unchanged
  end

  def test_atomic_world_install_writes_four_connected_native_maps
    assert_equal [303, 300, 301, 302], install_world
    infos = load_data(File.join(@root, "Data/MapInfos.rxdata"))
    tilesets = load_data(File.join(@root, "Data/Tilesets.rxdata"))
    assert_equal 6, tilesets.length
    assert_equal [1, 2, 300, 301, 302, 303], infos.keys.sort
    gate = load_data(File.join(@root, "Data/Map303.rxdata"))
    assert_equal [22, 21, 2, 5], [gate.width, gate.height, gate.tileset_id, gate.events.length]
    [300, 301, 302].each_with_index do |id, index|
      map = load_data(File.join(@root, format("Data/Map%03d.rxdata", id)))
      assert_equal index + 3, map.tileset_id
      assert_equal @road["floors"][index]["warps"].length, map.events.length
    end
    assert_equal [0, 302, 30, 46, 2, 0], gate.events[3].pages[0].list[0].parameters
    assert_equal [0, 303, 10, 2, 2, 0],
                 load_data(File.join(@root, "Data/Map302.rxdata")).events[1].pages[0].list[0].parameters
    assert_empty artifacts
  end

  def test_combined_transaction_holds_both_standalone_locks_through_commit
    observed = false
    original_rename = File.method(:rename)
    File.stub(:rename, lambda { |from, to|
      if from == "Data/Tilesets.rxdata"
        observed = true
        Dir.chdir(@root) do
          [ShatteredHNSWorldInstall::LOCK, ShatteredHNSGateImport::LOCK_PATH,
           ShatteredHNSVictoryRoadInstall::LOCK].each do |lock|
            assert File.file?(lock), "Combined transaction must hold #{lock}"
            assert_raises(Errno::EEXIST) do
              File.open(lock, File::WRONLY | File::CREAT | File::EXCL) {}
            end
          end
        end
      end
      original_rename.call(from, to)
    }) do
      assert_equal [303, 300, 301, 302], install_world
    end
    assert observed, "Native commit never started"
    assert_empty artifacts
  end

  def test_partial_lock_acquisition_failure_cleans_up_without_writing
    original_open = File.method(:open)
    File.stub(:open, lambda { |path, *args, &block|
      if path == ShatteredHNSVictoryRoadInstall::LOCK &&
         args.first == (File::WRONLY | File::CREAT | File::EXCL)
        raise Errno::EACCES, "injected standalone road lock denial"
      end
      original_open.call(path, *args, &block)
    }) do
      assert_raises(Errno::EACCES) { install_world }
    end
    assert_unchanged
  end

  def test_native_database_changed_between_preflight_and_lock_is_not_overwritten
    externally_changed = @original.fetch("Data/MapInfos.rxdata") + "external-change"
    original_open = File.method(:open)
    File.stub(:open, lambda { |path, *args, &block|
      if path == ShatteredHNSWorldInstall::LOCK &&
         args.first == (File::WRONLY | File::CREAT | File::EXCL)
        File.binwrite("Data/MapInfos.rxdata", externally_changed)
      end
      original_open.call(path, *args, &block)
    }) do
      error = assert_raises(RuntimeError) { install_world }
      assert_match(/Native database changed before HnS world transaction/, error.message)
    end
    assert_equal externally_changed, File.binread(File.join(@root, "Data/MapInfos.rxdata"))
    assert_equal @original.fetch("Data/Tilesets.rxdata"),
                 File.binread(File.join(@root, "Data/Tilesets.rxdata"))
    (300..303).each do |id|
      refute File.exist?(File.join(@root, format("Data/Map%03d.rxdata", id)))
    end
    assert_empty artifacts
  end

  def test_competing_map_created_during_lock_acquisition_is_preserved
    foreign_path = "Data/Map300.rxdata"
    original_open = File.method(:open)
    File.stub(:open, lambda { |path, *args, &block|
      if path == ShatteredHNSWorldInstall::LOCK &&
         args.first == (File::WRONLY | File::CREAT | File::EXCL)
        File.binwrite(foreign_path, "external map - do not delete")
      end
      original_open.call(path, *args, &block)
    }) do
      error = assert_raises(RuntimeError) { install_world }
      assert_match(/Native map appeared during HnS world lock acquisition/, error.message)
    end
    assert_equal "external map - do not delete",
                 File.binread(File.join(@root, foreign_path))
    @original.each { |path, bytes| assert_equal bytes, File.binread(File.join(@root, path)) }
    (301..303).each do |id|
      refute File.exist?(File.join(@root, format("Data/Map%03d.rxdata", id)))
    end
    assert_empty artifacts
  end

  def test_competing_map_created_during_staging_is_preserved
    foreign_path = "Data/Map300.rxdata"
    original_size = File.method(:size)
    injected = false
    File.stub(:size, lambda { |path|
      if !injected && path.to_s.end_with?(".shattered-hns-world.tmp")
        File.binwrite(foreign_path, "external map during serialization")
        injected = true
      end
      original_size.call(path)
    }) do
      error = assert_raises(RuntimeError) { install_world }
      assert_match(/Native map appeared during HnS world staging/, error.message)
    end
    assert injected
    assert_equal "external map during serialization",
                 File.binread(File.join(@root, foreign_path))
    @original.each { |path, bytes| assert_equal bytes, File.binread(File.join(@root, path)) }
    (301..303).each do |id|
      refute File.exist?(File.join(@root, format("Data/Map%03d.rxdata", id)))
    end
    assert_empty artifacts
  end

  def test_native_database_changed_during_staging_is_preserved
    external_bytes = @original.fetch("Data/MapInfos.rxdata") + "external update"
    original_size = File.method(:size)
    injected = false
    File.stub(:size, lambda { |path|
      if !injected && path.to_s.end_with?(".shattered-hns-world.tmp")
        File.binwrite("Data/MapInfos.rxdata", external_bytes)
        injected = true
      end
      original_size.call(path)
    }) do
      error = assert_raises(RuntimeError) { install_world }
      assert_match(/Native database changed during HnS world staging/, error.message)
    end
    assert injected
    assert_equal external_bytes, File.binread(File.join(@root, "Data/MapInfos.rxdata"))
    assert_equal @original.fetch("Data/Tilesets.rxdata"),
                 File.binread(File.join(@root, "Data/Tilesets.rxdata"))
    (300..303).each do |id|
      refute File.exist?(File.join(@root, format("Data/Map%03d.rxdata", id)))
    end
    assert_empty artifacts
  end

  def test_source_collision_blocks_gate_to_b2f
    @road["floors"][2]["source_collision"][46 * 40 + 30] = 1
    write_road
    assert_raises(RuntimeError) { install_world }
    assert_unchanged
  end

  def test_reciprocal_warp_mismatch_is_rejected
    @gate["warps"][2]["target"]["map_id"] = 301
    write_gate
    assert_raises(RuntimeError) { install_world }
    assert_unchanged
  end

  def test_atomic_rollback_after_database_rename
    original_rename = File.method(:rename)
    calls = 0
    File.stub(:rename, lambda { |from, to|
      calls += 1
      raise IOError, "injected world commit failure" if calls == 5
      original_rename.call(from, to)
    }) do
      assert_raises(IOError) { install_world }
    end
    assert_unchanged
  end

  def test_stale_world_backup_is_never_overwritten
    path = File.join(@root, "Data/Map303.rxdata.shattered-hns-world.bak")
    File.write(path, "do not overwrite")
    assert_raises(RuntimeError) { install_world }
    assert_equal "do not overwrite", File.read(path)
    @original.each { |name, bytes| assert_equal bytes, File.binread(File.join(@root, name)) }
  end

  def test_corrupt_staged_map_is_rejected_before_any_native_commit
    original_size = File.method(:size)
    injected = false
    File.stub(:size, lambda { |path|
      if !injected && path.to_s.include?("Map303.rxdata.shattered-hns-world.tmp")
        File.binwrite(path, "not a native RXData map")
        injected = true
      end
      original_size.call(path)
    }) do
      assert_raises(StandardError) { install_world }
    end
    assert injected, "Corruption was not injected into the staged Gate map"
    assert_unchanged
  end

  def test_wrong_native_object_type_is_rejected_before_commit
    original_size = File.method(:size)
    injected = false
    File.stub(:size, lambda { |path|
      if !injected && path.to_s.include?("Map303.rxdata.shattered-hns-world.tmp")
        File.binwrite(path, Marshal.dump([]))
        injected = true
      end
      original_size.call(path)
    }) do
      error = assert_raises(RuntimeError) { install_world }
      assert_match(/wrong native object type/, error.message)
    end
    assert injected, "Wrong-type map was not injected"
    assert_unchanged
  end

  def test_valid_but_altered_staged_mapinfos_is_rejected_before_commit
    original_size = File.method(:size)
    injected = false
    File.stub(:size, lambda { |path|
      if !injected && path.to_s.include?("MapInfos.rxdata.shattered-hns-world.tmp")
        File.binwrite(path, Marshal.dump({}))
        injected = true
      end
      original_size.call(path)
    }) do
      error = assert_raises(RuntimeError) { install_world }
      assert_match(/differs from intended native object/, error.message)
    end
    assert injected, "Valid but altered MapInfos was not injected"
    assert_unchanged
  end
end
