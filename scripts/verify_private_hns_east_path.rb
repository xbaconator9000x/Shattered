#!/usr/bin/env ruby
# frozen_string_literal: true
# Private native Map223 directional route audit; NOT an engine playthrough.
# The original HnS gate deliberately blocks the apparent straight shortcut
# at (12,9)->(13,9). The east door is reached via the northern y=7 walkway.
require 'digest'
require 'json'
require 'optparse'
require 'pathname'
require_relative 'audit_native_project'

module ShatteredHnSEastWalkway
  PATH = [[11, 8], [12, 8], [12, 7], [13, 7], [14, 7], [15, 7],
          [16, 7], [17, 7], [18, 7], [19, 7], [19, 8], [19, 9]].freeze
  SOURCE_BLOCKDATA_SHA256 = '121ddb32e6327f14469b7d7168900c2ee131bb822cccc0cb0139d5fd4168f3a7'
  module_function

  def check!(value, message)
    raise "HnS east walkway: #{message}" unless value
  end

  # Pinned Essentials Game_Map regular walking tile branch, including the
  # directional destination reverse check. Does not infer event AI or ledges.
  def tile_passable?(map, tileset, x, y, direction)
    return false unless x.between?(0, 21) && y.between?(0, 20)
    bit = 1 << ((direction / 2) - 1)
    data = map.instance_variable_get(:@data)
    passage = tileset.instance_variable_get(:@passages)
    priority = tileset.instance_variable_get(:@priorities)
    terrain = tileset.instance_variable_get(:@terrain_tags)
    2.downto(0) do |layer|
      tile = data[x, y, layer]
      next if tile == 0
      check!(tile.is_a?(Integer) && tile > 0, "invalid native tile")
      check!(terrain[tile] == 0, "unreviewed terrain tag at #{x},#{y}")
      mask = passage[tile]
      check!(mask.is_a?(Integer) && priority[tile].is_a?(Integer),
             "missing native passage/priority at #{x},#{y}")
      return false if mask & bit != 0 || mask & 15 == 15
      return true if priority[tile] == 0
    end
    true
  end

  def step_passable?(map, tileset, from, to)
    dx, dy = to[0] - from[0], to[1] - from[1]
    direction = { [0, -1] => 8, [1, 0] => 6, [0, 1] => 2, [-1, 0] => 4 }[[dx, dy]]
    check!(direction, "non-adjacent route step #{from.inspect} -> #{to.inspect}")
    tile_passable?(map, tileset, *from, direction) &&
      tile_passable?(map, tileset, *to, 10 - direction)
  end

  def audit!(map, tilesets)
    check!(map.is_a?(RPG::Map) && map.instance_variable_get(:@width) == 22 &&
           map.instance_variable_get(:@height) == 21, "not native 22x21 Map223")
    tileset = tilesets[map.instance_variable_get(:@tileset_id)]
    check!(tileset.is_a?(RPG::Tileset), "missing native gate tileset")
    events = map.instance_variable_get(:@events)
    check!(events.is_a?(Hash), "missing native events")
    {6 => [11, 7], 7 => [20, 9]}.each do |id, coords|
      event = events[id]
      check!(event && [event.instance_variable_get(:@x), event.instance_variable_get(:@y)] == coords,
             "event #{id} source position changed")
    end
    check!(!PATH.include?([11, 7]) && !PATH.include?([20, 9]),
           "walkway crosses a solid native event")
    PATH.each_cons(2) do |from, to|
      check!(step_passable?(map, tileset, from, to),
             "intended upper walkway blocked #{from.inspect} -> #{to.inspect}")
    end
    check!(!step_passable?(map, tileset, [12, 9], [13, 9]),
           "source-blocked direct shortcut unexpectedly opened")
    {
      'kind' => 'private_native_hns_gate_east_walkway_directional_preflight',
      'path_from_post_aipom' => PATH,
      'steps' => PATH.length - 1,
      'direct_shortcut_12_9_to_13_9_blocked' => true,
      'source_hns_map_sha256' => SOURCE_BLOCKDATA_SHA256,
      'native_gameplay_verified' => false, 'android_verified' => false
    }
  end

  def run!(project, expected_map_sha256, expected_tilesets_sha256)
    root = Pathname.new(project)
    check!(root.directory? && !(root.symlink?) &&
           (root / 'SHATTERED_STAGING_REPORT.json').file?, "not staged private project")
    map_path = root / 'Data/Map223.rxdata'
    tilesets_path = root / 'Data/Tilesets.rxdata'
    [map_path, tilesets_path].each do |path|
      check!(path.file? && !path.symlink?, "missing or unsafe native file")
    end
    check!(Digest::SHA256.file(map_path).hexdigest == expected_map_sha256,
           "unreviewed private Map223 SHA")
    check!(Digest::SHA256.file(tilesets_path).hexdigest == expected_tilesets_sha256,
           "unreviewed private tileset database SHA")
    map = Marshal.load(map_path.binread)
    tilesets = Marshal.load(tilesets_path.binread)
    result = audit!(map, tilesets)
    result.merge('native_map_sha256' => expected_map_sha256,
                 'native_tilesets_sha256' => expected_tilesets_sha256)
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.on('--project DIR') { |v| options[:project] = v }
    parser.on('--map-sha256 SHA') { |v| options[:map] = v }
    parser.on('--tilesets-sha256 SHA') { |v| options[:tilesets] = v }
  end.parse!
  abort 'Usage: ruby verify_private_hns_east_path.rb --project DIR --map-sha256 SHA --tilesets-sha256 SHA' unless
    options.values_at(:project, :map, :tilesets).all?
  puts JSON.pretty_generate(ShatteredHnSEastWalkway.run!(
    options[:project], options[:map], options[:tilesets]))
end
