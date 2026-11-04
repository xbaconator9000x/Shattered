#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline only. Reads a private, authorised Essentials v21.1 project; never
# uploads, modifies, or redistributes its Scripts.rxdata/graphics.
require 'digest'
require 'zlib'
require 'minitest/autorun'

root = ARGV.fetch(0) { abort 'Usage: ruby verify_private_human_healing_native.rb PRIVATE_PROJECT' }
scripts_path = File.join(root, 'Data', 'Scripts.rxdata')
plugins_path = File.join(root, 'Data', 'PluginScripts.rxdata')
core_path = File.join(root, 'Plugins', 'Shattered Core', '001_Core.rb')
raise 'Missing private Essentials scripts' unless File.file?(scripts_path)
raise 'Missing private compiled plugins' unless File.file?(plugins_path)
raise 'Missing Shattered Core source' unless File.file?(core_path)

scripts = Marshal.load(File.binread(scripts_path))
raise 'Unexpected Essentials script archive' unless scripts.is_a?(Array)
pins = {
  'Trainer' => 'b2995a8b8b9fa8381b21f9a37042d217843f712f7fecd00bfd462d79e068c2a7',
  'Interpreter_Commands' => 'ec927a007bee1889223dbc8b3de115f062a5308ab4410f87dab965eef3032561',
  'Settings' => '7c0b394c7204aaed5192f0cae9ab607e8a9a6228ebf1a4efd8af0ddcb3155fcd'
}
actual = {}
pins.each do |name, digest|
  matches = scripts.select { |entry| entry.is_a?(Array) && entry[1] == name }.map do |entry|
    Zlib::Inflate.inflate(entry[2])
  end
  actual[name] = matches.find { |src| Digest::SHA256.hexdigest(src) == digest }
  raise "Native Essentials #{name} source changed; review before execution" unless actual[name]
end
raise 'Pinned Gen 8 healing setting changed' unless actual['Settings'].include?('MECHANICS_GENERATION = 8') &&
  actual['Settings'].include?('HEAL_STORED_POKEMON = (MECHANICS_GENERATION <= 7)')
compiled = Marshal.load(File.binread(plugins_path))
entry = compiled.find { |part| part[0] == 'Shattered Core' }
raise 'Compiled Shattered Core 0.2.4 missing' unless entry && entry[1][:version] == '0.2.4'
raise 'Unexpected Core scripts' unless entry[2].length == 1 && entry[2][0][0] == '001_Core.rb'
raise 'Compiled Core differs from editable source' unless
  Zlib::Inflate.inflate(entry[2][0][1]) == File.binread(core_path)

class Pokemon
  attr_accessor :species, :level
  attr_reader :heals
  def initialize(species, level = 5)
    @species, @level, @heals = species, level, 0
  end
  def heal; @heals += 1; end
end
module Settings; HEAL_STORED_POKEMON = false; end
def pbEachPokemon
  $player.party.each { |pokemon| yield pokemon, 0 }
end
# Evaluate ONLY SHA-pinned native method sources in this isolated test process.
# No game engine, scene, renderer or save subsystem is started.
eval(actual.fetch('Trainer'), TOPLEVEL_BINDING, 'Pinned_Essentials_Trainer.rb')
eval(actual.fetch('Interpreter_Commands'), TOPLEVEL_BINDING, 'Pinned_Essentials_Interpreter_Commands.rb')
load core_path

class ShatteredNativeHealingContractTest < Minitest::Test
  def setup
    $PokemonGlobal = Object.new
    @human = Pokemon.new(:HUMAN, 15)
    @companion = Pokemon.new(:RATTATA)
    $player = Trainer.allocate
    $player.instance_variable_set(:@party, [@human, @companion])
    Shattered.restore_stamina(@human)
    raise 'Cannot debit HUMAN stamina' unless Shattered.spend_stamina(@human, :SLASH)
  end
  def teardown
    $player = nil
    $PokemonGlobal = nil
  end
  def test_actual_trainer_heal_party_restores_human_stamina
    assert_equal $player.party, $player.heal_party
    assert_equal Shattered.max_stamina(15), Shattered.stamina(@human)
    assert_equal 1, @companion.heals
  end
  def test_actual_gen8_interpreter_recover_all_restores_human_stamina
    interpreter = Interpreter.allocate
    interpreter.instance_variable_set(:@parameters, [0])
    assert_equal true, interpreter.command_314
    assert_equal Shattered.max_stamina(15), Shattered.stamina(@human)
    assert_equal 1, @human.heals
  end
end
