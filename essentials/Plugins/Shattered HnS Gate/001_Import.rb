require "json"

module ShatteredHNSGateImport
  FORMAT = "shattered-hns-rmxp-map"
  WIDTH = 22
  HEIGHT = 21
  TRANSACTION_SUFFIXES = [".se013-import.tmp", ".se013-import.bak"].freeze
  LOCK_PATH = "Data/.shattered-hns-gate-import.lock"

  module_function

  def integer!(value, label, min, max)
    raise "#{label} must be an integer in #{min}..#{max}" unless
      value.is_a?(Integer) && value >= min && value <= max
    value
  end

  def path_present?(path)
    File.exist?(path) || File.symlink?(path)
  end

  def regular_file?(path)
    File.file?(path) && !File.symlink?(path)
  end

  def preflight!(config)
    marker = File.join(Dir.pwd, "SHATTERED_STAGING_REPORT.json")
    raise "Reception gate import requires a staged project" unless regular_file?(marker)
    report = JSON.parse(File.read(marker))
    raise "Invalid Shattered staging marker" unless report["engine"] == "Essentials 21.1"
    raise "Unsupported reception gate import bundle" unless
      config["format"] == FORMAT && config["format_version"] == 1

    dimensions = config["dimensions"]
    raise "Reception gate must be 22x21" unless
      dimensions.is_a?(Hash) && dimensions["width"] == WIDTH && dimensions["height"] == HEIGHT
    target_config = config["target"]
    raise "Reception gate target is invalid" unless target_config.is_a?(Hash)
    map_id = integer!(target_config["map_id"], "map ID", 1, 999_999)
    template_id = integer!(target_config["tileset_template_id"], "tileset template ID", 1, 999_999)
    map_name = config["map_name"]
    raise "Reception gate map name is invalid" unless map_name.is_a?(String) && !map_name.empty?
    tileset_name = target_config["tileset_name"]
    raise "Reception gate tileset name is invalid" unless
      tileset_name.is_a?(String) && /\A[A-Za-z0-9_-]+\z/ =~ tileset_name
    raise "Reception gate tileset image name is invalid" unless
      target_config["tileset_image"] == "#{tileset_name}.png"

    map_infos = load_data("Data/MapInfos.rxdata")
    tilesets = load_data("Data/Tilesets.rxdata")
    raise "MapInfos data is invalid" unless map_infos.is_a?(Hash)
    raise "Tilesets data is invalid" unless tilesets.is_a?(Array)
    raise "Reception gate map ID already exists" if map_infos.key?(map_id) || map_infos.key?(map_id.to_s)
    template = tilesets[template_id]
    raise "Reception gate tileset template is missing" unless template
    tileset_id = tilesets.length
    raise "Reception gate tileset ID is already occupied" if tilesets[tileset_id]

    image_path = File.join("Graphics", "Tilesets", "#{tileset_name}.png")
    raise "Reception gate tileset image is missing or invalid" unless valid_tileset_image?(image_path)

    layers = config["layers"]
    raise "Reception gate import must have three tile layers" unless
      layers.is_a?(Array) && layers.length == 3 &&
      layers.all? { |layer| layer.is_a?(Array) && layer.length == WIDTH * HEIGHT }
    used_tile_ids = layers.flatten.uniq
    used_tile_ids.each do |tile_id|
      integer!(tile_id, "XP tile ID", 0, 8191)
      raise "Unsupported XP autotile ID #{tile_id}" if tile_id > 0 && tile_id < 384
    end
    tables = config["tileset_tables"]
    raise "Reception gate tileset tables are invalid" unless tables.is_a?(Hash)
    normalized_tables = {}
    tables.each do |key, values|
      raise "Invalid XP tileset table key #{key.inspect}" unless
        key.is_a?(String) && /\A(?:0|[1-9]\d*)\z/.match?(key)
      tile_id = integer!(key.to_i, "XP tileset table ID", 0, 8191)
      raise "Invalid tables for XP tile #{tile_id}" unless values.is_a?(Array) && values.length == 3
      normalized_tables[tile_id] = [
        integer!(values[0], "passage for tile #{tile_id}", 0, 31),
        integer!(values[1], "priority for tile #{tile_id}", 0, 5),
        integer!(values[2], "terrain tag for tile #{tile_id}", 0, 255)
      ]
    end
    missing_tables = used_tile_ids.reject { |tile_id| normalized_tables.key?(tile_id) }
    raise "Missing complete passage/priority/terrain tables for XP tiles #{missing_tables.join(', ')}" unless
      missing_tables.empty?

    warps = config["warps"]
    raise "Reception gate must have five warp events" unless warps.is_a?(Array) && warps.length == 5
    directions = Hash.new(0)
    warp_positions = {}
    warp_targets = []
    warps.each do |warp|
      raise "Invalid reception gate warp" unless warp.is_a?(Hash)
      x = integer!(warp["x"], "warp x", 0, WIDTH - 1)
      y = integer!(warp["y"], "warp y", 0, HEIGHT - 1)
      raise "Duplicate reception gate warp position" if warp_positions[[x, y]]
      warp_positions[[x, y]] = true
      directions[warp["direction"]] += 1
      target = warp["target"]
      raise "Invalid reception gate warp destination" unless target.is_a?(Hash)
      target_map_id = integer!(target["map_id"], "destination map ID", 1, 999_999)
      target_x = integer!(target["x"], "destination x", 0, 999_999)
      target_y = integer!(target["y"], "destination y", 0, 999_999)
      target_direction = integer!(target["direction"], "destination direction", 0, 8)
      raise "Invalid destination direction" unless [0, 2, 4, 6, 8].include?(target_direction)
      fade = integer!(target["fade"], "destination fade", 0, 1)
      raise "Reception gate destination map is missing" unless
        map_infos.key?(target_map_id) && regular_file?(sprintf("Data/Map%03d.rxdata", target_map_id))
      destination_map = load_data(sprintf("Data/Map%03d.rxdata", target_map_id))
      unless destination_map.respond_to?(:width) && destination_map.respond_to?(:height) &&
             target_x < destination_map.width && target_y < destination_map.height
        raise "Reception gate warp destination is outside its map"
      end
      warp_targets << [target_map_id, target_x, target_y, target_direction, fade]
    end
    unless directions == {"west" => 1, "east" => 1, "south" => 1, "north" => 2}
      raise "Reception gate warp directions are invalid"
    end

    targets = [
      ["Data/Tilesets.rxdata", tilesets, true],
      [sprintf("Data/Map%03d.rxdata", map_id), nil, false],
      ["Data/MapInfos.rxdata", map_infos, true]
    ]
    transaction_paths = targets.map do |path, object, existed|
      [path, path + TRANSACTION_SUFFIXES[0], path + TRANSACTION_SUFFIXES[1], object, existed]
    end
    raise "Reception gate import is already locked" if path_present?(LOCK_PATH)
    transaction_paths.each do |path, temp, backup, _object, existed|
      if path_present?(temp) || path_present?(backup)
        raise "Stale reception gate transaction file exists: #{temp} or #{backup}"
      end
      if existed
        unless regular_file?(path) && File.writable?(path) && File.writable?(File.dirname(path))
          raise "Required project file is missing, invalid, or not writable: #{path}"
        end
      elsif path_present?(path)
        raise "Reception gate map file already exists: #{path}"
      elsif !File.writable?(File.dirname(path))
        raise "Reception gate map directory is not writable: #{File.dirname(path)}"
      end
    end

    [map_id, map_name, tileset_name, tileset_id, template, layers,
     normalized_tables, warps, warp_targets, transaction_paths]
  rescue JSON::ParserError => error
    raise "Invalid staged project or reception gate JSON: #{error.message}"
  end

  def valid_tileset_image?(path)
    return false unless regular_file?(path)
    header = File.open(path, "rb") { |file| file.read(24) }
    return false unless header && header.length == 24 &&
                        header[0, 8] == "\x89PNG\r\n\x1A\n".b &&
                        header[12, 4] == "IHDR"
    width, height = header[16, 8].unpack("NN")
    width == 256 && height > 0 && (height % 32).zero?
  rescue SystemCallError
    false
  end

  def build_objects(values)
    map_id, map_name, tileset_name, tileset_id, template, layers,
      tables, warps, warp_targets, = values
    map_infos = load_data("Data/MapInfos.rxdata")
    tilesets = load_data("Data/Tilesets.rxdata")
    tileset = Marshal.load(Marshal.dump(template))
    tileset.name = map_name
    tileset.tileset_name = tileset_name
    tileset.autotile_names = ["", "", "", "", "", "", ""]
    table_size = [tables.keys.max.to_i + 1, 384].max
    tileset.passages = Table.new(table_size)
    tileset.priorities = Table.new(table_size)
    tileset.terrain_tags = Table.new(table_size)
    tables.each do |tile_id, values|
      tileset.passages[tile_id] = values[0]
      tileset.priorities[tile_id] = values[1]
      tileset.terrain_tags[tile_id] = values[2]
    end
    tilesets[tileset_id] = tileset

    map = RPG::Map.new(WIDTH, HEIGHT)
    map.tileset_id = tileset_id
    map.data = Table.new(WIDTH, HEIGHT, 3)
    3.times do |z|
      HEIGHT.times do |y|
        WIDTH.times do |x|
          map.data[x, y, z] = layers[z][y * WIDTH + x]
        end
      end
    end
    map.events = {}
    warps.each_with_index do |warp, index|
      event = RPG::Event.new(warp["x"], warp["y"])
      event.id = index + 1
      event.name = "Exit #{warp["direction"]}"
      page = RPG::Event::Page.new
      page.trigger = 1
      target_map_id, target_x, target_y, target_direction, fade = warp_targets[index]
      page.list = [
        RPG::EventCommand.new(201, 0,
          [0, target_map_id, target_x, target_y, target_direction, fade]),
        RPG::EventCommand.new(0, 0, [])
      ]
      event.pages = [page]
      map.events[event.id] = event
    end

    info = RPG::MapInfo.new
    info.name = map_name
    info.parent_id = 0
    info.order = map_id
    map_infos[map_id] = info
    [tilesets, map, map_infos]
  end

  def rollback!(transactions)
    failures = []
    transactions.reverse_each do |path, temp, backup, _object, existed|
      begin
        if path_present?(backup)
          File.delete(path) if path_present?(path)
          File.rename(backup, path)
        elsif !existed && path_present?(path)
          File.delete(path)
        end
      rescue StandardError => error
        failures << "#{path}: #{error.message}"
      end
      begin
        File.delete(temp) if path_present?(temp)
      rescue StandardError => error
        failures << "#{temp}: #{error.message}"
      end
    end
    failures
  end

  def install(plugin_dir = File.dirname(__FILE__))
    config = JSON.parse(File.read(File.join(plugin_dir, "reception_gate.json")))
    values = preflight!(config)
    map_id, _map_name, _tileset_name, _tileset_id, _template, _layers,
      _tables, _warps, _warp_targets, transactions = values
    lock_acquired = false
    keep_lock = false
    committed = false
    begin
      File.open(LOCK_PATH, File::WRONLY | File::CREAT | File::EXCL) do
        lock_acquired = true
      end
      transactions.each do |path, temp, backup, _object, existed|
        if path_present?(temp) || path_present?(backup)
          raise "Stale reception gate transaction file exists: #{temp} or #{backup}"
        end
        if existed
          raise "Required project file changed during preflight: #{path}" unless regular_file?(path)
        elsif path_present?(path)
          raise "Reception gate map file already exists: #{path}"
        end
      end
      objects = build_objects(values)
      transactions.each_with_index do |(_path, temp, _backup, _object, _existed), index|
        save_data(objects[index], temp)
        raise "Failed to write reception gate temporary data: #{temp}" unless
          File.file?(temp) && File.size(temp) > 0
      end
      transactions.each do |path, temp, backup, _object, existed|
        File.rename(path, backup) if existed
        File.rename(temp, path)
      end
      committed = true
    rescue StandardError => error
      rollback_failures = lock_acquired ? rollback!(transactions) : []
      unless rollback_failures.empty?
        keep_lock = true
        raise "Reception gate import failed (#{error.message}); rollback needs recovery: " \
              "#{rollback_failures.join('; ')}"
      end
      raise
    ensure
      transactions.each do |_path, temp, _backup, _object, _existed|
        File.delete(temp) if path_present?(temp)
      rescue StandardError
      end
      File.delete(LOCK_PATH) if lock_acquired && !committed && !keep_lock && path_present?(LOCK_PATH)
    end
    transactions.each do |_path, _temp, backup, _object, _existed|
      begin
        File.delete(backup) if path_present?(backup)
      rescue SystemCallError
      end
    end
    File.delete(LOCK_PATH) if lock_acquired && path_present?(LOCK_PATH)
    map_id
  ensure
    if defined?(lock_acquired) && lock_acquired && path_present?(LOCK_PATH) && !keep_lock
      File.delete(LOCK_PATH)
    end
  end
end

def pbInstallShatteredHNSReceptionGate
  ShatteredHNSGateImport.install
end
