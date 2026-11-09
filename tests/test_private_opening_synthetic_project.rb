# frozen_string_literal: true
require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "ostruct"
require "tmpdir"
require "zlib"

class Table
  attr_reader :xsize, :ysize, :zsize

  def initialize(*dimensions)
    @xsize, @ysize, @zsize = dimensions
    @values = Hash.new(0)
  end

  def [](*coordinates)
    @values[coordinates]
  end

  def []=(*arguments)
    value = arguments.pop
    @values[arguments] = value
  end
end

module RPG
  class Map
    attr_accessor :width, :height, :tileset_id, :data, :events

    def initialize(width, height)
      @width, @height, @tileset_id = width, height, 1
      @data, @events = Table.new(width, height, 3), {}
      width.times do |x|
        height.times { |y| @data[x, y, 0] = 384 }
      end
    end
  end

  class Event
    attr_accessor :id, :name, :x, :y, :pages

    def initialize(x, y)
      @id, @name, @x, @y, @pages = 0, "", x, y, []
    end

    class Page
      attr_accessor :trigger, :through, :always_on_top, :list, :graphic, :condition

      def initialize
        @trigger, @through, @always_on_top = 0, false, false
        @list = []
        @graphic = OpenStruct.new(:character_name => "")
        @condition = OpenStruct.new(:switch1_valid => false, :switch1_id => 1)
      end
    end
  end

  class EventCommand
    attr_accessor :code, :indent, :parameters

    def initialize(code, indent = 0, parameters = [])
      @code, @indent, @parameters = code, indent, parameters
    end
  end

  class MoveRoute
    attr_accessor :repeat, :skippable, :list

    def initialize
      @repeat, @skippable, @list = true, false, []
    end
  end

  class MoveCommand
    attr_accessor :code, :parameters

    def initialize(code, parameters = [])
      @code, @parameters = code, parameters
    end
  end

  class MapInfo
    attr_accessor :name, :parent_id, :order
  end

  class Tileset
    attr_accessor :name, :tileset_name, :autotile_names, :passages, :priorities,
                  :terrain_tags
  end

  class System
    attr_accessor :start_map_id, :start_x, :start_y
  end
end

def load_data(path)
  Marshal.load(File.binread(path))
end

def save_data(value, path)
  File.binwrite(path, Marshal.dump(value))
end

module GameData
  module Item
    def self.exists?(item)
      item == :SHATTEREDGATEKEY
    end
  end

  module Species
    def self.exists?(species)
      species == :RATTATA
    end
  end
end

module Shattered
  def self.human?(pokemon)
    pokemon == :HUMAN
  end

  def self.restore_stamina(_pokemon)
  end
end

class Symbol
  def able?
    self == :HUMAN || self == :RATTATA
  end
end

module WildBattle
  def self.start(_species, _level)
    $game_variables[$battle_outcome_variable] = $battle_outcomes.shift
  end
end

class Object
  private

  def setBattleRule(rule, value = nil)
    $battle_outcome_variable = value if rule == "outcome"
  end
end

class SyntheticBag
  def initialize
    @items = {}
  end

  def has?(item)
    !!@items[item]
  end

  def add(item, _quantity)
    @items[item] = true
  end
end

class SyntheticGameMap
  attr_accessor :map_id, :need_refresh, :events

  def initialize(map_id, events = {})
    @map_id, @events, @need_refresh = map_id, events, false
  end
end

class SyntheticGameScreen
  def start_shake(*_args)
  end
end

def pbMessage(_message)
end

def _INTL(message)
  message
end

def pbSEPlay(_name)
end

def pbWait(_seconds)
end

def pbExclaim(_event)
end

def load_synthetic_initial_slice_sources
  root = File.expand_path("..", __dir__)
  load File.join(root, "essentials/Plugins/Shattered HnS Gate/001_Import.rb")
  load File.join(root, "essentials/Plugins/Shattered World Links/001_Install.rb")
  load File.join(root, "essentials/Plugins/Shattered Gate Story/001_GateStory.rb")
  load File.join(root, "essentials/Plugins/Shattered Gate Story/002_Install.rb")
  load File.join(root, "essentials/Plugins/Shattered Route22/001_Route22.rb")
  load File.join(root, "essentials/Plugins/Shattered Route22/002_Install.rb")
  load File.join(root, "essentials/Plugins/Shattered Viridian/001_Entry.rb")
  load File.join(root, "scripts/templates/shattered_initial_slice_installer.rb")
