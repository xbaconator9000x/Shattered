require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "ostruct"
require "digest"

module GameData
  module Species
    def self.exists?(species); species == :RATTATA; end
  end
end
module Shattered
  def self.human?(pokemon); pokemon == :HUMAN; end
end
module WildBattle
  def self.start(species, level)
    ($battle_calls ||= []) << [species, level]
    raise "battle interrupted" if $battle_raises
    $game_variables[$battle_outcome_var] = $battle_outcome
  end
end
class Object
  private
  def setBattleRule(rule, value = nil)
    ($rules ||= []) << [rule, value]
    $battle_outcome_var = value if rule == "outcome"
  end
end
module RPG
  class Event
    attr_accessor :id, :name, :x, :y, :pages
    def initialize(x,y); @id = 0; @x=x; @y=y; @name=""; @pages=[]; end
    class Page
      attr_accessor :trigger, :through, :always_on_top, :list, :graphic, :condition
      def initialize
        @trigger=0; @through=false; @always_on_top=false; @list=[]
        @graphic=OpenStruct.new(:character_name=>"")
        @condition=OpenStruct.new(:switch1_valid=>false,:switch1_id=>1)
      end
    end
  end
  class EventCommand
    attr_accessor :code, :indent, :parameters
    def initialize(code, indent, parameters); @code=code; @indent=indent; @parameters=parameters; end
  end
  class MoveRoute
    attr_accessor :repeat, :skippable, :list
    def initialize; @repeat=true; @skippable=false; @list=[]; end
  end
  class MoveCommand
    attr_accessor :code, :parameters
    def initialize(code, parameters=[]); @code=code; @parameters=parameters; end
  end
end
MapStub = Struct.new(:width, :height, :events)
def load_data(path); Marshal.load(File.binread(path)); end
def save_data(data, path); File.binwrite(path, Marshal.dump(data)); end

def pbMessage(message); ($messages ||= []) << message; end
def _INTL(message); message; end
load File.expand_path("../essentials/Plugins/Shattered Route22/001_Route22.rb", __dir__)
load File.expand_path("../essentials/Plugins/Shattered Route22/002_Install.rb", __dir__)

class Route22TestPlayer
  attr_reader :x, :y
  def initialize(x, y)
    @x, @y = x, y
  end
  def moveto(x, y)
    @x, @y = x, y
  end
end

