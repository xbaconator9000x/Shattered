# frozen_string_literal: true
# SE-018: install guarded, native RMXP Viridian escort/weather events in a COPY.
# Source-only NPC anchors from the private Shattered parity manifest; no assets.
require "json"
require "digest"
module ShatteredViridian
  PREFIX = "SHATTERED_VIRIDIAN:"
  SOURCE_UUID = "5e2cbf0c-2a22-47ac-9205-ccca87172d2e"
  CITY_SIZE = [48, 40].freeze
  SOURCE_NPCS = {
    "3.1:npc:1" => [9,16], "3.1:npc:13" => [20,7],
    "3.1:npc:14" => [34,30], "3.1:npc:15" => [36,20],
    "3.1:npc:16" => [12,23], "3.1:npc:17" => [28,29],
    "3.1:npc:19" => [30,29], "3.1:npc:21" => [22,8],
    "3.1:npc:22" => [17,9], "3.1:npc:23" => [32,29],
    "3.1:npc:24" => [35,20], "3.1:npc:25" => [13,23],
    "3.1:npc:3" => [33,32], "3.1:npc:4" => [23,4],
    "3.1:npc:5" => [9,32], "3.1:npc:6" => [26,33],
    "3.1:npc:8" => [18,9]
  }.freeze
  SOURCE_ENTRIES = [[0,17], [0,18], [0,19]].freeze
  EVENT_NAMES = ["guard", "nidoran", "entry", "finish", "rain", "center"].freeze

  def self.integer!(n, min, max, label)
    raise ArgumentError, "invalid #{label}" unless n.instance_of?(Integer) && n.between?(min, max)
    n
  end

  def self.point!(point, size, label)
    raise ArgumentError, "invalid #{label}" unless point.is_a?(Array) && point.length == 2
    integer!(point[0], 0, size[0] - 1, "#{label}.x")
    integer!(point[1], 0, size[1] - 1, "#{label}.y")
    point
  end

  def self.path!(path, start, size, label)
    raise ArgumentError, "#{label} must start at the source NPC" unless path.is_a?(Array) &&
      path.length.between?(2, 64) && path.first == start
    path.each_with_index do |p, i|
      point!(p, size, "#{label}[#{i}]")
      next if i == 0
      raise ArgumentError, "#{label} has a jump or zero movement" unless
        (p[0] - path[i-1][0]).abs + (p[1] - path[i-1][1]).abs == 1
    end
    path
  end

  def self.character!(name)
    raise ArgumentError, "unsafe character basename" unless name.is_a?(String) &&
      /\A[A-Za-z0-9_ -]{1,80}\z/.match(name)
    name
  end

  def self.validate(config)
    raise ArgumentError, "unsupported Viridian plan" unless config.is_a?(Hash) &&
      config["schema_version"] == 1 && config["source_map_uuid"] == SOURCE_UUID
    # The source marker alone cannot prove a sprite's identity or a passable route.
    # Require deliberate manual mapping; actual in-engine checks remain mandatory.
    raise ArgumentError, "NPC roles and path must be explicitly reviewed" unless
      config["roles_reviewed"] == true && config["path_passability_reviewed"] == true
    city_id = integer!(config["city_map_id"], 1, 999, "city_map_id")
    center_id = integer!(config["center_map_id"], 1, 999, "center_map_id")
    raise ArgumentError, "city and Center maps must differ" if city_id == center_id
    center_size = config["center_dimensions"]
    raise ArgumentError, "invalid Center dimensions" unless center_size.is_a?(Array) &&
      center_size.length == 2
    center_size.each { |v| integer!(v, 1, 200, "Center dimension") }
    ["city", "center"].each do |name|
      sha = config["expected_#{name}_sha256"]
      raise ArgumentError, "missing reviewed #{name} map SHA256" unless
        sha.is_a?(String) && /\A[0-9a-f]{64}\z/.match(sha)
    end
    ["guard", "nidoran"].each do |role|
      npc = config[role]
      raise ArgumentError, "missing #{role}" unless npc.is_a?(Hash)
      source = SOURCE_NPCS[npc["source_event_id"]]
      raise ArgumentError, "unverified #{role} source NPC anchor" unless source &&
        [npc["x"], npc["y"]] == source
      character!(npc["character"])
      path!(config["#{role}_path"], source, CITY_SIZE, "#{role}_path")
    end
    raise ArgumentError, "NPC source anchors must differ" if
      config["guard"]["source_event_id"] == config["nidoran"]["source_event_id"]
    marker = point!(config["entry_source_marker"], CITY_SIZE, "entry_source_marker")
    raise ArgumentError, "entry marker absent from original Viridian map" unless SOURCE_ENTRIES.include?(marker)
    entry = point!(config["entry_trigger"], CITY_SIZE, "entry_trigger")
    raise ArgumentError, "entry trigger too far from source entrance" unless
      (entry[0]-marker[0]).abs + (entry[1]-marker[1]).abs <= 3
    ["finish_trigger", "rain_controller"].each { |key| point!(config[key], CITY_SIZE, key) }
    point!(config["center_trigger"], center_size, "center_trigger")
    city_points = [entry, config["finish_trigger"], config["rain_controller"],
                   [config["guard"]["x"], config["guard"]["y"]],
                   [config["nidoran"]["x"], config["nidoran"]["y"]]]
    raise ArgumentError, "overlapping Viridian events" unless city_points.uniq.length == city_points.length
    switches = config["switches"]
    raise ArgumentError, "missing switch map" unless switches.is_a?(Hash)
    ids = ["started", "arrived", "center", "rain"].map do |key|
      integer!(switches[key], 1, 9999, "switches.#{key}")
    end
    raise ArgumentError, "switch IDs must be distinct" unless ids.uniq.length == 4
    config
  end

  def self.command(code, params = [])
    RPG::EventCommand.new(code, 0, params)
  end

  def self.page(condition_switch = nil, trigger = 0)
    p = RPG::Event::Page.new
    p.trigger = trigger
    p.through = true
    p.always_on_top = false
    if condition_switch
      p.condition.switch1_valid = true
      p.condition.switch1_id = condition_switch
    end
    p
  end

  def self.event(name, point, pages)
    e = RPG::Event.new(point[0], point[1])
    e.name = PREFIX + name
    e.pages = pages
    e
  end

  def self.npc(name, config, started)
    record = config[name]
    visible = page
    visible.graphic.character_name = record["character"]
    visible.list = [command(0)]
    hidden = page(started)
    hidden.list = [command(0)]
    event(name, [record["x"], record["y"]], [visible, hidden])
  end

  def self.move_route(path)
    codes = { [0,1] => 1, [-1,0] => 2, [1,0] => 3, [0,-1] => 4 }
    route = RPG::MoveRoute.new
    route.repeat = false
    route.skippable = false
    route.list = path.each_cons(2).map do |from, to|
      RPG::MoveCommand.new(codes[[to[0]-from[0], to[1]-from[1]]])
    end
    route.list << RPG::MoveCommand.new(0)
    route
  end

  def self.build_events(config, guard_id, nidoran_id)
    switches = config["switches"]
    started = switches["started"]
    arrived = switches["arrived"]
    center = switches["center"]
    rain = switches["rain"]
    guard = npc("guard", config, started)
    nidoran = npc("nidoran", config, started)
    entry = page
    entry.trigger = 2 # player touch
    entry.list = [
      command(236, [1, 6, 20]), # RMXP rain, power 6, 20 frames
      command(209, [guard_id, move_route(config["guard_path"])]),
      command(209, [nidoran_id, move_route(config["nidoran_path"])]),
      command(210), # wait for movement; only then persist escort start
      command(355, ["ShatteredViridian.start!(#{started}, #{rain})"]),
      command(0)
    ]
    entry_done = page(started, 2)
    entry_done.list = [command(0)]
    entry_event = event("entry", config["entry_trigger"], [entry, entry_done])
    finish_page = page(started, 2)
    finish_page.list = [command(355, ["ShatteredViridian.arrive!(#{arrived})"]), command(0)]
    finish_done = page(arrived, 2)
    finish_done.list = [command(0)]
    finish_event = event("finish", config["finish_trigger"], [page, finish_page, finish_done])
    # Parallel rain refresh on city reload; gated by the saved rain switch.
    weather_page = page(rain, 4)
    weather_page.list = [command(236, [1, 6, 0]), command(106, [600]), command(0)]
    rain_event = event("rain", config["rain_controller"], [page, weather_page])
    # This event belongs INSIDE the Center, not on a transfer/door tile.
    center_page = page(started, 3) # autorun, once on first Center entry
    center_page.list = [
      command(236, [0, 0, 20]),
      command(355, ["ShatteredViridian.center!(#{center}, #{rain})"]),
      command(0)
    ]
    center_done = page(center)
    center_done.list = [command(0)]
    center_event = event("center", config["center_trigger"], [page, center_page, center_done])
    {"guard" => guard, "nidoran" => nidoran, "entry" => entry_event,
     "finish" => finish_event, "rain" => rain_event, "center" => center_event}
  end

  def self.install(config)
    validate(config)
    raise "Refusing to edit unstaged original" unless File.file?("SHATTERED_STAGING_REPORT.json")
    paths = {
      "city" => format("Data/Map%03d.rxdata", config["city_map_id"]),
      "center" => format("Data/Map%03d.rxdata", config["center_map_id"])
    }
    paths.each_value do |path|
      raise "Stale Viridian backup/temp: #{path}" if
        File.exist?(path + ".shattered_viridian.tmp") ||
        File.exist?(path + ".shattered_viridian.bak")
      raise "Missing map #{path}" unless File.file?(path)
    end
    infos = load_data("Data/MapInfos.rxdata")
    raise "City/Center MapInfo missing" unless infos[config["city_map_id"]] && infos[config["center_map_id"]]
    maps = paths.transform_values { |path| load_data(path) }
    raise "Viridian source must be 48x40" unless
      [maps["city"].width, maps["city"].height] == CITY_SIZE
    raise "Center dimensions differ from reviewed plan" unless
      [maps["center"].width, maps["center"].height] == config["center_dimensions"]
    maps.each_value { |map| raise "Missing event collection" unless map.events.is_a?(Hash) }
    ["guard", "nidoran"].each do |role|
      sprite = config[role]["character"]
      raise "Missing licensed local sprite #{sprite}" unless
        File.file?("Graphics/Characters/#{sprite}.png")
    end
    city = maps["city"]
    center = maps["center"]
    expected_names = EVENT_NAMES.map { |n| PREFIX + n }
    existing = [city, center].flat_map { |m| m.events.values.select { |e| e.name.start_with?(PREFIX) } }
    if existing.any?
      raise "Partial/foreign Viridian installation" unless existing.map(&:name).sort == expected_names.sort
      guard_id = existing.find { |e| e.name == PREFIX + "guard" }.id
      nidoran_id = existing.find { |e| e.name == PREFIX + "nidoran" }.id
      built = build_events(config, guard_id, nidoran_id)
      built.each do |name, e|
        target_map = name == "center" ? center : city
        actual = target_map.events.values.find { |v| v.name == PREFIX + name }
        e.id = actual.id
        raise "Viridian event drift: #{name}" unless Marshal.dump(e) == Marshal.dump(actual)
      end
      return {"installed" => 0, "unchanged" => 6}
    end
    paths.each do |kind, path|
      raise "Source map SHA changed: #{kind}" unless
        Digest::SHA256.file(path).hexdigest == config["expected_#{kind}_sha256"]
    end
    planned_city = [config["entry_trigger"], config["finish_trigger"],
                    config["rain_controller"],
                    [config["guard"]["x"], config["guard"]["y"]],
                    [config["nidoran"]["x"], config["nidoran"]["y"]]]
    raise "Occupied city event tile" if city.events.values.any? { |e| planned_city.include?([e.x, e.y]) }
    raise "Occupied Center event tile" if center.events.values.any? { |e| [e.x,e.y] == config["center_trigger"] }
    guard_id = (city.events.keys.max || 0) + 1
    nidoran_id = guard_id + 1
    built = build_events(config, guard_id, nidoran_id)
    built.each do |name, e|
      map = name == "center" ? center : city
      e.id = name == "guard" ? guard_id : name == "nidoran" ? nidoran_id : (map.events.keys.max || 0) + 1
      map.events[e.id] = e
    end
    # Preflight BOTH maps and stage BOTH temporary files before replacing either.
    begin
      paths.each { |kind, path| save_data(maps[kind], path + ".shattered_viridian.tmp") }
      paths.each_value do |path|
        File.rename(path, path + ".shattered_viridian.bak")
        File.rename(path + ".shattered_viridian.tmp", path)
      end
    rescue Exception
      paths.values.reverse.each do |path|
        backup = path + ".shattered_viridian.bak"
        next unless File.exist?(backup)
        File.delete(path) if File.exist?(path)
        File.rename(backup, path)
      end
      raise
    ensure
      paths.each_value do |path|
        tmp = path + ".shattered_viridian.tmp"
        File.delete(tmp) if File.exist?(tmp)
      end
    end
    paths.each_value { |path| File.delete(path + ".shattered_viridian.bak") }
    {"installed" => 6, "changed_maps" => [config["city_map_id"], config["center_map_id"]]}
  end
end

def pbInstallShatteredViridian(path)
  ShatteredViridian.install(JSON.parse(File.read(path)))
end
