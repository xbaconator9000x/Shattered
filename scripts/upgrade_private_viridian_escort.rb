#!/usr/bin/env ruby
# frozen_string_literal: true
# Native Guard/Nidoran escort for the exact reviewed PRIVATE Shattered v0.4
# Viridian arrival candidate. Source only; never commit native map/art assets.
require 'digest'
require 'json'
require 'pathname'
require_relative 'private_rgss_writer'

module ShatteredPrivateViridianEscort
  CITY_SHA = 'dcc96f73607eca6b83bceee85473a8eff77b17d79234dcbc0bfc95edee2d0bcf'
  CENTER_SHA = 'd096c3244c3f7fdee749d9c5c121d6a3e91ed90fedaad0b60a1dcee1d1bea3b6'
  SYSTEM_SHA = 'f638861d52157b0320b54870358f14c772c101f5379eccb0062831d9d483a141'
  STARTED, ARRIVED, CENTER, RAIN = 993, 994, 995, 996
  GUARD, NIDORAN, GUARD_END, NIDORAN_END = 25, 26, 27, 28
  GUARD_START = [24, 20].freeze
  NIDORAN_START = [23, 20].freeze
  GUARD_FINISH = [25, 27].freeze
  NIDORAN_FINISH = [24, 27].freeze
  GUARD_STEPS = [1, 1, 2, 1, 1, 1, 1, 1, 3, 3].freeze
  NIDORAN_STEPS = [1, 1, 1, 1, 1, 1, 1, 3].freeze
  DELTA = { 1 => [0, 1], 2 => [-1, 0], 3 => [1, 0], 4 => [0, -1] }.freeze
  module_function

  def cmd(code, params = [], indent = 0)
    RPG::EventCommand.new(code, indent, params)
  end

  def page(sprite = '', switch = nil)
    p = RPG::Event::Page.new
    p.through = true
    p.graphic.character_name = sprite
    if switch
      p.condition.switch1_valid = true
      p.condition.switch1_id = switch
    end
    p
  end

  def actor(id, name, position, first_sprite, last_sprite, message = nil)
    e = RPG::Event.new(*position)
    e.id = id
    e.name = name
    first = page(first_sprite)
    first.list = [cmd(101, [message]), cmd(0)] if message
    last = page(last_sprite, ARRIVED)
    last.list = [cmd(0)]
    e.pages = [first, last]
    e
  end

  def finish_actor(id, name, position, sprite, message)
    e = RPG::Event.new(*position)
    e.id = id
    e.name = name
    hidden = page
    hidden.list = [cmd(0)]
    visible = page(sprite, ARRIVED)
    visible.list = [cmd(101, [message]), cmd(0)]
    e.pages = [hidden, visible]
    e
  end

  def move_route(steps)
    route = RPG::MoveRoute.new
    route.repeat = false
    route.skippable = true # dynamic obstacles must not freeze the escort autorun
    route.list = steps.map { |code| RPG::MoveCommand.new(code) } + [RPG::MoveCommand.new(0)]
    route
  end

  def tiles_clear?(map, tilesets, point)
    x, y = point
    return false unless x.between?(0, map.width - 1) && y.between?(0, map.height - 1)
    tileset = tilesets[map.tileset_id]
    raise 'Native Viridian tileset/passages missing' unless tileset && tileset.respond_to?(:passages)
    2.downto(0) do |layer|
      tile = map.data[x, y, layer]
      next if tile.nil? || tile == 0
      flag = tileset.passages[tile]
      raise "Unknown native passage at #{point.inspect}" unless flag.is_a?(Integer)
      next if (flag & 0x10) != 0
      return (flag & 0x0f) == 0
    end
    false
  end

  def path!(start, steps, finish, map, tilesets, occupied)
    point = start.dup
    ([start] + steps.map { |code|
      dx, dy = DELTA.fetch(code)
      point = [point[0] + dx, point[1] + dy]
    }).each do |tile|
      raise "Escort crosses blocked tile #{tile.inspect}" unless tiles_clear?(map, tilesets, tile)
      raise "Escort overlaps existing event #{tile.inspect}" if occupied.include?(tile)
    end
    raise 'Escort route ends at wrong coordinate' unless point == finish
  end

  def install!(project)
    project = Pathname.new(project).expand_path
    raise 'Only a private staged project may be modified' unless
      project.directory? && !project.symlink? && project.join('SHATTERED_STAGING_REPORT.json').file?
    city_path = project.join('Data/Map010.rxdata')
    center_path = project.join('Data/Map011.rxdata')
    system_path = project.join('Data/System.rxdata')
    tiles_path = project.join('Data/Tilesets.rxdata')
    [[city_path, CITY_SHA], [center_path, CENTER_SHA], [system_path, SYSTEM_SHA]].each do |path, sha|
      raise "Missing/symlinked native input #{path}" unless path.file? && !path.symlink?
      raise "Unreviewed native input #{path.basename}" unless Digest::SHA256.file(path).hexdigest == sha
    end
    raise 'Missing native tileset' unless tiles_path.file? && !tiles_path.symlink?
    { 'NPC 07' => [128, 192], 'POKEMON_NidoranMale' => [128, 128] }.each do |name, dims|
      sprite = project.join("Graphics/Characters/#{name}.png")
      raise "Missing/symlinked licensed private sprite #{name}" unless sprite.file? && !sprite.symlink?
      header = sprite.binread(24)
      raise "Invalid RPG Maker sprite #{name}" unless header.start_with?("\x89PNG\r\n\x1a\n".b) &&
        header.byteslice(16, 8).unpack('N2') == dims
    end
    city = Marshal.load(city_path.binread)
    center = Marshal.load(center_path.binread)
    system = Marshal.load(system_path.binread)
    tilesets = Marshal.load(tiles_path.binread)
    raise 'Wrong native map' unless city.is_a?(RPG::Map) &&
      [city.width, city.height, city.events.keys.max] == [50, 40, 24] &&
      center.is_a?(RPG::Map) && [center.width, center.height] == [20, 15]
    switches = system.instance_variable_get(:@switches)
    raise 'Missing prior Viridian switch reservation' unless switches.is_a?(Array) &&
      switches[STARTED] == 'Shattered Viridian entered' &&
      switches[ARRIVED] == 'Shattered Viridian arrival' &&
      switches[CENTER] == 'Shattered Center visited' &&
      switches[RAIN] == 'Shattered Viridian rain'
    arrival = city.events[23]
    raise 'Unexpected arrival event' unless arrival && arrival.name == 'SHATTERED: Viridian arrival' &&
      [arrival.x, arrival.y] == [25, 20] && arrival.pages.length == 2 &&
      arrival.pages[0].trigger == 3 &&
      arrival.pages[1].condition.switch1_valid && arrival.pages[1].condition.switch1_id == STARTED
    raise 'Unexpected original arrival script' unless arrival.pages[0].list.any? { |c|
      c.code == 355 && c.parameters == ['ShatteredViridian.start!(993, 996); ShatteredViridian.arrive!(994)'] }
    raise 'Unexpected native event allocation' unless (GUARD..NIDORAN_END).none? { |id| city.events.key?(id) }
    occupied = city.events.values.reject { |e| e.pages[0].through }.map { |e| [e.x, e.y] }
    path!(GUARD_START, GUARD_STEPS, GUARD_FINISH, city, tilesets, occupied)
    path!(NIDORAN_START, NIDORAN_STEPS, NIDORAN_FINISH, city, tilesets, occupied)
    raise 'End actors on occupied native tiles' unless [GUARD_FINISH, NIDORAN_FINISH].all? { |p|
      tiles_clear?(city, tilesets, p) && !occupied.include?(p) }
    old_tiles = Marshal.dump(city.data)
    old_events = city.events.transform_values { |e| Marshal.dump(e) }

    arrival.pages[0].list = [
      cmd(355, ['ShatteredViridian.start!(993, 996)']),
      cmd(236, [1, 6, 20]),
      cmd(101, ['Guard: Stay with us. Nidoran will help us reach the Center safely.']),
      cmd(209, [GUARD, move_route(GUARD_STEPS)]),
      cmd(210),
      cmd(209, [NIDORAN, move_route(NIDORAN_STEPS)]),
      cmd(210),
      cmd(111, [12, 'ShatteredViridian.complete_route!(25, 26, [24, 20], [23, 20], [25, 27], [24, 27], 993, 996)']),
      cmd(355, ['ShatteredViridian.arrive!(994)'], 1),
      cmd(101, ['Guard: The Center is just ahead. Get inside before the rain worsens.'], 1),
      cmd(411),
      cmd(101, ['Guard: The route is blocked. We will try again when the way clears.'], 1),
      cmd(116, [], 1),
      cmd(412),
      cmd(0)
    ]
    arrival.pages[1].condition.switch1_id = ARRIVED
    city.events[GUARD] = actor(GUARD, 'SHATTERED_VIRIDIAN:escort_guard', GUARD_START,
      'NPC 07', '', 'Guard: Stay close; we will get you to safety.')
    city.events[NIDORAN] = actor(NIDORAN, 'SHATTERED_VIRIDIAN:escort_nidoran', NIDORAN_START,
      'POKEMON_NidoranMale', '', 'Nidoran watches the road ahead.')
    city.events[GUARD_END] = finish_actor(GUARD_END, 'SHATTERED_VIRIDIAN:guard_at_center',
      GUARD_FINISH, 'NPC 07', 'Guard: Stay inside until we know the city is secure.')
    city.events[NIDORAN_END] = finish_actor(NIDORAN_END, 'SHATTERED_VIRIDIAN:nidoran_at_center',
      NIDORAN_FINISH, 'POKEMON_NidoranMale', 'Nidoran stands watch beside the Center.')
    raise 'Native tile data changed' unless Marshal.dump(city.data) == old_tiles
    raise 'Unrelated events changed' unless old_events.all? { |id, bytes|
      id == 23 || Marshal.dump(city.events.fetch(id)) == bytes }
    output = Marshal.dump(city)
    raise 'Native Marshal roundtrip failed' unless Marshal.dump(Marshal.load(output)) == output
    backup = Pathname.new(city_path.to_s + '.shattered_escort.bak')
    tmp = Pathname.new(city_path.to_s + '.shattered_escort.tmp')
    raise 'Stale escort transaction' if backup.exist? || tmp.exist? || backup.symlink? || tmp.symlink?
    begin
      File.binwrite(tmp, output)
      File.rename(city_path, backup)
      File.rename(tmp, city_path)
    rescue Exception
      File.delete(city_path) if backup.file? && city_path.file?
      File.rename(backup, city_path) if backup.file?
      raise
    ensure
      File.delete(tmp) if tmp.file?
    end
    File.delete(backup)
    { 'native_map_sha256' => Digest::SHA256.file(city_path).hexdigest,
      'native_events_added' => 4, 'guard_steps' => GUARD_STEPS.length,
      'nidoran_steps' => NIDORAN_STEPS.length, 'arrival_requires_completed_route' => true,
      'persistent_escort_after_reload' => true, 'engine_playthrough_verified' => false,
      'android_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby upgrade_private_viridian_escort.rb PRIVATE_STAGED_PROJECT' unless ARGV.length == 1
  puts JSON.pretty_generate(ShatteredPrivateViridianEscort.install!(ARGV[0]))
end
