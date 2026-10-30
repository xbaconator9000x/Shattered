#!/usr/bin/env ruby
# Frozen, local-only RMXP map inventory for an authorised Essentials project.
# Does not execute RPG Maker events, install plugins or copy any game assets.
require 'json'
require 'digest'
require 'optparse'
require 'pathname'

module RPG; end
%w[AudioFile System System::TestBattler System::Words MapInfo Map Event Event::Page Event::Page::Condition Event::Page::Graphic EventCommand MoveCommand MoveRoute Tileset].each do |qualified|
  parent = RPG
  qualified.split('::').each do |name|
    parent.const_set(name, Class.new) unless parent.const_defined?(name, false)
    parent = parent.const_get(name, false)
  end
end
class Table
  def self._load(bytes)
    raise ArgumentError, 'invalid RMXP Table header' if bytes.bytesize < 20
    dimensions, width, height, depth, count = bytes.unpack('V5')
    raise ArgumentError, 'invalid RMXP Table shape' unless (1..3).cover?(dimensions) &&
      width.positive? && height.positive? && depth.positive? &&
      width * height * depth == count && bytes.bytesize == 20 + 2 * count
    obj = allocate
    obj.instance_variable_set(:@bytes, bytes)
    obj.instance_variable_set(:@shape, [width, height, depth])
    obj
  end
  def shape = @shape
  def [](x, y = 0, z = 0)
    width, height, depth = @shape
    return nil unless x.between?(0, width - 1) && y.between?(0, height - 1) && z.between?(0, depth - 1)
    @bytes.byteslice(20 + 2 * (x + width * y + width * height * z), 2).unpack1('s<')
  end
end
class Color
  def self._load(bytes) = allocate
end
class Tone
  def self._load(bytes) = allocate
end

