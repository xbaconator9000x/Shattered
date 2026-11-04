#!/usr/bin/env ruby
# frozen_string_literal: true
# Executes pinned Essentials v21.1 interpreter commands from a private
# Map016. This is NOT a launched game, battle simulation, or Android test.
# Never upload Scripts.rxdata, Map016.rxdata, or other game assets.
require 'digest'
require 'json'
require 'optparse'
require 'ostruct'
require 'zlib'

module RPG
  class Map; end
  class Event
    class Page
      class Condition; end
      class Graphic; end
    end
  end
  class EventCommand
    attr_accessor :code, :indent, :parameters
  end
  class MoveCommand; end
  class MoveRoute; end
  class AudioFile; end
end
class Table
  def self._load(bytes)
    obj = allocate
    obj.instance_variable_set(:@raw, bytes)
    obj
  end
end
class Tone
  def self._load(_bytes) = allocate
end
class Color
  def self._load(_bytes) = allocate
end

module ShatteredNativeRoute22GuardProbe
  SCRIPT_SHA256 = {
    'Interpreter' => 'b2f4c542a1542a5908d1208b87eae05d8b6f6ec0d26df1835871595842ed0355',
    'Interpreter_Commands' => 'ec927a007bee1889223dbc8b3de115f062a5308ab4410f87dab965eef3032561'
  }.freeze
  EXPECTED_CODES = [111, 101, 201, 411, 355, 412, 0].freeze
  EXPECTED_INDENTS = [0, 1, 1, 0, 1, 0, 0].freeze
  EXPECTED_TRANSFER = [0, 10, 25, 20, 2, 0].freeze
  EXPECTED_RETURN = 'ShatteredRoute22.return_to_entry(16, 29, 17)'
  EXPECTED_CONDITION = 'ShatteredRoute22.cleared? || (ShatteredRoute22.scatter! && ShatteredRoute22.encounter(991, 992))'
  module_function

  def regular!(path)
    raise "Missing or symlinked private input: #{path}" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def engine_sources!(path)
    raise 'Oversized private Scripts.rxdata' if File.size(regular!(path)) > 20_000_000
    entries = Marshal.load(File.binread(path))
    raise 'Not a native Essentials script array' unless entries.is_a?(Array)
    SCRIPT_SHA256.to_h do |name, sha|
      hits = entries.select { |entry| entry.is_a?(Array) && entry[1] == name }
      raise "Missing/ambiguous pinned engine script #{name}" unless hits.length == 1
      compressed = hits.first[2]
      raise 'Unsafe compressed engine script' unless compressed.is_a?(String) && compressed.bytesize < 2_000_000
      begin
        source = Zlib::Inflate.inflate(compressed)
      rescue Zlib::Error
        raise "Invalid compressed pinned engine script #{name}"
      end
      raise "Engine source mismatch #{name}" unless Digest::SHA256.hexdigest(source) == sha
      [name, source]
    end
  end

  def native_commands!(map)
    raise 'Wrong native Route22 map' unless map.is_a?(RPG::Map) &&
      [map.instance_variable_get(:@width), map.instance_variable_get(:@height)] == [54, 34]
    events = map.instance_variable_get(:@events)
    raise 'Unexpected native event inventory' unless events.is_a?(Hash) &&
      (1..7).all? { |id| events.key?(id) }
    event = events.fetch(4)
    raise 'Viridian gate identity changed' unless
      event.instance_variable_get(:@name) == 'SHATTERED: Viridian gate' &&
      [event.instance_variable_get(:@x), event.instance_variable_get(:@y)] == [32, 17]
    pages = event.instance_variable_get(:@pages)
    raise 'Unexpected Viridian gate pages' unless pages.is_a?(Array) && pages.length == 1
    page = pages.first
    raise 'Viridian gate trigger/through changed' unless
      page.instance_variable_get(:@trigger) == 1 && page.instance_variable_get(:@through) == true
    commands = page.instance_variable_get(:@list)
    raise 'Unsafe native Viridian branch shape' unless commands.is_a?(Array) &&
      commands.map { |c| c.instance_variable_get(:@code) } == EXPECTED_CODES &&
      commands.map { |c| c.instance_variable_get(:@indent) } == EXPECTED_INDENTS &&
      commands[0].instance_variable_get(:@parameters) == [12, EXPECTED_CONDITION] &&
      commands[2].instance_variable_get(:@parameters) == EXPECTED_TRANSFER &&
      commands[4].instance_variable_get(:@parameters) == [EXPECTED_RETURN]
    commands
  end

  def install_interpreter!(sources)
    # Evaluate ONLY the exact SHA-pinned, locally held Essentials scripts.
    sources.each_value { |source| TOPLEVEL_BINDING.eval(source) }
    Object.const_set(:Graphics, Module.new) unless defined?(Graphics)
    Graphics.define_singleton_method(:freeze) {}
    Object.const_set(:ShatteredRoute22, Module.new) unless defined?(ShatteredRoute22)
    ShatteredRoute22.define_singleton_method(:cleared?) { $route22_probe_cleared }
    ShatteredRoute22.define_singleton_method(:scatter!) do
      ($route22_probe_scatters ||= []) << :scatter
      $route22_probe_scatter_result
    end
    ShatteredRoute22.define_singleton_method(:encounter) do |*args|
      ($route22_probe_encounters ||= []) << args
      $route22_probe_battle_result
    end
    ShatteredRoute22.define_singleton_method(:return_to_entry) do |*args|
      ($route22_probe_returns ||= []) << args
      false
    end
    Interpreter.class_eval do
      def end_follower_overrides; end
      def command_101
        ($route22_probe_messages ||= []) << @parameters.first
        true
      end
    end
  end

  def run_case(commands, cleared:, battle_result:, scatter_result: true)
    $route22_probe_cleared = cleared
    $route22_probe_battle_result = battle_result
    $route22_probe_scatter_result = scatter_result
    $route22_probe_scatters = []
    $route22_probe_encounters = []
    $route22_probe_returns = []
    $route22_probe_messages = []
    $game_map = OpenStruct.new(map_id: 16)
    $game_temp = OpenStruct.new(in_battle: false, player_transferring: false,
      message_window_showing: false, transition_processing: false, menu_calling: false)
    interpreter = Interpreter.new
    interpreter.setup(commands, 4, 16)
    steps = 0
    while interpreter.instance_variable_get(:@index) < commands.length - 1
      steps += 1
      raise 'Nonterminating Route22 event' if steps > 30
      continue = interpreter.execute_command
      break unless continue
      interpreter.instance_variable_set(:@index, interpreter.instance_variable_get(:@index) + 1)
    end
    { 'cleared' => cleared, 'battle_result' => battle_result,
      'scatter_result' => scatter_result, 'scatters' => $route22_probe_scatters,
      'transferred' => !!$game_temp.player_transferring,
      'destination' => [$game_temp.player_new_map_id, $game_temp.player_new_x, $game_temp.player_new_y],
      'encounters' => $route22_probe_encounters, 'returns' => $route22_probe_returns,
      'messages' => $route22_probe_messages, 'steps' => steps }
  end

  def probe!(project, expected_map_sha256)
    raise 'Expected exact private Map016 SHA256' unless expected_map_sha256.is_a?(String) &&
      /\A[0-9a-f]{64}\z/.match?(expected_map_sha256)
    root = File.expand_path(project)
    raise 'Not a staged private project' unless File.directory?(root) && !File.symlink?(root) &&
      File.file?(File.join(root, 'SHATTERED_STAGING_REPORT.json'))
    map_path = regular!(File.join(root, 'Data/Map016.rxdata'))
    sha = Digest::SHA256.file(map_path).hexdigest
    raise 'Private native Route22 map SHA mismatch' unless sha == expected_map_sha256
    commands = native_commands!(Marshal.load(File.binread(map_path)))
    install_interpreter!(engine_sources!(File.join(root, 'Data/Scripts.rxdata')))
    denied = run_case(commands, cleared: false, battle_result: false)
    victory = run_case(commands, cleared: false, battle_result: true)
    already = run_case(commands, cleared: true, battle_result: false)
    missing_actor = run_case(commands, cleared: false, battle_result: true, scatter_result: false)
    raise 'Defeat/escape transferred into Viridian' if denied['transferred']
    raise 'Defeat skipped the three-Rattata scatter' unless denied['scatters'] == [:scatter]
    raise 'Victory skipped the three-Rattata scatter' unless victory['scatters'] == [:scatter]
    raise 'Completed encounter replayed scatter' unless already['scatters'].empty?
    raise 'Missing scatter actors allowed a battle/transfer' if
      missing_actor['transferred'] || !missing_actor['encounters'].empty? ||
      missing_actor['scatters'] != [:scatter] || missing_actor['returns'] != [[16, 29, 17]]
    raise 'Missing safe return after failed encounter' unless denied['returns'] == [[16, 29, 17]]
    raise 'Mandatory battle was skipped' unless denied['encounters'] == [[991, 992]]
    raise 'Victory did not transfer' unless victory.values_at('transferred', 'destination') == [true, [10, 25, 20]]
    raise 'Completed save did not transfer' unless already['transferred'] && already['encounters'].empty?
    { 'kind' => 'actual_pinned_essentials_interpreter_offline_route22_probe',
      'map_sha256' => sha, 'engine_script_sha256' => SCRIPT_SHA256,
      'failed_battle' => denied, 'victory' => victory, 'already_cleared' => already,
      'missing_scatter_actor' => missing_actor,
      'native_gameplay_verified' => false, 'save_reload_verified' => false, 'android_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  args = {}
  OptionParser.new do |p|
    p.on('--project DIR') { |v| args[:project] = v }
    p.on('--expected-map-sha256 SHA') { |v| args[:sha] = v }
    p.on('--output FILE') { |v| args[:output] = v }
  end.parse!
  abort 'Usage: ruby scripts/verify_private_route22_viridian_guard.rb --project DIR --expected-map-sha256 SHA' unless args[:project] && args[:sha]
  result = JSON.pretty_generate(ShatteredNativeRoute22GuardProbe.probe!(args[:project], args[:sha])) + "\n"
  if args[:output]
    raise 'Refusing to overwrite report' if File.exist?(args[:output]) || File.symlink?(args[:output])
    File.write(args[:output], result)
  else
    puts result
  end
end
