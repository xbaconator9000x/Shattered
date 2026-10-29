require "json"

def pbInstallShatteredHNSReceptionGate
  plugin_dir = File.dirname(__FILE__)
  config = JSON.parse(File.read(File.join(plugin_dir, "reception_gate.json")))
  raise "Unsupported reception gate import bundle" if config["format"] != "shattered-hns-rmxp-map" ||
                                                      config["format_version"] != 1
  width = config["dimensions"]["width"]
  height = config["dimensions"]["height"]
  raise "Reception gate must be 22x21" if width != 22 || height != 21
  raise "Reception gate import must have three tile layers" if config["layers"].length != 3 ||
    config["layers"].any? { |layer| layer.length != width * height }
  map_id = config["target"]["map_id"]
  map_infos = load_data("Data/MapInfos.rxdata")
  tilesets = load_data("Data/Tilesets.rxdata")
  raise "Reception gate map ID already exists" if map_infos[map_id]
  template_id = config["target"]["tileset_template_id"]
  template = tilesets[template_id]
  raise "Reception gate tileset template is missing" if !template
  image_path = File.join("Graphics", "Tilesets", config["target"]["tileset_name"] + ".png")
  raise "Reception gate tileset image is missing" if !File.file?(image_path)
  tileset_id = tilesets.length
  raise "Reception gate tileset ID is already occupied" if tilesets[tileset_id]

  tileset = Marshal.load(Marshal.dump(template))
  tileset.name = config["map_name"]
  tileset.tileset_name = config["target"]["tileset_name"]
  tileset.autotile_names = ["", "", "", "", "", "", ""]
  table_size = [config["tileset_tables"].keys.map(&:to_i).max.to_i + 1, 384].max
  tileset.passages = Table.new(table_size)
  tileset.priorities = Table.new(table_size)
  tileset.terrain_tags = Table.new(table_size)
  config["tileset_tables"].each do |tile_id, values|
    id = tile_id.to_i
    tileset.passages[id] = values[0]
    tileset.priorities[id] = values[1]
    tileset.terrain_tags[id] = values[2]
  end
  tilesets[tileset_id] = tileset

  map = RPG::Map.new(width, height)
  map.tileset_id = tileset_id
  map.data = Table.new(width, height, 3)
  3.times do |z|
    height.times do |y|
      width.times do |x|
        map.data[x, y, z] = config["layers"][z][y * width + x]
      end
    end
  end

  map.events = {}
  config["warps"].each_with_index do |warp, index|
    if warp["x"] < 0 || warp["y"] < 0 || warp["x"] >= width || warp["y"] >= height
      raise "Reception gate warp is outside the map"
    end
    target = warp["target"]
    raise "Reception gate warp map is missing" if !map_infos[target["map_id"]]
    target_map = load_data(sprintf("Data/Map%03d.rxdata", target["map_id"]))
    if target["x"] < 0 || target["y"] < 0 ||
       target["x"] >= target_map.width || target["y"] >= target_map.height
      raise "Reception gate warp destination is outside its map"
    end
    event = RPG::Event.new(warp["x"], warp["y"])
    event.id = index + 1
    event.name = "Exit #{warp["direction"]}"
    page = RPG::Event::Page.new
    page.trigger = 1
    page.list = [
      RPG::EventCommand.new(201, 0,
        [0, target["map_id"], target["x"], target["y"], target["direction"], target["fade"]]),
      RPG::EventCommand.new(0, 0, [])
    ]
    event.pages = [page]
    map.events[event.id] = event
  end

  info = RPG::MapInfo.new
  info.name = config["map_name"]
  info.parent_id = 0
  info.order = map_id
  map_infos[map_id] = info
  save_data(tilesets, "Data/Tilesets.rxdata")
  save_data(map, sprintf("Data/Map%03d.rxdata", map_id))
  save_data(map_infos, "Data/MapInfos.rxdata")
  return map_id
end
