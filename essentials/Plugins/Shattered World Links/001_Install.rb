# frozen_string_literal: true
# Explicit rights-safe RMXP transfer-event installer.
# Execute pbInstallShatteredWorldLinks(path) ONLY in a separately staged project.
# Does not install source maps, graphics, collision, sound or cutscenes.
require "json"

module ShatteredWorldLinks
  PREFIX = "SHATTERED_LINK:"

  def self.int(value, label, minimum = 0, maximum = 999)
    raise ArgumentError, "#{label}: invalid integer" unless value.instance_of?(Integer) &&
      value >= minimum && value <= maximum
    value
  end

  def self.validate(plan)
    raise ArgumentError, "unsupported world-link plan" unless
      plan.is_a?(Hash) && plan["format"] == "shattered-world-links" &&
      plan["format_version"] == 1 && plan["maps"].is_a?(Array) &&
      plan["events"].is_a?(Array)
    specs = {}
    plan["maps"].each do |spec|
      raise ArgumentError, "invalid map record" unless spec.is_a?(Hash)
      id = int(spec["map_id"], "map_id", 1)
      raise ArgumentError, "duplicate target map ID" if specs.key?(id)
      specs[id] = {"width" => int(spec["width"], "width", 1),
                   "height" => int(spec["height"], "height", 1)}
    end
    occupied = {}
    names = {}
    plan["events"].each do |event|
      raise ArgumentError, "invalid event" unless event.is_a?(Hash)
      id = int(event["map_id"], "event.map_id", 1)
      spec = specs[id]
      raise ArgumentError, "unmapped event map" unless spec
      x = int(event["x"], "event.x", 0, spec["width"] - 1)
      y = int(event["y"], "event.y", 0, spec["height"] - 1)
      dest = event["destination"]
      raise ArgumentError, "missing destination" unless dest.is_a?(Hash)
      dest_id = int(dest["map_id"], "destination.map_id", 1)
      dest_spec = specs[dest_id]
      raise ArgumentError, "unmapped destination map" unless dest_spec
      int(dest["x"], "destination.x", 0, dest_spec["width"] - 1)
      int(dest["y"], "destination.y", 0, dest_spec["height"] - 1)
      raise ArgumentError, "invalid arrival facing" unless [0, 2, 4, 6, 8].include?(dest["direction"]) &&
        dest["direction"].instance_of?(Integer)
      raise ArgumentError, "invalid fade" unless [0, 1].include?(dest["fade"]) &&
        dest["fade"].instance_of?(Integer)
      raise ArgumentError, "invalid source link ID" unless event["link_id"].is_a?(String) &&
        /\A[A-Za-z0-9_-]+\z/.match(event["link_id"])
      raise ArgumentError, "invalid side" unless ["F", "R"].include?(event["side"])
      name = PREFIX + event["link_id"] + ":" + event["side"]
      raise ArgumentError, "duplicate link name" if names[name]
      names[name] = true
      key = [id, x, y]
      raise ArgumentError, "duplicate transfer trigger #{key.inspect}" if occupied[key]
      occupied[key] = true
    end
    plan["events"].each do |event|
      dest = event["destination"]
      key = [dest["map_id"], dest["x"], dest["y"]]
      raise ArgumentError, "arrival tile is a transfer trigger #{key.inspect}" if occupied[key]
    end
    specs
  end

  def self.event_matches?(existing, entry)
    dest = entry["destination"]
    cmd = existing.pages[0].list[0] rescue nil
    existing.x == entry["x"] && existing.y == entry["y"] &&
      existing.pages.length == 1 && existing.pages[0].trigger == 1 &&
      cmd && cmd.code == 201 &&
      cmd.parameters == [0, dest["map_id"], dest["x"], dest["y"], dest["direction"], dest["fade"]]
  end

  def self.install(plan)
    raise "Refusing to modify a non-staged project" unless File.file?("SHATTERED_STAGING_REPORT.json")
    specs = validate(plan)
    map_infos = load_data("Data/MapInfos.rxdata")
    maps = {}
    specs.each do |id, spec|
      raise "RMXP map #{id} missing from MapInfos" unless map_infos[id]
      path = sprintf("Data/Map%03d.rxdata", id)
      raise "RMXP map file missing: #{path}" unless File.file?(path)
      map = load_data(path)
      raise "RMXP map #{id} dimensions differ from mapping" unless
        map.width == spec["width"] && map.height == spec["height"]
      raise "RMXP map #{id} lacks event collection" unless map.events.is_a?(Hash)
      maps[id] = map
    end

    # Preflight every event and every target map before writing ANY Data file.
    changed, created, unchanged = {}, 0, 0
    plan["events"].each do |entry|
      map = maps[entry["map_id"]]
      name = PREFIX + entry["link_id"] + ":" + entry["side"]
      same_name = map.events.values.select { |event| event.name == name }
      raise "Duplicate existing link events: #{name}" if same_name.length > 1
      unless same_name.empty?
        raise "Existing link differs: #{name}" unless event_matches?(same_name.first, entry)
        unchanged += 1
        next
      end
      raise "Occupied RMXP event tile #{entry['map_id']}:#{entry['x']},#{entry['y']}" if
        map.events.values.any? { |event| event.x == entry["x"] && event.y == entry["y"] }
      dest = entry["destination"]
      landing_map = maps[dest["map_id"]]
      if landing_map.events.values.any? { |e| e.x == dest["x"] && e.y == dest["y"] &&
        e.pages.any? { |p| p.trigger == 1 && p.list.any? { |cmd| cmd.code == 201 } } }
        raise "Landing on an existing transfer event: #{name}"
      end
      event = RPG::Event.new(entry["x"], entry["y"])
      event.id = (map.events.keys.max || 0) + 1
      event.name = name
      page = RPG::Event::Page.new
      page.trigger = 1 # Player touch
      page.through = false
      page.always_on_top = false # Native RMXP Page flags; blank graphic = below player
      page.list = [
        RPG::EventCommand.new(201, 0, [0, dest["map_id"], dest["x"], dest["y"],
                                         dest["direction"], dest["fade"]]),
        RPG::EventCommand.new(0, 0, [])
      ]
      event.pages = [page]
      map.events[event.id] = event
      changed[entry["map_id"]] = true
      created += 1
    end

    # Stage all modified rxdata before replacing original staged map files.
    # Backups allow rollback on an ordinary Ruby exception; crash recovery is manual.
    paths = changed.keys.sort.map { |id| sprintf("Data/Map%03d.rxdata", id) }
    paths.each do |path|
      raise "Stale installer temp/backup: #{path}" if
        File.exist?(path + ".shattered.tmp") || File.exist?(path + ".shattered.bak")
    end
    begin
      paths.each do |path|
        id = File.basename(path)[3, 3].to_i
        save_data(maps[id], path + ".shattered.tmp")
      end
      paths.each do |path|
        File.rename(path, path + ".shattered.bak")
        File.rename(path + ".shattered.tmp", path)
      end
    rescue Exception
      paths.reverse.each do |path|
        backup = path + ".shattered.bak"
        next unless File.exist?(backup)
        File.delete(path) if File.exist?(path)
        File.rename(backup, path)
      end
      raise
    ensure
      paths.each do |path|
        tmp = path + ".shattered.tmp"
        File.delete(tmp) if File.exist?(tmp)
      end
    end
    paths.each { |path| File.delete(path + ".shattered.bak") }
    {"created" => created, "unchanged" => unchanged, "changed_maps" => changed.keys.sort}
  end
end

def pbInstallShatteredWorldLinks(path)
  ShatteredWorldLinks.install(JSON.parse(File.read(path)))
end