class Route22BattleTest < Minitest::Test
  def setup
    $PokemonGlobal=Object.new
    $game_variables=Hash.new(0)
    $game_switches=Hash.new(false)
    $player=OpenStruct.new(:party=>[:HUMAN])
    $game_map=OpenStruct.new(:need_refresh=>false)
    $rules=[]; $battle_calls=[]; $battle_outcome=1; $battle_raises=false
  end
  def test_win_sets_both_persistent_state_and_switch
    assert ShatteredRoute22.encounter(91,92)
    assert ShatteredRoute22.cleared?
    assert $game_switches[92]
    assert_equal true, $game_map.need_refresh
    assert_equal [[:RATTATA,5]], $battle_calls
    assert_equal [["disablePokeBalls",nil],["outcome",91]], $rules
    assert ShatteredRoute22.encounter(91,92)
    assert_equal 1, $battle_calls.size
    $PokemonGlobal=Marshal.load(Marshal.dump($PokemonGlobal))
    $game_switches[92]=false
    assert ShatteredRoute22.reconcile(92)
    assert $game_switches[92]
  end
  def test_completed_save_reconciliation_refreshes_native_event_pages
    ShatteredRoute22.state[:cleared] = true
    $game_switches[92] = true
    $game_map.need_refresh = false
    assert ShatteredRoute22.reconcile(92)
    assert_equal true, $game_map.need_refresh
    assert_empty $battle_calls
  end

  def test_nonvictory_remains_mandatory
    [0,2,3,5].each do |result|
      $battle_outcome=result
      refute ShatteredRoute22.encounter(91,92)
      refute ShatteredRoute22.cleared?
      refute $game_switches[92]
    end
    assert_equal 4, $battle_calls.length
    $battle_outcome=1
    assert ShatteredRoute22.encounter(91,92)
  end
  def test_capture_is_detected_and_never_clears
    $battle_outcome=4
    refute ShatteredRoute22.encounter(91,92)
    assert ShatteredRoute22.capture_violation?
    refute ShatteredRoute22.cleared?
  end
  def test_stale_cleared_switch_cannot_skip_unsolved_mandatory_battle
    $game_switches[92] = true
    refute ShatteredRoute22.reconcile(92)
    refute $game_switches[92]
    assert ShatteredRoute22.encounter(91, 92)
    assert_equal 1, $battle_calls.length
    assert ShatteredRoute22.cleared?
  end

  def test_invalid_saved_route_state_is_not_silently_reset
    $PokemonGlobal.instance_variable_set(:@shattered_route22_rattata,
      { :version => 999, :cleared => true })
    $game_switches[92] = true
    assert_raises(RuntimeError) { ShatteredRoute22.reconcile(92) }
    assert $game_switches[92]
    assert_equal 999,
      $PokemonGlobal.instance_variable_get(:@shattered_route22_rattata)[:version]
    assert_empty $battle_calls
  end

  def test_capture_diagnostic_clears_on_new_non_capture_battle
    $battle_outcome = 4
    refute ShatteredRoute22.encounter(91, 92)
    assert ShatteredRoute22.capture_violation?
    $battle_outcome = 0
    refute ShatteredRoute22.encounter(91, 92)
    refute ShatteredRoute22.capture_violation?
    $battle_outcome = 1
    assert ShatteredRoute22.encounter(91, 92)
    refute ShatteredRoute22.capture_violation?
  end

  def test_missing_human_cannot_start
    $player.party=[:RATTATA]
    assert_raises(RuntimeError) { ShatteredRoute22.encounter(91,92) }
    assert_empty $battle_calls
  end
  def test_battle_exception_leaves_retryable_state
    $battle_raises=true
    assert_raises(RuntimeError) { ShatteredRoute22.encounter(91,92) }
    refute ShatteredRoute22.cleared?
    $battle_raises=false
    assert ShatteredRoute22.encounter(91,92)
  end
  def test_nonvictory_returns_player_to_safe_gate_side_only_on_route22
    $game_player = Route22TestPlayer.new(31, 17)
    $game_map.map_id = 16
    $battle_outcome = 3 # escape
    refute ShatteredRoute22.encounter(91, 92)
    refute ShatteredRoute22.return_to_entry(16, 30, 17)
    assert_equal [30, 17], [$game_player.x, $game_player.y]
    assert $game_map.need_refresh
    $game_player.moveto(31, 17)
    $game_map.map_id = 10 # blackout moved to another map
    refute ShatteredRoute22.return_to_entry(16, 30, 17)
    assert_equal [31, 17], [$game_player.x, $game_player.y]
    $game_map.map_id = 16
    ShatteredRoute22.state[:cleared] = true
    assert ShatteredRoute22.return_to_entry(16, 30, 17)
    assert_equal [31, 17], [$game_player.x, $game_player.y]
  end

  def test_bad_ids_rejected_before_battle
    [0,-1,10000,"91",true].each do |id|
      assert_raises(ArgumentError) { ShatteredRoute22.encounter(id,92) }
    end
  end
end

NativeRoute22Map = Struct.new(:width, :height, :events, :tileset_id, :data)
NativeRoute22Tileset = Struct.new(:passages)
class NativeRoute22TileData
  def initialize(values)
    @values = values
  end
  def [](x, y, layer)
    @values.fetch([x, y, layer], 0)
  end
end

