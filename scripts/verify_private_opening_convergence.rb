#!/usr/bin/env ruby
# frozen_string_literal: true
# Source-only offline acceptance preflight for ONE private native Shattered
# candidate. Requires user-held assets; never uploads or distributes them.
require 'digest'
require 'json'
require 'zlib'
require_relative 'private_rgss_writer'
require_relative 'install_private_viridian_beedrill'

module ShatteredPrivateOpeningConvergence
  SOURCES = {
    'Shattered Gate Story' => ['001_GateStory.rb', '2173092bd36d5f38379c4c3ffb3fe7fcd8f0dcf0', '0.2.3'],
    'Shattered Route22' => ['001_Route22.rb', '22e9d9ae71518e28f2210a649afdb8b710ba7bc9', '0.1.5'],
    'Shattered Murkrow Rescue' => ['001_Quest.rb', '30d370ddfe30edd94860f9de654dbeb718b93fa7', '0.1.3'],
    'Shattered Raid' => ['001_Raid.rb', '414dfddd790e80a64c5fc842d5dbfcdeeacd0a81', '0.1.3'],
    'Shattered Viridian' => ['001_Entry.rb', '7932d06e61f20f8357f696a6185600b003f49622', '0.1.2']
  }.freeze
  module_function

  def require_file!(root, relative)
    path = File.join(root, relative)
    raise "Missing or symlinked private file: #{relative}" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def git_blob(bytes)
    Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes)
  end

  def commands(event)
    raise 'Missing native event' unless event && event.respond_to?(:pages)
    event.pages.flat_map { |page| page.instance_variable_get(:@list) || [] }
  end

  # Compare the exact native event source, including Center page gating,
  # progression switches, trigger kind and battle script. This catches an
  # older v0.2.9 raid map even when the compiled plugin has been updated.
  def verify_raid_pages!(city)
    raise 'Missing native Viridian event inventory' unless city.events.is_a?(Hash) &&
      (29..31).all? { |id| city.events.key?(id) }
    3.times do |index|
      actual = city.events[29 + index]
      expected = ShatteredPrivateViridianBeedrill.event(index)
      raise "Viridian raid event #{29 + index} differs from reviewed Center-gated source" unless
        Marshal.dump(actual) == Marshal.dump(expected)
    end
    true
  end

  # An entry from the HnS gate can walk around the separate Rattata ambush
  # tile and reach the Viridian transfer directly. The transfer must invoke
  # the scatter sequence before the mandatory battle, with the native transfer
  # command confined to the successful conditional branch.
  def verify_route22_transfer_scatter!(route)
    raise 'Wrong native Route22 map' unless route.is_a?(RPG::Map) &&
      [route.width, route.height] == [54, 34]
    warp = route.events[4]
    raise 'Missing native Route22 transfer' unless warp &&
      [warp.x, warp.y] == [32, 17] && warp.pages.length == 1 &&
      warp.pages.first.trigger == 1
    commands = warp.pages.first.list
    expected = 'ShatteredRoute22.cleared? || (ShatteredRoute22.scatter! && ShatteredRoute22.encounter(991, 992))'
    raise 'Route22 warp bypasses Rattata scatter or battle' unless
      commands.map(&:code) == [111, 101, 201, 411, 355, 412, 0] &&
      commands.map(&:indent) == [0, 1, 1, 0, 1, 0, 0] &&
      commands.first.parameters == [12, expected] &&
      commands[2].parameters == [0, 10, 25, 20, 2, 0] &&
      commands[4].parameters == ['ShatteredRoute22.return_to_entry(16, 29, 17)']
    [5, 6, 7].each do |id|
      event = route.events[id]
      raise "Missing native Rattata scatter actor #{id}" unless event &&
        event.name == "SHATTERED: Rattata scatter #{id - 4}" &&
        event.pages.length == 2 && event.pages.last.condition.switch1_valid &&
        event.pages.last.condition.switch1_id == 992
    end
    true
  end

  def verify_center_arrival!(center)
    raise 'Wrong native Viridian Center map' unless center.is_a?(RPG::Map) &&
      [center.width, center.height] == [20, 15]
    event = center.events[11]
    raise 'Missing native Center first-visit event' unless event &&
      event.name == 'SHATTERED_VIRIDIAN:center_first_visit' &&
      [event.x, event.y] == [8, 7] && event.pages.length == 3
    autorun, finished = event.pages[1, 2]
    raise 'Center autorun bypasses escort arrival' unless autorun.trigger == 3 &&
      autorun.condition.switch1_valid && autorun.condition.switch1_id == 994 &&
      autorun.list.any? { |command| command.code == 355 &&
        command.parameters == ['ShatteredViridian.center!(995, 996)'] }
    raise 'Center completion page missing' unless finished.condition.switch1_valid &&
      finished.condition.switch1_id == 995
    true
  end

  def verify!(root)
    root = File.realpath(root)
    require_file!(root, 'SHATTERED_STAGING_REPORT.json')
    archive = Marshal.load(File.binread(require_file!(root, 'Data/PluginScripts.rxdata')))
    raise 'Invalid compiled plugin archive' unless archive.is_a?(Array)
    checked = []
    SOURCES.each do |name, (script, pin, version)|
      source = File.binread(require_file!(root, "Plugins/#{name}/#{script}"))
      raise "Source Git blob mismatch: #{name}" unless git_blob(source) == pin
      metadata = File.read(require_file!(root, "Plugins/#{name}/meta.txt"))
      raise "Loose metadata version mismatch: #{name}" unless
        metadata[/^Version\s*=\s*(\d+\.\d+\.\d+)/, 1] == version
      entry = archive.select { |item| item.is_a?(Array) && item[0] == name }
      raise "Missing/duplicate compiled plugin: #{name}" unless entry.length == 1
      _, compiled_meta, scripts = entry.first
      raise "Compiled metadata mismatch: #{name}" unless compiled_meta[:version] == version
      raise "Compiled source inventory mismatch: #{name}" unless scripts.length == 1 && scripts[0][0] == script
      raise "Stale compiled source: #{name}" unless Zlib::Inflate.inflate(scripts[0][1]) == source
      checked << { 'name' => name, 'version' => version, 'git_blob' => pin }
    end
    gate = Marshal.load(File.binread(require_file!(root, 'Data/Map223.rxdata')))
    route = Marshal.load(File.binread(require_file!(root, 'Data/Map016.rxdata')))
    city = Marshal.load(File.binread(require_file!(root, 'Data/Map010.rxdata')))
    center = Marshal.load(File.binread(require_file!(root, 'Data/Map011.rxdata')))
    raise 'Wrong native map dimensions' unless
      [gate.width, gate.height, route.width, route.height, city.width, city.height] == [22, 21, 54, 34, 50, 40]
    north = [2, 3].map do |id|
      transfers = commands(gate.events[id]).select { |command| command.code == 201 }
      raise "Gate north exit #{id} has ambiguous transfer" unless transfers.length == 1
      transfer = transfers.first.parameters
      raise "Gate north exit #{id} not B2F" unless transfer[0..1] == [0, 224]
      transfer[2, 2]
    end
    raise 'Gate north exits collapse to one landing' unless north.uniq.length == 2
    east = commands(gate.events[7])
    raise 'Unconditional Gate key bypass' unless
      east.any? { |c| c.code == 111 && c.indent == 0 && c.parameters == [12, 'ShatteredGateStory.key_obtained?'] } &&
      east.any? { |c| c.code == 201 && c.indent == 1 && c.parameters[0..3] == [0, 16, 14, 10] }
    raise 'Johto debris absent' unless [1, 8, 9].all? { |id| gate.events[id] } &&
      gate.events[8].name == 'SHATTERED_HNS_DEBRIS:8' &&
      gate.events[9].name == 'SHATTERED_HNS_DEBRIS:9'
    raise 'Route22 mandatory battle or Murkrow absent' unless
      route.events[3]&.name == 'SHATTERED: Rattata ambush' &&
      route.events[4]&.name == 'SHATTERED: Viridian gate' &&
      route.events[8]&.name&.start_with?('SHATTERED_MURKROW_RESCUE:')
    raise 'Viridian escort not installed' unless
      [25, 26, 27, 28].all? { |id| city.events[id]&.name&.start_with?('SHATTERED_VIRIDIAN:') }
    verify_route22_transfer_scatter!(route)
    verify_raid_pages!(city)
    verify_center_arrival!(center)
    { 'kind' => 'private_native_opening_source_and_map_convergence',
      'checked_plugins' => checked, 'gate_north_landings' => north,
      'route22_mandatory_event' => true, 'route22_warp_scatter_guarded' => true,
      'center_autorun_requires_escort_arrival' => true, 'murkrow_native_event' => true,
      'viridian_native_escort' => true, 'beedrill_center_gated' => true,
      'gate_key_branch_guarded' => true,
      'native_game_launched' => false, 'save_continue_verified' => false,
      'android_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby verify_private_opening_convergence.rb PRIVATE_PROJECT' unless ARGV.length == 1
  puts JSON.pretty_generate(ShatteredPrivateOpeningConvergence.verify!(ARGV.first))
end
