# frozen_string_literal: true
# SE-019C: explicit-plan, transactional native RPG Maker XP event installer.
require "json"
require "digest"

module ShatteredMurkrowRescue
  PREFIX = "SHATTERED_MURKROW_RESCUE:" unless const_defined?(:PREFIX)
  SOURCE_MAP_UUID = "491b8085-ec13-440e-9800-335edda8b08d"
  SOURCE_MAP_SIZE = [67, 36].freeze
  SOURCE_ANCHORS = {
    "28.5:npc:1" => [51, 16],
    "28.5:npc:2" => [50, 16],
    "28.5:npc:3" => [52, 15],
    "28.5:npc:4" => [52, 17],
    "28.5:trigger:53,15" => [53, 15],
    "28.5:trigger:53,17" => [53, 17],
    "28.5:trigger:54,16" => [54, 16]
  }.freeze

  def self.valid_id?(value)
    value.instance_of?(Integer) && value.between?(1, 999)
  end

  def self.valid_point?(point, width, height)
    point.is_a?(Array) && point.length == 2 &&
      point.all? { |coordinate| coordinate.instance_of?(Integer) } &&
      point[0] >= 0 && point[0] < width && point[1] >= 0 && point[1] < height
  end

  def self.canonical(value)
    if value.is_a?(Hash)
      value.keys.sort.each_with_object({}) { |key, result| result[key] = canonical(value[key]) }
    elsif value.is_a?(Array)
      value.map { |item| canonical(item) }
    else
      value
    end
  end

  def self.validate_plan!(plan)
    raise ArgumentError, "Murkrow plan must be a JSON object" unless plan.is_a?(Hash)
    raise ArgumentError, "Unsupported Murkrow plan" unless plan["schema_version"] == 1 &&
      plan["source_map_uuid"] == SOURCE_MAP_UUID
    raise ArgumentError, "Source-only Route 22 dimensions mismatch" unless
      plan["source_map_size"] == SOURCE_MAP_SIZE
    anchor = SOURCE_ANCHORS[plan["source_event_id"]]
    raise ArgumentError, "Unknown source-only Murkrow anchor" unless anchor
    raise ArgumentError, "Source anchor coordinate mismatch" unless plan["source_position"] == anchor
    raise ArgumentError, "Source role, target location and passability need user review" unless
      plan["role_reviewed"] == true && plan["location_reviewed"] == true &&
      plan["passability_reviewed"] == true &&
      plan["reviewed_source_role"].is_a?(String) &&
      !plan["reviewed_source_role"].strip.empty?
    raise ArgumentError, "Invalid target map ID" unless valid_id?(plan["target_map_id"])
    size = plan["target_map_size"]
    raise ArgumentError, "Invalid reviewed target map dimensions" unless
      size.is_a?(Array) && size.length == 2 &&
      size.all? { |dimension| dimension.instance_of?(Integer) && dimension > 0 }
    point = plan["target_position"]
    raise ArgumentError, "Invalid event position" unless
      valid_point?(point, size[0], size[1])
    event_id = plan["event_id"]
    raise ArgumentError, "Invalid event ID" unless event_id.instance_of?(Integer) &&
      event_id.between?(1, 9999)
    sha = plan["expected_map_sha256"]
    raise ArgumentError, "Reviewed target map SHA256 required" unless
      sha.is_a?(String) && /\A[0-9a-f]{64}\z/.match(sha)
    character = plan["character"]
    raise ArgumentError, "Unsafe character filename" unless
      character.is_a?(String) && /\A[A-Za-z0-9_ -]{1,80}\z/.match(character)
    raise ArgumentError, "Character role needs user review" unless plan["sprite_reviewed"] == true
    raise ArgumentError, "This plugin uses saved quest flags, not RMXP switches or variables" unless
      plan["switch_ids"] == [] && plan["variable_ids"] == []
    warp = plan["destination_warp"]
    raise ArgumentError, "Reviewed destination warp required" unless warp.is_a?(Hash) &&
      warp["reviewed"] == true && warp["event_id"].instance_of?(Integer) &&
      warp["event_id"].between?(1, 9999) && valid_id?(warp["map_id"]) &&
      warp["map_id"] != plan["target_map_id"] &&
      warp["x"].instance_of?(Integer) && warp["y"].instance_of?(Integer)
    ShatteredMurkrowRescue.validate_battle!(plan["battle"])
    ShatteredMurkrowRescue.validate_reward!(plan["reward"])
    plan
  end

  def self.build_event(plan)
    point = plan["target_position"]
    marker = PREFIX + Digest::SHA256.hexdigest(JSON.generate(canonical(plan)))
    event = RPG::Event.new(point[0], point[1])
    event.id = plan["event_id"]
    event.name = marker
    page = RPG::Event::Page.new
    page.trigger = 0
    page.through = false
    page.always_on_top = false
    page.graphic.character_name = plan["character"]
    runtime = { "battle" => plan["battle"], "reward" => plan["reward"] }
    encoded = Base64.strict_encode64(JSON.generate(runtime))
    script = "ShatteredMurkrowRescue.run_event(Base64.decode64(\"#{encoded}\"))"
    page.list = [
      RPG::EventCommand.new(355, 0, [script]),
      RPG::EventCommand.new(0, 0, [])
    ]
    event.pages = [page]
    event
  end

  def self.load_game_data(path)
    Object.new.send(:load_data, path)
  end

  def self.map_path(map_id)
    format("Data/Map%03d.rxdata", map_id)
  end

  def self.validate_destination_warp!(map, plan, map_infos)
    warp = plan["destination_warp"]
    event = map.events[warp["event_id"]]
    raise "Reviewed destination warp event is missing" unless event
    destination_path = map_path(warp["map_id"])
    raise "Reviewed destination map is missing" unless map_infos[warp["map_id"]] &&
      File.file?(destination_path) && !File.symlink?(destination_path)
    destination_map = load_game_data(destination_path)
    unless valid_point?([warp["x"], warp["y"]], destination_map.width, destination_map.height)
      raise "Reviewed destination warp coordinates are outside the target map"
    end
    transfers = event.pages.to_a.flat_map { |page| page.list.to_a }.select do |command|
      command.code == 201
    end
    matching = transfers.any? do |command|
      parameters = command.parameters
      parameters.is_a?(Array) && parameters.length >= 4 &&
        parameters[0] == 0 && parameters[1] == warp["map_id"] &&
        parameters[2] == warp["x"] && parameters[3] == warp["y"]
    end
    raise "Reviewed destination warp no longer matches the map event" unless matching
    true
  end

  def self.install(plan)
    validate_plan!(plan)
    raise "Refusing to modify an unstaged project" unless
      File.file?("SHATTERED_STAGING_REPORT.json")
    raise "Data directory missing or symlinked" unless File.directory?("Data") &&
      !File.symlink?("Data")
    map_id = plan["target_map_id"]
    path = map_path(map_id)
    tmp = path + ".shattered_murkrow.tmp"
    backup = path + ".shattered_murkrow.bak"
    raise "Stale Murkrow temporary or backup file; manual recovery required" if
      File.exist?(tmp) || File.exist?(backup)
    raise "Target map missing" unless File.file?(path) && !File.symlink?(path)
    infos_path = "Data/MapInfos.rxdata"
    raise "MapInfo missing" unless File.file?(infos_path) && !File.symlink?(infos_path)
    map_infos = load_game_data(infos_path)
    raise "Reviewed target map ID is absent from MapInfos" unless map_infos[map_id]
    map = load_game_data(path)
    raise "Target map dimensions differ from reviewed plan" unless
      [map.width, map.height] == plan["target_map_size"]
    raise "Target map event collection unavailable" unless map.events.is_a?(Hash)
    sprite_path = "Graphics/Characters/#{plan['character']}.png"
    raise "Locally licensed character sprite missing" unless
      File.file?(sprite_path) && !File.symlink?(sprite_path)
    validate_destination_warp!(map, plan, map_infos)

    managed = map.events.values.select do |event|
      event.name.is_a?(String) && event.name.start_with?(PREFIX)
    end
    expected = build_event(plan)
    if managed.any?
      raise "Partial or foreign Murkrow installation" unless managed.length == 1 &&
        managed.first.id == plan["event_id"] &&
        Marshal.dump(expected) == Marshal.dump(managed.first)
      return { "installed" => 0, "unchanged" => 1, "map_id" => map_id,
               "event_id" => plan["event_id"] }
    end
    raise "Target map changed since manual review" unless
      Digest::SHA256.file(path).hexdigest == plan["expected_map_sha256"]
    position = plan["target_position"]
    raise "Target event ID is occupied" if map.events.key?(plan["event_id"])
    raise "Target event position is occupied" if
      map.events.values.any? { |event| [event.x, event.y] == position }
    map.events[plan["event_id"]] = expected

    backup_created = false
    begin
      Object.new.send(:save_data, map, tmp)
      raise "Staged map write missing" unless File.file?(tmp)
      File.rename(path, backup)
      backup_created = true
      File.rename(tmp, path)
      File.delete(backup)
    rescue StandardError
      if backup_created && File.exist?(backup)
        File.delete(path) if File.exist?(path)
        File.rename(backup, path)
      end
      raise
    ensure
      File.delete(tmp) if File.exist?(tmp)
    end
    { "installed" => 1, "map_id" => map_id, "event_id" => plan["event_id"] }
  end
end

def pbInstallShatteredMurkrowRescue(plan_path)
  ShatteredMurkrowRescue.install(JSON.parse(File.read(plan_path)))
end
