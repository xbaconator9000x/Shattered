#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline-only, exact-input Map016 migration for the private Essentials v21.1
# candidate. Ensures the Rattata scatter runs even when the player approaches
# the Viridian transfer without touching the separate ambush tile.
# No commercial map or sprite bytes belong in this repository.
require 'digest'
require 'json'
require 'pathname'
require_relative 'private_rgss_writer'

module ShatteredPrivateRoute22WarpScatter
  module_function
  MAP_SHA_BEFORE = '173b4560718fbf9d46df1ecf2bc52c181cbbeaada38f2846381114c66f02f2c3'
  MAP_SHA_AFTER = 'd5b7d99c6f541f6928f8667fb204567ad800d457044d8ee766f249e6efee0ad1'
  OLD_CONDITION = 'ShatteredRoute22.cleared? || ShatteredRoute22.encounter(991, 992)'
  NEW_CONDITION = 'ShatteredRoute22.cleared? || (ShatteredRoute22.scatter! && ShatteredRoute22.encounter(991, 992))'
  WARP_CODES = [111, 101, 201, 411, 355, 412, 0].freeze
  WARP_INDENTS = [0, 1, 1, 0, 1, 0, 0].freeze
  TRANSFER = [0, 10, 25, 20, 2, 0].freeze

  def inspect_map!(map, condition)
    raise 'Unreviewed Route22 dimensions' unless map.is_a?(RPG::Map) &&
      [map.width, map.height] == [54, 34] && map.events.is_a?(Hash)
    ambush, warp = map.events.values_at(3, 4)
    raise 'Unreviewed Rattata ambush' unless ambush &&
      [ambush.x, ambush.y] == [30, 17] && ambush.pages.length == 1 &&
      ambush.pages.first.trigger == 1 &&
      ambush.pages.first.list.any? { |c| c.code == 355 &&
        c.parameters.length == 1 &&
        c.parameters[0].include?('ShatteredRoute22.scatter!; ShatteredRoute22.encounter(991, 992)') }
    raise 'Unreviewed Viridian transfer' unless warp &&
      [warp.x, warp.y] == [32, 17] && warp.pages.length == 1 &&
      warp.pages.first.trigger == 1
    commands = warp.pages.first.list
    raise 'Unreviewed warp command structure' unless commands.map(&:code) == WARP_CODES &&
      commands.map(&:indent) == WARP_INDENTS &&
      commands[0].parameters == [12, condition] &&
      commands[2].parameters == TRANSFER &&
      commands[4].parameters == ['ShatteredRoute22.return_to_entry(16, 29, 17)']
    [5, 6, 7].each do |id|
      event = map.events[id]
      raise "Missing Rattata scatter sprite event #{id}" unless event &&
        event.name == "SHATTERED: Rattata scatter #{id - 4}" &&
        event.pages.length == 2 &&
        event.pages[1].condition.switch1_valid &&
        event.pages[1].condition.switch1_id == 992
    end
    true
  end

  def transform!(map)
    inspect_map!(map, OLD_CONDITION)
    before_tiles = Marshal.dump(map.data)
    before_events = map.events.transform_values { |e| Marshal.dump(e) }
    map.events[4].pages.first.list.first.parameters[1] = NEW_CONDITION
    inspect_map!(map, NEW_CONDITION)
    raise 'Native Route22 tiles changed' unless Marshal.dump(map.data) == before_tiles
    raise 'Unrelated Route22 events changed' unless before_events.all? { |id, bytes|
      id == 4 || Marshal.dump(map.events.fetch(id)) == bytes }
    map
  end

  def install!(project, failure_hook: nil)
    root = Pathname.new(project).expand_path
    raise 'Not a private staged project' unless root.directory? && !root.symlink? &&
      root.join('SHATTERED_STAGING_REPORT.json').file?
    path = root.join('Data/Map016.rxdata')
    raise 'Missing or symlinked Route22 map' unless path.file? && !path.symlink? &&
      !root.join('Data').symlink?
    before = path.binread
    sha = Digest::SHA256.hexdigest(before)
    raise 'Unreviewed Route22 map input' unless [MAP_SHA_BEFORE, MAP_SHA_AFTER].include?(sha)
    map = Marshal.load(before)
    if sha == MAP_SHA_AFTER
      inspect_map!(map, NEW_CONDITION)
      return { 'result' => 'already_installed', 'map_sha256' => sha,
        'native_gameplay_verified' => false, 'android_verified' => false }
    end
    raise 'Unstable native Marshal serialization' unless Marshal.dump(map) == before
    transform!(map)
    after = Marshal.dump(map)
    raise 'Unreviewed output bytes' unless Digest::SHA256.hexdigest(after) == MAP_SHA_AFTER
    raise 'Native map roundtrip failed' unless Marshal.dump(Marshal.load(after)) == after
    temp = Pathname.new(path.to_s + '.warp-scatter.tmp')
    backup = Pathname.new(path.to_s + '.warp-scatter.bak')
    raise 'Stale Route22 transaction' if [temp, backup].any? { |p| p.exist? || p.symlink? }
    begin
      File.binwrite(temp, after)
      failure_hook.call(:after_temp) if failure_hook
      raise 'Route22 input changed during transaction' unless path.binread == before
      File.rename(path, backup)
      failure_hook.call(:after_backup) if failure_hook
      File.rename(temp, path)
      failure_hook.call(:after_replace) if failure_hook
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
    { 'result' => 'installed', 'map_sha256' => MAP_SHA_AFTER,
      'viridian_transfer_runs_rattata_scatter' => true,
      'native_gameplay_verified' => false, 'android_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby repair_private_route22_warp_scatter.rb PRIVATE_PROJECT' unless ARGV.length == 1
  puts JSON.pretty_generate(ShatteredPrivateRoute22WarpScatter.install!(ARGV.first))
end
