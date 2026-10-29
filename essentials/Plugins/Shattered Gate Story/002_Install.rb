# frozen_string_literal: true
# Adds executable native RMXP events only to a separately staged 22x21 gate.
# Requires locally verified coordinates, graphics, sound and compiled key item.
require "json"
module ShatteredGateStory
  PREFIX = "SHATTERED_GATE:"
  def self.validate_install(config)
    raise ArgumentError, "unsupported gate scene configuration" unless
      config.is_a?(Hash) && config["schema_version"] == 1 &&
      config["map_id"].instance_of?(Integer) && config["map_id"] > 0
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
    names = sound_names + [config["aipom_cry"], config["aipom_character"]]
    raise ArgumentError, "unsafe asset basename" unless names.all? { |s| s.is_a?(String) &&
      /\A[A-Za-z0-9_ -]+\z/.match(s) }
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
    raise "Gate MapInfo missing" unless infos[id]
    map = load_data(map_path)
    raise "Not the verified 22x21 gate" unless map.width == 22 && map.height == 21
    raise "Gate map events missing" unless map.events.is_a?(Hash)
    raise "Gate key PBS entry missing" unless File.file?("PBS/items.txt") &&
      File.read("PBS/items.txt").match?(/^\[SHATTEREDGATEKEY\]\s*$/)
    (config["collapse_sounds"] + [config["aipom_cry"]]).each do |sound|
      raise "Missing locally provided sound #{sound}" unless Dir.glob("Audio/SE/#{sound}.*").any?
    end
    sprite = config["aipom_character"]
    raise "Missing locally provided Aipom sprite" unless File.file?("Graphics/Characters/#{sprite}.png")
    positions = config["positions"]
    scripts = {
      "collapse" => "ShatteredGateStory.run_collapse(#{config['collapse_sounds'][0, MAX_IMPACTS].inspect})",
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
    already_blocked = south.name == PREFIX + "johto_block" &&
      south.pages.length == 1 && first && first.code == 355 &&
      first.parameters == expected["johto_block"].pages.first.list.first.parameters
    unless already_blocked
      raise "South exit is not a simple transfer" unless south.name == "Exit south" &&
        south.pages.length == 1 && first && first.code == 201 &&
        south.pages.first.list.length == 2 && south.pages.first.list.last.code == 0
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
        raise "Existing scene event differs: #{name}" unless existing.pages.length == 1 &&
          existing.pages.first.list.first.code == 355 &&
          existing.pages.first.list.first.parameters == expected[name].pages.first.list.first.parameters &&
          existing.pages.first.trigger == expected[name].pages.first.trigger &&
          (name != "aipom" || existing.pages.first.graphic.character_name == config["aipom_character"])
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
      event.id = (map.events.keys.max || 0) + 1
      map.events[event.id] = event
    end
    tmp = map_path + ".shattered_gate.tmp"
    backup = map_path + ".shattered_gate.bak"
    raise "Stale gate installer temp or backup" if File.exist?(tmp) || File.exist?(backup)
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
    {"installed" => ["collapse", "aipom", "johto_block"], "map_id" => id}
  end
end

def pbInstallShatteredGateStory(path)
  ShatteredGateStory.install(JSON.parse(File.read(path)))
end
