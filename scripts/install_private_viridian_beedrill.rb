#!/usr/bin/env ruby
# frozen_string_literal: true
# Private-only native Viridian Beedrill placement for Essentials v21.1.
# Source map and HnS sprite are held locally; no game assets in this file.
require 'digest'
require 'json'
require 'optparse'
require 'pathname'
require_relative 'private_rgss_writer'

module ShatteredPrivateViridianBeedrill
  module_function

  MAP_SHA = '9a30262d8f21a46259b677a78a17b51aa6f8f16cb14f0b169d54b625adda2180'
  INSTALLED_SHA = 'dcae21f06f1bb138c082d89ebe882fbd125e549dc9dc53b35b39e6aba3638da5'
  SPRITE_SHA = '6a502bbab6d34ddc534cbc102a40fb679bed7a9f8112b11dbfb818e8b306a184'
  SOURCE_SPRITE_SHA = '663b93a030f303569fefd40d15736b4b6270e9d8a398d9433040c09320a0339f'
  MAP_ID = 10
  SWITCHES = [997, 998, 999].freeze
  OUTCOME_VARIABLE = 990
  LEVELS = [5, 6, 7].freeze
  POSITIONS = [[32, 22], [32, 25], [31, 28]].freeze
  EVENT_IDS = [29, 30, 31].freeze
  PREFIX = 'ShatteredRaid:BEEDRILL:'
  STAGING = 'SHATTERED_STAGING_REPORT.json'

  def script(index)
    entries = LEVELS.each_with_index.map do |level, i|
      { 'index' => i, 'level' => level, 'switch_id' => SWITCHES.fetch(i) }
    end
    config = { 'map_id' => MAP_ID, 'outcome_variable_id' => OUTCOME_VARIABLE,
               'events' => entries }
    "ShatteredRaid.trigger(#{index}, #{config.inspect})"
  end

  def page(sprite: '', switch: nil, through: true, trigger: 0, commands: nil)
    p = RPG::Event::Page.new
    p.graphic.character_name = sprite
    p.graphic.character_hue = 0
    p.step_anime = !sprite.empty?
    p.through = through
    p.trigger = trigger
    if switch
      p.condition.switch1_valid = true
      p.condition.switch1_id = switch
    end
    p.list = commands || [RPG::EventCommand.new(0, 0, [])]
    p
  end

  def event(index)
    x, y = POSITIONS.fetch(index)
    e = RPG::Event.new(x, y)
    e.id = EVENT_IDS.fetch(index)
    e.name = PREFIX + index.to_s
    hidden = page
    active = page(sprite: 'Beedrill', switch: (index.zero? ? nil : SWITCHES[index - 1]),
                  through: false, trigger: 2,
                  commands: [RPG::EventCommand.new(355, 0, [script(index)]),
                             RPG::EventCommand.new(0, 0, [])])
    cleared = page(switch: SWITCHES.fetch(index))
    # Later encounters are invisible until the preceding encounter is won.
    e.pages = index.zero? ? [active, cleared] : [hidden, active, cleared]
    e
  end

  def tile_clear?(map, tilesets, x, y)
    return false unless x.between?(0, map.width - 1) && y.between?(0, map.height - 1)
    tileset = tilesets[map.tileset_id]
    return false unless tileset && tileset.respond_to?(:passages) && tileset.passages
    (map.data.zsize - 1).downto(0) do |z|
      tile = map.data[x, y, z]
      next if tile.nil? || tile.zero?
      flag = tileset.passages[tile]
      return false unless flag.is_a?(Integer)
      next if (flag & 0x10) != 0
      return (flag & 0x0f).zero?
    end
    false
  end

  def adjacent_reachable?(map, tilesets, from, goal, occupied)
    visited = { from => true }
    queue = [from]
    until queue.empty?
      x, y = queue.shift
      return true if (x - goal[0]).abs + (y - goal[1]).abs == 1
      [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]].each do |point|
        next if visited[point] || occupied.include?(point)
        next unless tile_clear?(map, tilesets, *point)
        visited[point] = true
        queue << point
      end
    end
    false
  end

  def validate_map!(map, tilesets)
    raise 'Expected native Viridian 50x40 map' unless map.is_a?(RPG::Map) &&
      [map.width, map.height, map.tileset_id] == [50, 40, 1] &&
      map.events.is_a?(Hash) && map.data.is_a?(Table)
    arrival = map.events[23]
    raise 'Unreviewed Viridian escort anchor' unless arrival &&
      arrival.name == 'SHATTERED: Viridian arrival' && [arrival.x, arrival.y] == [25, 20]
    raise 'Missing escort/Center actors' unless [25, 26, 27, 28].all? { |id| map.events.key?(id) }
    occupied = map.events.values.map { |e| [e.x, e.y] }
    POSITIONS.each do |x, y|
      raise "Occupied Beedrill spawn #{x},#{y}" if occupied.include?([x, y])
      raise "Blocked Beedrill spawn #{x},#{y}" unless tile_clear?(map, tilesets, x, y)
      raise "Inaccessible Beedrill encounter #{x},#{y}" unless
        adjacent_reachable?(map, tilesets, [25, 27], [x, y], occupied + POSITIONS)
    end
    true
  end

  def transform!(map, tilesets)
    existing = map.events.values.select { |e| e.name.to_s.start_with?(PREFIX) }
    unless existing.empty?
      raise 'Partial or foreign Beedrill install' unless existing.map(&:id).sort == EVENT_IDS
      EVENT_IDS.each_with_index do |id, index|
        raise "Beedrill event drift at #{id}" unless Marshal.dump(map.events.fetch(id)) == Marshal.dump(event(index))
      end
      return :already_installed
    end
    raise 'Unreviewed native Viridian event inventory' unless map.events.keys.sort == (1..28).to_a
    validate_map!(map, tilesets)
    old_tiles = Marshal.dump(map.data)
    old_events = map.events.transform_values { |e| Marshal.dump(e) }
    3.times { |i| map.events[EVENT_IDS[i]] = event(i) }
    raise 'Native Viridian tiles changed' unless Marshal.dump(map.data) == old_tiles
    raise 'Unrelated Viridian events changed' unless old_events.all? { |id, bytes| Marshal.dump(map.events.fetch(id)) == bytes }
    :installed
  end

  def install!(root, failure_hook: nil)
    project = Pathname.new(root).expand_path
    raise 'Only a private staged Shattered project may be modified' unless
      project.directory? && !project.symlink? && project.join(STAGING).file?
    marker = project.join(STAGING).read
    raise 'Staging report is not Essentials 21.1' unless marker.include?('"engine": "Essentials 21.1"')
    map_path = project.join('Data/Map010.rxdata')
    tiles_path = project.join('Data/Tilesets.rxdata')
    sprite_path = project.join('Graphics/Characters/Beedrill.png')
    plugin_path = project.join('Plugins/Shattered Raid/001_Raid.rb')
    [map_path, tiles_path, sprite_path, plugin_path].each do |path|
      raise "Missing or symlinked private input #{path}" unless path.file? && !path.symlink?
    end
    raise 'Unreviewed private Beedrill overworld sprite' unless
      Digest::SHA256.file(sprite_path).hexdigest == SPRITE_SHA
    raise 'Missing runtime Beedrill battle hook' unless
      plugin_path.read.include?('def trigger(index, config)')
    source_bytes = map_path.binread
    map = Marshal.load(source_bytes)
    tilesets = Marshal.load(tiles_path.binread)
    if Digest::SHA256.hexdigest(source_bytes) != MAP_SHA
      raise 'Native Viridian map SHA changed; refusing overwrite' unless
        Digest::SHA256.hexdigest(source_bytes) == INSTALLED_SHA &&
        transform!(map, tilesets) == :already_installed
      return { 'result' => 'already_installed', 'map_sha256' => Digest::SHA256.hexdigest(source_bytes) }
    end
    raise 'Unexpected existing Beedrill events' unless transform!(map, tilesets) == :installed
    result = Marshal.dump(map)
    raise 'Unexpected native Beedrill map result' unless Digest::SHA256.hexdigest(result) == INSTALLED_SHA
    raise 'Native Marshal roundtrip failed' unless Marshal.dump(Marshal.load(result)) == result
    tmp = Pathname.new(map_path.to_s + '.beedrill.tmp')
    backup = Pathname.new(map_path.to_s + '.beedrill.bak')
    raise 'Stale Beedrill transaction' if [tmp, backup].any? { |p| p.exist? || p.symlink? }
    begin
      File.binwrite(tmp, result)
      failure_hook.call(:after_temp) if failure_hook
      File.rename(map_path, backup)
      failure_hook.call(:after_backup) if failure_hook
      File.rename(tmp, map_path)
      failure_hook.call(:after_replace) if failure_hook
    rescue Exception
      if backup.file?
        File.delete(map_path) if map_path.file?
        File.rename(backup, map_path)
      end
      raise
    ensure
      File.delete(tmp) if tmp.file?
    end
    File.delete(backup)
    { 'result' => 'installed', 'map_sha256' => Digest::SHA256.file(map_path).hexdigest,
      'sprite_sha256' => SPRITE_SHA, 'source_sprite_sha256' => SOURCE_SPRITE_SHA,
      'events' => EVENT_IDS, 'switches' => SWITCHES,
      'native_gameplay_verified' => false, 'android_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {}
  OptionParser.new { |o| o.on('--project DIR') { |v| opts[:project] = v } }.parse!
  abort 'Usage: ruby install_private_viridian_beedrill.rb --project PRIVATE_PROJECT' unless opts[:project]
  puts JSON.pretty_generate(ShatteredPrivateViridianBeedrill.install!(opts[:project]))
end
