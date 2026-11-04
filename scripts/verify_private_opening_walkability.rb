#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline native RMXP opening-path audit. PRIVATE assets stay on the caller's machine.
# Not an engine launch, Save/Continue or Android acceptance test.
require 'digest'
require 'json'
require 'zlib'

module RPG
  class Map; end
  class Tileset; end
  class Event
    class Page
      class Condition; end
      class Graphic; end
    end
  end
  class EventCommand; end
  class MoveCommand; end
  class MoveRoute; end
  class AudioFile; end
end
class Table
  def self._load(bytes)
    header = bytes.unpack('L<5')
    raise 'Invalid native RPG Table' unless (1..3).cover?(header[0]) &&
      header[1..3].all? { |n| n.positive? } &&
      header[4] == header[1] * header[2] * header[3] &&
      bytes.bytesize == 20 + header[4] * 2
    obj = allocate
    obj.instance_variable_set(:@raw, bytes)
    obj.instance_variable_set(:@dimensions, header[1..3])
    obj
  end

  def [](x, y = 0, z = 0)
    width, height, depth = @dimensions
    return nil unless x.is_a?(Integer) && y.is_a?(Integer) && z.is_a?(Integer) &&
      x.between?(0, width - 1) && y.between?(0, height - 1) && z.between?(0, depth - 1)
    @raw.byteslice(20 + 2 * (x + width * (y + height * z)), 2).unpack1('s<')
  end
end
class Tone
  def self._load(_bytes) = allocate
end
class Color
  def self._load(_bytes) = allocate
end

