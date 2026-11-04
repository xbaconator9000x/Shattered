#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline private-only probe of a native Map223 using the exact Essentials v21.1
# interpreter scripts. No engine source or commercial map data is committed.
# This is interpreter branch execution, NOT a launched game or Android test.
require 'digest'
require 'json'
require 'optparse'
require 'ostruct'
require 'zlib'
require_relative 'audit_native_project'

module ShatteredNativeGateBranchProbe
  SCRIPT_SHA256 = {
    'Interpreter' => 'b2f4c542a1542a5908d1208b87eae05d8b6f6ec0d26df1835871595842ed0355',
    'Interpreter_Commands' => 'ec927a007bee1889223dbc8b3de115f062a5308ab4410f87dab965eef3032561'
  }.freeze
  EXPECTED_CODES = [111, 101, 201, 411, 101, 412, 0].freeze
  SAFE_INDENTS = [0, 1, 1, 0, 1, 0, 0].freeze
  EXPECTED_TRANSFER = [0, 16, 14, 10, 2, 0].freeze
  module_function

  def regular!(path)
    raise "Missing or unsafe private file: #{path}" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def source_scripts!(path)
    raise 'Scripts.rxdata exceeds probe limit' if File.size(regular!(path)) > 20_000_000
    entries = Marshal.load(File.binread(path))
    raise 'Not a native Scripts.rxdata array' unless entries.is_a?(Array)
    SCRIPT_SHA256.to_h do |name, expected|
      matches = entries.select { |entry| entry.is_a?(Array) && entry[1] == name }
      raise "Missing or ambiguous pinned engine script #{name}" unless matches.size == 1
      compressed = matches.first[2]
      raise "Invalid compressed engine script #{name}" unless compressed.is_a?(String) && compressed.bytesize < 2_000_000
      source = Zlib::Inflate.inflate(compressed)
      raise "Unrecognized engine script #{name}" unless Digest::SHA256.hexdigest(source) == expected
      [name, source]
    end
  end

  def validated_commands!(map)
    raise 'Not the native HnS 22x21 gate' unless map.is_a?(RPG::Map) &&
      [map.instance_variable_get(:@width), map.instance_variable_get(:@height)] == [22, 21]
    event = map.instance_variable_get(:@events).fetch(7)
    raise 'Gate east-door identity changed' unless event.instance_variable_get(:@name) == 'SHATTERED_HNS:7' &&
      [event.instance_variable_get(:@x), event.instance_variable_get(:@y)] == [20, 9]
    pages = event.instance_variable_get(:@pages)
    raise 'Gate east-door pages changed' unless pages.is_a?(Array) && pages.size == 1
    page = pages.first
    raise 'Gate east-door trigger changed' unless page.instance_variable_get(:@trigger) == 0 &&
      page.instance_variable_get(:@through) == false
    commands = page.instance_variable_get(:@list)
    raise 'Gate east-door commands changed' unless commands.is_a?(Array) &&
      commands.map { |c| c.instance_variable_get(:@code) } == EXPECTED_CODES &&
      commands.map { |c| c.instance_variable_get(:@indent) } == SAFE_INDENTS &&
      commands[0].instance_variable_get(:@parameters) == [12, 'ShatteredGateStory.key_obtained?'] &&
      commands[2].instance_variable_get(:@parameters) == EXPECTED_TRANSFER &&
      commands[1].instance_variable_get(:@parameters) == ['The eastern Kanto door unlocks.'] &&
      commands[4].instance_variable_get(:@parameters) == ['The eastern Route 22 door is locked. You need the key.']
    commands
  end

  def install_pinned_interpreter!(sources)
    RPG::EventCommand.class_eval { attr_accessor :code, :indent, :parameters }
    # Eval is restricted to SHA-pinned user-held engine source. Its real
    # conditional/skip/transfer methods run unchanged; only text UI is stubbed.
    sources.each_value { |source| TOPLEVEL_BINDING.eval(source) }
    Object.const_set(:Graphics, Module.new) unless defined?(Graphics)
    Graphics.define_singleton_method(:freeze) {}
    Object.const_set(:ShatteredGateStory, Module.new) unless defined?(ShatteredGateStory)
    ShatteredGateStory.define_singleton_method(:key_obtained?) { $shattered_probe_key }
    Interpreter.class_eval do
      def end_follower_overrides; end
      def command_101
        ($shattered_probe_messages ||= []) << @parameters.first
        true
      end
    end
  end

  def run_case(commands, key)
    $shattered_probe_key = key
    $shattered_probe_messages = []
    $game_map = OpenStruct.new(map_id: 223)
    $game_temp = OpenStruct.new(in_battle: false, player_transferring: false,
      message_window_showing: false, transition_processing: false, menu_calling: false)
    interpreter = Interpreter.new
    interpreter.setup(commands, 7, 223)
    steps = 0
    while interpreter.instance_variable_get(:@index) < commands.length - 1
      steps += 1
      raise 'Nonterminating native interpreter event' if steps > 30
      continue = interpreter.execute_command
      break unless continue
      interpreter.instance_variable_set(:@index, interpreter.instance_variable_get(:@index) + 1)
    end
    { 'key' => key, 'transferred' => !!$game_temp.player_transferring,
      'map_id' => $game_temp.player_new_map_id,
      'x' => $game_temp.player_new_x, 'y' => $game_temp.player_new_y,
      'messages' => $shattered_probe_messages, 'steps' => steps }
  end

  def probe!(project, expected_map_sha256)
    raise 'Expected private map SHA256 must be lowercase hex' unless
      expected_map_sha256.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(expected_map_sha256)
    root = File.expand_path(project)
    raise 'Not a staged private Essentials project' unless File.directory?(root) &&
      !File.symlink?(root) && File.file?(File.join(root, 'SHATTERED_STAGING_REPORT.json'))
    map_path = regular!(File.join(root, 'Data/Map223.rxdata'))
    map_sha = Digest::SHA256.file(map_path).hexdigest
    raise 'Native Map223 differs from reviewed candidate' unless map_sha == expected_map_sha256
    commands = validated_commands!(Marshal.load(File.binread(map_path)))
    sources = source_scripts!(File.join(root, 'Data/Scripts.rxdata'))
    install_pinned_interpreter!(sources)
    locked = run_case(commands, false)
    unlocked = run_case(commands, true)
    raise 'Locked east door transferred player' if locked['transferred']
    raise 'Locked dialogue missing' unless locked['messages'].include?('The eastern Route 22 door is locked. You need the key.')
    raise 'Keyholder failed to transfer to Route22' unless unlocked.values_at('transferred', 'map_id', 'x', 'y') == [true, 16, 14, 10]
    # Reproduce the old bypass on an IN-MEMORY copy, never edit the game.
    unsafe = Marshal.load(Marshal.dump(commands))
    unsafe.each { |command| command.indent = 0 }
    old = run_case(unsafe, false)
    raise 'Legacy unsafe branch bypass not reproduced' unless old['transferred'] && old['map_id'] == 16
    { 'kind' => 'actual_pinned_essentials_interpreter_offline_branch_probe',
      'map_sha256' => map_sha, 'engine_script_sha256' => SCRIPT_SHA256,
      'locked' => locked, 'unlocked' => unlocked, 'old_unsafe_reproduced' => old,
      'native_gameplay_verified' => false, 'save_reload_verified' => false,
      'android_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {}
  parser = OptionParser.new do |p|
    p.on('--project DIR') { |v| opts[:project] = v }
    p.on('--expected-map-sha256 SHA') { |v| opts[:sha] = v }
    p.on('--output FILE') { |v| opts[:output] = v }
  end
  parser.parse!
  abort parser.to_s unless opts[:project] && opts[:sha]
  report = ShatteredNativeGateBranchProbe.probe!(opts[:project], opts[:sha])
  result = JSON.pretty_generate(report) + "\n"
  if opts[:output]
    raise 'Refusing to overwrite report' if File.exist?(opts[:output]) || File.symlink?(opts[:output])
    File.write(opts[:output], result)
  else
    puts result
  end
end
