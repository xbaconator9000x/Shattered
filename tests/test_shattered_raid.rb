require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest/sha2"

module RPG
  class Map
    attr_accessor :width, :height, :events
    def initialize(width, height)
      @width, @height, @events = width, height, {}
    end
  end

  class Event
    attr_accessor :id, :name, :x, :y, :pages
    def initialize(x, y)
      @x, @y, @pages = x, y, []
    end

    class Page
      attr_accessor :graphic, :condition, :trigger, :through, :always_on_top, :list
      def initialize
        @graphic = Graphic.new
        @condition = Condition.new
        @through = false
        @always_on_top = false
        @list = []
      end

      class Graphic
        attr_accessor :character_name, :character_hue
        def initialize
          @character_name, @character_hue = "", 0
        end
      end

      class Condition
        attr_accessor :switch1_valid, :switch1_id
      end
    end
  end

  class EventCommand
    attr_accessor :code, :indent, :parameters
    def initialize(code, indent, parameters)
      @code, @indent, @parameters = code, indent, parameters
    end
  end
end

module EventHandlers
  @handlers = {}
  def self.add(event, key, handler)
    @handlers[[event, key]] = handler
  end
  def self.handler(event, key)
    @handlers[[event, key]]
  end
end

module GameData
  class Species
    @species = [:HUMAN, :BEEDRILL]
    def self.exists?(species)
      @species.include?(species)
    end
    def self.species=(species)
      @species = species
    end
  end
end

module Shattered
  def self.human?(pokemon)
    pokemon && pokemon.species == :HUMAN
  end
end

module WildBattle
  class << self
    attr_accessor :outcome, :callback, :calls
    def start(species, level)
      self.calls ||= []
      calls << [species, level]
      callback.call if callback
      $game_variables[$raid_outcome_id] = outcome unless callback
    end
  end
end

$battle_rules = []
def setBattleRule(*args)
  $battle_rules << args
  $raid_outcome_id = args[1] if args[0] == "outcome"
end

RaidPokemon = Struct.new(:species, :hp) do
  def able?
    hp.to_i > 0
  end
end

load File.expand_path("../essentials/Plugins/Shattered Raid/001_Raid.rb", __dir__)