module ShatteredOpeningWalkability
  module_function
  ENGINE_SHA = {
    'Game_Map' => '8b2e10ce1b52b67c40241614d64606c657a81b17bee7c7e35d973b7f6ef9cb63',
    'Game_Character' => '0cb6a5149f998c053055d3c7726d557fe1a1368fcabe14bb4a7c159f09a686b9'
  }.freeze
  MAP_SIZES = {223 => [22, 21], 224 => [40, 50], 16 => [54, 34], 10 => [50, 40]}.freeze
  DIRECTIONS = [[0, -1, 8], [0, 1, 2], [-1, 0, 4], [1, 0, 6]].freeze

  def file!(root, relative)
    path = File.join(root, relative)
    raise "Missing or symlinked private file: #{relative}" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def engine!(root)
    scripts = Marshal.load(File.binread(file!(root, 'Data/Scripts.rxdata')))
    raise 'Invalid native Essentials script archive' unless scripts.is_a?(Array)
    ENGINE_SHA.each do |name, sha|
      hits = scripts.select { |item| item.is_a?(Array) && item[1] == name }
      raise "Missing or duplicate pinned Essentials script #{name}" unless hits.size == 1
      source = Zlib::Inflate.inflate(hits.first.fetch(2))
      raise "Unreviewed Essentials movement implementation #{name}" unless Digest::SHA256.hexdigest(source) == sha
      raise "Missing native movement implementation #{name}" unless source.include?('def passable?')
    end
  end

  def load_maps!(root)
    tilesets = Marshal.load(File.binread(file!(root, 'Data/Tilesets.rxdata')))
    MAP_SIZES.to_h do |id, size|
      map = Marshal.load(File.binread(file!(root, format('Data/Map%03d.rxdata', id))))
      raise "Unexpected native map #{id}" unless map.is_a?(RPG::Map) &&
        [map.instance_variable_get(:@width), map.instance_variable_get(:@height)] == size
      tileset = tilesets[map.instance_variable_get(:@tileset_id)]
      raise "Missing native tileset for map #{id}" unless tileset.is_a?(RPG::Tileset)
      [id, [map, tileset]]
    end
  end

  def event_at!(map, id, x, y, fragment)
    event = map.instance_variable_get(:@events).fetch(id)
    raise "Native event #{id} moved or changed" unless
      [event.instance_variable_get(:@x), event.instance_variable_get(:@y)] == [x, y] &&
      event.instance_variable_get(:@name).include?(fragment)
    event
  end

  # The regular tile branch of pinned Essentials Game_Map#playerPassable?.
  # Only valid for maps with terrain tags == 0; no surfing/bridge inference.
  def tile_passable?(map, tileset, x, y, direction)
    width, height = [map.instance_variable_get(:@width), map.instance_variable_get(:@height)]
    return false unless x.between?(0, width - 1) && y.between?(0, height - 1)
    bit = 1 << ((direction / 2) - 1)
    data = map.instance_variable_get(:@data)
    passages = tileset.instance_variable_get(:@passages)
    priorities = tileset.instance_variable_get(:@priorities)
    terrain = tileset.instance_variable_get(:@terrain_tags)
    2.downto(0) do |layer|
      tile = data[x, y, layer]
      next if tile == 0
      raise 'Unreviewed nonzero terrain tag in gate navigation' unless terrain[tile] == 0
      passage = passages[tile]
      raise 'Missing native passage/priority' unless passage.is_a?(Integer) && priorities[tile].is_a?(Integer)
      return false if passage & bit != 0 || passage & 0x0f == 0x0f
      return true if priorities[tile] == 0
    end
    true
  end

  def traverse(map, tileset, start, blocked: [])
    width, height = [map.instance_variable_get(:@width), map.instance_variable_get(:@height)]
    raise 'Invalid native starting coordinate' unless start[0].between?(0, width - 1) &&
      start[1].between?(0, height - 1)
    obstacles = blocked.to_h { |pos| [pos, true] }
    raise 'Start is occupied by a blocking event' if obstacles[start]
    seen = {start => nil}
    queue = [start]
    until queue.empty?
      x, y = queue.shift
      DIRECTIONS.each do |dx, dy, direction|
        dest = [x + dx, y + dy]
        next if seen.key?(dest) || obstacles[dest]
        next unless tile_passable?(map, tileset, x, y, direction) &&
          tile_passable?(map, tileset, dest[0], dest[1], 10 - direction)
        seen[dest] = [x, y]
        queue << dest
      end
    end
    seen
  end

  def check!(root)
    root = File.realpath(root)
    file!(root, 'SHATTERED_STAGING_REPORT.json')
    engine!(root)
    maps = load_maps!(root)
    gate, tileset = maps.fetch(223)
    road, road_tiles = maps.fetch(224)
    aipom = event_at!(gate, 6, 11, 7, 'SHATTERED_HNS:6')
    east = event_at!(gate, 7, 20, 9, 'SHATTERED_HNS:7')
    raise 'Aipom/east door are not solid native events' unless
      [aipom, east].all? { |e| e.instance_variable_get(:@pages).first.instance_variable_get(:@through) == false }
    [1, 8, 9].zip([11, 10, 12]).each do |id, x|
      event = event_at!(gate, id, x, 19, id == 1 ? 'SHATTERED_HNS:1' : 'SHATTERED_HNS_DEBRIS:')
      page = event.instance_variable_get(:@pages).last
      condition = page.instance_variable_get(:@condition)
      raise "Debris #{id} is not switch-controlled and solid" unless
        condition.instance_variable_get(:@switch1_valid) &&
        condition.instance_variable_get(:@switch1_id) == 997 &&
        !page.instance_variable_get(:@through)
    end
    before = traverse(gate, tileset, [11, 14], blocked: [[11, 7], [20, 9]])
    after = traverse(gate, tileset, [11, 14], blocked: [[11, 7], [20, 9], [10, 19], [11, 19], [12, 19]])
    required = {'aipom_approach' => [11, 8], 'east_door_approach' => [19, 9],
                'north_west' => [10, 1], 'north_east' => [11, 1]}
    required.each do |name, pos|
      raise "Gate navigation cannot reach #{name} at #{pos.inspect}" unless after.key?(pos)
    end
    raise 'South entrance was blocked before collapse' unless before.key?([11, 19])
    raise 'South rock is traversable after collapse' if after.key?([11, 19])
    event_at!(road, 1, 30, 47, 'ReceptionGate')
    [[30, 46], [29, 47]].each do |x, y|
      raise 'B2F north landing blocked' unless DIRECTIONS.all? { |_, _, d| tile_passable?(road, road_tiles, x, y, d) }
    end
    route, = maps.fetch(16)
    city, = maps.fetch(10)
    event_at!(route, 3, 30, 17, 'Rattata ambush')
    event_at!(route, 4, 32, 17, 'Viridian gate')
    event_at!(city, 23, 25, 20, 'Viridian arrival')
    {'kind' => 'native_hns_gate_directional_navigation_preflight',
     'engine_script_sha256' => ENGINE_SHA,
     'gate_map_sha256' => Digest::SHA256.file(file!(root, 'Data/Map223.rxdata')).hexdigest,
     'reachable_before_collapse' => before.length, 'reachable_after_collapse' => after.length,
     'required_gate_approaches' => required, 'south_rock_blocks_after_collapse' => true,
     'distinct_b2f_landings_passable' => true, 'route22_viridian_events_present' => true,
     'actual_gameplay_verified' => false, 'save_continue_verified' => false, 'android_verified' => false}
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby verify_private_opening_walkability.rb PRIVATE_PROJECT' unless ARGV.size == 1
  puts JSON.pretty_generate(ShatteredOpeningWalkability.check!(ARGV.first))
end
