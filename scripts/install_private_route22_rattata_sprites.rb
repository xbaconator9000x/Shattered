#!/usr/bin/env ruby
# frozen_string_literal: true
# Install SHA-pinned HnS overworld art into the private, reviewed native Route22.
# Source-only: never commit the PNG or proprietary RMXP map to GitHub.
require 'digest'
require 'json'
require 'optparse'
require 'pathname'
require_relative 'private_rgss_writer'

module ShatteredRoute22Sprites
  INPUT_SHA = '064d66435b37c263369380d6c4077d53191f6d2f65db71569977717f312e6339'
  SPRITE_SHA = '3b7119e99a4bba28ceeab6250792ca9d3aad6f3aa6ca2ead37fdbeb448efef03'
  EVENT_IDS = [5, 6, 7].freeze
  POSITIONS = [[31, 17], [31, 18], [32, 18]].freeze
  SCRIPT_FROM = 'ShatteredRoute22.encounter(991, 992) || ShatteredRoute22.return_to_entry(16, 29, 17)'
  SCRIPT_TO = 'ShatteredRoute22.scatter!; ' + SCRIPT_FROM
  WARP_OLD_CONDITION = 'ShatteredRoute22.cleared? || ShatteredRoute22.encounter(991, 992)'
  WARP_NEW_CONDITION = 'ShatteredRoute22.cleared? || (ShatteredRoute22.scatter! && ShatteredRoute22.encounter(991, 992))'

  def self.transform!(map)
    raise 'Unexpected native Route22 dimensions or tile table' unless
      map.is_a?(RPG::Map) && [map.width, map.height] == [54, 34] && map.data.is_a?(Table)
    raise 'Unreviewed Route22 event inventory' unless map.events.is_a?(Hash) && map.events.keys.sort == [1, 2, 3, 4]
    ambush = map.events.fetch(3)
    raise 'Unreviewed Rattata trigger' unless [ambush.x, ambush.y] == [30, 17] &&
      ambush.pages.length == 1 && ambush.pages.first.trigger == 1
    script = ambush.pages.first.list.find { |cmd| cmd.code == 355 }
    raise 'Unreviewed Rattata script' unless script && script.parameters.length == 1 &&
      script.parameters.first.scan(SCRIPT_FROM).length == 1 &&
      !script.parameters.first.include?('scatter!')
    # The transfer at (32,17) is reachable without stepping on the ambush
    # tile at (30,17). Preserve the mandatory battle AND the scatter cinematic
    # for that bypass route. Do not patch a foreign or unguarded transfer.
    warp = map.events.fetch(4)
    commands = warp.pages.first.list
    raise 'Unreviewed Route22 Viridian transfer' unless warp.pages.length == 1 &&
      warp.pages.first.trigger == 1 &&
      commands.map(&:code) == [111, 101, 201, 411, 355, 412, 0] &&
      commands.map(&:indent) == [0, 1, 1, 0, 1, 0, 0] &&
      commands.first.parameters == [12, WARP_OLD_CONDITION] &&
      commands[2].parameters == [0, 10, 25, 20, 2, 0] &&
      commands[4].parameters == ['ShatteredRoute22.return_to_entry(16, 29, 17)']
    before_tiles = Marshal.dump(map.data)
    before_events = map.events.transform_values { |event| Marshal.dump(event) }
    script.parameters[0] = script.parameters.first.sub(SCRIPT_FROM, SCRIPT_TO)
    commands.first.parameters[1] = WARP_NEW_CONDITION
    POSITIONS.each_with_index do |(x, y), i|
      id = EVENT_IDS.fetch(i)
      event = RPG::Event.new(x, y)
      event.id = id
      event.name = "SHATTERED: Rattata scatter #{i + 1}"
      visible = event.pages.first
      visible.graphic.character_name = 'Rattata'
      visible.graphic.direction = 4
      visible.through = true
      visible.step_anime = true
      visible.trigger = 0
      visible.list = [RPG::EventCommand.new(0, 0, [])]
      hidden = RPG::Event::Page.new
      hidden.condition.switch1_valid = true
      hidden.condition.switch1_id = 992
      hidden.through = true
      hidden.list = [RPG::EventCommand.new(0, 0, [])]
      event.pages << hidden
      map.events[id] = event
    end
    raise 'Native Route22 tiles mutated' unless Marshal.dump(map.data) == before_tiles
    raise 'Unrelated Route22 events mutated' unless [1, 2].all? { |id| Marshal.dump(map.events.fetch(id)) == before_events.fetch(id) }
    raise 'Route22 transfer lost scatter/battle guard' unless commands.first.parameters == [12, WARP_NEW_CONDITION]
    raise 'Only the ambush script may change' unless map.events.fetch(3).pages.first.list.find { |c| c.code == 355 }.parameters.first.include?(SCRIPT_TO)
    map
  end

  def self.install!(project, expected_map_sha: INPUT_SHA)
    project = Pathname.new(project).expand_path
    raise 'Missing or symlinked private project' unless project.directory? && !project.symlink?
    raise 'Not a staged private Shattered project' unless project.join('SHATTERED_STAGING_REPORT.json').file?
    path = project.join('Data/Map016.rxdata')
    sprite = project.join('Graphics/Characters/Rattata.png')
    plugin = project.join('Plugins/Shattered Route22/001_Route22.rb')
    raise 'Missing, symlinked or wrong native Rattata sheet' unless sprite.file? && !sprite.symlink? && Digest::SHA256.file(sprite).hexdigest == SPRITE_SHA
    raise 'Missing Route22 scatter runtime' unless plugin.file? && !plugin.symlink? && plugin.read.include?('def self.scatter!')
    raise 'Missing or symlinked native Route22 map' unless path.file? && !path.symlink?
    raise 'Unreviewed native Route22 source map' unless Digest::SHA256.file(path).hexdigest == expected_map_sha
    map = load_data(path.to_s)
    transform!(map)
    output = Marshal.dump(map)
    raise 'Native Marshal roundtrip failed' unless Marshal.dump(Marshal.load(output)) == output
    temp = Pathname.new(path.to_s + '.rattata.tmp')
    backup = Pathname.new(path.to_s + '.rattata.bak')
    raise 'Stale Rattata install transaction' if temp.exist? || backup.exist? || temp.symlink? || backup.symlink?
    begin
      File.binwrite(temp, output)
      File.rename(path, backup)
      File.rename(temp, path)
    rescue Exception
      if backup.file?
        File.delete(path) if path.file?
        File.rename(backup, path)
      end
      raise
    ensure
      File.delete(temp) if temp.file?
    end
    File.delete(backup)
    {'kind'=>'private_native_route22_rattata_group_not_gameplay_acceptance',
     'source_map_sha256'=>expected_map_sha,
     'result_map_sha256'=>Digest::SHA256.file(path).hexdigest,
     'sprite_sha256'=>SPRITE_SHA,'sprite_events'=>EVENT_IDS,
     'engine_playthrough_verified'=>false,'android_verified'=>false}
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new { |p| p.on('--project DIR') { |v| options[:project] = v } }.parse!
  abort 'Usage: ruby scripts/install_private_route22_rattata_sprites.rb --project PRIVATE_PROJECT' unless options[:project]
  puts JSON.pretty_generate(ShatteredRoute22Sprites.install!(options.fetch(:project)))
end
