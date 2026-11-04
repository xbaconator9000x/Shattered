#!/usr/bin/env ruby
# frozen_string_literal: true
# Source-only private native Essentials v21.1 repair. The Center's autorun
# must wait for saved escort arrival (994), not merely escort start (993).
# Never commit Map011.rxdata or user-owned graphics to GitHub.
require 'digest'
require 'json'
require 'pathname'
require_relative 'private_rgss_writer'

module ShatteredPrivateViridianCenterArrival
  module_function

  MAP_ID = 11
  OLD_SHA = 'd096c3244c3f7fdee749d9c5c121d6a3e91ed90fedaad0b60a1dcee1d1bea3b6'
  NEW_SHA = 'e05a63a69e99fe1795e8c43b503d05777967d66a88171aa4f212b616b10e09e5'
  STARTED = 993
  ARRIVED = 994
  CENTER = 995
  EVENT_ID = 11

  def transform!(map)
    raise 'Unreviewed native Viridian Center dimensions' unless
      map.is_a?(RPG::Map) && [map.width, map.height] == [20, 15] &&
      map.events.is_a?(Hash)
    event = map.events[EVENT_ID]
    raise 'Unreviewed Center first-visit event' unless event &&
      event.name == 'SHATTERED_VIRIDIAN:center_first_visit' &&
      [event.x, event.y] == [8, 7] && event.pages.length == 3
    hidden, autorun, completed = event.pages
    raise 'Unreviewed Center autorun' unless
      autorun.trigger == 3 && autorun.condition.switch1_valid &&
      [STARTED, ARRIVED].include?(autorun.condition.switch1_id) &&
      completed.condition.switch1_valid && completed.condition.switch1_id == CENTER &&
      autorun.list.any? { |command| command.code == 355 &&
        command.parameters == ['ShatteredViridian.center!(995, 996)'] }
    raise 'Unreviewed blank Center page' unless hidden.list.all? { |command| command.code == 0 }
    return :already_installed if autorun.condition.switch1_id == ARRIVED
    before_tiles = Marshal.dump(map.data)
    before_other_events = map.events.reject { |id, _| id == EVENT_ID }
      .transform_values { |other| Marshal.dump(other) }
    autorun.condition.switch1_id = ARRIVED
    raise 'Native Center tiles modified' unless Marshal.dump(map.data) == before_tiles
    raise 'Unrelated Center events modified' unless before_other_events.all? { |id, bytes|
      Marshal.dump(map.events.fetch(id)) == bytes
    }
    :installed
  end

  def install!(root, failure_hook: nil)
    root = Pathname.new(root).expand_path
    raise 'Only private staged Essentials projects can be modified' unless
      root.directory? && !root.symlink? && root.join('SHATTERED_STAGING_REPORT.json').file?
    marker = root.join('SHATTERED_STAGING_REPORT.json').read
    raise 'Wrong Essentials base' unless marker.include?('"engine": "Essentials 21.1"')
    path = root.join('Data/Map011.rxdata')
    raise 'Missing/symlinked native Center map' unless path.file? && !path.symlink? &&
      !root.join('Data').symlink?
    original = path.binread
    sha = Digest::SHA256.hexdigest(original)
    raise 'Unreviewed Center source; refusing rewrite' unless [OLD_SHA, NEW_SHA].include?(sha)
    map = Marshal.load(original)
    result = transform!(map)
    if sha == NEW_SHA
      raise 'Native Center event drift' unless result == :already_installed
      return { 'result' => 'already_installed', 'map_sha256' => sha }
    end
    raise 'Expected old Center autorun page' unless result == :installed
    replacement = Marshal.dump(map)
    raise 'Unexpected native Center output' unless Digest::SHA256.hexdigest(replacement) == NEW_SHA
    raise 'Native Center Marshal roundtrip failed' unless
      Marshal.dump(Marshal.load(replacement)) == replacement
    tmp = Pathname.new(path.to_s + '.center-arrival.tmp')
    backup = Pathname.new(path.to_s + '.center-arrival.bak')
    raise 'Stale Center transaction' if [tmp, backup].any? { |p| p.exist? || p.symlink? }
    begin
      File.binwrite(tmp, replacement)
      failure_hook.call(:after_temp) if failure_hook
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
    { 'result' => 'installed', 'map_sha256' => NEW_SHA,
      'native_center_autorun_gated_on_escort_arrival' => true,
      'native_gameplay_verified' => false, 'android_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby repair_private_viridian_center_arrival.rb PRIVATE_PROJECT' unless ARGV.length == 1
  puts JSON.pretty_generate(ShatteredPrivateViridianCenterArrival.install!(ARGV.first))
end
