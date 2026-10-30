require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"
require "json"

class Pokemon
  attr_accessor :species, :level

  def initialize(species, level)
    @species, @level = species, level
  end
end

PlayerStub = Struct.new(:party)
SaveStub = Class.new

load File.expand_path("../essentials/Plugins/Shattered Core/001_Core.rb", __dir__)

module RPG
  class Event
    attr_accessor :id, :x, :y, :name, :pages

    def initialize(x, y)
      @x, @y = x, y
    end

    class Page
      class Graphic
        attr_accessor :character_name
      end

      attr_accessor :trigger, :through, :always_on_top, :graphic, :list

      def initialize
        @graphic = Graphic.new
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

MapStub = Struct.new(:width, :height, :events)

def load_data(path)
  Marshal.load(File.binread(path))
end

def save_data(data, path)
  raise IOError, "fixture write failure" if $fail_map_save
  File.binwrite(path, Marshal.dump(data))
end

def pbMessage(_message)
  true
end

def pbConfirmMessage(_message)
  $confirm_results.empty? ? true : $confirm_results.shift
end

def pbWildBattle(*_arguments)
  raise "Wild battle was started without the no-capture rule" unless
    $battle_rules.include?("disablePokeBalls")
  result = $battle_results.shift
  raise "fixture battle interruption" if result == :raise
  result
end

def pbTrainerBattle(*_arguments)
  result = $battle_results.shift
  raise "fixture battle interruption" if result == :raise
  result
end

def setBattleRule(rule)
  raise "fixture battle-rule failure" if $fail_battle_rule
  $battle_rules << rule
end

def pbReceiveItem(_item, _quantity)
  $reward_count += 1
  true
end

load File.expand_path("../essentials/Plugins/Shattered Murkrow Rescue/001_Quest.rb", __dir__)
load File.expand_path("../essentials/Plugins/Shattered Murkrow Rescue/002_Install.rb", __dir__)

