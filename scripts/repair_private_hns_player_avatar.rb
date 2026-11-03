#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline-only, exact-source private Map223 migration. No Pokémon graphics or
# native map bytes are committed. The compiled Essentials player starts with
# character_ID=0; the HnS opening never called pbTrainerName/pbChangePlayer,
# leaving Game_Player#character_name empty despite a valid HUMAN party.
require 'digest'
require 'json'
require 'pathname'
require_relative 'private_rgss_writer'

module ShatteredPrivateHNSPlayerAvatar
  BEFORE_SHA256 = '3004ab941e1579de3c6a6061b054850087c58815e50c3b6e2cdaaacae2dfa75c'
  AFTER_SHA256 = 'ec21eecaca1653672040c35fd9d3429c2bfbd3e04a3215e3bba545ea3dfb653d'
  OLD_SCRIPT = 'Shattered.ensure_human'
  NEW_SCRIPT = 'pbChangePlayer(1) if $player.character_ID < 1; Shattered.ensure_human'
  INTRO_CODES = [101, 101, 355, 355, 123, 0].freeze
  module_function

  def verify!(map, expected_script)
    raise 'Unreviewed HnS gate map' unless map.is_a?(RPG::Map) &&
      [map.width, map.height] == [22, 21] && map.events.is_a?(Hash)
    event = map.events[5]
    raise 'Missing HnS opening event' unless event && event.id == 5 &&
      event.name == 'SHATTERED_HNS:5' && [event.x, event.y] == [11, 14] &&
      event.pages.length == 2 && event.pages.first.trigger == 3
    commands = event.pages.first.list
    raise 'Unreviewed HnS opening commands' unless commands.map(&:code) == INTRO_CODES &&
      commands.map(&:indent).all?(&:zero?) &&
      commands[0].parameters == ['Twenty Years Later...'] &&
      commands[1].parameters == ['The old Johto League Reception Gate is deserted.'] &&
      commands[2].parameters == [expected_script] &&
      commands[3].parameters.first.start_with?('ShatteredGateStory.run_collapse(') &&
      commands[4].parameters == ['A', 0]
    done = event.pages.last
    raise 'Opening completion page missing' unless done.condition.self_switch_valid &&
      done.condition.self_switch_ch == 'A'
    true
  end

  def transform!(map)
    verify!(map, OLD_SCRIPT)
    original_tiles = Marshal.dump(map.data)
    other_events = map.events.reject { |id, _event| id == 5 }.transform_values { |event| Marshal.dump(event) }
    map.events[5].pages.first.list[2].parameters = [NEW_SCRIPT]
    verify!(map, NEW_SCRIPT)
    raise 'HnS tiles changed' unless Marshal.dump(map.data) == original_tiles
    raise 'Unrelated HnS event changed' unless other_events.all? { |id, bytes|
      Marshal.dump(map.events.fetch(id)) == bytes }
    map
  end

  def install!(project, failure_hook: nil)
    root = Pathname.new(project).expand_path
    raise 'Not a private staged project' unless root.directory? && !root.symlink? &&
      root.join('SHATTERED_STAGING_REPORT.json').file?
    data = root.join('Data')
    path = data.join('Map223.rxdata')
    raise 'Missing/symlinked native HnS map' unless data.directory? && !data.symlink? &&
      path.file? && !path.symlink?
    before = path.binread
    digest = Digest::SHA256.hexdigest(before)
    raise 'Unreviewed private HnS gate source' unless [BEFORE_SHA256, AFTER_SHA256].include?(digest)
    map = Marshal.load(before)
    raise 'Unstable native map Marshal encoding' unless Marshal.dump(map) == before
    if digest == AFTER_SHA256
      verify!(map, NEW_SCRIPT)
      return { 'result' => 'already_installed', 'map_sha256' => digest,
        'native_runtime_verified' => false, 'android_verified' => false }
    end
    transform!(map)
    after = Marshal.dump(map)
    raise 'Unreviewed output hash' unless Digest::SHA256.hexdigest(after) == AFTER_SHA256
    raise 'Native map roundtrip failed' unless Marshal.dump(Marshal.load(after)) == after
    tmp = Pathname.new(path.to_s + '.player-avatar.tmp')
    backup = Pathname.new(path.to_s + '.player-avatar.bak')
    raise 'Stale native map transaction' if [tmp, backup].any? { |p| p.exist? || p.symlink? }
    begin
      File.binwrite(tmp, after)
      failure_hook.call(:after_temp) if failure_hook
      raise 'Native map changed during transaction' unless path.binread == before
      File.rename(path, backup)
      failure_hook.call(:after_backup) if failure_hook
      File.rename(tmp, path)
      failure_hook.call(:after_replace) if failure_hook
    rescue Exception
      if backup.file?
        File.delete(path) if path.file?
        File.rename(backup, path)
      end
      raise
    ensure
      File.delete(tmp) if tmp.file?
    end
    File.delete(backup)
    { 'result' => 'installed', 'map_sha256' => AFTER_SHA256,
      'player_avatar_initialized_before_collapse' => true,
      'native_runtime_verified' => false, 'android_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby repair_private_hns_player_avatar.rb PRIVATE_PROJECT' unless ARGV.length == 1
  puts JSON.pretty_generate(ShatteredPrivateHNSPlayerAvatar.install!(ARGV.first))
end
