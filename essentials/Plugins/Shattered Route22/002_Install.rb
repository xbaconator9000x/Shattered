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
  LEGACY_DISABLED = "SHATTERED_LEGACY_ROUTE22_DISABLED"
  V04_ROUTE22_SHA256 = "0ec2a363a411c9b0086a4a3868fdca0d8b0339c26ab1ddf5a5c33b84174f9b6b"
  V04_LEGACY_EVENT_SHA256 = "ef8861a24531fedc56be153cc88a80ed6e314103af48b810d85b116aaadfe786"
  V04_TRIGGERS = [[27, 16], [27, 17], [27, 18]].freeze
  V04_NPCS = [[29, 17], [29, 18], [28, 18]].freeze
  V04_SCATTER_MOVES = [3, 4, 3].freeze
  MOVE_DELTAS = {1 => [0, 1], 2 => [-1, 0], 3 => [1, 0], 4 => [0, -1]}.freeze

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
        points.is_a?(Array) && points.length == 3 && points.all? { |point|
          point.is_a?(Array) && point.length == 2 &&
            point[0].instance_of?(Integer) && point[1].instance_of?(Integer) &&
            point[0].between?(0, dimensions[0] - 1) &&
            point[1].between?(0, dimensions[1] - 1)
        }
    end
    all = positions["triggers"] + positions["npcs"]
    raise ArgumentError, "duplicate Route22 event position" unless all.uniq.length == 6
    [dimensions, positions["triggers"], positions["npcs"]]
  end

  def self.scatter_moves(config)
    moves = config.fetch("scatter_moves", MOVES)
    raise ArgumentError, "Route22 scatter moves must be three cardinal steps" unless
      moves.is_a?(Array) && moves.length == 3 &&
      moves.all? { |move| MOVE_DELTAS.key?(move) }
    moves
  end

  def self.scatter_destinations(npcs, config)
    npcs.each_with_index.map do |(x, y), i|
      dx, dy = MOVE_DELTAS.fetch(scatter_moves(config)[i])
      [x + dx, y + dy]
    end
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
    dimensions, triggers, npcs = geometry(config)
    scatter_moves(config)
    if config["expected_map_sha256"] == V04_ROUTE22_SHA256
      raise ArgumentError, "audited v0.4 Route22 positions/moves changed" unless
        dimensions == [54, 34] && triggers == V04_TRIGGERS &&
        npcs == V04_NPCS && scatter_moves(config) == V04_SCATTER_MOVES
      record = config["legacy_migration"]
      raise ArgumentError, "audited v0.4 requires pinned legacy event migration" unless
        record.is_a?(Hash) && record == {
          "event_id" => 3, "event_name" => "SHATTERED: Rattata ambush",
          "x" => 30, "y" => 17, "event_sha256" => V04_LEGACY_EVENT_SHA256
        }
    end
    config
  end

  # Only the exact audited legacy autorun is eligible for migration. The
  # original event is replaced inside the same transactional map write, never
  # in the user's source project. A receipt/backup restores it if installation fails.
  def self.legacy_event(map, config)
    record = config["legacy_migration"]
    legacy_names = map.events.values.select { |e|
      e.name.to_s.match?(/SHATTERED.*Rattata ambush/i)
    }
    if !record
      raise "Legacy Rattata ambush would cause duplicate mandatory battles" unless legacy_names.empty?
      raise "Unowned disabled legacy Route22 event" if
        map.events.values.any? { |e| e.name == LEGACY_DISABLED }
      return nil
    end
    id = record["event_id"]
    event = map.events[id]
    raise "Reviewed legacy Rattata event missing" unless event &&
      event.id == id && event.x == record["x"] && event.y == record["y"]
    if event.name == LEGACY_DISABLED
      raise "Tampered disabled legacy Rattata event" unless
        event.pages.length == 1 && event.pages[0].trigger == 0 &&
        event.pages[0].through == true &&
        event.pages[0].list.map(&:code) == [0]
      return nil
    end
    raise "Unexpected legacy Rattata event or duplicate" unless
      legacy_names.length == 1 && legacy_names.first.equal?(event) &&
      event.name == record["event_name"] &&
      Digest::SHA256.hexdigest(Marshal.dump(event)) == record["event_sha256"]
    event
  end

  def self.disable_legacy!(event)
    return unless event
    event.name = LEGACY_DISABLED
    blank = page
    blank.trigger = 0
    blank.list = [command(0)]
    event.pages = [blank]
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
    moves = scatter_moves(config)
    npc_ids.each_with_index do |npc_id, i|
      route = RPG::MoveRoute.new
      route.repeat = false
      route.skippable = true
      route.list = [RPG::MoveCommand.new(moves[i]), RPG::MoveCommand.new(0)]
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
    legacy = legacy_event(map, config)
    validate_native_tiles!(map, triggers + npcs + scatter_destinations(npcs, config)) if
      dimensions != SOURCE_DIMENSIONS
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
    raise "Legacy migration is incomplete without six installed events" if
      map.events.values.any? { |e| e.name == LEGACY_DISABLED }
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
    disable_legacy!(legacy)
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
