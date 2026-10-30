# frozen_string_literal: true
# Adds executable native RMXP events only to a separately staged 22x21 gate.
# Requires locally verified coordinates, graphics, sound and compiled key item.
require "json"
module ShatteredGateStory
  PREFIX = "SHATTERED_GATE:"
  FLAG_PLAN = "shattered_gate_story_v1"

  def self.validate_map_events!(events)
    raise "Gate map events missing" unless events.is_a?(Hash)
    events.each do |id, event|
      raise "Malformed gate event ID" unless id.instance_of?(Integer) && id > 0
      raise "Malformed gate event entry" unless event.is_a?(RPG::Event) && event.id == id
    end
  end

  def self.passable_tile?(map, tilesets, x, y)
    raise "Gate map tileset ID missing" unless map.respond_to?(:tileset_id) &&
      map.tileset_id.instance_of?(Integer) && map.tileset_id > 0
    tileset = tilesets[map.tileset_id]
    raise "Gate map tileset missing" unless tileset && tileset.respond_to?(:passages)
    data = map.data
    raise "Gate map tile data missing" unless data &&
      data.respond_to?(:xsize) && data.respond_to?(:ysize) && data.respond_to?(:zsize) &&
      data.xsize == map.width && data.ysize == map.height && data.zsize > 0
    (data.zsize - 1).downto(0) do |z|
      tile_id = data[x, y, z]
      next if tile_id == 0
      passage = tileset.passages[tile_id]
      raise "Gate tileset passage data missing" unless passage.instance_of?(Integer)
      next if (passage & 0x10) != 0
      return (passage & 0x0F) == 0
    end
    true
  end

  def self.same_event?(actual, expected)
    return false unless actual.is_a?(RPG::Event) &&
      actual.x == expected.x && actual.y == expected.y && actual.name == expected.name &&
      actual.pages.is_a?(Array) && actual.pages.length == 1
    actual_page = actual.pages.first
    expected_page = expected.pages.first
    return false unless actual_page.trigger == expected_page.trigger &&
      actual_page.through == expected_page.through &&
      actual_page.always_on_top == expected_page.always_on_top &&
      actual_page.graphic.character_name == expected_page.graphic.character_name &&
      actual_page.list.is_a?(Array) && actual_page.list.length == 2
    actual_page.list.each_with_index.all? do |command, index|
      expected_command = expected_page.list[index]
      command.code == expected_command.code &&
        command.indent == expected_command.indent &&
        command.parameters == expected_command.parameters
    end
  end

  def self.validate_install(config)
    raise ArgumentError, "unsupported gate scene configuration" unless
      config.is_a?(Hash) && config["schema_version"] == 1 &&
      config["map_id"].instance_of?(Integer) && config["map_id"] > 0
    raise ArgumentError, "unsupported gate story flag plan" unless
      config["flag_plan"] == FLAG_PLAN
    positions = config["positions"]
    raise ArgumentError, "missing event positions" unless positions.is_a?(Hash) &&
      (positions.keys.sort == ["aipom", "collapse", "johto_block"].sort)
    seen = {}
    positions.each do |label, pos|
      raise ArgumentError, "invalid #{label} position" unless pos.is_a?(Hash) &&
        pos.keys.sort == ["x", "y"].sort &&
        pos["x"].instance_of?(Integer) && (0...22).include?(pos["x"]) &&
        pos["y"].instance_of?(Integer) && (0...21).include?(pos["y"])
      raise ArgumentError, "duplicate scene tile" if seen[[pos["x"], pos["y"]]]
      seen[[pos["x"], pos["y"]]] = true
    end
    sound_names = config["collapse_sounds"]
    raise ArgumentError, "six sound basenames required" unless sound_names.is_a?(Array) &&
      sound_names.length == MAX_IMPACTS
    names = sound_names + [config["aipom_cry"], config["final_roar_sound"],
      config["aipom_character"]]
    raise ArgumentError, "unsafe asset basename" unless names.all? { |s| s.is_a?(String) &&
      !s.strip.empty? &&
      /\A[A-Za-z0-9_ -]+\z/.match(s) }
    transfer = config["expected_south_transfer"]
    raise ArgumentError, "invalid reviewed south transfer" unless
      transfer.is_a?(Array) && transfer.length == 6 &&
      transfer.all? { |value| value.instance_of?(Integer) && value >= 0 } &&
      transfer[0] == 0 && transfer[1] > 0
    config
  end

  def self.scene_event(x, y, name, script, trigger, character = nil)
    event = RPG::Event.new(x, y)
    event.name = PREFIX + name
    page = RPG::Event::Page.new
    page.trigger = trigger
    page.through = false
    page.always_on_top = false
    page.graphic.character_name = character if character
    page.list = [RPG::EventCommand.new(355, 0, [script]), RPG::EventCommand.new(0, 0, [])]
    event.pages = [page]
    event
  end

  def self.install(config)
    raise "Refusing to modify non-staged project" unless File.file?("SHATTERED_STAGING_REPORT.json")
    validate_install(config)
    id = config["map_id"]
    map_path = sprintf("Data/Map%03d.rxdata", id)
    raise "Gate map missing" unless File.file?(map_path)
    infos = load_data("Data/MapInfos.rxdata")
    raise "Gate MapInfo missing" unless infos.is_a?(Hash) && infos[id]
    map = load_data(map_path)
    raise "Not the verified 22x21 gate" unless map.width == 22 && map.height == 21
    validate_map_events!(map.events)
    tilesets = load_data("Data/Tilesets.rxdata")
    raise "Gate tilesets missing" unless tilesets.is_a?(Hash)
    raise "Gate key PBS entry missing" unless File.file?("PBS/items.txt") &&
      File.read("PBS/items.txt").match?(/^\[SHATTEREDGATEKEY\]\s*$/)
    (config["collapse_sounds"] + [config["aipom_cry"], config["final_roar_sound"]]).each do |sound|
      raise "Missing locally provided sound #{sound}" unless
        Dir.glob("Audio/SE/#{sound}.*").any? { |path| File.file?(path) }
    end
    sprite = config["aipom_character"]
    raise "Missing locally provided Aipom sprite" unless File.file?("Graphics/Characters/#{sprite}.png")
    positions = config["positions"]
    positions.each do |name, pos|
      if name == "johto_block"
        # A south-border transfer may deliberately occupy an impassable tile.
        # The blocking event must still be reachable from the gate interior.
        raise "Johto blocker has no northern approach" if pos["y"] == 0 ||
          !passable_tile?(map, tilesets, pos["x"], pos["y"] - 1)
      else
        raise "Scene event tile is impassable: #{name}" unless
          passable_tile?(map, tilesets, pos["x"], pos["y"])
      end
    end
    scripts = {
      "collapse" => "ShatteredGateStory.run_collapse(#{config['collapse_sounds'][0, MAX_IMPACTS].inspect}, #{config['final_roar_sound'].inspect})",
      "aipom" => "ShatteredGateStory.run_aipom(#{config['aipom_cry'].inspect})",
      "johto_block" => "ShatteredGateStory.blocked_johto"
    }
    expected = {}
    positions.each do |name, pos|
      expected[name] = scene_event(pos["x"], pos["y"], name, scripts[name],
        name == "aipom" ? 0 : 1, name == "aipom" ? sprite : nil)
    end
    # The south gate must be a verified existing native transfer before replacing it.
    # Do not silently delete unrelated NPCs or transfer scripts.
    blocked = positions["johto_block"]
    matches = map.events.values.select { |e| e.x == blocked["x"] && e.y == blocked["y"] }
    raise "Expected exactly one south exit" unless matches.length == 1
    south = matches.first
    first = south.pages.first.list.first rescue nil
    expected["johto_block"].id = south.id
    already_blocked = same_event?(south, expected["johto_block"])
    unless already_blocked
      page = south.pages.first if south.pages.is_a?(Array) && south.pages.length == 1
      commands = page.list if page && page.list.is_a?(Array)
      raise "South exit is not a simple transfer" unless south.name == "Exit south" &&
        page && page.trigger == 1 && commands && commands.length == 2 &&
        first && first.code == 201 && first.indent == 0 &&
        commands.last.code == 0 && commands.last.indent == 0 &&
        commands.last.parameters == []
      # Require the caller to pin the exact destination to prevent replacing the wrong exit.
      raise "South exit destination differs from reviewed map" unless
        first.parameters == config["expected_south_transfer"]
    end
    for name in ["collapse", "aipom"]
      pos = positions[name]
      namesakes = map.events.values.select { |e| e.name == PREFIX + name }
      raise "Duplicate or relocated scene event: #{name}" if namesakes.length > 1 ||
        (namesakes.length == 1 && (namesakes.first.x != pos["x"] || namesakes.first.y != pos["y"]))
      occupied = map.events.values.select { |e| e.x == pos["x"] && e.y == pos["y"] }
      raise "Scene event tile occupied: #{name}" unless occupied.empty? ||
        (occupied.length == 1 && occupied.first.name == PREFIX + name)
      if occupied.length == 1
        existing = occupied.first
        raise "Existing scene event differs: #{name}" unless same_event?(existing, expected[name])
      end
    end
    # Re-running with identical inputs leaves the staged map untouched.
    if already_blocked && ["collapse", "aipom"].all? { |name| map.events.values.any? { |e| e.name == PREFIX + name } }
      return {"installed" => [], "unchanged" => 3, "map_id" => id}
    end
    expected["johto_block"].id = south.id
    map.events[south.id] = expected["johto_block"]
    ["collapse", "aipom"].each do |name|
      next if map.events.values.any? { |e| e.name == PREFIX + name }
      event = expected[name]
      event.id = (1..(map.events.length + 1)).find { |candidate| !map.events.key?(candidate) }
      map.events[event.id] = event
    end
    tmp = map_path + ".shattered_gate.tmp"
    backup = map_path + ".shattered_gate.bak"
    raise "Stale gate installer temp or backup" if File.exist?(tmp) || File.exist?(backup)
    original_moved = false
    begin
      save_data(map, tmp)
      File.rename(map_path, backup)
      original_moved = true
      File.rename(tmp, map_path)
    rescue StandardError => install_error
      begin
        if original_moved && File.exist?(backup)
          File.delete(map_path) if File.exist?(map_path)
          File.rename(backup, map_path)
        end
      rescue StandardError => rollback_error
        raise "Gate install failed (#{install_error.message}); rollback failed (#{rollback_error.message}); preserve #{backup}"
      end
      raise install_error
    ensure
      File.delete(tmp) if File.exist?(tmp)
    end
    File.delete(backup)
    {"installed" => ["collapse", "aipom", "johto_block"], "map_id" => id}
  end
end

def pbInstallShatteredGateStory(path)
  ShatteredGateStory.install(JSON.parse(File.read(path)))
end