class MurkrowRescueTest < Minitest::Test
  def setup
    @store = SaveStub.new
    @player = PlayerStub.new([Pokemon.new(:HUMAN, 5)])
    $PokemonGlobal = @store
    $player = @player
    $battle_results = []
    $confirm_results = []
    $reward_count = 0
    $fail_map_save = false
    $battle_rules = []
    $fail_battle_rule = false
  end

  def test_loss_flee_and_interruption_leave_encounter_retryable
    ShatteredMurkrowRescue.discover!(@store)
    assert ShatteredMurkrowRescue.begin_battle!(@store)
    refute ShatteredMurkrowRescue.finish_battle!(false, @store)
    assert_equal :discovered, ShatteredMurkrowRescue.state(@store)[:stage]

    assert ShatteredMurkrowRescue.begin_battle!(@store)
    restored = Marshal.load(Marshal.dump(@store))
    assert_equal :discovered, ShatteredMurkrowRescue.state(restored)[:stage]
    assert ShatteredMurkrowRescue.begin_battle!(restored)
    refute ShatteredMurkrowRescue.finish_battle!(:fled, restored)
    assert_equal :discovered, ShatteredMurkrowRescue.state(restored)[:stage]
  end

  def test_save_restore_preserves_discovery_and_rescue_flags
    ShatteredMurkrowRescue.discover!(@store)
    ShatteredMurkrowRescue.begin_battle!(@store)
    ShatteredMurkrowRescue.finish_battle!(true, @store)
    restored = Marshal.load(Marshal.dump(@store))

    value = ShatteredMurkrowRescue.state(restored)
    assert_equal :befriending, value[:stage]
    assert value[:flags][:discovered]
    assert value[:flags][:battle_won]
  end

  def test_recruitment_is_non_ball_and_idempotent
    ready_to_befriend
    friend = ShatteredMurkrowRescue.recruit!(@player, @store)
    assert_equal :MURKROW, friend.species
    assert_same friend, ShatteredMurkrowRescue.recruit!(@player, @store)
    assert_equal 1, @player.party.count { |pokemon| pokemon.species == :MURKROW }
    assert ShatteredMurkrowRescue.state(@store)[:flags][:murkrow_recruited]
  end

  def test_existing_murkrow_is_not_duplicated_after_interrupted_recruitment
    ready_to_befriend
    existing = Pokemon.new(:MURKROW, 5)
    @player.party << existing

    assert_same existing, ShatteredMurkrowRescue.recruit!(@player, @store)
    assert_equal 1, @player.party.count { |pokemon| pokemon.species == :MURKROW }
  end

  def test_complete_native_event_recruits_and_rewards_once
    $confirm_results = [true, true]
    $battle_results = [true]

    assert ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal :complete, ShatteredMurkrowRescue.state(@store)[:stage]
    assert_equal 1, @player.party.count { |pokemon| pokemon.species == :MURKROW }
    assert_equal 1, $reward_count
    assert ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal 1, @player.party.count { |pokemon| pokemon.species == :MURKROW }
    assert_equal 1, $reward_count
  end

  def test_wild_rescue_battle_enforces_no_pokeballs
    $confirm_results = [true, true]
    $battle_results = [true]
    assert ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal ["disablePokeBalls"], $battle_rules
  end

  def test_failed_battle_rule_does_not_start_rescue_or_complete_it
    $confirm_results = [true]
    $battle_results = [true]
    $fail_battle_rule = true
    refute ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal :discovered, ShatteredMurkrowRescue.state(@store)[:stage]
    assert_empty $battle_rules
    assert_equal [true], $battle_results
    assert_equal 0, $reward_count
    assert_equal 1, @player.party.length
  end

  def test_event_battle_loss_or_abort_can_be_retried
    $confirm_results = [true, true, true]
    $battle_results = [false, :raise, true]

    refute ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal :discovered, ShatteredMurkrowRescue.state(@store)[:stage]
    refute ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal :discovered, ShatteredMurkrowRescue.state(@store)[:stage]
    assert ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal 1, @player.party.count { |pokemon| pokemon.species == :MURKROW }
  end

  def test_installer_rejects_unreviewed_or_mismatched_map_without_writes
    with_staged_project do |root, plan|
      plan["role_reviewed"] = false
      assert_raises(ArgumentError) { Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) } }
      assert_equal 1, Marshal.load(File.binread(File.join(root, "Data/Map001.rxdata"))).events.length

      plan["role_reviewed"] = true
      plan["target_map_size"] = [66, 36]
      assert_raises(RuntimeError) { Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) } }
      refute File.exist?(File.join(root, "Data/Map001.rxdata.shattered_murkrow.tmp"))
    end
  end

  def test_installer_rejects_occupied_event_location
    with_staged_project do |root, plan|
      map = load_data(File.join(root, "Data/Map001.rxdata"))
      occupied = RPG::Event.new(plan["target_position"][0], plan["target_position"][1])
      occupied.id = 12
      occupied.name = "Existing"
      map.events[12] = occupied
      save_data(map, File.join(root, "Data/Map001.rxdata"))
      plan["expected_map_sha256"] = Digest::SHA256.file(
        File.join(root, "Data/Map001.rxdata")
      ).hexdigest

      assert_raises(RuntimeError) { Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) } }
      assert_equal 2, load_data(File.join(root, "Data/Map001.rxdata")).events.length
    end
  end

  def test_installer_rejects_switch_and_variable_reservations
    with_staged_project do |root, plan|
      plan["switch_ids"] = [42]
      assert_raises(ArgumentError) { Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) } }
      plan["switch_ids"] = []
      plan["variable_ids"] = [17]
      assert_raises(ArgumentError) { Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) } }
      assert_equal 1, load_data(File.join(root, "Data/Map001.rxdata")).events.length
    end
  end

  def test_installer_rejects_changed_destination_warp
    with_staged_project do |root, plan|
      path = File.join(root, "Data/Map001.rxdata")
      map = load_data(path)
      map.events[3].pages.first.list.first.parameters[2] = 4
      save_data(map, path)
      plan["expected_map_sha256"] = Digest::SHA256.file(path).hexdigest

      assert_raises(RuntimeError) { Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) } }
      assert_equal 1, load_data(path).events.length
    end
  end

  def test_installer_rejects_occupied_event_id
    with_staged_project do |root, plan|
      map = load_data(File.join(root, "Data/Map001.rxdata"))
      occupied = RPG::Event.new(2, 2)
      occupied.id = plan["event_id"]
      occupied.name = "Existing"
      map.events[plan["event_id"]] = occupied
      path = File.join(root, "Data/Map001.rxdata")
      save_data(map, path)
      plan["expected_map_sha256"] = Digest::SHA256.file(path).hexdigest

      assert_raises(RuntimeError) { Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) } }
      assert_equal 2, load_data(path).events.length
    end
  end

  def test_installer_is_idempotent_and_builds_native_event_commands
    with_staged_project do |root, plan|
      result = Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) }
      assert_equal 1, result["installed"]
      again = Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) }
      assert_equal 1, again["unchanged"]

      map = load_data(File.join(root, "Data/Map001.rxdata"))
      event = map.events[plan["event_id"]]
      assert_equal plan["target_position"], [event.x, event.y]
      assert_equal 355, event.pages.first.list.first.code
      assert_match(/ShatteredMurkrowRescue\.run_event/, event.pages.first.list.first.parameters.first)
    end
  end

  def test_installer_rolls_back_when_staged_write_fails
    with_staged_project do |root, plan|
      path = File.join(root, "Data/Map001.rxdata")
      original = File.binread(path)
      $fail_map_save = true

      assert_raises(IOError) { Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) } }
      assert_equal original, File.binread(path)
      refute File.exist?(path + ".shattered_murkrow.tmp")
      refute File.exist?(path + ".shattered_murkrow.bak")
    end
  end

  def test_installer_restores_original_map_when_replace_fails
    with_staged_project do |root, plan|
      path = File.join(root, "Data/Map001.rxdata")
      original_bytes = File.binread(path)
      original_rename = File.method(:rename)
      rename_count = 0
      failing_rename = proc do |source, destination|
        rename_count += 1
        raise IOError, "fixture replace failure" if rename_count == 2
        original_rename.call(source, destination)
      end

      File.stub(:rename, failing_rename) do
        assert_raises(IOError) { Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) } }
      end
      assert_equal original_bytes, File.binread(path)
      refute File.exist?(path + ".shattered_murkrow.tmp")
      refute File.exist?(path + ".shattered_murkrow.bak")
    end
  end

  private

  def ready_to_befriend
    ShatteredMurkrowRescue.discover!(@store)
    ShatteredMurkrowRescue.begin_battle!(@store)
    ShatteredMurkrowRescue.finish_battle!(true, @store)
  end

  def runtime_plan
    JSON.generate(
      "battle" => { "hook" => "pbWildBattle",
                    "arguments" => [{ "symbol" => "PIKACHU" }, 5] },
      "reward" => { "item" => "POTION", "quantity" => 1 }
    )
  end

  def with_staged_project
    Dir.mktmpdir("shattered-murkrow") do |root|
      FileUtils.mkdir_p(File.join(root, "Data"))
      FileUtils.mkdir_p(File.join(root, "Graphics/Characters"))
      File.write(File.join(root, "SHATTERED_STAGING_REPORT.json"), "{}")
      File.write(File.join(root, "Graphics/Characters/Murkrow.png"), "fixture")
      warp = RPG::Event.new(1, 1)
      warp.id = 3
      warp.name = "Reviewed Route 22 transfer"
      page = RPG::Event::Page.new
      page.list = [RPG::EventCommand.new(201, 0, [0, 2, 3, 4, 2, 0])]
      warp.pages = [page]
      source = MapStub.new(67, 36, { 3 => warp })
      destination = MapStub.new(10, 10, {})
      File.binwrite(File.join(root, "Data/Map001.rxdata"), Marshal.dump(source))
      File.binwrite(File.join(root, "Data/Map002.rxdata"), Marshal.dump(destination))
      File.binwrite(File.join(root, "Data/MapInfos.rxdata"), Marshal.dump({ 1 => :source, 2 => :destination }))
      plan = {
        "schema_version" => 1,
        "source_map_uuid" => "491b8085-ec13-440e-9800-335edda8b08d",
        "source_map_size" => [67, 36],
        "source_event_id" => "28.5:npc:1",
        "source_position" => [51, 16],
        "reviewed_source_role" => "fixture-reviewed rescue anchor",
        "role_reviewed" => true,
        "location_reviewed" => true,
        "passability_reviewed" => true,
        "target_map_id" => 1,
        "target_map_size" => [67, 36],
        "target_position" => [51, 16],
        "event_id" => 9,
        "expected_map_sha256" => Digest::SHA256.file(
          File.join(root, "Data/Map001.rxdata")
        ).hexdigest,
        "character" => "Murkrow",
        "sprite_reviewed" => true,
        "switch_ids" => [],
        "variable_ids" => [],
        "battle_reviewed" => true,
        "reward_reviewed" => true,
        "destination_warp" => {
          "reviewed" => true,
          "event_id" => 3,
          "map_id" => 2,
          "x" => 3,
          "y" => 4
        },
        "battle" => {
          "hook" => "pbWildBattle",
          "arguments" => [{ "symbol" => "PIKACHU" }, 5]
        },
        "reward" => { "item" => "POTION", "quantity" => 1 }
      }
      yield root, plan
    end
  end
end