end

load_synthetic_initial_slice_sources

class PrivateOpeningSyntheticProjectTest < Minitest::Test
  SWITCHES = {"started" => 993, "arrived" => 994, "center" => 995, "rain" => 996}.freeze

  def setup
    @root = Dir.mktmpdir("shattered-rmxp-project-")
    @old_dir = Dir.pwd
    Dir.chdir(@root)
    FileUtils.mkdir_p(%w[Data Plugins/Shattered\ HnS\ Gate Plugins/Shattered\ Initial\ Slice\ Installer
                         Audio/SE Graphics/Characters Graphics/Tilesets PBS])
    File.write("SHATTERED_STAGING_REPORT.json",
      JSON.generate("engine" => "Essentials 21.1", "profile" => "initial_slice"))
    File.write("PBS/items.txt", "[SHATTEREDGATEKEY]\nName = Shattered Gate Key\n")
    %w[rum1 rum2 rum3 rum4 rum5 rum6 cry roar].each do |name|
      File.write("Audio/SE/#{name}.ogg", "synthetic sound marker")
    end
    %w[Aipom Rattata].each do |name|
      File.write("Graphics/Characters/#{name}.png", "synthetic local sprite marker")
    end

    @route_id, @gate_id = 16, 223
    maps = {}
    [10, 11, @route_id, 20, 21].each do |id|
      maps[id] = RPG::Map.new(48, 40)
    end
    maps[@route_id] = RPG::Map.new(48, 24)
    map_infos = maps.keys.to_h { |id| [id, RPG::MapInfo.new] }
    tileset = RPG::Tileset.new
    tileset.passages = Array.new(8192, 0)
    tileset.priorities = Array.new(8192, 0)
    tileset.terrain_tags = Array.new(8192, 0)
    tileset.passages[0] = 0
    tileset.passages[384] = 0
    tileset.priorities[384] = 0
    tilesets = [nil, tileset]
    system = RPG::System.new
    system.start_map_id, system.start_x, system.start_y = 10, 1, 1
    maps.each { |id, map| save_data(map, format("Data/Map%03d.rxdata", id)) }
    save_data(map_infos, "Data/MapInfos.rxdata")
    save_data(tilesets, "Data/Tilesets.rxdata")
    save_data(system, "Data/System.rxdata")

    @hns_image = "Graphics/Tilesets/Gate.png"
    File.binwrite(@hns_image, "\x89PNG\r\n\x1A\n".b + ("\0" * 4) + "IHDR" +
      [256, 32].pack("NN") + ("\0" * 4))
    @hns = {
      "format" => "shattered-hns-rmxp-map",
      "format_version" => 1,
      "map_name" => "Synthetic Shattered Reception Gate",
      "dimensions" => {"width" => 22, "height" => 21, "tile_pixels" => 32},
      "target" => {
        "map_id" => @gate_id, "tileset_template_id" => 1,
        "tileset_name" => "Gate", "tileset_image" => "Gate.png",
        "tileset_sha256" => Digest::SHA256.file(@hns_image).hexdigest
      },
      "layers" => [Array.new(462, 384), Array.new(462, 0), Array.new(462, 0)],
      "tileset_tables" => {"0" => [0, 0, 0], "384" => [0, 0, 0]},
      "warps" => [
        warp("west", 1, 9, 10), warp("east", 20, 9, @route_id),
        warp("south", 11, 19, 11), warp("north", 10, 1, 20),
        warp("north", 11, 1, 21)
      ]
    }
    @story = {
      "schema_version" => 1, "map_id" => @gate_id,
      "flag_plan" => "shattered_gate_story_v1",
      "positions" => {
        "collapse" => {"x" => 9, "y" => 11},
        "aipom" => {"x" => 11, "y" => 2},
        "johto_block" => {"x" => 11, "y" => 19}
      },
      "collapse_sounds" => %w[rum1 rum2 rum3 rum4 rum5 rum6],
      "final_roar_sound" => "roar", "aipom_cry" => "cry",
      "aipom_character" => "Aipom",
      "expected_south_transfer" => [0, 11, 1, 2, 2, 0]
    }
    @route = {
      "schema_version" => 1,
      "source_map_uuid" => ShatteredRoute22::SOURCE_UUID,
      "map_id" => @route_id,
      "rattata_character" => "Rattata",
      "cleared_switch" => 992, "scatter_switch" => 991,
      "outcome_variable" => 990
    }
    @world_links = {
      "format" => "shattered-world-links", "format_version" => 1,
      "maps" => [
        {"map_id" => @gate_id, "width" => 22, "height" => 21},
        {"map_id" => @route_id, "width" => 48, "height" => 24}
      ],
      "events" => [
        link(@gate_id, 4, 4, @route_id, 5, 5, "gate-route22", "F"),
        link(@route_id, 30, 5, @gate_id, 4, 5, "gate-route22", "R")
      ]
    }
    @configs = {
      "hns_import" => @hns, "gate_story" => @story,
      "world_links" => @world_links, "route22" => @route
    }
    write_configs
    @route["expected_map_sha256"] = Digest::SHA256.file(
      format("Data/Map%03d.rxdata", @route_id)
    ).hexdigest
    write_configs

    @plan_path = "Plugins/Shattered Initial Slice Installer/initial_slice_plan.json"
    @plan = {
      "schema_version" => 1, "profile" => "initial_slice",
      "status" => "native_install_pending",
      "source_pins" => [],
      "map_targets" => {
        "reception_gate" => {"id" => @gate_id},
        "route22" => {"id" => @route_id, "dimensions" => [48, 24],
                      "sha256" => @route["expected_map_sha256"]}
      },
      "route22_reserved_positions" => ShatteredInitialSlice::ROUTE22_RESERVED,
      "new_game_spawn" => {
        "map_id" => @gate_id, "x" => 5, "y" => 5,
        "reviewed" => true, "passability_attested" => true
      },
      "config_paths" => {
        "hns_import" => "Plugins/Shattered HnS Gate/reception_gate.json",
        "world_links" => "Plugins/Shattered Initial Slice Installer/world_links.json",
        "gate_story" => "Plugins/Shattered Initial Slice Installer/gate_story.json",
        "route22" => "Plugins/Shattered Initial Slice Installer/route22.json"
      }
    }
    File.write(@plan_path, JSON.pretty_generate(@plan) + "\n")
    ShatteredInitialSlice.send(:remove_const, :PLAN_SHA256)
    ShatteredInitialSlice.const_set(:PLAN_SHA256,
      Digest::SHA256.hexdigest(File.binread(@plan_path)))
    $shattered_synthetic_plan = @plan
    $shattered_synthetic_configs = @configs
    $PokemonGlobal = Object.new
    $bag = SyntheticBag.new
    $game_switches = Hash.new(false)
    $game_variables = Hash.new(0)
    $game_map = SyntheticGameMap.new(@gate_id)
    $game_screen = SyntheticGameScreen.new
    $player = OpenStruct.new(:party => [:HUMAN], :able_pokemon_count => 1)
    $battle_outcomes = []
    $battle_outcome_variable = nil
  end

  def teardown
    Dir.chdir(@old_dir)
    FileUtils.remove_entry(@root)
  end

  def warp(direction, x, y, map_id)
    {"direction" => direction, "x" => x, "y" => y,
     "target" => {"map_id" => map_id, "x" => 1, "y" => 2,
                  "direction" => 2, "fade" => 0}}
  end

  def link(map_id, x, y, target_map, target_x, target_y, link_id, side)
    {"map_id" => map_id, "x" => x, "y" => y, "link_id" => link_id, "side" => side,
     "destination" => {"map_id" => target_map, "x" => target_x, "y" => target_y,
                       "direction" => 2, "fade" => 0}}
  end

  def write_configs
    File.write("Plugins/Shattered HnS Gate/reception_gate.json", JSON.generate(@hns))
    File.write("Plugins/Shattered Initial Slice Installer/world_links.json",
      JSON.generate(@world_links))
    File.write("Plugins/Shattered Initial Slice Installer/gate_story.json",
      JSON.generate(@story))
    File.write("Plugins/Shattered Initial Slice Installer/route22.json",
      JSON.generate(@route))
  end

  def install_gate
    ShatteredHNSGateImport.install("Plugins/Shattered HnS Gate")
  end

  def install_world_links(path)
    ShatteredWorldLinks.install(JSON.parse(File.read(path)))
  end

  def install_gate_story(path)
    ShatteredGateStory.install(JSON.parse(File.read(path)))
  end

  def install_route22(path)
    ShatteredRoute22.install(JSON.parse(File.read(path)))
  end

  def install_with_native_fixture(fail_after_import: false)
    singleton = ShatteredInitialSlice.singleton_class
    singleton.define_method(:validate_plan!) do |_verify_baseline = true|
      [$shattered_synthetic_plan, $shattered_synthetic_configs, {}]
    end
    singleton.define_method(:preflight_native!) do |plan, _configs|
      [plan, {}]
    end
    fixture = self
    Object.define_method(:pbInstallShatteredHNSReceptionGate) { fixture.install_gate }
    Object.define_method(:pbInstallShatteredWorldLinks) do |path|
      raise "injected world-link installer failure" if fail_after_import
      fixture.install_world_links(path)
    end
    Object.define_method(:pbInstallShatteredGateStory) do |path|
      fixture.install_gate_story(path)
    end
    Object.define_method(:pbInstallShatteredRoute22) do |path|
      fixture.install_route22(path)
    end
    ShatteredInitialSlice.install
  end

  def seed_original_hashes
    %w[Data/MapInfos.rxdata Data/Tilesets.rxdata Data/System.rxdata
       Data/Map016.rxdata].to_h { |path| [path, File.binread(path)] }
  end

  def test_native_install_fixture_is_idempotent_and_serializes_reviewed_events
    report = install_with_native_fixture
    assert_equal "native_install_complete", report["status"]
    assert_equal false, report["gameplay_verified"]
    assert_equal [@gate_id, 5, 5],
      [load_data("Data/System.rxdata").start_map_id,
       load_data("Data/System.rxdata").start_x,
       load_data("Data/System.rxdata").start_y]

    gate = load_data("Data/Map223.rxdata")
    door = gate.events.values.find { |event| event.name == ShatteredInitialSlice::EAST_DOOR_NAME }
    assert door
    assert_equal [111, 101, 201, 411, 101, 412, 0], door.pages.first.list.map(&:code)
    assert_equal [12, "ShatteredGateStory.key_obtained?"],
      door.pages.first.list.first.parameters
    assert_equal [0, 16, 1, 2, 2, 0],
      door.pages.first.list.find { |command| command.code == 201 }.parameters

    route = load_data("Data/Map016.rxdata")
    trigger = route.events.values.find { |event| event.name == "SHATTERED_ROUTE22:trigger_0" }
    assert_equal [1, 1, 1], trigger.pages.map(&:trigger)
    assert_equal "ShatteredRoute22.encounter(990, 992)",
      trigger.pages.last.list.first.parameters.first
    links = route.events.values.select { |event| event.name.start_with?("SHATTERED_LINK:") }
    assert_equal 1, links.length
    transfer = links.first.pages.first.list.first
    assert_equal 201, transfer.code
    assert_equal [0, @gate_id, 4, 5, 2, 0], transfer.parameters

    before = %w[Data/Map223.rxdata Data/Map016.rxdata Data/MapInfos.rxdata
                Data/Tilesets.rxdata Data/System.rxdata].to_h do |path|
      [path, File.binread(path)]
    end
    repeated = install_with_native_fixture
    assert_equal report["plan_sha256"], repeated["plan_sha256"]
    before.each { |path, bytes| assert_equal bytes, File.binread(path), path }
    refute File.exist?(ShatteredInitialSlice::ROLLBACK_DIR)
  end

  def test_initial_slice_transaction_rolls_back_serialized_maps_and_system
    originals = seed_original_hashes
    ShatteredInitialSlice.begin_transaction!(
      ShatteredInitialSlice.transaction_paths(@plan)
    )
    File.binwrite("Data/MapInfos.rxdata", "partial map infos")
    File.binwrite("Data/Tilesets.rxdata", "partial tilesets")
    File.binwrite("Data/System.rxdata", "partial start")
    File.binwrite("Data/Map223.rxdata", "partial new gate")
    File.binwrite("Data/Map016.rxdata", "partial route")
    File.write(ShatteredInitialSlice::RECEIPT_PATH, "premature receipt")

    error = assert_raises(RuntimeError) do
      ShatteredInitialSlice.rollback_after_error!(RuntimeError.new("injected fixture failure"))
    end
    assert_equal "injected fixture failure", error.message
    originals.each { |path, bytes| assert_equal bytes, File.binread(path), path }
    refute File.exist?("Data/Map223.rxdata")
    refute File.exist?(ShatteredInitialSlice::RECEIPT_PATH)
    refute File.exist?(ShatteredInitialSlice::ROLLBACK_DIR)
    assert_instance_of RPG::Map, load_data("Data/Map016.rxdata")
  end

  def test_native_install_failure_restores_maps_created_by_earlier_installers
    originals = seed_original_hashes
    error = assert_raises(RuntimeError) do
      install_with_native_fixture(fail_after_import: true)
    end
    assert_match(/injected world-link installer failure/, error.message)
    originals.each { |path, bytes| assert_equal bytes, File.binread(path), path }
    refute File.exist?("Data/Map223.rxdata")
    refute File.exist?(ShatteredInitialSlice::RECEIPT_PATH)
    refute File.exist?(ShatteredInitialSlice::ROLLBACK_DIR)
  end

  def test_route22_loss_retry_victory_and_viridian_save_restore
    # Native event arrays are real Marshal-serialized RMXP-shaped map objects;
    # this test evaluates source state and event contracts, not game rendering.
    install_gate
    install_gate_story("Plugins/Shattered Initial Slice Installer/gate_story.json")
    gate = load_data("Data/Map223.rxdata")
    ShatteredInitialSlice.guard_east_exit!(gate,
      ShatteredInitialSlice.reviewed_east_transfer(@configs, @route_id))
    save_data(gate, "Data/Map223.rxdata")
    @route["expected_map_sha256"] = Digest::SHA256.file("Data/Map016.rxdata").hexdigest
    write_configs
    install_route22("Plugins/Shattered Initial Slice Installer/route22.json")

    # Gate remains locked until the saved collapse/clue and actual bag item exist.
    door = load_data("Data/Map223.rxdata").events.values.find do |event|
      event.name == ShatteredInitialSlice::EAST_DOOR_NAME
    end
    refute ShatteredGateStory.key_obtained?
    assert_equal "ShatteredGateStory.key_obtained?",
      door.pages.first.list.first.parameters.last
    ShatteredGateStory.run_collapse(%w[rum1 rum2 rum3 rum4 rum5 rum6], "roar")
    assert ShatteredGateStory.run_aipom("cry")
    assert ShatteredGateStory.key_obtained?
    assert_equal [0, @route_id, 1, 2, 2, 0],
      door.pages.first.list.find { |command| command.code == 201 }.parameters

    # Viridian's native entry effects stay off until the mandatory encounter wins.
    refute ShatteredViridian.start!(993, 996)
    refute ShatteredViridian.arrive!(994)
    refute ShatteredViridian.center!(995, 996)
    refute ShatteredViridian.state[:started]

    $battle_outcomes = [2, 1]
    refute ShatteredRoute22.encounter(990, 992)
    refute ShatteredRoute22.cleared?
    refute $game_switches[992]
    refute ShatteredViridian.start!(993, 996)

    # Persist exactly the gameplay-owned save objects, then restore them as a
    # separate-process Continue would; no Ruby globals are treated as save data.
    save = Marshal.dump([$PokemonGlobal, $bag, $game_switches, $game_variables])
    $PokemonGlobal, $bag, $game_switches, $game_variables = Marshal.load(save)
    $game_map = SyntheticGameMap.new(@route_id)
    assert ShatteredRoute22.encounter(990, 992)
    assert ShatteredRoute22.cleared?
    assert $game_switches[992]
    save = Marshal.dump([$PokemonGlobal, $bag, $game_switches, $game_variables])
    $PokemonGlobal, $bag, $game_switches, $game_variables = Marshal.load(save)

    $game_switches[992] = false
    assert ShatteredRoute22.reconcile_on_map_setup
    assert $game_switches[992]
    assert ShatteredViridian.start!(993, 996)
    assert ShatteredViridian.arrive!(994)
    save = Marshal.dump([$PokemonGlobal, $bag, $game_switches])
    $PokemonGlobal, $bag, $game_switches = Marshal.load(save)
    $game_map = SyntheticGameMap.new(10)
    assert ShatteredViridian.reconcile_on_map_restore
    assert $game_switches[993]
    assert $game_switches[994]
    assert $game_switches[996]
    assert ShatteredGateStory.key_obtained?
  end
end
