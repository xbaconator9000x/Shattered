#!/usr/bin/env ruby
# frozen_string_literal: true
# One-time private repair of the exact reviewed v0.4 Map016 candidate.
# Source-only: do not commit the proprietary native map or any game graphics.
require 'digest'
require 'json'
require 'optparse'
require 'pathname'
require 'fileutils'
require_relative 'private_rgss_writer'

module ShatteredPrivateRoute22Cutline
  SOURCE_SHA = 'e480646fa53bf5ad138686abcbb1e763b5c10f378b92b3b2b080b533cfb6b629'
  AMBUSH_SHA = 'ef8861a24531fedc56be153cc88a80ed6e314103af48b810d85b116aaadfe786'
  WARP_SHA = 'cd089fc35dce5cfdfbea89de202a9f7125f2d033fdc389538c9abdd9939f1767'
  TRANSFER = [0, 10, 25, 20, 2, 0].freeze
  MARKER = 'ShatteredRoute22.encounter(991, 992)'

  def self.command(code, indent, params = [])
    RPG::EventCommand.new(code, indent, params)
  end

  def self.repair!(project, report_path: nil)
    project = Pathname.new(project).expand_path
    raise 'Missing or symlinked private project' unless project.directory? && !project.symlink?
    raise 'Not a staged private Shattered project' unless project.join('SHATTERED_STAGING_REPORT.json').file?
    plugin_path = project.join('Plugins/Shattered Route22/001_Route22.rb')
    raise 'Missing or symlinked runtime Route22 plugin' unless plugin_path.file? && !plugin_path.symlink?
    runtime_source = plugin_path.read
    raise 'Route22 plugin must support defeat/retry before patching' unless
      runtime_source.include?('module ShatteredRoute22') &&
      runtime_source.include?('setBattleRule("canLose")')
    path = project.join('Data/Map016.rxdata')
    raise 'Missing or symlinked Route22 map' unless path.file? && !path.symlink?
    raise 'Unreviewed Route22 source map; refusing edit' unless Digest::SHA256.file(path).hexdigest == SOURCE_SHA
    map = load_data(path.to_s)
    raise 'Unexpected Route22 dimensions or missing native tile data' unless
      [map.width, map.height] == [54, 34] && map.data.is_a?(Table)
    raise 'Unexpected Route22 event inventory' unless map.events.is_a?(Hash) && map.events.keys.sort == [1, 2, 3, 4]
    ambush, warp = map.events.values_at(3, 4)
    raise 'Unreviewed original Rattata event' unless
      [ambush.x, ambush.y] == [30, 17] && Digest::SHA256.hexdigest(Marshal.dump(ambush)) == AMBUSH_SHA
    raise 'Unreviewed original Viridian transfer' unless
      [warp.x, warp.y] == [32, 17] && Digest::SHA256.hexdigest(Marshal.dump(warp)) == WARP_SHA
    raise 'Unreviewed original transfer destination' unless
      warp.pages[0].list.select { |c| c.code == 201 }.map(&:parameters) == [TRANSFER]

    # Preserve native tile data and every unrelated event. No sprites or art are introduced.
    original_tiles = Marshal.dump(map.data)
    other_events = map.events.slice(1, 2).transform_values { |e| Marshal.dump(e) }

    # The original autorun used self-switch A unconditionally after a loss.
    # Use Player Touch and authoritative saved quest state; old self-switch A
    # cannot bypass the fight because the legacy second page is removed.
    page = ambush.pages.first
    raise 'Unexpected original Rattata autorun' unless page.trigger == 3 && ambush.pages.length == 2
    page.trigger = 1
    page.list = [
      command(355, 0, [
        'unless ShatteredRoute22.cleared?; pbMessage(_INTL("A group of Rattata scatters among the grass.")); pbMessage(_INTL("One turns and lunges towards you!")); ' \
        + MARKER + ' || ShatteredRoute22.return_to_entry(16, 29, 17); end'
      ]),
      command(0, 0)
    ]
    ambush.pages = [page]

    # The gate transfer itself is guarded, so alternate paths cannot bypass
    # the mandatory fight. Keep the original native transfer command unchanged.
    original_warp_page = warp.pages.first
    original_transfer = original_warp_page.list.find { |c| c.code == 201 }
    original_warp_page.list = [
      command(111, 0, [12, 'ShatteredRoute22.cleared? || ' + MARKER]),
      command(101, 1, ['The guards wave you towards the walled city.']),
      command(201, 1, original_transfer.parameters.dup),
      command(411, 0),
      command(355, 1, ['ShatteredRoute22.return_to_entry(16, 29, 17)']),
      command(412, 0),
      command(0, 0)
    ]

    raise 'Native tile data mutated' unless Marshal.dump(map.data) == original_tiles
    raise 'Unrelated Route22 events mutated' unless
      other_events.all? { |id, bytes| Marshal.dump(map.events.fetch(id)) == bytes }
    raise 'Original Viridian transfer mutated' unless
      warp.pages[0].list.find { |c| c.code == 201 }.parameters == TRANSFER

    output = Marshal.dump(map)
    raise 'Native map marshal failed roundtrip' unless Marshal.dump(Marshal.load(output)) == output
    tmp = Pathname.new(path.to_s + '.shattered_cutline.tmp')
    backup = Pathname.new(path.to_s + '.shattered_cutline.bak')
    raise 'Stale native Route22 transaction' if tmp.exist? || backup.exist? || tmp.symlink? || backup.symlink?
    begin
      File.binwrite(tmp, output)
      File.rename(path, backup)
      File.rename(tmp, path)
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
    result = {
      'kind' => 'private_route22_cutline_repair_not_runtime_acceptance',
      'source_map_sha256' => SOURCE_SHA,
      'repaired_map_sha256' => Digest::SHA256.file(path).hexdigest,
      'legacy_autorun_removed' => true,
      'legacy_self_switch_bypass_removed' => true,
      'viridian_transfer_guarded' => true,
      'native_tiles_preserved' => true,
      'runtime_verified' => false,
      'save_reload_verified' => false,
      'android_verified' => false
    }
    if report_path
      report = Pathname.new(report_path).expand_path
      raise 'Refusing to overwrite report' if report.exist? || report.symlink?
      report.write(JSON.pretty_generate(result) + "\n")
    end
    result
  end
end

if $PROGRAM_NAME == __FILE__
  args = {}
  OptionParser.new { |p|
    p.on('--project DIR') { |value| args[:project] = value }
    p.on('--report FILE') { |value| args[:report_path] = value }
  }.parse!
  abort 'Usage: ruby scripts/repair_private_route22_cutline.rb --project PRIVATE_STAGED_DIR' unless args[:project]
  puts JSON.pretty_generate(ShatteredPrivateRoute22Cutline.repair!(args.fetch(:project), report_path: args[:report_path]))
end
