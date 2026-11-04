#!/usr/bin/env ruby
# frozen_string_literal: true
# Source-identified RMXP east-door branch repair for a PRIVATE staged HnS gate.
# Original native Map223 event #7 had all commands at indent 0, making its
# conditional transfer executable even when the gate key was missing.
# This is structural validation, NOT an observed Essentials/Android playthrough.
require 'digest'
require 'json'
require 'optparse'
require_relative 'private_rgss_writer'

module ShatteredGateEastGuardRepair
  MAP_ID = 223
  EVENT_ID = 7
  EXPECTED_EVENT_NAME = 'SHATTERED_HNS:7'
  EXPECTED_CODES = [111, 101, 201, 411, 101, 412, 0].freeze
  UNSAFE_INDENTS = [0, 0, 0, 0, 0, 0, 0].freeze
  SAFE_INDENTS = [0, 1, 1, 0, 1, 0, 0].freeze
  EXPECTED_TRANSFER = [0, 16, 14, 10, 2, 0].freeze
  EXPECTED_CONDITION = [12, 'ShatteredGateStory.key_obtained?'].freeze

  def self.event_status!(event)
    raise 'Reviewed HnS east door identity missing' unless event.is_a?(RPG::Event) &&
      event.id == EVENT_ID && event.name == EXPECTED_EVENT_NAME &&
      [event.x, event.y] == [20, 9] && event.pages.is_a?(Array) && event.pages.length == 1
    page = event.pages.first
    raise 'Reviewed HnS door page changed' unless page.trigger == 0 && page.through == false
    commands = page.list
    raise 'Reviewed HnS door command sequence changed' unless
      commands.is_a?(Array) && commands.map(&:code) == EXPECTED_CODES &&
      commands[0].parameters == EXPECTED_CONDITION &&
      commands[2].parameters == EXPECTED_TRANSFER &&
      commands[3].parameters == [] && commands[5].parameters == [] &&
      commands[6].parameters == [] &&
      commands[1].parameters == ['The eastern Kanto door unlocks.'] &&
      commands[4].parameters == ['The eastern Route 22 door is locked. You need the key.']
    indents = commands.map(&:indent)
    return :safe if indents == SAFE_INDENTS
    return :unsafe if indents == UNSAFE_INDENTS
    raise 'Unknown HnS door branch indentation; refusing to alter it'
  end

  def self.repair!(project, expected_sha)
    raise ArgumentError, 'Expected map SHA-256 required' unless
      expected_sha.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(expected_sha)
    root = File.expand_path(project)
    raise 'Project must be a private staged directory' unless
      File.directory?(root) && !File.symlink?(root) &&
      File.file?(File.join(root, 'SHATTERED_STAGING_REPORT.json'))
    data = File.join(root, 'Data')
    raise 'Data directory missing or symlinked' unless File.directory?(data) && !File.symlink?(data)
    path = File.join(data, format('Map%03d.rxdata', MAP_ID))
    infos = File.join(data, 'MapInfos.rxdata')
    raise 'Map/MapInfos missing or symlinked' unless [path, infos].all? { |p| File.file?(p) && !File.symlink?(p) }
    raise 'Reviewed HnS map ID absent' unless load_data(infos).key?(MAP_ID)
    temp, backup = path + '.shattered_gate_guard.tmp', path + '.shattered_gate_guard.bak'
    raise 'Unrecovered HnS gate transaction' if File.exist?(temp) || File.exist?(backup)
    map = load_data(path)
    raise 'Reviewed HnS gate geometry changed' unless
      map.is_a?(RPG::Map) && [map.width, map.height] == [22, 21] && map.events.is_a?(Hash)
    status = event_status!(map.events[EVENT_ID])
    return { 'changed' => false, 'map_sha256' => Digest::SHA256.file(path).hexdigest } if status == :safe
    raise 'Private HnS map differs from reviewed SHA' unless Digest::SHA256.file(path).hexdigest == expected_sha
    original_data = Marshal.dump(map.data)
    original_other_events = map.events.reject { |id, _| id == EVENT_ID }.transform_values { |e| Marshal.dump(e) }
    map.events[EVENT_ID].pages.first.list.each_with_index { |cmd, i| cmd.indent = SAFE_INDENTS[i] }
    raise 'Failed to repair HnS branch' unless event_status!(map.events[EVENT_ID]) == :safe
    backup_created = false
    begin
      File.binwrite(temp, Marshal.dump(map))
      staged = load_data(temp)
      raise 'Staged HnS gate guard validation failed' unless
        event_status!(staged.events[EVENT_ID]) == :safe &&
        Marshal.dump(staged.data) == original_data &&
        staged.events.reject { |id, _| id == EVENT_ID }.transform_values { |e| Marshal.dump(e) } == original_other_events
      File.rename(path, backup)
      backup_created = true
      File.rename(temp, path)
      raise 'Committed HnS guard failed verification' unless event_status!(load_data(path).events[EVENT_ID]) == :safe
      File.delete(backup)
      { 'changed' => true, 'map_sha256' => Digest::SHA256.file(path).hexdigest }
    rescue StandardError
      if backup_created && File.exist?(backup)
        File.delete(path) if File.exist?(path)
        File.rename(backup, path)
      end
      raise
    ensure
      File.delete(temp) if File.exist?(temp)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.on('--project PATH') { |v| options[:project] = v }
    parser.on('--expected-map-sha256 SHA') { |v| options[:sha] = v }
  end.parse!
  abort 'Provide --project and --expected-map-sha256' unless options[:project] && options[:sha]
  puts JSON.pretty_generate(ShatteredGateEastGuardRepair.repair!(options[:project], options[:sha]))
end
