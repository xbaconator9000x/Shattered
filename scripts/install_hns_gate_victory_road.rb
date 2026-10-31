# frozen_string_literal: true
# Offline-only atomic installer for the connected HnS Reception Gate and
# Victory Road. Neither map set can be installed standalone first: the gate's
# north exits point to B2F, and B2F returns to the (not-yet-installed) gate.
# Requires a private, staged Essentials v21.1 project with RGSS classes,
# load_data/save_data and approved local PNGs. Never load at game startup.
require "json"
require "digest"
require_relative "../essentials/Plugins/Shattered HnS Gate/001_Import"
require_relative "install_hns_victory_road"

module ShatteredHNSWorldInstall
  LOCK = "Data/.shattered-hns-world-install.lock"
  SUFFIX = ".shattered-hns-world"
  GATE_SOURCE = "MAP_RECEPTION_GATE_HNS"
  B2F_SOURCE = "MAP_VICTORY_ROAD_KANTO_B2F_HNS"
  module_function

  def present?(path)
    File.exist?(path) || File.symlink?(path)
  end

  def regular!(path)
    raise "Missing or unsafe private input: #{path}" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def assert!(condition, message)
    raise message unless condition
  end

  def walkable!(map, x, y)
    width, height = map.fetch("dimensions").values_at("width", "height")
    assert!(x.instance_of?(Integer) && y.instance_of?(Integer) &&
            x.between?(0, width - 1) && y.between?(0, height - 1),
            "HnS reciprocal landing is out of bounds")
    index = y * width + x
    layers = map.fetch("layers")
    collision = map.fetch("source_collision")
    assert!(layers.is_a?(Array) && layers.size == 3 &&
            layers.all? { |layer| layer.is_a?(Array) && layer.size == width * height } &&
            collision.is_a?(Array) && collision.size == width * height,
            "HnS reciprocal landing lacks complete source geometry")
    assert!(collision[index] == 0, "HnS reciprocal landing blocked in source collision")
    assert!(map.fetch("warps").none? { |warp| warp["x"] == x && warp["y"] == y },
            "HnS reciprocal landing overlaps a warp event")
    assert!(layers[0][index].instance_of?(Integer) && layers[0][index] >= 384,
            "HnS reciprocal landing has no ordinary floor tile")
    layers.each do |layer|
      tile = layer[index]
      next if tile == 0
      triple = map.fetch("tileset_tables")[tile.to_s]
      assert!(triple.is_a?(Array) && triple.size == 3 &&
              triple[0].instance_of?(Integer) && triple[0].between?(0, 31),
              "HnS reciprocal landing lacks reviewed XP passage")
      next if (triple[0] & 0x10) != 0
      assert!((triple[0] & 0x0f) == 0, "HnS reciprocal landing blocked in native XP")
    end
    true
  end

  def verify_link!(gate, road)
    floors = road.fetch("floors")
    assert!(floors.is_a?(Array) && floors.size == 3 &&
            floors[2]["source_map_id"] == B2F_SOURCE,
            "Missing pinned Victory Road B2F")
    gate_id = gate.fetch("target").fetch("map_id")
    road_ids = floors.map { |floor| floor.fetch("target").fetch("map_id") }
    assert!((road_ids + [gate_id]).all? { |id| id.instance_of?(Integer) && id > 0 } &&
            (road_ids + [gate_id]).uniq.size == 4, "HnS native map IDs overlap")
    b2f = floors[2]
    b2f_id = road_ids[2]
    return_warps = b2f.fetch("warps").select { |warp| warp["source_destination"] == GATE_SOURCE }
    assert!(return_warps.size == 1, "B2F must have one Reception Gate return")
    back = return_warps.first
    assert!(back.fetch("target")["map_id"] == gate_id, "B2F return targets wrong gate map")
    north = gate.fetch("warps").select { |warp| warp["direction"] == "north" }
    assert!(north.size == 2, "Gate must have two northern Victory Road exits")
    landings = north.map { |warp| warp.fetch("target").values_at("x", "y") }
    assert!(landings.uniq.size == north.size,
            "Gate north exits collapse onto same B2F landing")
    north.each do |warp|
      assert!(warp["source_destination"] == B2F_SOURCE &&
              warp.fetch("target")["map_id"] == b2f_id,
              "Gate north exit targets wrong B2F map")
      target = warp.fetch("target")
      assert!((target["x"] - back["x"]).abs + (target["y"] - back["y"]).abs == 1,
              "Gate-to-B2F landing is not adjacent to return warp")
      walkable!(b2f, target["x"], target["y"])
    end
    source_index = back.fetch("source_destination_warp_id")
    assert!(source_index.is_a?(String) && /\A(?:0|[1-9]\d*)\z/.match?(source_index),
            "Invalid B2F source gate warp index")
    original_gate_warp = gate.fetch("warps")[source_index.to_i]
    assert!(original_gate_warp && original_gate_warp["direction"] == "north",
            "B2F return references wrong gate source warp")
    target = back.fetch("target")
    assert!((target["x"] - original_gate_warp["x"]).abs +
            (target["y"] - original_gate_warp["y"]).abs == 1,
            "B2F-to-gate landing is not adjacent to source warp")
    walkable!(gate, target["x"], target["y"])
    [gate_id, road_ids]
  end

  # Only undo writes that THIS invocation completed. A competing process may
  # create a destination after preflight; never delete that unrelated map on
  # a lock/pre-commit failure. Preserve backups if restoration itself fails.
  def rollback!(entries, installed_paths, backed_up_paths, staged_paths)
    failures = []
    entries.reverse_each do |path, temp, backup, _existed|
      begin
        if backed_up_paths.include?(path)
          if present?(backup)
            File.delete(path) if installed_paths.include?(path) && present?(path)
            File.rename(backup, path)
          else
            failures << "#{path}: missing transaction-owned backup"
          end
        elsif installed_paths.include?(path) && present?(path)
          File.delete(path)
        end
        File.delete(temp) if staged_paths.include?(temp) && present?(temp)
      rescue StandardError => error
        failures << "#{path}: #{error.message}"
      end
    end
    failures
  end

  def install(gate_bundle_path, road_bundle_path)
    regular!(gate_bundle_path)
    regular!(road_bundle_path)
    gate = JSON.parse(File.read(gate_bundle_path))
    road = JSON.parse(File.read(road_bundle_path))
    gate_id, road_ids = verify_link!(gate, road)

    # A standalone installer may finish between our preflight and lock
    # acquisition. Pin the native databases BEFORE reading either map bundle,
    # then recheck them under all three exclusive locks before any writes.
    native_hashes = ["Data/Tilesets.rxdata", "Data/MapInfos.rxdata"].to_h do |path|
      [path, Digest::SHA256.file(regular!(path)).hexdigest]
    end
    # Validate both halves against the same untouched native databases before
    # creating a single transaction. Neither standalone installer is invoked.
    gate_values = ShatteredHNSGateImport.preflight!(gate, {road_ids[2] => [40, 50]})
    road_values = ShatteredHNSVictoryRoadInstall.preflight!(road, {gate_id => [22, 21]})
    assert!(gate_values[0] == gate_id && road_values[1] == road_ids,
            "Native map allocation changed during preflight")
    native_hashes.each do |path, expected|
      assert!(Digest::SHA256.file(regular!(path)).hexdigest == expected,
              "Native database changed during HnS world preflight")
    end
    assert!(!present?(LOCK) &&
            !present?(ShatteredHNSGateImport::LOCK_PATH) &&
            !present?(ShatteredHNSVictoryRoadInstall::LOCK),
            "An HnS map installation is already locked")

    paths = ["Data/Tilesets.rxdata", format("Data/Map%03d.rxdata", gate_id)] +
      road_ids.map { |id| format("Data/Map%03d.rxdata", id) } +
      ["Data/MapInfos.rxdata"]
    entries = paths.each_with_index.map do |path, i|
      [path, path + SUFFIX + ".tmp", path + SUFFIX + ".bak",
       i == 0 || i == paths.length - 1]
    end
    entries.each do |path, temp, backup, existed|
      assert!(!present?(temp) && !present?(backup), "Stale HnS world transaction exists")
      if existed
        assert!(File.file?(path) && !File.symlink?(path) && File.writable?(path),
                "Original native database changed or is not writable")
      else
        assert!(!present?(path), "Native map appeared during world preflight")
      end
      assert!(File.writable?(File.dirname(path)), "Native map directory is not writable")
    end

    acquired_locks = []
    staged_paths = []
    backed_up_paths = []
    installed_paths = []
    keep_lock = false
    begin
      # The standalone installers only inspect their own lock paths. Hold
      # both locks for the entire combined transaction so neither can race
      # with this installer after preflight but before the final rename.
      [LOCK, ShatteredHNSGateImport::LOCK_PATH,
       ShatteredHNSVictoryRoadInstall::LOCK].each do |lock|
        File.open(lock, File::WRONLY | File::CREAT | File::EXCL) {}
        acquired_locks << lock
      end
      native_hashes.each do |path, expected|
        assert!(Digest::SHA256.file(regular!(path)).hexdigest == expected,
                "Native database changed before HnS world transaction")
      end
      entries.each do |path, _temp, _backup, existed|
        assert!(!present?(path), "Native map appeared during HnS world lock acquisition") unless existed
      end
      gate_objects = ShatteredHNSGateImport.build_objects(gate_values)
      road_values[2] = gate_objects[2] # combined MapInfos, including the gate
      road_values[3] = gate_objects[0] # combined Tilesets, including the gate
      road_objects = ShatteredHNSVictoryRoadInstall.objects!(road_values)
      objects = [road_objects[0], gate_objects[1], *road_objects[1, 3], road_objects[4]]
      assert!(objects.size == entries.size, "HnS world object count mismatch")
      entries.zip(objects).each do |entry, object|
        staged_paths << entry[1]
        save_data(object, entry[1])
        assert!(File.file?(entry[1]) && !File.symlink?(entry[1]) &&
                File.size(entry[1]) > 0,
                "Failed to stage native HnS world data")
        # A nonempty RXData file is not necessarily loadable. Decode every
        # staged native object BEFORE any original database is renamed.
        # A corrupt or wrong-type serialization must roll back all temps.
        decoded = load_data(entry[1])
        assert!(decoded.class == object.class,
                "Staged HnS world RXData has the wrong native object type")
        assert!(Marshal.dump(decoded) == Marshal.dump(object),
                "Staged HnS world RXData differs from intended native object")
      end
      # A non-cooperating editor could change databases or add a map while
      # temporary data is being serialized. Abort BEFORE the first rename.
      native_hashes.each do |path, expected|
        assert!(Digest::SHA256.file(regular!(path)).hexdigest == expected,
                "Native database changed during HnS world staging")
      end
      entries.each do |path, _temp, _backup, existed|
        assert!(!present?(path), "Native map appeared during HnS world staging") unless existed
      end
      entries.each do |path, temp, backup, existed|
        if existed
          File.rename(path, backup)
          backed_up_paths << path
        end
        File.rename(temp, path)
        installed_paths << path
      end
    rescue StandardError => error
      unless acquired_locks.empty?
        failures = rollback!(entries, installed_paths, backed_up_paths, staged_paths)
        unless failures.empty?
          keep_lock = true
          raise "HnS world install failed (#{error.message}); manual recovery: #{failures.join('; ')}"
        end
      end
      raise
    ensure
      staged_paths.each { |temp| File.delete(temp) if present?(temp) } unless keep_lock
      acquired_locks.reverse_each { |lock| File.delete(lock) if present?(lock) } unless keep_lock
    end
    entries.each do |path, _temp, backup, _existed|
      File.delete(backup) if backed_up_paths.include?(path) && present?(backup)
    end
    [gate_id, *road_ids]
  end
end
