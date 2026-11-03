#!/usr/bin/env ruby
# frozen_string_literal: true
# Private-only repair of the two HnS Gate north exits accidentally sharing
# one B2F landing. No licensed maps or graphics belong in this repository.
require 'digest'
require 'json'
require 'optparse'
require_relative 'private_rgss_writer'

module ShatteredHNSNorthWarpRepair
  GATE_SHA256 = 'eb6a12f51b324d727f95890b79948db261ac71b047c993d71f6582c1e4f3833f'
  ROAD_SHA256 = '6e198527e9dfd1d2acf9251bab4192a6964fe2b368ddccb44fa88cb0a550dea4'
  ORIGINAL = [0, 224, 30, 46, 8, 0].freeze
  CORRECTED = [0, 224, 29, 47, 8, 0].freeze
  RETURN = [0, 223, 10, 2, 2, 0].freeze
  module_function

  def check!(condition, message)
    raise "HnS north warp repair: #{message}" unless condition
  end

  def command!(map, id, x, y, name, expected)
    event = map.events.fetch(id)
    check!(event.id == id && event.x == x && event.y == y && event.name == name,
           "native event #{id} identity/position drift")
    check!(event.pages.is_a?(Array) && event.pages.length == 1,
           "native event #{id} page drift")
    page = event.pages.first
    check!(page.trigger == 1 && page.through == true,
           "native event #{id} must be a Player Touch warp")
    commands = page.list
    check!(commands.is_a?(Array) && commands.map(&:code) == [201, 0] &&
           commands.all? { |cmd| cmd.indent == 0 } &&
           commands.last.parameters == [], "native event #{id} command drift")
    check!(expected.include?(commands.first.parameters),
           "native event #{id} has an unreviewed transfer target")
    commands.first
  end

  def walkable!(road, tilesets, x, y)
    check!(x.between?(0, road.width - 1) && y.between?(0, road.height - 1),
           'landing outside Victory Road B2F')
    check!(road.events.values.none? { |e| e.x == x && e.y == y },
           'landing overlaps native Player Touch event')
    tileset = tilesets[road.tileset_id]
    check!(tileset && tileset.passages && road.data && road.data.zsize == 3,
           'native tileset passages unavailable')
    found_passable = false
    2.downto(0) do |z|
      tile = road.data[x, y, z]
      next if tile.nil? || tile == 0
      flag = tileset.passages[tile]
      check!(flag.is_a?(Integer), 'native passage flag missing')
      next if (flag & 0x10) != 0
      check!((flag & 0x0f) == 0, 'native landing is blocked')
      found_passable = true
    end
    check!(found_passable, 'native landing has no walkable passage tile')
    true
  end

  def validate!(gate, road, tilesets)
    check!(gate.is_a?(RPG::Map) && [gate.width, gate.height] == [22, 21] &&
           road.is_a?(RPG::Map) && [road.width, road.height] == [40, 50] &&
           gate.events.is_a?(Hash) && road.events.is_a?(Hash),
           'not the pinned HnS Gate/B2F pair')
    first = command!(gate, 2, 11, 1, 'HnS transfer VictoryRoadKanto_B2F_hns', [ORIGINAL])
    second = command!(gate, 3, 10, 1, 'HnS transfer VictoryRoadKanto_B2F_hns', [ORIGINAL, CORRECTED])
    back = command!(road, 1, 30, 47, 'HnS transfer ReceptionGate_hns', [RETURN])
    check!(first.parameters == ORIGINAL && back.parameters == RETURN,
           'reciprocal transfer changed')
    [ORIGINAL, CORRECTED].each do |target|
      check!((target[2] - 30).abs + (target[3] - 47).abs == 1,
             'north landing is not adjacent to B2F return')
      walkable!(road, tilesets, target[2], target[3])
    end
    second.parameters == CORRECTED ? :unchanged : :repairable
  end

  def repair!(project)
    root = File.expand_path(project)
    check!(File.directory?(root) && !File.symlink?(root) &&
           File.file?(File.join(root, 'SHATTERED_STAGING_REPORT.json')),
           'requires an authorised, staged private game')
    gate_path = File.join(root, 'Data/Map223.rxdata')
    road_path = File.join(root, 'Data/Map224.rxdata')
    tiles_path = File.join(root, 'Data/Tilesets.rxdata')
    [gate_path, road_path, tiles_path].each do |path|
      check!(File.file?(path) && !File.symlink?(path), "missing native input #{path}")
    end
    check!(Digest::SHA256.file(road_path).hexdigest == ROAD_SHA256,
           'B2F changed since private geometry review')
    raw = File.binread(gate_path)
    gate = Marshal.load(raw)
    road = Marshal.load(File.binread(road_path))
    tilesets = Marshal.load(File.binread(tiles_path))
    check!(Marshal.dump(gate) == raw, 'native gate Marshal roundtrip is not lossless')
    state = validate!(gate, road, tilesets)
    if state == :unchanged
      gate.events[3].pages[0].list.first.parameters = ORIGINAL.dup
      check!(Digest::SHA256.hexdigest(Marshal.dump(gate)) == GATE_SHA256,
             'already repaired map contains unrelated changes')
      return { 'status' => 'unchanged', 'map_sha256' => Digest::SHA256.hexdigest(raw) }
    end
    check!(Digest::SHA256.hexdigest(raw) == GATE_SHA256,
           'Map223 differs from the reviewed private candidate')
    gate.events[3].pages[0].list.first.parameters = CORRECTED.dup
    check!(validate!(gate, road, tilesets) == :unchanged,
           'repaired map fails native landing checks')
    replacement = Marshal.dump(gate)
    check!(Marshal.load(replacement).is_a?(RPG::Map), 'repaired map cannot be decoded')
    temp, backup = gate_path + '.north-warp.tmp', gate_path + '.north-warp.bak'
    check!([temp, backup].none? { |p| File.exist?(p) || File.symlink?(p) },
           'stale native map transaction')
    moved = false
    begin
      File.binwrite(temp, replacement)
      check!(File.binread(gate_path) == raw &&
             Digest::SHA256.file(road_path).hexdigest == ROAD_SHA256,
             'native map changed during transaction')
      File.rename(gate_path, backup)
      moved = true
      File.rename(temp, gate_path)
      check!(validate!(Marshal.load(File.binread(gate_path)), road, tilesets) == :unchanged,
             'committed map verification failed')
    rescue StandardError
      if moved && File.file?(backup)
        File.delete(gate_path) if File.exist?(gate_path)
        File.rename(backup, gate_path)
      end
      raise
    ensure
      File.delete(temp) if File.exist?(temp)
    end
    File.delete(backup)
    { 'status' => 'repaired', 'original_map_sha256' => GATE_SHA256,
      'map_sha256' => Digest::SHA256.hexdigest(replacement),
      'north_landings' => [[30, 46], [29, 47]],
      'engine_playthrough_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  args = {}
  OptionParser.new { |p| p.on('--project DIR') { |v| args[:project] = v } }.parse!
  abort 'Usage: ruby repair_private_hns_north_warps.rb --project PRIVATE_STAGED' unless args[:project]
  puts JSON.pretty_generate(ShatteredHNSNorthWarpRepair.repair!(args[:project]))
end
