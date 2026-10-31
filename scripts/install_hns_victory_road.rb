# frozen_string_literal: true
# Offline-only native RMXP installer for a privately generated HnS Victory Road bundle.
# Run in a staged Essentials v21.1 project after sourcing authorised tilesets.
# Do not place this file in Plugins/; it must never run during game startup.
require "json"
require "digest"

module ShatteredHNSVictoryRoadInstall
  FORMAT = "shattered-hns-victory-road-rmxp-bundle"
  REVISION = "167aa6d537b109bb229c231ddce4616974c4da71"
  IDS = %w[MAP_VICTORY_ROAD_KANTO_1F_HNS MAP_VICTORY_ROAD_KANTO_B1F_HNS MAP_VICTORY_ROAD_KANTO_B2F_HNS].freeze
  DIMENSIONS = [[50, 30], [60, 30], [40, 50]].freeze
  SOURCE_WARPS = [
    [[28, 2, "MAP_ROUTE23_HNS", 0],
     [4, 6, IDS[1], 1], [21, 23, IDS[1], 2],
     [42, 7, IDS[1], 3], [41, 21, IDS[1], 4],
     [16, 5, IDS[1], 5], [17, 16, IDS[1], 6],
     [24, 22, IDS[1], 7], [45, 23, IDS[1], 8],
     [45, 13, IDS[1], 9]],
    [[7, 15, IDS[2], 1], [5, 2, IDS[0], 1],
     [30, 26, IDS[0], 2], [54, 5, IDS[0], 3],
     [47, 22, IDS[0], 4], [14, 3, IDS[0], 3],
     [30, 20, IDS[0], 3], [33, 26, IDS[0], 3],
     [52, 24, IDS[0], 3], [55, 11, IDS[0], 3]],
    [[30, 47, "MAP_RECEPTION_GATE_HNS", 2],
     [4, 3, IDS[1], 0]]
  ].freeze
  LOCK = "Data/.shattered-victory-road-install.lock"
  SUFFIX = ".shattered-vr-install"

  module_function

  def present?(path)
    File.exist?(path) || File.symlink?(path)
  end

  def regular!(path)
    raise "Missing or unsafe native project file: #{path}" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def integer!(value, label, low, high)
    raise "#{label} must be integer in #{low}..#{high}" unless value.instance_of?(Integer) && value.between?(low, high)
    value
  end

  def png_height!(filename, expected_sha)
    raise "Unsafe tileset image name" unless filename.is_a?(String) && /\A[A-Za-z0-9_-]+\.png\z/.match?(filename)
    path = File.join("Graphics", "Tilesets", filename)
    regular!(path)
    raise "Missing reviewed tileset SHA-256" unless expected_sha.is_a?(String) &&
      /\A[0-9a-f]{64}\z/.match?(expected_sha)
    raise "Tileset PNG differs from reviewed SHA-256" unless Digest::SHA256.file(path).hexdigest == expected_sha
    header = File.open(path, "rb") { |f| f.read(24) }
    raise "Invalid RMXP tileset PNG #{path}" unless header && header.bytesize == 24 &&
      header[0, 8] == "\x89PNG\r\n\x1a\n".b && header[12, 4] == "IHDR"
    width, height = header[16, 8].unpack("NN")
    raise "Tileset PNG must be 256 pixels wide and 32px row aligned" unless width == 256 && height > 0 && (height % 32).zero?
    height
  end

  # The converter verifies source-relative landings, but a private JSON bundle
  # can be edited after conversion. Recheck the geometry here before writing
  # any native map: landing ON a Player Touch warp can bounce immediately back.
  # The only safe automatic placement is a cardinal neighbour with a clear
  # native XP tile. This is a static guard, NOT an in-engine collision test.
  def safe_internal_landing!(floor, x, y, destination_index, source_warp_index)
    source_warp = SOURCE_WARPS[destination_index][source_warp_index]
    raise "Unrecognised source destination warp" unless source_warp
    distance = (x - source_warp[0]).abs + (y - source_warp[1]).abs
    raise "Internal landing must be adjacent to source warp, not on it" unless distance == 1
    width = DIMENSIONS[destination_index][0]
    tile_index = y * width + x
    found_floor = false
    2.downto(0) do |layer|
      tile_id = floor["layers"][layer][tile_index]
      next if tile_id == 0
      values = floor["tileset_tables"][tile_id.to_s]
      raise "Internal landing has no reviewed XP passage table" unless values.is_a?(Array)
      passage = values[0]
      next if (passage & 0x10) != 0 # star-priority overlay
      # Never accept a permissive upper tile before inspecting the base:
      # an edited bundle could otherwise bypass a blocked ground layer.
      raise "Internal landing blocked by XP passage flags" unless (passage & 0x0f).zero?
      found_floor = true if layer == 0
    end
    raise "Internal landing has no walkable XP floor tile" unless found_floor
    true
  end

  def preflight!(bundle, pending_external = {})
    marker = "SHATTERED_STAGING_REPORT.json"
    regular!(marker)
    raise "Not a staged Essentials v21.1 project" unless JSON.parse(File.read(marker))["engine"] == "Essentials 21.1"
    raise "Unrecognised Victory Road conversion bundle" unless bundle.is_a?(Hash) &&
      bundle["format"] == FORMAT && bundle["format_version"] == 1 &&
      bundle["source_revision"] == REVISION && bundle["source_repository"] == "PokemonHnS-Development/pokehns-expansion"
    floors = bundle["floors"]
    raise "Exactly three ordered source floors are required" unless floors.is_a?(Array) && floors.size == 3 &&
      floors.map { |floor| floor["source_map_id"] } == IDS
    map_infos = load_data(regular!("Data/MapInfos.rxdata"))
    tilesets = load_data(regular!("Data/Tilesets.rxdata"))
    raise "Invalid native MapInfos/Tilesets databases" unless map_infos.is_a?(Hash) && tilesets.is_a?(Array)
    raise "A Victory Road import is already locked" if present?(LOCK)

    native_ids = []
    floors.each_with_index do |floor, index|
      width, height = DIMENSIONS[index]
      raise "Wrong source floor geometry" unless floor["dimensions"] == {"width" => width, "height" => height, "tile_pixels" => 32}
      target = floor["target"]
      raise "Invalid floor target" unless target.is_a?(Hash)
      map_id = integer!(target["map_id"], "target map ID", 1, 999_999)
      raise "Duplicate target map ID" if native_ids.include?(map_id)
      native_ids << map_id
      raise "Target map ID already occupied" if map_infos.key?(map_id) || map_infos.key?(map_id.to_s) ||
        present?(format("Data/Map%03d.rxdata", map_id))
      template_id = integer!(target["tileset_template_id"], "tileset template ID", 1, tilesets.length - 1)
      raise "Missing tileset template" unless tilesets[template_id]
      stem = target["tileset_name"]
      raise "Unsafe tileset name" unless stem.is_a?(String) && /\A[A-Za-z0-9_-]+\z/.match?(stem)
      raise "Tileset name/image mismatch" unless target["tileset_image"] == "#{stem}.png"
      png_height = png_height!(target["tileset_image"], target["tileset_sha256"])
      layers = floor["layers"]
      raise "Wrong native tile layers" unless layers.is_a?(Array) && layers.size == 3 &&
        layers.all? { |layer| layer.is_a?(Array) && layer.size == width * height }
      max_id = 384 + 8 * (png_height / 32) - 1
      used = layers.flatten.uniq
      used.each do |tile_id|
        integer!(tile_id, "XP tile ID", 0, 8191)
        raise "Autotile IDs require an explicit autotile mapping" if tile_id > 0 && tile_id < 384
        raise "XP tile ID outside supplied PNG" if tile_id > max_id
      end
      tables = floor["tileset_tables"]
      raise "Invalid tileset tables" unless tables.is_a?(Hash)
      raise "Missing XP tile tables" unless used.all? { |id| tables.key?(id.to_s) }
      tables.each do |key, values|
        raise "Invalid tile table key" unless key.is_a?(String) && /\A(?:0|[1-9]\d*)\z/.match?(key)
        id = integer!(key.to_i, "table tile ID", 0, 8191)
        raise "Invalid passage/priority/terrain values" unless values.is_a?(Array) && values.size == 3
        integer!(values[0], "passage", 0, 31)
        integer!(values[1], "priority", 0, 5)
        integer!(values[2], "terrain", 0, 255)
        raise "Transparent tile cannot carry collision" if id == 0 && values != [0, 0, 0]
      end
      warps = floor["warps"]
      raise "Wrong pinned source warp count" unless warps.is_a?(Array) && warps.size == SOURCE_WARPS[index].size
      seen = {}
      warps.each_with_index do |warp, i|
        raise "Source warp index mismatch" unless warp["source_warp_index"] == i
        expected = SOURCE_WARPS[index][i]
        actual = [warp["x"], warp["y"], warp["source_destination"],
                  warp["source_destination_warp_id"]]
        raise "Pinned source warp record mismatch" unless
          actual == [expected[0], expected[1], expected[2], expected[3].to_s]
        x = integer!(warp["x"], "source warp x", 0, width - 1)
        y = integer!(warp["y"], "source warp y", 0, height - 1)
        raise "Duplicate source warp position" if seen[[x, y]]
        seen[[x, y]] = true
      end
    end
    floors.each do |floor|
      floor["warps"].each do |warp|
        target = warp["target"]
        raise "Missing reviewed warp target" unless target.is_a?(Hash)
        id = integer!(target["map_id"], "warp map ID", 1, 999_999)
        x = integer!(target["x"], "warp x", 0, 999_999)
        y = integer!(target["y"], "warp y", 0, 999_999)
        direction = integer!(target["direction"], "warp direction", 0, 8)
        raise "Invalid warp direction" unless [0, 2, 4, 6, 8].include?(direction)
        integer!(target["fade"], "warp fade", 0, 1)
        destination_source = warp["source_destination"]
        if IDS.include?(destination_source)
          index = IDS.index(destination_source)
          raise "Internal Victory Road warp targets wrong native floor" unless id == native_ids[index]
          dw, dh = DIMENSIONS[index]
          source_index = warp["source_destination_warp_id"]
          raise "Invalid internal source warp index" unless
            source_index.is_a?(String) && /\\A(?:0|[1-9]\\d*)\\z/.match?(source_index)
          safe_internal_landing!(floors[index], x, y, index, source_index.to_i)
        else
          raise "Unreviewed external Victory Road destination" unless %w[MAP_RECEPTION_GATE_HNS MAP_ROUTE23_HNS].include?(destination_source)
          raise "External warp incorrectly targets a new Victory Road floor" if native_ids.include?(id)
          if map_infos.key?(id)
            path = format("Data/Map%03d.rxdata", id)
            map = load_data(regular!(path))
            dw, dh = map.width, map.height
          else
            # A missing Reception Gate is permitted ONLY during a combined,
            # atomic import. Standalone imports still fail closed.
            raise "External destination map missing" unless
              destination_source == "MAP_RECEPTION_GATE_HNS" &&
              pending_external[id] == [22, 21]
            dw, dh = 22, 21
          end
        end
        raise "Warp landing outside target map" unless x < dw && y < dh
      end
    end
    [floors, native_ids, map_infos, tilesets]
  end

  def objects!(values)
    floors, ids, infos, tilesets = values
    maps = []
    floors.each_with_index do |floor, i|
      width, height = DIMENSIONS[i]
      target = floor["target"]
      template = tilesets[target["tileset_template_id"]]
      tile = Marshal.load(Marshal.dump(template))
      tile.name = "Heart & Soul Victory Road #{%w[1F B1F B2F][i]}"
      tile.tileset_name = target["tileset_name"]
      tile.autotile_names = ["", "", "", "", "", "", ""]
      tables = floor["tileset_tables"]
      size = [384, tables.keys.map(&:to_i).max.to_i + 1].max
      tile.passages = Table.new(size)
      tile.priorities = Table.new(size)
      tile.terrain_tags = Table.new(size)
      tables.each do |key, triple|
        id = key.to_i
        tile.passages[id], tile.priorities[id], tile.terrain_tags[id] = triple
      end
      tile_id = tilesets.length
      tilesets << tile
      map = RPG::Map.new(width, height)
      map.tileset_id = tile_id
      map.data = Table.new(width, height, 3)
      3.times do |z|
        height.times do |y|
          width.times do |x|
            map.data[x, y, z] = floor["layers"][z][y * width + x]
          end
        end
      end
      map.events = {}
      floor["warps"].each_with_index do |warp, j|
        event = RPG::Event.new(warp["x"], warp["y"])
        event.id = j + 1
        event.name = "Victory Road exit #{j + 1}"
        page = RPG::Event::Page.new
        page.trigger = 1
        target = warp["target"]
        page.list = [RPG::EventCommand.new(201, 0, [0, target["map_id"], target["x"], target["y"], target["direction"], target["fade"]]),
                     RPG::EventCommand.new(0, 0, [])]
        event.pages = [page]
        map.events[event.id] = event
      end
      maps << map
      info = RPG::MapInfo.new
      info.name = tile.name
      info.parent_id = 0
      info.order = ids[i]
      infos[ids[i]] = info
    end
    [tilesets, *maps, infos]
  end

  def rollback!(entries)
    failures = []
    entries.reverse_each do |path, tmp, bak, existed|
      begin
        if present?(bak)
          File.delete(path) if present?(path)
          File.rename(bak, path)
        elsif !existed && present?(path)
          File.delete(path)
        end
        File.delete(tmp) if present?(tmp)
      rescue StandardError => error
        failures << "#{path}: #{error.message}"
      end
    end
    failures
  end

  def install(bundle_path)
    regular!(bundle_path)
    values = preflight!(JSON.parse(File.read(bundle_path)))
    ids = values[1]
    entries = [["Data/Tilesets.rxdata", true]] +
      ids.map { |id| [format("Data/Map%03d.rxdata", id), false] } +
      [["Data/MapInfos.rxdata", true]]
    entries = entries.map { |path, existed| [path, path + SUFFIX + ".tmp", path + SUFFIX + ".bak", existed] }
    entries.each do |path, tmp, bak, existed|
      raise "Stale import transaction file" if present?(tmp) || present?(bak)
      raise "Native database changed before import" if existed && !File.writable?(regular!(path))
      raise "Native map appeared before import" if !existed && present?(path)
    end
    acquired = false
    keep_lock = false
    committed = false
    begin
      File.open(LOCK, File::WRONLY | File::CREAT | File::EXCL) { acquired = true }
      objects = objects!(values)
      entries.zip(objects).each do |entry, object|
        save_data(object, entry[1])
        raise "Failed to write staged native object" unless File.file?(entry[1]) && File.size(entry[1]) > 0
      end
      entries.each do |path, tmp, bak, existed|
        File.rename(path, bak) if existed
        File.rename(tmp, path)
      end
      committed = true
    rescue StandardError => error
      if acquired
        failures = rollback!(entries)
        unless failures.empty?
          keep_lock = true
          raise "Victory Road installation failed (#{error.message}); recovery required: #{failures.join('; ')}"
        end
      end
      raise
    ensure
      entries.each { |_path, tmp, _bak, _existed| File.delete(tmp) if present?(tmp) }
      File.delete(LOCK) if acquired && !keep_lock && present?(LOCK)
    end
    entries.each { |_path, _tmp, bak, _existed| File.delete(bak) if present?(bak) }
    ids
  end
end