module ShatteredNativeAudit
  module_function
  DEFAULT_ROUTE_POSITIONS = [[36, 16], [36, 17], [36, 18], [38, 17], [39, 16], [39, 18]].freeze
  MAX_RXDATA_BYTES = 30 * 1024 * 1024

  def read_rxdata(project, relative)
    path = project.join(relative)
    raise ArgumentError, "missing native file: #{relative}" unless path.file? && !path.symlink?
    raise ArgumentError, "oversized native file: #{relative}" if path.size > MAX_RXDATA_BYTES
    Marshal.load(path.binread)
  end

  def digest(project, relative)
    Digest::SHA256.file(project.join(relative)).hexdigest
  end

  def event_position(event)
    [event.instance_variable_get(:@x), event.instance_variable_get(:@y)]
  end

  def legacy_human_placeholder?(map)
    map.instance_variable_get(:@events).values.any? do |event|
      event.instance_variable_get(:@pages).any? do |page|
        commands = page.instance_variable_get(:@list) || []
        script = commands.select { |command| [355, 655].include?(command.instance_variable_get(:@code)) }
                         .flat_map { |command| command.instance_variable_get(:@parameters) }
                         .grep(String).join("\n")
        script.match?(/Pokemon\.new\s*\(\s*:MACHOP\b/) && script.match?(/HUMAN/)
      end
    end
  end

  # Conservative tile-only static check, not a native collision/movement test.
  # RGSS 0x10 star overlays are ignored; any direction mask is flagged.
  def tile_status(map, tilesets, x, y)
    width, height = [map.instance_variable_get(:@width), map.instance_variable_get(:@height)]
    return 'out_of_bounds' unless x.is_a?(Integer) && y.is_a?(Integer) &&
      x.between?(0, width - 1) && y.between?(0, height - 1)
    tile_data = map.instance_variable_get(:@data)
    return 'unknown' unless tile_data.is_a?(Table) && tile_data.shape[0, 2] == [width, height]
    tileset = tilesets[map.instance_variable_get(:@tileset_id)]
    flags = tileset&.instance_variable_get(:@passages)
    return 'unknown' unless flags.is_a?(Table)
    (tile_data.shape[2] - 1).downto(0) do |layer|
      tile = tile_data[x, y, layer]
      next if tile.nil? || tile.zero?
      flag = flags[tile]
      return 'unknown' if flag.nil?
      next if (flag & 0x10) != 0
      return (flag & 0x0F).zero? ? 'clear' : 'directional_or_blocked'
    end
    'unknown'
  end

  def point_report(map, tilesets, x, y)
    event_ids = map.instance_variable_get(:@events).select do |_id, event|
      event_position(event) == [x, y]
    end.keys.sort
    { 'x' => x, 'y' => y, 'tile_status' => tile_status(map, tilesets, x, y),
      'existing_event_ids' => event_ids }
  end

  # Tile-only reachability; ignores event movement, warps and dynamic passage.
  # A cutline is a candidate mandatory trigger barrier, NOT a gameplay proof.
  def tile_path?(map, tilesets, start, goal, excluded = [])
    return false unless [start, goal].all? { |point|
      point.is_a?(Array) && point.length == 2 &&
        tile_status(map, tilesets, *point) == 'clear'
    }
    blocked = excluded.to_h { |point| [point, true] }
    return false if blocked[start] || blocked[goal]
    visited = { start => true }
    queue = [start]
    head = 0
    while head < queue.length
      x, y = queue[head]
      head += 1
      return true if [x, y] == goal
      [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]].each do |point|
        next if blocked[point] || visited[point]
        next unless tile_status(map, tilesets, *point) == 'clear'
        visited[point] = true
        queue << point
      end
    end
    false
  end

  def cutline_report(map, tilesets, entry:, exit_point:, triggers:)
    raise ArgumentError, 'expected three distinct trigger positions' unless
      triggers.is_a?(Array) && triggers.length == 3 && triggers.uniq.length == 3
    connected = tile_path?(map, tilesets, entry, exit_point)
    bypass = tile_path?(map, tilesets, entry, exit_point, triggers)
    { 'entry' => entry, 'exit' => exit_point, 'triggers' => triggers,
      'entry_reaches_exit' => connected, 'bypass_without_trigger' => bypass,
      'static_cutline_candidate' => connected && !bypass,
      'runtime_verified' => false }
  end

  def audit(project, gate_id: 222, route_id: 16, viridian_id: 10,
            route_positions: DEFAULT_ROUTE_POSITIONS, archive: nil)
    project = Pathname(project).expand_path
    raise ArgumentError, 'project must contain Game.ini' unless project.join('Game.ini').file?
    data = 'Data'
    system = read_rxdata(project, "#{data}/System.rxdata")
    infos = read_rxdata(project, "#{data}/MapInfos.rxdata")
    tilesets = read_rxdata(project, "#{data}/Tilesets.rxdata")
    raise ArgumentError, 'invalid MapInfos or Tilesets structure' unless infos.is_a?(Hash) && tilesets.is_a?(Array)
    start_id = system.instance_variable_get(:@start_map_id)
    start_x = system.instance_variable_get(:@start_x)
    start_y = system.instance_variable_get(:@start_y)
    maps = {}
    [gate_id, route_id, viridian_id].uniq.each do |id|
      relative = format('Data/Map%03d.rxdata', id)
      map = read_rxdata(project, relative)
      raise ArgumentError, "invalid native map #{id}" unless map.is_a?(RPG::Map) &&
        map.instance_variable_get(:@events).is_a?(Hash)
      events = map.instance_variable_get(:@events)
      record = {
        'id' => id, 'sha256' => digest(project, relative),
        'name' => infos[id]&.instance_variable_get(:@name).to_s.encode('UTF-8', invalid: :replace, undef: :replace),
        'dimensions' => [map.instance_variable_get(:@width), map.instance_variable_get(:@height)],
        'tileset_id' => map.instance_variable_get(:@tileset_id),
        'event_count' => events.size,
        'event_positions' => events.map { |event_id, event| [event_id, *event_position(event)] }.sort,
        'legacy_machop_named_human' => legacy_human_placeholder?(map)
      }
      if id == route_id
        record['proposed_route22_positions'] = route_positions.map { |x, y| point_report(map, tilesets, x, y) }
      end
      if id == start_id
        record['current_new_game_start'] = point_report(map, tilesets, start_x, start_y)
      end
      maps[id.to_s] = record
    end
    all_ids = infos.keys.grep(Integer)
    next_id = ((all_ids + Dir.glob(project.join('Data/Map*.rxdata')).filter_map do |path|
      File.basename(path)[/^Map(\d+)\.rxdata$/, 1]&.to_i
    end).max || 0) + 1
    route = maps.fetch(route_id.to_s)
    gate = maps.fetch(gate_id.to_s)
    warnings = []
    warnings << 'legacy_machop_named_human_in_original_gate' if gate['legacy_machop_named_human']
    warnings << 'original_gate_is_not_22x21_hns' if gate['dimensions'] != [22, 21]
    warnings << 'route22_not_pinned_48x24' if route['dimensions'] != [48, 24]
    warnings << 'proposed_route22_events_on_directionally_blocked_tiles' if route.fetch('proposed_route22_positions').any? { |p| p['tile_status'] == 'directional_or_blocked' }
    warnings << 'proposed_route22_events_overlap_existing_events' if route.fetch('proposed_route22_positions').any? { |p| !p['existing_event_ids'].empty? }
    result = {
      'schema_version' => 1, 'kind' => 'private_native_source_inventory_not_runtime_acceptance',
      'system_sha256' => digest(project, 'Data/System.rxdata'),
      'map_infos_sha256' => digest(project, 'Data/MapInfos.rxdata'),
      'tilesets_sha256' => digest(project, 'Data/Tilesets.rxdata'),
      'new_game' => { 'map_id' => start_id, 'x' => start_x, 'y' => start_y },
      'candidate_unoccupied_map_id' => next_id,
      'maps' => maps, 'warnings' => warnings,
      'native_compiled' => false, 'gameplay_verified' => false, 'android_verified' => false
    }
    result['input_archive_sha256'] = Digest::SHA256.file(archive).hexdigest if archive
    result
  end
end

if $PROGRAM_NAME == __FILE__
  opts = { gate_id: 222, route_id: 16, viridian_id: 10 }
  parser = OptionParser.new do |o|
    o.banner = 'Usage: ruby scripts/audit_native_project.rb --project /private/Essentials [--archive original.zip] [--output private.json]'
    o.on('--project DIR') { |v| opts[:project] = v }
    o.on('--archive FILE') { |v| opts[:archive] = v }
    o.on('--output FILE') { |v| opts[:output] = v }
    o.on('--gate-id N', Integer) { |v| opts[:gate_id] = v }
    o.on('--route-id N', Integer) { |v| opts[:route_id] = v }
    o.on('--viridian-id N', Integer) { |v| opts[:viridian_id] = v }
  end
  parser.parse!
  abort parser.to_s unless opts[:project]
  output = opts.delete(:output)
  report = ShatteredNativeAudit.audit(opts.delete(:project), **opts)
  json = JSON.pretty_generate(report) + "\n"
  if output
    raise ArgumentError, 'refusing to overwrite an existing private report' if File.exist?(output)
    File.write(output, json)
  else
    puts json
  end
end
