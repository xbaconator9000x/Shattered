# frozen_string_literal: true
# Native RPG Maker XP events; never modifies an unstaged original project.
require "json"
require "digest"
module ShatteredRoute22
  PREFIX = "SHATTERED_ROUTE22:"
  SOURCE_UUID = "c4c03051-b9be-4d3c-a06c-bcde09a0e3a2"
  SOURCE_DIMENSIONS = [48, 24].freeze
  # Sanitised SE-015 source reference: 3.41 triggers and Rattata NPC markers.
  TRIGGERS = [[36, 16], [36, 17], [36, 18]].freeze
  NPCS = [[38, 17], [39, 16], [39, 18]].freeze
  MOVES = [3, 4, 1].freeze # RMXP MoveCommand: right, up, down.

  # The 48x24 positions describe the original source-indexed reference, not
  # every RMXP project. Native adaptations require explicit reviewed geometry
  # and six non-overlapping, in-bounds placements, plus the pinned map digest.
  def self.geometry(config)
    dimensions = config.fetch("native_dimensions", SOURCE_DIMENSIONS)
    raise ArgumentError, "invalid reviewed Route22 dimensions" unless
      dimensions.is_a?(Array) && dimensions.length == 2 &&
      dimensions.all? { |n| n.instance_of?(Integer) && n.between?(1, 256) }
    adapted = dimensions != SOURCE_DIMENSIONS || config.key?("event_positions")
    if adapted
      raise ArgumentError, "native Route22 adaptation requires explicit review" unless
        config["reviewed_native_geometry"] == true && config["event_positions"].is_a?(Hash)
    end
    positions = config.fetch("event_positions", {
      "triggers" => TRIGGERS, "npcs" => NPCS
    })
    raise ArgumentError, "invalid Route22 event position keys" unless
      positions.is_a?(Hash) && positions.keys.sort == %w[npcs triggers]
    %w[triggers npcs].each do |kind|
      points = positions[kind]
      raise ArgumentError, "Route22 requires exactly three #{kind}" unless
        points.is_a?(Array) && points.length == 3 && points.all? do |point|
          point.is_a?(Array) && point.length == 2 &&
            point[0].instance_of?(Integer) && point[1].instance_of?(Integer) &&
            point[0].between?(0, dimensions[0] - 1) &&
            point[1].between?(0, dimensions[1] - 1)
        end
    end
    all = positions["triggers"] + positions["npcs"]
    raise ArgumentError, "duplicate Route22 event position" unless all.uniq.length == 6
    [dimensions, positions["triggers"], positions["npcs"]]
  end

  def self.validate_native_tiles!(map, coordinates)
    raise "Adapted Route22 map has no native tile layers" unless
      map.respond_to?(:data) && map.data && map.respond_to?(:tileset_id)
    raise "Adapted Route22 tileset file is missing" unless File.file?("Data/Tilesets.rxdata")
    tilesets = load_data("Data/Tilesets.rxdata")
    tileset = tilesets[map.tileset_id] if tilesets.is_a?(Array)
    raise "Adapted Route22 passage table is missing" unless
      tileset && tileset.respond_to?(:passages) && tileset.passages
    coordinates.each do |x, y|
      passable = false
      2.downto(0) do |layer|
        tile = map.data[x, y, layer]
        next if tile.nil? || tile == 0
        passage = tileset.passages[tile]
        raise "Unverified Route22 passage at #{x},#{y}" unless passage.is_a?(Integer)
        next if (passage & 0x10) != 0
        passable = (passage & 0x0f) == 0
        break
      end
      raise "Blocked or unknown Route22 event tile #{x},#{y}" unless passable
    end
  end

  def self.validate_config(config)
    raise ArgumentError, "unsupported Route22 configuration" unless config.is_a?(Hash) &&
      config["schema_version"] == 1 && config["source_map_uuid"] == SOURCE_UUID
    raise ArgumentError, "invalid map ID" unless config["map_id"].instance_of?(Integer) &&
      (1..999).include?(config["map_id"])
    ["outcome_variable", "scatter_switch", "cleared_switch"].each do |key|
      validate_id(config[key])
    end
    raise ArgumentError, "switch IDs must be distinct" if
      config["scatter_switch"] == config["cleared_switch"]
    raise ArgumentError, "missing reviewed source map SHA256" unless
      config["expected_map_sha256"].is_a?(String) &&
      /\A[0-9a-f]{64}\z/.match(config["expected_map_sha256"])
    raise ArgumentError, "invalid sprite basename" unless
      config["rattata_character"].is_a?(String) &&
      /\A[A-Za-z0-9_ -]+\z/.match(config["rattata_character"])
    geometry(config)
    config
  end

  def self.command(code, params = [])
    RPG::EventCommand.new(code, 0, params)
  end

  def self.page(conditional_switch = nil)
    result = RPG::Event::Page.new
    result.through = true
    result.always_on_top = false
    if conditional_switch
      result.condition.switch1_valid = true
      result.condition.switch1_id = conditional_switch
    end
    result
  end

  def self.build_npc(x, y, index, sprite, cleared_switch)
    event = RPG::Event.new(x, y)
    event.name = PREFIX + "rattata_#{index}"
    visible = page
    visible.trigger = 0
    visible.graphic.character_name = sprite
    visible.list = [command(355, ['pbMessage(_INTL("The Rattata looks ready to flee."))']), command(0)]
    hidden = page(cleared_switch)
    hidden.list = [command(0)]
    event.pages = [visible, hidden]
    event
  end

  def self.build_trigger(x, y, index, npc_ids, config)
    event = RPG::Event.new(x, y)
    event.name = PREFIX + "trigger_#{index}"
    initial = page
    initial.trigger = 1 # RMXP Player Touch (2 is Event Touch)
    commands = [command(355, ['pbMessage(_INTL("The Rattata scatter! One turns and attacks!"))'])]
    npc_ids.each_with_index do |npc_id, i|
      route = RPG::MoveRoute.new
      route.repeat = false
      route.skippable = true
      route.list = [RPG::MoveCommand.new(MOVES[i]), RPG::MoveCommand.new(0)]
      commands << command(209, [npc_id, route]) # RMXP Set Move Route
    end
    commands << command(210) # Wait for Move Completion
    commands << command(121, [config["scatter_switch"], config["scatter_switch"], 0])
    script = "ShatteredRoute22.encounter(#{config['outcome_variable']}, #{config['cleared_switch']})"
    commands << command(355, [script])
    commands << command(0)
    initial.list = commands
    retry_page = page(config["scatter_switch"])
    retry_page.trigger = 1
    retry_page.list = [command(355, [script]), command(0)]
    done_page = page(config["cleared_switch"])
    done_page.trigger = 1
    done_page.list = [command(0)]
    event.pages = [initial, retry_page, done_page]
    event
  end

  def self.install(config)
    validate_config(config)
    raise "Refusing to modify non-staged project" unless File.file?("SHATTERED_STAGING_REPORT.json")
    map_path = format("Data/Map%03d.rxdata", config["map_id"])
    # An interrupted replacement may leave a recoverable backup. Never silently
    # accept a partial transaction as an idempotent installation.
    raise "Stale Route22 installer backup/temp; recover manually" if
      File.exist?(map_path + ".shattered_route22.tmp") ||
      File.exist?(map_path + ".shattered_route22.bak")
    raise "Route22 map missing" unless File.file?(map_path)
    infos = load_data("Data/MapInfos.rxdata")
    raise "Route22 MapInfo missing" unless infos[config["map_id"]]
    map = load_data(map_path)
    dimensions, triggers, npcs = geometry(config)
    raise "Route22 map differs from reviewed native geometry" unless
      [map.width, map.height] == dimensions
    raise "Route22 event table missing" unless map.events.is_a?(Hash)
    raise "Legacy Rattata ambush would cause duplicate mandatory battles" if
      map.events.values.any? { |e| e.name.to_s.match?(/SHATTERED.*Rattata ambush/i) }
    validate_native_tiles!(map, triggers + npcs) if dimensions != SOURCE_DIMENSIONS
    sprite = config["rattata_character"]
    raise "Missing locally licensed Rattata character sprite" unless
      File.file?("Graphics/Characters/#{sprite}.png")
    all_names = (0..2).flat_map { |i| [PREFIX + "rattata_#{i}", PREFIX + "trigger_#{i}"] }
    existing = map.events.values.select { |e| e.name.start_with?(PREFIX) }
    if existing.any?
      raise "Partial/foreign Route22 installation; refusing overwrite" unless
        existing.map(&:name).sort == all_names.sort
      ids = (0..2).map { |i| existing.find { |e| e.name == PREFIX + "rattata_#{i}" }.id }
      expected = (0..2).map { |i| build_npc(*npcs[i], i, sprite, config["cleared_switch"]) } +
        (0..2).map { |i| build_trigger(*triggers[i], i, ids, config) }
      expected.each do |event|
        actual = existing.find { |e| e.name == event.name }
        event.id = actual.id
        raise "Route22 installed event changed: #{event.name}" unless
          Marshal.dump(event) == Marshal.dump(actual)
      end
      return {"installed" => 0, "unchanged" => 6, "map_id" => config["map_id"]}
    end
    raise "Source map hash changed; verify geometry and passability" unless
      Digest::SHA256.file(map_path).hexdigest == config["expected_map_sha256"]
    occupied = map.events.values.map { |e| [e.x, e.y] }
    raise "Route22 event tile already occupied" unless (triggers + npcs).none? { |p| occupied.include?(p) }
    next_id = (map.events.keys.max || 0) + 1
    npc_events = npcs.each_with_index.map do |point, i|
      event = build_npc(*point, i, sprite, config["cleared_switch"])
      event.id = next_id
      next_id += 1
      event
    end
    trigger_events = triggers.each_with_index.map do |point, i|
      event = build_trigger(*point, i, npc_events.map(&:id), config)
      event.id = next_id
      next_id += 1
      event
    end
    (npc_events + trigger_events).each { |e| map.events[e.id] = e }
    tmp = map_path + ".shattered_route22.tmp"
    backup = map_path + ".shattered_route22.bak"
    raise "Stale Route22 installer backup/temp" if File.exist?(tmp) || File.exist?(backup)
    begin
      save_data(map, tmp)
      File.rename(map_path, backup)
      File.rename(tmp, map_path)
    rescue Exception
      if File.exist?(backup)
        File.delete(map_path) if File.exist?(map_path)
        File.rename(backup, map_path)
      end
      raise
    ensure
      File.delete(tmp) if File.exist?(tmp)
    end
    File.delete(backup)
    {"installed" => 6, "map_id" => config["map_id"]}
  end
end

def pbInstallShatteredRoute22(path)
  ShatteredRoute22.install(JSON.parse(File.read(path)))
end
