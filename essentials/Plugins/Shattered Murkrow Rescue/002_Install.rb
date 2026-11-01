# frozen_string_literal: true
# SE-019C: explicit-plan, transactional native RPG Maker XP event installer.
require "json"
require "digest"
require "zlib"

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
    tilesets_sha = plan["expected_tilesets_sha256"]
    raise ArgumentError, "Reviewed native tilesets SHA256 required" unless
      tilesets_sha.is_a?(String) && /\A[0-9a-f]{64}\z/.match(tilesets_sha)
    character = plan["character"]
    raise ArgumentError, "Unsafe character filename" unless
      character.is_a?(String) && /\A[A-Za-z0-9_ -]{1,80}\z/.match(character)
    character_sha = plan["expected_character_sha256"]
    raise ArgumentError, "Reviewed local character SHA256 required" unless
      character_sha.is_a?(String) && /\A[0-9a-f]{64}\z/.match(character_sha)
    raise ArgumentError, "Character role needs user review" unless plan["sprite_reviewed"] == true
    raise ArgumentError, "This plugin uses saved quest flags, not RMXP switches or variables" unless
      plan["switch_ids"] == [] && plan["variable_ids"] == []
    raise ArgumentError, "Battle and reward details need user review" unless
      plan["battle_reviewed"] == true && plan["reward_reviewed"] == true
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
    # Hash#inspect produces escaped Ruby literals from the validated plan.
    # No JSON or Base64 library is required when this event runs in mkxp-z.
    script = "ShatteredMurkrowRescue.run_event(#{runtime.inspect}); " +
      "ShatteredMurkrowRescue.sync_event_self_switch!($game_map.map_id, @event_id)"
    page.list = [
      RPG::EventCommand.new(355, 0, [script]),
      RPG::EventCommand.new(0, 0, [])
    ]
    # The self-switch is a visual projection of PokemonGlobal quest completion,
    # not the authority for recruitment. It is reconciled on Continue/transfer.
    hidden = RPG::Event::Page.new
    hidden.condition.self_switch_valid = true
    hidden.condition.self_switch_ch = "A"
    hidden.through = true
    hidden.always_on_top = false
    hidden.list = [RPG::EventCommand.new(0, 0, [])]
    event.pages = [page, hidden]
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

  # Native RPG Maker XP passage check, not a claim of tested gameplay.
  # An unknown tile/tileset must block installation rather than trusting a
  # manually checked 'passability_reviewed' flag alone.
  def self.passable_tile?(map, tilesets, x, y)
    return false unless map.respond_to?(:data) && map.data &&
      map.respond_to?(:tileset_id) && tilesets.is_a?(Array) &&
      valid_point?([x, y], map.width, map.height)
    tileset = tilesets[map.tileset_id]
    return false unless tileset && tileset.respond_to?(:passages) && tileset.passages
    2.downto(0) do |layer|
      tile = map.data[x, y, layer]
      next if tile.nil? || tile == 0
      flag = tileset.passages[tile]
      return false unless flag.is_a?(Integer)
      next if (flag & 0x10) != 0  # star/overhead tile
      return (flag & 0x0f) == 0
    end
    false
  end

  def self.validate_native_position!(map, tilesets, point)
    x, y = point
    raise "Reviewed Murkrow event tile is blocked or unverified" unless
      passable_tile?(map, tilesets, x, y)
    neighbours = [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]
    reachable = neighbours.any? do |nx, ny|
      passable_tile?(map, tilesets, nx, ny) &&
        map.events.values.none? { |event| event.x == nx && event.y == ny }
    end
    raise "Reviewed Murkrow event has no open adjacent approach tile" unless reachable
    true
  end

  # Structural and hash verification only; does not prove correct animation.
  # No third-party sprite is committed with this installer.
  def self.validate_character_sheet!(path, expected_sha)
    raise "Locally licensed character sprite missing" unless
      File.file?(path) && !File.symlink?(path) && File.size(path).between?(70, 1024 * 1024)
    raise "Reviewed Murkrow character sprite changed" unless
      Digest::SHA256.file(path).hexdigest == expected_sha
    bytes = File.binread(path)
    raise "Murkrow character PNG signature invalid" unless
      bytes.start_with?("\x89PNG\r\n\x1a\n".b)
    offset = 8
    header = false
    image_data = false
    ended = false
    while offset < bytes.bytesize
      raise "Murkrow PNG truncated" if ended || offset + 12 > bytes.bytesize
      length = bytes.byteslice(offset, 4).unpack1("N")
      raise "Murkrow PNG chunk exceeds file" if length > bytes.bytesize - offset - 12
      kind = bytes.byteslice(offset + 4, 4)
      data = bytes.byteslice(offset + 8, length)
      crc = bytes.byteslice(offset + 8 + length, 4).unpack1("N")
      raise "Murkrow PNG CRC mismatch" unless Zlib.crc32(kind + data) == crc
      case kind
      when "IHDR"
        raise "Murkrow must be a 128x128 RGBA character sheet" unless
          !header && offset == 8 && length == 13 &&
          data.byteslice(0, 8).unpack("N2") == [128, 128] &&
          data.byteslice(8, 5).bytes == [8, 6, 0, 0, 0]
        header = true
      when "IDAT"
        raise "Murkrow PNG image data out of order" unless header && !ended
        image_data = true
      when "IEND"
        raise "Murkrow PNG end invalid" unless
          header && image_data && length == 0 && offset + 12 == bytes.bytesize
        ended = true
      else
        raise "Murkrow PNG unsupported critical chunk" unless
          header && (kind.getbyte(0) & 0x20) != 0
      end
      offset += 12 + length
    end
    raise "Murkrow PNG has no complete image" unless ended
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
    tilesets_path = "Data/Tilesets.rxdata"
    raise "Native tilesets file missing or symlinked" unless
      File.file?(tilesets_path) && !File.symlink?(tilesets_path)
    raise "Native tileset data changed since review" unless
      Digest::SHA256.file(tilesets_path).hexdigest == plan["expected_tilesets_sha256"]
    tilesets = load_game_data(tilesets_path)
    raise "Target map dimensions differ from reviewed plan" unless
      [map.width, map.height] == plan["target_map_size"]
    raise "Target map event collection unavailable" unless map.events.is_a?(Hash)
    sprite_path = "Graphics/Characters/#{plan['character']}.png"
    validate_character_sheet!(sprite_path, plan["expected_character_sha256"])
    validate_destination_warp!(map, plan, map_infos)
    validate_native_position!(map, tilesets, plan["target_position"])

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
