# frozen_string_literal: true
# SE-019: install a real RPG Maker XP action-button dojo event in a staged game.
# Does not import commercial art or assume the original NPC's role.
require "json"
require "digest"
module ShatteredDojo
  PREFIX = "SHATTERED_DOJO:"
  SOURCE_MAP_UUID = "b1d081d6-6600-4c9e-a280-a38a162831b1"
  SOURCE_SIZE = [10, 9].freeze
  SOURCE_NPCS = { "5.2:npc:1" => [6, 4], "5.2:npc:2" => [3, 5] }.freeze

  def self.validate_plan(plan)
    raise ArgumentError, "Unsupported dojo plan" unless plan.is_a?(Hash) &&
      plan["schema_version"] == 1 && plan["source_map_uuid"] == SOURCE_MAP_UUID
    raise ArgumentError, "NPC role and passability must be reviewed against the original" unless
      plan["role_reviewed"] == true && plan["passability_reviewed"] == true
    id = plan["dojo_map_id"]
    raise ArgumentError, "Invalid dojo map ID" unless id.instance_of?(Integer) && id.between?(1, 999)
    anchor = SOURCE_NPCS[plan["source_event_id"]]
    raise ArgumentError, "Source NPC is not a dojo-scene anchor" unless anchor
    raise ArgumentError, "Source coordinate mismatch" unless plan["source_position"] == anchor
    raise ArgumentError, "Native map review required" unless plan["native_map_reviewed"] == true
    dims = plan["native_map_dimensions"]
    raise ArgumentError, "Reviewed native dojo dimensions required" unless
      dims.is_a?(Array) && dims.length == 2 &&
      dims.all? { |v| v.instance_of?(Integer) && v.between?(1, 200) }
    position = plan["event_position"]
    raise ArgumentError, "Native event position out of bounds" unless
      position.is_a?(Array) && position.length == 2 &&
      position.each_with_index.all? { |v, i| v.instance_of?(Integer) && v.between?(0, dims[i] - 1) }
    sha = plan["expected_map_sha256"]
    raise ArgumentError, "Expected reviewed SHA256 required" unless
      sha.is_a?(String) && /\A[0-9a-f]{64}\z/.match(sha)
    sprite = plan["character"]
    raise ArgumentError, "Unsafe character filename" unless sprite.is_a?(String) &&
      /\A[A-Za-z0-9_ -]{1,80}\z/.match(sprite)
    plan
  end

  def self.build_event(plan)
    point = plan["event_position"]
    event = RPG::Event.new(point[0], point[1])
    event.name = PREFIX + "questionnaire"
    page = RPG::Event::Page.new
    page.trigger = 0 # Action button
    page.through = false
    page.always_on_top = false
    page.graphic.character_name = plan["character"]
    page.list = [
      RPG::EventCommand.new(355, 0, ["ShatteredDojo.run_quiz"]),
      RPG::EventCommand.new(0, 0, [])
    ]
    event.pages = [page]
    event
  end

  # Static native tileset passage check. Does not establish approach direction
  # or a working action-button interaction without launching Essentials.
  def self.native_tile_clear?(map, tilesets, x, y)
    return false unless map.respond_to?(:data) && map.data &&
      map.respond_to?(:tileset_id) && tilesets.is_a?(Array)
    tileset = tilesets[map.tileset_id]
    return false unless tileset && tileset.respond_to?(:passages) && tileset.passages
    layers = map.data.respond_to?(:zsize) ? map.data.zsize : 3
    (layers - 1).downto(0) do |layer|
      tile = map.data[x, y, layer]
      next if tile.nil? || tile == 0
      flag = tileset.passages[tile]
      return false unless flag.is_a?(Integer)
      next if (flag & 0x10) != 0
      return (flag & 0x0f) == 0
    end
    false
  end

  def self.install(plan)
    validate_plan(plan)
    raise "Refusing to modify an unstaged project" unless File.file?("SHATTERED_STAGING_REPORT.json")
    path = format("Data/Map%03d.rxdata", plan["dojo_map_id"])
    tmp = path + ".shattered_dojo.tmp"
    backup = path + ".shattered_dojo.bak"
    raise "Stale dojo backup or temporary file; manual recovery required" if
      File.exist?(tmp) || File.exist?(backup)
    raise "Dojo map missing" unless File.file?(path)
    raise "MapInfo missing" unless File.file?("Data/MapInfos.rxdata") &&
      load_data("Data/MapInfos.rxdata")[plan["dojo_map_id"]]
    raise "Locally licensed character sprite missing" unless
      File.file?("Graphics/Characters/#{plan['character']}.png")
    map = load_data(path)
    raise "Dojo map differs from reviewed native geometry" unless
      [map.width, map.height] == plan["native_map_dimensions"]
    raise "Dojo map event collection unavailable" unless map.events.is_a?(Hash)
    installed = map.events.values.select { |e| e.name.start_with?(PREFIX) }
    if installed.any?
      raise "Partial or foreign dojo installation" unless installed.length == 1 &&
        installed.first.name == PREFIX + "questionnaire"
      expected = build_event(plan)
      expected.id = installed.first.id
      raise "Dojo event drift detected" unless Marshal.dump(expected) == Marshal.dump(installed.first)
      return { "installed" => 0, "unchanged" => 1 }
    end
    raise "Dojo map changed since manual review" unless
      Digest::SHA256.file(path).hexdigest == plan["expected_map_sha256"]
    pos = plan["event_position"]
    raise "Dojo native tile is blocked or unverified" unless
      File.file?("Data/Tilesets.rxdata") &&
      native_tile_clear?(map, load_data("Data/Tilesets.rxdata"), *pos)
    raise "Occupied dojo event tile" if map.events.values.any? { |e| [e.x, e.y] == pos }
    event = build_event(plan)
    event.id = (map.events.keys.max || 0) + 1
    map.events[event.id] = event
    begin
      save_data(map, tmp)
      File.rename(path, backup)
      File.rename(tmp, path)
      File.delete(backup)
    rescue Exception
      if File.exist?(backup)
        File.delete(path) if File.exist?(path)
        File.rename(backup, path)
      end
      raise
    ensure
      File.delete(tmp) if File.exist?(tmp)
    end
    { "installed" => 1, "map_id" => plan["dojo_map_id"], "event_id" => event.id }
  end
end

def pbInstallShatteredDojo(path)
  ShatteredDojo.install(JSON.parse(File.read(path)))
end
