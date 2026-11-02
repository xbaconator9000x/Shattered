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

  # A walkable corridor is not a working exit. Validate the actual native
  # Action Button event and the key-gated interpreter branch as well as tiles.
  # A misplaced transfer or an unconditional warp would otherwise pass this
  # walkway-only preflight and be mistaken for opening-route acceptance.
  def verify_east_door!(events)
    aipom = events[6]
    check!(aipom && aipom.pages.length == 1 &&
           aipom.pages.first.trigger == 0 &&
           aipom.pages.first.list.any? { |c|
             c.code == 355 &&
             c.parameters == ['ShatteredGateStory.run_aipom("Cries/AIPOM", get_character(0))']
           }, "Aipom interaction missing or no longer grants the gate key")
    door = events[7]
    check!(door && door.pages.length == 1, "missing or ambiguous east-door event")
    page = door.pages.first
    commands = page.list
    check!(page.trigger == 0 && page.through == false &&
           page.graphic.character_name == 'doors1',
           "east door is not a solid Action Button event")
    check!(commands.map(&:code) == [111, 101, 201, 411, 101, 412, 0] &&
           commands.map(&:indent) == [0, 1, 1, 0, 1, 0, 0],
           "east-door conditional branch is malformed")
    check!(commands[0].parameters == [12, 'ShatteredGateStory.key_obtained?'] &&
           commands[2].parameters == [0, 16, 14, 10, 2, 0] &&
           commands[4].parameters ==
             ['The eastern Route 22 door is locked. You need the key.'],
           "east-door key check, Route22 landing or locked response changed")
    true
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
    verify_east_door!(events)
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

  # The reciprocal native door must exist at the actual HnS landing. A
  # correct Map223 transfer alone cannot prove the player can enter Route22
  # or return to the Reception Gate after a save/Continue.
  def verify_route22_landing!(route, tilesets)
    check!(route.is_a?(RPG::Map) && route.instance_variable_get(:@width) == 54 &&
           route.instance_variable_get(:@height) == 34, "wrong native Route22 dimensions")
    events = route.instance_variable_get(:@events)
    door = events[1] if events.is_a?(Hash)
    check!(door && door.instance_variable_get(:@name) == 'Plateau Gate Door' &&
           [door.instance_variable_get(:@x), door.instance_variable_get(:@y)] == [14, 9],
           "Route22 return door missing or displaced")
    pages = door.instance_variable_get(:@pages)
    check!(pages && pages.first && pages.first.trigger == 1,
           "Route22 return door no longer activates on player touch")
    transfers = pages.first.list.select { |cmd| cmd.code == 201 }
    check!(transfers.length == 1 &&
           transfers.first.parameters == [0, 223, 19, 9, 4, 0],
           "Route22 return door does not lead to the reviewed Gate landing")
    tileset = tilesets[route.instance_variable_get(:@tileset_id)]
    check!(tileset.is_a?(RPG::Tileset), "Route22 native tileset missing")
    check!(tile_passable?(route, tileset, 14, 10, 8) &&
           tile_passable?(route, tileset, 14, 9, 2),
           "Route22 landing or return-door approach is blocked")
    true
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
    route_path = root / 'Data/Map016.rxdata'
    check!(route_path.file? && !route_path.symlink?, "missing private Route22 native map")
    route = Marshal.load(route_path.binread)
    verify_route22_landing!(route, tilesets)
    result.merge('native_map_sha256' => expected_map_sha256,
                 'native_tilesets_sha256' => expected_tilesets_sha256,
                 'route22_native_sha256' => Digest::SHA256.file(route_path).hexdigest,
                 'route22_landing_and_return_door_preflight' => true)
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