class ShatteredRaidTest < Minitest::Test
  def setup
    $PokemonGlobal = Object.new
    $player = Struct.new(:party) do
      def able_pokemon_count
        party.count { |pkmn| pkmn.respond_to?(:able?) && pkmn.able? }
      end
    end.new([RaidPokemon.new(:HUMAN, 10)])
    $game_variables = Hash.new(0)
    $game_switches = Hash.new(false)
    $game_map = Struct.new(:map_id).new(301)
    $battle_rules = []
    $game_temp = Object.new
    def $game_temp.clear_battle_rules
      $battle_rules.clear
    end
    WildBattle.calls = []
    WildBattle.callback = nil
    WildBattle.outcome = 1
    GameData::Species.species = [:HUMAN, :BEEDRILL]
  end

  def test_victory_advances_once_and_syncs_switches
    assert ShatteredRaid.trigger(0, runtime_config)
    assert_equal 1, ShatteredRaid.progression
    assert_equal [true, false, false], switch_values
    assert_equal [[:BEEDRILL, 5]], WildBattle.calls
    assert_equal [["disablePokeBalls"], ["canLose"], ["outcome", 7]], $battle_rules
    refute ShatteredRaid.trigger(0, runtime_config)
    assert_equal 1, WildBattle.calls.length
  end

  def test_fainted_human_or_companion_lead_cannot_skip_mandatory_raid
    human = $player.party.first
    human.hp = 0
    $player.party << RaidPokemon.new(:RATTATA, 10)
    refute ShatteredRaid.trigger(0, runtime_config)
    assert_empty WildBattle.calls
    assert_equal 0, ShatteredRaid.progression
    human.hp = 10
    $player.party.reverse!
    refute ShatteredRaid.trigger(0, runtime_config)
    assert_empty WildBattle.calls
    $player.party.reverse!
    assert ShatteredRaid.trigger(0, runtime_config)
    assert_equal 1, ShatteredRaid.progression
  end

  def test_battle_setup_exception_clears_queued_rules_before_retry
    WildBattle.callback = proc { raise "native battle setup failed" }
    assert_raises(RuntimeError) { ShatteredRaid.trigger(0, runtime_config) }
    assert_empty $battle_rules
    assert_equal 0, ShatteredRaid.progression
    WildBattle.callback = nil
    assert ShatteredRaid.trigger(0, runtime_config)
    assert_equal [["disablePokeBalls"], ["canLose"], ["outcome", 7]], $battle_rules
  end

  def test_continue_hook_reconciles_saved_raid_pages
    assert ShatteredRaid.trigger(0, runtime_config)
    $game_switches[21] = false
    $game_switches[22] = true
    $game_map = Struct.new(:map_id, :need_refresh).new(301, false)
    handler = EventHandlers.handler(:on_map_or_spriteset_change, :shattered_raid_continue_sync)
    assert handler.call
    assert_equal [true, false, false], switch_values
    assert $game_map.need_refresh
  end

  def test_flee_blackout_and_undecided_outcomes_remain_retryable
    [2, 3, 0].each do |outcome|
      WildBattle.outcome = outcome
      refute ShatteredRaid.trigger(0, runtime_config)
      assert_equal 0, ShatteredRaid.progression
      assert_equal [false, false, false], switch_values
    end
    WildBattle.outcome = 1
    assert ShatteredRaid.trigger(0, runtime_config)
    assert_equal 1, ShatteredRaid.progression
  end

  def test_blackout_does_not_consume_current_encounter
    WildBattle.outcome = 2
    refute ShatteredRaid.trigger(0, runtime_config)
    assert_equal 0, ShatteredRaid.progression
    assert_equal false, $game_switches[21]
  end

  def test_battle_exception_releases_guard_and_preserves_retry
    WildBattle.callback = proc { raise "battle failed" }
    assert_raises(RuntimeError) { ShatteredRaid.trigger(0, runtime_config) }
    assert_equal 0, ShatteredRaid.progression
    WildBattle.callback = nil
    assert ShatteredRaid.trigger(0, runtime_config)
    assert_equal 1, ShatteredRaid.progression
  end

  def test_reentrant_and_parallel_triggers_cannot_stack_battles
    nested_results = []
    WildBattle.callback = proc do
      nested_results << ShatteredRaid.trigger(0, runtime_config)
      sleep 0.05
      $game_variables[7] = 1
    end
    thread = Thread.new { ShatteredRaid.trigger(0, runtime_config) }
    sleep 0.01 until WildBattle.calls.length == 1
    refute ShatteredRaid.trigger(0, runtime_config)
    assert thread.value
    assert_equal [false], nested_results
    assert_equal 1, WildBattle.calls.length
  end

  def test_three_sequential_wins_complete_exactly_once
    3.times do |index|
      assert ShatteredRaid.trigger(index, runtime_config)
      assert_equal index + 1, ShatteredRaid.progression
    end
    assert ShatteredRaid.state["completed"]
    refute ShatteredRaid.trigger(2, runtime_config)
    assert_equal 3, WildBattle.calls.length
  end

  def test_missing_human_or_compiled_beedrill_prevents_battle
    $player.party.clear
    refute ShatteredRaid.trigger(0, runtime_config)
    assert_empty WildBattle.calls
    $player.party << Struct.new(:species).new(:HUMAN)
    GameData::Species.species = [:HUMAN]
    refute ShatteredRaid.trigger(0, runtime_config)
    assert_empty WildBattle.calls
  end

  def test_invalid_saved_state_is_rejected
    $PokemonGlobal.instance_variable_set(:@shattered_raid_state,
      { "version" => 99, "progression" => 3, "completed" => true })
    assert_raises(ShatteredRaid::ConfigurationError) { ShatteredRaid.progression }
    assert_empty WildBattle.calls
  end

  def test_save_restore_and_map_reload_resynchronize_event_switches
    assert ShatteredRaid.trigger(0, runtime_config)
    $PokemonGlobal = Marshal.load(Marshal.dump($PokemonGlobal))
    $game_switches[21] = false
    $game_switches[22] = true
    handler = EventHandlers.handler(:on_game_map_setup, :shattered_raid_switch_sync)
    assert handler.call(301, nil, nil)
    assert_equal [true, false, false], switch_values
    assert_equal 1, ShatteredRaid.progression
  end

  def test_installs_native_events_and_is_idempotent
    with_staged_map do |root, config, original|
      assert_equal :installed, ShatteredRaid.install_staged(root, config, passability)
      installed_bytes = File.open(map_path(root, 301), "rb") { |file| file.read }
      assert_equal original, File.open(map_path(root, 301) + ".shattered-raid.bak", "rb") { |file| file.read }
      installed = Marshal.load(installed_bytes)
      assert_equal 6, installed.events.length
      raid_events = installed.events.values.select { |event| event.name.to_s.include?("ShatteredRaid:BEEDRILL:") }
      assert_equal 3, raid_events.length
      assert_equal 355, raid_events[0].pages[0].list[0].code
      assert_match(/ShatteredRaid\.trigger\(0, /, raid_events[0].pages[0].list[0].parameters[0])
      assert raid_events[0].pages[1].condition.switch1_valid
      raid_events.each do |event|
        active, cleared = event.pages
        assert_equal 0, active.trigger
        refute active.through
        refute active.always_on_top
        assert cleared.through, "cleared Beedrill must not block player movement"
        refute cleared.always_on_top
        refute_respond_to active, :priority_type
        refute_respond_to cleared, :priority_type
      end
      assert_equal :already_installed, ShatteredRaid.install_staged(root, config, passability)
      assert_equal installed_bytes, File.open(map_path(root, 301), "rb") { |file| file.read }
    end
  end

  def test_installer_rejects_modified_installed_map_instead_of_overwriting
    with_staged_map do |root, config, _original|
      ShatteredRaid.install_staged(root, config, passability)
      path = map_path(root, 301)
      installed = Marshal.load(File.open(path, "rb") { |file| file.read })
      event = installed.events.values.find { |candidate| candidate.name == "ShatteredRaid:BEEDRILL:0" }
      event.pages[0].list[0].parameters[0] = "changed"
      File.open(path, "wb") { |file| file.write(Marshal.dump(installed)) }
      changed = File.open(path, "rb") { |file| file.read }
      assert_raises(ShatteredRaid::InstallationError) do
        ShatteredRaid.install_staged(root, config, passability)
      end
      assert_equal changed, File.open(path, "rb") { |file| file.read }
    end
  end

  def test_install_failure_after_replacement_rolls_back_every_write
    with_staged_map do |root, config, original|
      failure = proc { |stage| raise "injected install failure" if stage == :after_replace }
      assert_raises(RuntimeError) do
        ShatteredRaid.install_staged(root, config, passability, failure)
      end
      assert_equal original, File.open(map_path(root, 301), "rb") { |file| file.read }
      refute File.exist?(map_path(root, 301) + ".shattered-raid.bak")
      refute File.exist?(map_path(root, 301) + ".shattered-raid.tmp")
      refute File.exist?(map_path(root, 301) + ".shattered-raid.rollback")
    end
  end

  def test_install_failure_during_preflight_writes_nothing
    with_staged_map do |root, config, original|
      assert_raises(ShatteredRaid::InstallationError) do
        ShatteredRaid.install_staged(root, config, proc { |_map, _x, _y, _direction| false })
      end
      assert_equal original, File.open(map_path(root, 301), "rb") { |file| file.read }
      refute File.exist?(map_path(root, 301) + ".shattered-raid.bak")
    end
  end

  def test_install_refuses_occupied_tiles_before_writing
    with_staged_map do |root, config, _original|
      map = Marshal.load(File.open(map_path(root, 301), "rb") { |file| file.read })
      occupied = RPG::Event.new(config["events"][0]["x"], config["events"][0]["y"])
      occupied.id = 4
      map.events[occupied.id] = occupied
      original = Marshal.dump(map)
      File.open(map_path(root, 301), "wb") { |file| file.write(original) }
      config["expected_sha256"] = Digest::SHA256.hexdigest(original)
      assert_raises(ShatteredRaid::InstallationError) do
        ShatteredRaid.install_staged(root, config, passability)
      end
      assert_equal original, File.open(map_path(root, 301), "rb") { |file| file.read }
      refute File.exist?(map_path(root, 301) + ".shattered-raid.bak")
    end
  end

  def test_installer_rejects_dangling_sidecar_symlinks_without_following_them
    with_staged_map do |root, config, original|
      temp = map_path(root, 301) + ".shattered-raid.tmp"
      outside = File.join(root, "outside-write")
      File.symlink(outside, temp)
      assert_raises(ShatteredRaid::InstallationError) do
        ShatteredRaid.install_staged(root, config, passability)
      end
      refute File.exist?(outside)
      assert_equal original, File.open(map_path(root, 301), "rb") { |file| file.read }
    end
  end

  def test_install_refuses_unreviewed_roles_missing_sprites_and_stale_backups
    with_staged_map do |root, config, original|
      config["events"][0]["role_reviewed"] = false
      assert_raises(ShatteredRaid::ConfigurationError) do
        ShatteredRaid.install_staged(root, config, passability)
      end
      config["events"][0]["role_reviewed"] = true
      config["events"][0]["source_anchor_reviewed"] = false
      assert_raises(ShatteredRaid::ConfigurationError) do
        ShatteredRaid.install_staged(root, config, passability)
      end
      config["events"][0]["source_anchor_reviewed"] = true
      File.delete(File.join(root, "Graphics", "Characters", "BeedrillRaid1.png"))
      assert_raises(ShatteredRaid::InstallationError) do
        ShatteredRaid.install_staged(root, config, passability)
      end
      backup_path = map_path(root, 301) + ".shattered-raid.bak"
      File.open(backup_path, "wb") { |file| file.write("stale") }
      assert_raises(ShatteredRaid::InstallationError) do
        ShatteredRaid.install_staged(root, config, passability)
      end
      File.delete(backup_path)
      File.open(backup_path + ".tmp", "wb") { |file| file.write("stale") }
      assert_raises(ShatteredRaid::InstallationError) do
        ShatteredRaid.install_staged(root, config, passability)
      end
      assert_equal original, File.open(map_path(root, 301), "rb") { |file| file.read }
    end
  end

  def test_installer_requires_staging_marker_and_exact_dimensions
    with_staged_map do |root, config, _original|
      File.delete(File.join(root, "SHATTERED_STAGING_REPORT.json"))
      assert_raises(ShatteredRaid::InstallationError) do
        ShatteredRaid.install_staged(root, config, passability)
      end
    end
    with_staged_map do |root, config, _original|
      config["width"] = 47
      assert_raises(ShatteredRaid::ConfigurationError) do
        ShatteredRaid.install_staged(root, config, passability)
      end
    end
  end

  private

  def runtime_config
    {
      "map_id" => 301,
      "outcome_variable_id" => 7,
      "events" => [
        { "index" => 0, "level" => 5, "switch_id" => 21 },
        { "index" => 1, "level" => 6, "switch_id" => 22 },
        { "index" => 2, "level" => 7, "switch_id" => 23 }
      ]
    }
  end

  def switch_values
    [21, 22, 23].map { |switch_id| $game_switches[switch_id] }
  end

  def passability
    proc { |_map, _x, _y, _direction| true }
  end

  def map_path(root, map_id)
    File.join(root, "Data", "Map%03d.rxdata" % map_id)
  end

  def with_staged_map
    Dir.mktmpdir("shattered-raid-test-") do |root|
      FileUtils.mkdir_p(File.join(root, "Data"))
      FileUtils.mkdir_p(File.join(root, "Graphics", "Characters"))
      FileUtils.mkdir_p(File.join(root, "Plugins", "Shattered Core"))
      File.open(File.join(root, "Plugins", "Shattered Core", "001_Core.rb"), "wb") { |file| file.write("stub") }
      File.open(File.join(root, "SHATTERED_STAGING_REPORT.json"), "wb") do |file|
        file.write('{"engine": "Essentials 21.1"}')
      end
      3.times do |index|
        File.open(File.join(root, "Graphics", "Characters", "BeedrillRaid#{index + 1}.png"), "wb") do |file|
          file.write("test sprite")
        end
      end
      map = RPG::Map.new(48, 40)
      3.times do |index|
        anchor = RPG::Event.new(index + 1, 1)
        anchor.id = index + 1
        anchor.name = "reviewed source anchor #{index + 1}"
        map.events[anchor.id] = anchor
      end
      original = Marshal.dump(map)
      File.open(map_path(root, 301), "wb") { |file| file.write(original) }
      config = {
        "reviewed" => true,
        "switches_reviewed" => true,
        "outcome_variable_reviewed" => true,
        "map_id" => 301,
        "expected_sha256" => Digest::SHA256.hexdigest(original),
        "width" => 48,
        "height" => 40,
        "outcome_variable_id" => 7,
        "events" => 3.times.map do |index|
          {
            "index" => index,
            "role" => "beedrill_threat_#{index + 1}",
            "role_reviewed" => true,
            "source_anchor_event_id" => index + 1,
            "source_anchor_reviewed" => true,
            "x" => 10 + index * 2,
            "y" => 10,
            "level" => 5 + index,
            "switch_id" => 21 + index,
            "sprite_name" => "BeedrillRaid#{index + 1}",
            "sprite_hue" => 0
          }
        end
      }
      yield root, config, original
    end
  end
end
