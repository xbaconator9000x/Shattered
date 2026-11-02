#!/usr/bin/env ruby
# frozen_string_literal: true
# Source-only offline acceptance preflight for ONE private native Shattered
# candidate. Requires user-held assets; never uploads or distributes them.
require 'digest'
require 'json'
require 'zlib'
require_relative 'private_rgss_writer'

module ShatteredPrivateOpeningConvergence
  SOURCES = {
    'Shattered Gate Story' => ['001_GateStory.rb', '2173092bd36d5f38379c4c3ffb3fe7fcd8f0dcf0', '0.2.3'],
    'Shattered Route22' => ['001_Route22.rb', '22e9d9ae71518e28f2210a649afdb8b710ba7bc9', '0.1.5'],
    'Shattered Murkrow Rescue' => ['001_Quest.rb', '30d370ddfe30edd94860f9de654dbeb718b93fa7', '0.1.3']
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
    { 'kind' => 'private_native_opening_source_and_map_convergence',
      'checked_plugins' => checked, 'gate_north_landings' => north,
      'route22_mandatory_event' => true, 'murkrow_native_event' => true,
      'viridian_native_escort' => true, 'gate_key_branch_guarded' => true,
      'native_game_launched' => false, 'save_continue_verified' => false,
      'android_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby verify_private_opening_convergence.rb PRIVATE_PROJECT' unless ARGV.length == 1
  puts JSON.pretty_generate(ShatteredPrivateOpeningConvergence.verify!(ARGV.first))
end