class Route22InstallerTest < Minitest::Test
  def setup
    @old=Dir.pwd
    @tmp=Dir.mktmpdir
    Dir.chdir(@tmp)
    FileUtils.mkdir_p(["Data", "Graphics/Characters"])
    File.write("SHATTERED_STAGING_REPORT.json","{}")
    File.write("Graphics/Characters/Rattata.png", "local-test-only")
    save_data({42=>true},"Data/MapInfos.rxdata")
    save_data(MapStub.new(48,24,{}),"Data/Map042.rxdata")
    @config={"schema_version"=>1,"source_map_uuid"=>ShatteredRoute22::SOURCE_UUID,
      "map_id"=>42,"expected_map_sha256"=>Digest::SHA256.file("Data/Map042.rxdata").hexdigest,
      "outcome_variable"=>91,"scatter_switch"=>92,"cleared_switch"=>93,
      "rattata_character"=>"Rattata"}
  end
  def teardown
    Dir.chdir(@old)
    FileUtils.remove_entry(@tmp)
  end
  def native_v04_fixture(blocked = nil, legacy = false)
    positions = {
      "triggers" => [[31, 17], [31, 18], [32, 18]],
      "npcs" => [[29, 17], [29, 18], [28, 18]]
    }
    tiles = {}
    (positions["triggers"] + positions["npcs"]).each { |x, y| tiles[[x, y, 0]] = 385 }
    tiles[[30, 17, 0]] = 385 # first Rattata scatter landing
    tiles[[blocked[0], blocked[1], 0]] = 384 if blocked
    events = {}
    if legacy
      event = RPG::Event.new(30, 17)
      event.id = 3
      event.name = "SHATTERED: Rattata ambush"
      events[3] = event
    end
    save_data(NativeRoute22Map.new(54, 34, events, 1, NativeRoute22TileData.new(tiles)),
              "Data/Map042.rxdata")
    save_data([nil, NativeRoute22Tileset.new({384 => 15, 385 => 0})],
              "Data/Tilesets.rxdata")
    @config["expected_map_sha256"] = Digest::SHA256.file("Data/Map042.rxdata").hexdigest
    @config["native_dimensions"] = [54, 34]
    @config["reviewed_native_geometry"] = true
    @config["event_positions"] = positions
    @config["scatter_moves"] = [3, 4, 3]
  end

  def test_native_adaptation_installs_six_and_is_idempotent
    native_v04_fixture
    assert_equal 6, ShatteredRoute22.install(@config)["installed"]
    map = load_data("Data/Map042.rxdata")
    assert_equal 6, map.events.size
    assert_equal @config["event_positions"]["triggers"].sort,
      map.events.values.select { |e| e.name.include?("trigger_") }.map { |e| [e.x, e.y] }.sort
    before = File.binread("Data/Map042.rxdata")
    assert_equal 6, ShatteredRoute22.install(@config)["unchanged"]
    assert_equal before, File.binread("Data/Map042.rxdata")
  end

  def test_reviewed_legacy_autorun_is_disabled_atomically_and_idempotently
    native_v04_fixture(nil, true)
    original = load_data("Data/Map042.rxdata").events[3]
    @config["legacy_migration"] = {
      "event_id" => 3, "event_name" => original.name,
      "x" => 30, "y" => 17,
      "event_sha256" => Digest::SHA256.hexdigest(Marshal.dump(original))
    }
    assert_equal 6, ShatteredRoute22.install(@config)["installed"]
    map = load_data("Data/Map042.rxdata")
    assert_equal 7, map.events.length
    assert_equal ShatteredRoute22::LEGACY_DISABLED, map.events[3].name
    assert_equal [0], map.events[3].pages.first.list.map(&:code)
    before = File.binread("Data/Map042.rxdata")
    assert_equal 6, ShatteredRoute22.install(@config)["unchanged"]
    assert_equal before, File.binread("Data/Map042.rxdata")
  end

  def test_wrong_legacy_event_digest_cannot_mutate_map
    native_v04_fixture(nil, true)
    @config["legacy_migration"] = {
      "event_id" => 3, "event_name" => "SHATTERED: Rattata ambush",
      "x" => 30, "y" => 17, "event_sha256" => "0" * 64
    }
    before = File.binread("Data/Map042.rxdata")
    assert_raises(RuntimeError) { ShatteredRoute22.install(@config) }
    assert_equal before, File.binread("Data/Map042.rxdata")
  end

  def test_native_adaptation_rejects_blocked_and_legacy_event
    native_v04_fixture([31, 17])
    before = File.binread("Data/Map042.rxdata")
    assert_raises(RuntimeError) { ShatteredRoute22.install(@config) }
    assert_equal before, File.binread("Data/Map042.rxdata")
    native_v04_fixture(nil, true)
    before = File.binread("Data/Map042.rxdata")
    error = assert_raises(RuntimeError) { ShatteredRoute22.install(@config) }
    assert_match(/duplicate mandatory battles/, error.message)
    assert_equal before, File.binread("Data/Map042.rxdata")
  end

  def test_native_scatter_destination_must_be_passable
    native_v04_fixture([30, 17])
    before = File.binread("Data/Map042.rxdata")
    error = assert_raises(RuntimeError) { ShatteredRoute22.install(@config) }
    assert_match(/Blocked or unknown Route22 event tile/, error.message)
    assert_equal before, File.binread("Data/Map042.rxdata")
  end

  def test_pinned_v04_hash_rejects_unreviewed_event_relocation
    native_v04_fixture
    @config["expected_map_sha256"] = ShatteredRoute22::V04_ROUTE22_SHA256
    @config["legacy_migration"] = {
      "event_id" => 3, "event_name" => "SHATTERED: Rattata ambush",
      "x" => 30, "y" => 17,
      "event_sha256" => ShatteredRoute22::V04_LEGACY_EVENT_SHA256
    }
    ShatteredRoute22.validate_config(@config)
    @config["event_positions"]["triggers"][0] = [30, 16]
    assert_raises(ArgumentError) { ShatteredRoute22.validate_config(@config) }
  end

  def test_native_adaptation_requires_review_and_unique_coordinates
    native_v04_fixture
    @config.delete("reviewed_native_geometry")
    assert_raises(ArgumentError) { ShatteredRoute22.validate_config(@config) }
    @config["reviewed_native_geometry"] = true
    @config["event_positions"]["npcs"][0] = @config["event_positions"]["triggers"][0]
    assert_raises(ArgumentError) { ShatteredRoute22.validate_config(@config) }
    @config["event_positions"]["npcs"][0] = [54, 17]
    assert_raises(ArgumentError) { ShatteredRoute22.validate_config(@config) }
  end

  def test_installs_six_native_events_and_repeated_install_is_byte_identical
    assert_equal 6, ShatteredRoute22.install(@config)["installed"]
    map=load_data("Data/Map042.rxdata")
    assert_equal 6, map.events.size
    assert_equal ShatteredRoute22::TRIGGERS.sort,
      map.events.values.select { |e| e.name.include?("trigger_") }.map { |e| [e.x,e.y] }.sort
    trigger=map.events.values.find { |e| e.name.end_with?("trigger_1") }
    assert_equal [1,1,1], trigger.pages.map(&:trigger), "all pages must be RMXP Player Touch, not Event Touch"
    assert_equal [false,true,true], trigger.pages.map { |p| p.condition.switch1_valid }
    assert_equal [355,209,209,209,210,121,355,0], trigger.pages[0].list.map(&:code)
    assert_equal [355,0], trigger.pages[1].list.map(&:code)
    assert_equal [355,0], trigger.pages[2].list.map(&:code)
    assert_equal [3,4,1], trigger.pages[0].list.select { |c| c.code == 209 }.map { |c| c.parameters[1].list[0].code }
    assert_equal [92,92,0], trigger.pages[0].list.find { |c| c.code == 121 }.parameters
    assert_equal 93, trigger.pages[2].condition.switch1_id
    assert_equal 92, trigger.pages[1].condition.switch1_id
    before=File.binread("Data/Map042.rxdata")
    assert_equal 6, ShatteredRoute22.install(@config)["unchanged"]
    assert_equal before, File.binread("Data/Map042.rxdata")
    refute File.exist?("Data/Map042.rxdata.shattered_route22.bak")
  end
  def test_completed_event_page_rechecks_authoritative_save_before_bypass
    config = @config.dup
    trigger = ShatteredRoute22.build_trigger(36, 17, 0, [1, 2, 3], config)
    done = trigger.pages.last
    assert_equal 1, done.trigger
    assert done.condition.switch1_valid
    assert_equal 93, done.condition.switch1_id
    assert_equal [355, 0], done.list.map(&:code)
    assert_equal "ShatteredRoute22.encounter(91, 93)", done.list.first.parameters.first
  end

  def test_native_v04_trigger_rejects_escape_and_defeat_bypass
    config = @config.merge("expected_map_sha256" => ShatteredRoute22::V04_ROUTE22_SHA256)
    trigger = ShatteredRoute22.build_trigger(31, 17, 0, [1, 2, 3], config)
    script = "ShatteredRoute22.encounter(91, 93) || ShatteredRoute22.return_to_entry(42, 30, 17)"
    assert_equal script, trigger.pages.first.list.select { |cmd| cmd.code == 355 }.last.parameters.first
    assert_equal script, trigger.pages[1].list.first.parameters.first
    assert_equal script, trigger.pages[2].list.first.parameters.first
  end

  def test_plugin_metadata_uses_essentials_v21_format
    metadata=File.read(File.expand_path("../essentials/Plugins/Shattered Route22/meta.txt", __dir__))
    assert_match(/\AName\s*=/, metadata)
    assert_match(/^Essentials\s*= 21\.1$/, metadata)
    refute_match(/^\[/, metadata)
  end
  def test_stale_backup_blocks_even_if_installed_events_exist
    ShatteredRoute22.install(@config)
    File.write("Data/Map042.rxdata.shattered_route22.bak", "recovery")
    before=File.binread("Data/Map042.rxdata")
    assert_raises(RuntimeError) { ShatteredRoute22.install(@config) }
    assert_equal before, File.binread("Data/Map042.rxdata")
  end
  def test_wrong_source_hash_cannot_mutate_map
    @config["expected_map_sha256"]="0"*64
    before=File.binread("Data/Map042.rxdata")
    assert_raises(RuntimeError) { ShatteredRoute22.install(@config) }
    assert_equal before, File.binread("Data/Map042.rxdata")
  end
  def test_occupied_trigger_refused_without_mutation
    map=load_data("Data/Map042.rxdata")
    existing=RPG::Event.new(36,17); existing.id=1; existing.name="Existing"
    map.events[1]=existing
    save_data(map,"Data/Map042.rxdata")
    @config["expected_map_sha256"]=Digest::SHA256.file("Data/Map042.rxdata").hexdigest
    before=File.binread("Data/Map042.rxdata")
    assert_raises(RuntimeError) { ShatteredRoute22.install(@config) }
    assert_equal before, File.binread("Data/Map042.rxdata")
  end
  def test_partial_installation_refused
    map=load_data("Data/Map042.rxdata")
    e=RPG::Event.new(38,17);e.id=1;e.name=ShatteredRoute22::PREFIX+"rattata_0"
    map.events[1]=e
    save_data(map,"Data/Map042.rxdata")
    assert_raises(RuntimeError) { ShatteredRoute22.install(@config) }
  end
  def test_no_staging_marker_or_sprite_refused
    File.delete("SHATTERED_STAGING_REPORT.json")
    assert_raises(RuntimeError) { ShatteredRoute22.install(@config) }
    File.write("SHATTERED_STAGING_REPORT.json","{}")
    File.delete("Graphics/Characters/Rattata.png")
    assert_raises(RuntimeError) { ShatteredRoute22.install(@config) }
  end
  def test_wrong_dimensions_refused
    save_data(MapStub.new(47,24,{}),"Data/Map042.rxdata")
    assert_raises(RuntimeError) { ShatteredRoute22.install(@config) }
  end
  def test_rejects_nonmatching_or_duplicate_switches
    @config["scatter_switch"]=93
    assert_raises(ArgumentError) { ShatteredRoute22.install(@config) }
    @config["scatter_switch"]=92
    @config["source_map_uuid"]="other"
    assert_raises(ArgumentError) { ShatteredRoute22.install(@config) }
  end
end
