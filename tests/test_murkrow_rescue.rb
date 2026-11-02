require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"
require "json"
require "zlib"

class Pokemon
  attr_accessor :species, :level

  def initialize(species, level)
    @species, @level = species, level
  end
end

PlayerStub = Struct.new(:party) do
  attr_accessor :forced_able_count
  def able_pokemon_count
    forced_able_count.nil? ? party.length : forced_able_count
  end
end
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

      class Condition
        attr_accessor :self_switch_valid, :self_switch_ch
        def initialize
          @self_switch_valid = false
          @self_switch_ch = "A"
        end
      end

      attr_accessor :trigger, :through, :always_on_top, :graphic, :list, :condition

      def initialize
        @graphic = Graphic.new
        @condition = Condition.new
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

MapStub = Struct.new(:width, :height, :events, :tileset_id, :data)
TilesetStub = Struct.new(:passages)
class TileTableStub
  def initialize(values = {})
    @values = values
  end
  def [](*point)
    @values.fetch(point, 0)
  end
end

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

# Match the actual v21.1 battle entry points and integer outcome contract.
class WildBattle
  def self.start_core(species, level)
    raise "Wrong Murkrow species" unless species == :MURKROW && level == 5
    raise "Wild battle was started without the no-capture rule" unless
      $battle_rules.include?("disablePokeBalls")
    result = $battle_results.shift
    raise "fixture battle interruption" if result == :raise
    result
  end
end

class TrainerBattle
  def self.start_core(*_arguments)
    result = $battle_results.shift
    raise "fixture battle interruption" if result == :raise
    result
  end
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

def murkrow_png_chunk(kind, payload)
  [payload.bytesize].pack("N") + kind + payload +
    [Zlib.crc32(kind + payload)].pack("N")
end

def valid_murkrow_png
  header = [128, 128, 8, 6, 0, 0, 0].pack("N2C5")
  row = "\x00".b * (1 + 128 * 4)
  "\x89PNG\r\n\x1a\n".b +
    murkrow_png_chunk("IHDR", header) +
    murkrow_png_chunk("IDAT", Zlib::Deflate.deflate(row * 128)) +
    murkrow_png_chunk("IEND", "".b)
end

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
    $game_map = nil
    $game_self_switches = nil
    $game_temp = nil
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

  def test_false_saved_quest_value_is_rejected_without_reset
    @store.instance_variable_set(ShatteredMurkrowRescue::STATE_IVAR, false)
    assert_raises(ShatteredMurkrowRescue::InvalidState) do
      ShatteredMurkrowRescue.state(@store)
    end
    assert_equal false, @store.instance_variable_get(ShatteredMurkrowRescue::STATE_IVAR)
    assert_equal 0, $reward_count
  end

  def test_inconsistent_murkrow_reward_flags_fail_closed_after_save_reload
    ShatteredMurkrowRescue.discover!(@store)
    ShatteredMurkrowRescue.begin_battle!(@store)
    ShatteredMurkrowRescue.finish_battle!(true, @store)
    saved = Marshal.load(Marshal.dump(@store))
    raw = saved.instance_variable_get(ShatteredMurkrowRescue::STATE_IVAR)
    raw[:flags][:reward_claimed] = true
    assert_raises(ShatteredMurkrowRescue::InvalidState) do
      ShatteredMurkrowRescue.state(saved)
    end
    assert_equal :befriending, raw[:stage]
    assert_equal 0, $reward_count
    raw[:flags][:reward_claimed] = false
    raw[:flags][:murkrow_recruited] = true
    raw[:flags][:battle_won] = false
    assert_raises(ShatteredMurkrowRescue::InvalidState) do
      ShatteredMurkrowRescue.state(saved)
    end
  end

  def test_save_stage_cannot_jump_ahead_of_authoritative_rescue_flags
    # A stale/malformed stage alone must not hide the native event, skip the
    # battle, recruit an unrelated Murkrow or claim the rescue reward.
    requirements = {
      :discovered => :discovered,
      :battle_pending => :discovered,
      :befriending => :battle_won,
      :recruited => :murkrow_recruited,
      :complete => :reward_claimed
    }
    requirements.each do |stage, missing|
      store = SaveStub.new
      value = ShatteredMurkrowRescue.state(store)
      value[:flags].keys.each { |flag| value[:flags][flag] = true }
      value[:flags][missing] = false
      value[:stage] = stage
      restored = Marshal.load(Marshal.dump(store))
      saved = restored.instance_variable_get(ShatteredMurkrowRescue::STATE_IVAR)
      assert_raises(ShatteredMurkrowRescue::InvalidState, "#{stage} without #{missing}") do
        ShatteredMurkrowRescue.state(restored)
      end
      assert_equal stage, saved[:stage]
      refute saved[:flags][missing]
    end

    store = SaveStub.new
    value = ShatteredMurkrowRescue.state(store)
    value[:stage] = :complete
    assert_raises(ShatteredMurkrowRescue::InvalidState) do
      ShatteredMurkrowRescue.state(Marshal.load(Marshal.dump(store)))
    end
    assert_equal 0, $reward_count
  end

  def test_undiscovered_stage_rejects_progress_flags_but_valid_retry_recovers
    store = SaveStub.new
    value = ShatteredMurkrowRescue.state(store)
    value[:flags][:discovered] = true
    assert_raises(ShatteredMurkrowRescue::InvalidState) do
      ShatteredMurkrowRescue.state(store)
    end

    store = SaveStub.new
    ShatteredMurkrowRescue.discover!(store)
    assert ShatteredMurkrowRescue.begin_battle!(store)
    restored = Marshal.load(Marshal.dump(store))
    assert_equal :discovered, ShatteredMurkrowRescue.state(restored)[:stage]
    assert ShatteredMurkrowRescue.begin_battle!(restored)
  end

  def test_recruitment_is_non_ball_and_idempotent
    ready_to_befriend
    friend = ShatteredMurkrowRescue.recruit!(@player, @store)
    assert_equal :MURKROW, friend.species
    assert_same friend, ShatteredMurkrowRescue.recruit!(@player, @store)
    assert_equal 1, @player.party.count { |pokemon| pokemon.species == :MURKROW }
    assert ShatteredMurkrowRescue.state(@store)[:flags][:murkrow_recruited]
  end

  def test_unrelated_murkrow_cannot_be_adopted_as_quest_reward
    ready_to_befriend
    existing = Pokemon.new(:MURKROW, 5)
    @player.party << existing
    assert_raises(ShatteredMurkrowRescue::InvalidState) do
      ShatteredMurkrowRescue.recruit!(@player, @store)
    end
    refute ShatteredMurkrowRescue.state(@store)[:flags][:murkrow_recruited]
    assert_equal :befriending, ShatteredMurkrowRescue.state(@store)[:stage]
    assert_equal 1, @player.party.count { |pokemon| pokemon.species == :MURKROW }
  end

  def test_tagged_murkrow_recovers_after_interrupted_save_without_duplication
    ready_to_befriend
    friend = Pokemon.new(:MURKROW, 5)
    friend.instance_variable_set(ShatteredMurkrowRescue::RECRUIT_TAG, ShatteredMurkrowRescue::VERSION)
    @player.party << friend
    restored = Marshal.load(Marshal.dump(@store))
    assert_same friend, ShatteredMurkrowRescue.recruit!(@player, restored)
    assert ShatteredMurkrowRescue.state(restored)[:flags][:murkrow_recruited]
    assert_equal :recruited, ShatteredMurkrowRescue.state(restored)[:stage]
    assert_equal 1, @player.party.count { |pokemon| pokemon.species == :MURKROW }
  end

  def test_missing_tagged_reward_does_not_adopt_an_unrelated_murkrow
    ready_to_befriend
    friend = ShatteredMurkrowRescue.recruit!(@player, @store)
    assert ShatteredMurkrowRescue.tagged_murkrow?(friend)
    @player.party.delete(friend)
    @player.party << Pokemon.new(:MURKROW, 5)
    assert_raises(ShatteredMurkrowRescue::InvalidState) do
      ShatteredMurkrowRescue.recruit!(@player, @store)
    end
    assert_equal :recruited, ShatteredMurkrowRescue.state(@store)[:stage]
  end

  def test_reward_requires_the_actual_tagged_rescue_companion
    ready_to_befriend
    friend = ShatteredMurkrowRescue.recruit!(@player, @store)
    reward = { "item" => "POTION", "quantity" => 1 }
    @player.party.delete(friend)
    @player.party << Pokemon.new(:MURKROW, 5)
    assert_raises(ShatteredMurkrowRescue::InvalidState) do
      ShatteredMurkrowRescue.claim_reward!(reward, @store)
    end
    assert_equal 0, $reward_count
    refute ShatteredMurkrowRescue.state(@store)[:flags][:reward_claimed]
    @player.party.pop
    @player.party << friend
    assert ShatteredMurkrowRescue.claim_reward!(reward, @store)
    assert_equal 1, $reward_count
    assert ShatteredMurkrowRescue.claim_reward!(reward, @store)
    assert_equal 1, $reward_count
  end

  def test_complete_native_event_recruits_and_rewards_once
    $confirm_results = [true, true]
    $battle_results = [1]

    assert ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal :complete, ShatteredMurkrowRescue.state(@store)[:stage]
    assert_equal 1, @player.party.count { |pokemon| pokemon.species == :MURKROW }
    assert_equal 1, $reward_count
    assert ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal 1, @player.party.count { |pokemon| pokemon.species == :MURKROW }
    assert_equal 1, $reward_count
  end

  def test_runtime_accepts_native_hash_without_json_or_base64_decode
    $confirm_results = [true, true]
    $battle_results = [1]
    assert ShatteredMurkrowRescue.run_event(JSON.parse(runtime_plan))
    assert_equal :complete, ShatteredMurkrowRescue.state(@store)[:stage]
    assert_equal 1, $reward_count
  end

  def test_failed_wild_rescue_restores_human_stamina_only_after_loss_or_draw
    human = @player.party.first
    [2, 5].each do |decision|
      @store.instance_variable_set(:@shattered_stamina, 0)
      $confirm_results = [true]
      $battle_results = [decision]
      refute ShatteredMurkrowRescue.run_event(runtime_plan)
      assert_equal Shattered.max_stamina(human.level), Shattered.stamina(human, @store)
      assert_equal :discovered, ShatteredMurkrowRescue.state(@store)[:stage]
    end
    [0, 3, 4].each do |decision|
      @store.instance_variable_set(:@shattered_stamina, 0)
      $confirm_results = [true]
      $battle_results = [decision]
      refute ShatteredMurkrowRescue.run_event(runtime_plan)
      assert_equal 0, Shattered.stamina(human, @store)
    end
  end

  def test_no_able_party_cannot_skip_murkrow_battle_as_victory
    # Essentials' real skip_battle helper returns 1 for a skipped wild
    # battle. An exhausted party cannot use that outcome to earn Murkrow.
    @player.forced_able_count = 0
    $confirm_results = [true]
    $battle_results = [1]
    refute ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal :discovered, ShatteredMurkrowRescue.state(@store)[:stage]
    refute ShatteredMurkrowRescue.state(@store)[:flags][:battle_won]
    assert_equal [1], $battle_results
    assert_empty $battle_rules
    assert_equal 0, $reward_count
    @player.forced_able_count = 1
    $confirm_results = [true, true]
    assert ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal :complete, ShatteredMurkrowRescue.state(@store)[:stage]
  end

  def test_wild_rescue_battle_enforces_no_pokeballs
    $confirm_results = [true, true]
    $battle_results = [1]
    assert ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal ["disablePokeBalls", "canLose"], $battle_rules
  end

  def test_failed_battle_rule_does_not_start_rescue_or_complete_it
    $confirm_results = [true]
    $battle_results = [1]
    $fail_battle_rule = true
    refute ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal :discovered, ShatteredMurkrowRescue.state(@store)[:stage]
    assert_empty $battle_rules
    assert_equal [1], $battle_results
    assert_equal 0, $reward_count
    assert_equal 1, @player.party.length
  end

  def test_murkrow_setup_failure_clears_queued_rules_and_preserves_retry
    temp = Object.new
    temp.instance_variable_set(:@clear_count, 0)
    temp.define_singleton_method(:clear_battle_rules) { @clear_count += 1 }
    temp.define_singleton_method(:clear_count) { @clear_count }
    $game_temp = temp
    $confirm_results = [true]
    $battle_results = [:raise]
    refute ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal 1, temp.clear_count
    assert_equal :discovered, ShatteredMurkrowRescue.state(@store)[:stage]
    refute ShatteredMurkrowRescue.state(@store)[:flags][:battle_won]
    $confirm_results = [true, true]
    $battle_results = [1]
    assert ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal 1, temp.clear_count, "successful battle should retain engine-owned rule lifecycle"
  end

  def test_event_battle_loss_or_abort_can_be_retried
    $confirm_results = [true, true, true]
    $battle_results = [2, :raise, 1]

    refute ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal :discovered, ShatteredMurkrowRescue.state(@store)[:stage]
    refute ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal :discovered, ShatteredMurkrowRescue.state(@store)[:stage]
    assert ShatteredMurkrowRescue.run_event(runtime_plan)
    assert_equal 1, @player.party.count { |pokemon| pokemon.species == :MURKROW }
  end

  def test_wild_rescue_does_not_mark_escape_capture_draw_or_abort_as_victory
    [0, 2, 3, 4, 5].each do |decision|
      setup
      $confirm_results = [true]
      $battle_results = [decision]
      refute ShatteredMurkrowRescue.run_event(runtime_plan),
        "Essentials outcome #{decision} incorrectly completed Murkrow battle"
      assert_equal :discovered, ShatteredMurkrowRescue.state(@store)[:stage]
      refute ShatteredMurkrowRescue.state(@store)[:flags][:battle_won]
      assert_equal 0, $reward_count
      assert_equal ["disablePokeBalls", "canLose"], $battle_rules
    end
  end

  def test_legacy_battle_hooks_are_rejected_before_event_execution
    ["pbWildBattle", "pbTrainerBattle", "WildBattle.start"].each do |hook|
      assert_raises(ArgumentError) do
        ShatteredMurkrowRescue.validate_battle!(
          "hook" => hook, "arguments" => [{ "symbol" => "MURKROW" }, 5])
      end
    end
  end

  def test_wild_rescue_cannot_replace_murkrow_with_another_species
    assert_raises(ArgumentError) do
      ShatteredMurkrowRescue.validate_battle!(
        "hook" => "WildBattle.start_core",
        "arguments" => [{ "symbol" => "PIKACHU" }, 5])
    end
  end

  def test_trainer_battle_core_requires_numeric_victory
    plan = JSON.parse(runtime_plan)
    plan["battle"] = {
      "hook" => "TrainerBattle.start_core",
      "arguments" => [{ "symbol" => "YOUNGSTER" }, "Test Trainer"]
    }
    $confirm_results = [true, true, true]
    $battle_results = [3, 1]
    refute ShatteredMurkrowRescue.run_event(JSON.generate(plan))
    assert_equal :discovered, ShatteredMurkrowRescue.state(@store)[:stage]
    assert ShatteredMurkrowRescue.run_event(JSON.generate(plan))
    assert_equal :complete, ShatteredMurkrowRescue.state(@store)[:stage]
    assert_empty $battle_rules
  end

  def test_murkrow_sprite_is_hash_pinned_and_structurally_checked_before_map_write
    with_staged_project do |root, plan|
      path = File.join(root, "Graphics/Characters/Murkrow.png")
      map_path = File.join(root, "Data/Map001.rxdata")
      original_map = File.binread(map_path)
      original_png = File.binread(path)
      assert ShatteredMurkrowRescue.validate_character_sheet!(
        path, plan["expected_character_sha256"])

      File.binwrite(path, original_png + "changed")
      assert_raises(RuntimeError) do
        Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) }
      end
      assert_equal original_map, File.binread(map_path)

      File.binwrite(path, "not a png")
      plan["expected_character_sha256"] = Digest::SHA256.file(path).hexdigest
      assert_raises(RuntimeError) do
        Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) }
      end
      assert_equal original_map, File.binread(map_path)

      damaged = original_png.dup
      damaged.setbyte(45, damaged.getbyte(45) ^ 0x01)
      File.binwrite(path, damaged)
      plan["expected_character_sha256"] = Digest::SHA256.file(path).hexdigest
      assert_raises(RuntimeError) do
        Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) }
      end
      assert_equal original_map, File.binread(map_path)

      File.binwrite(path, original_png)
      plan["expected_character_sha256"] = Digest::SHA256.file(path).hexdigest
      assert ShatteredMurkrowRescue.validate_character_sheet!(
        path, plan["expected_character_sha256"])
    end
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

  def test_installer_rejects_blocked_event_tile_without_writes
    with_staged_project do |root, plan|
      path = File.join(root, "Data/Tilesets.rxdata")
      File.binwrite(path, Marshal.dump([nil, TilesetStub.new({ 384 => 15 })]))
      plan["expected_tilesets_sha256"] = Digest::SHA256.file(path).hexdigest
      map_path = File.join(root, "Data/Map001.rxdata")
      original = File.binread(map_path)
      error = assert_raises(RuntimeError) do
        Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) }
      end
      assert_match(/event tile is blocked/, error.message)
      assert_equal original, File.binread(map_path)
    end
  end

  def test_installer_rejects_changed_native_tilesets
    with_staged_project do |root, plan|
      path = File.join(root, "Data/Tilesets.rxdata")
      File.binwrite(path, Marshal.dump([nil, TilesetStub.new({ 384 => 15 })]))
      error = assert_raises(RuntimeError) do
        Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) }
      end
      assert_match(/tileset data changed/, error.message)
    end
  end

  def test_installer_requires_open_adjacent_approach_tile
    with_staged_project do |root, plan|
      path = File.join(root, "Data/Map001.rxdata")
      map = load_data(path)
      map.data = TileTableStub.new({ [51, 16, 0] => 384 })
      save_data(map, path)
      plan["expected_map_sha256"] = Digest::SHA256.file(path).hexdigest
      error = assert_raises(RuntimeError) do
        Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) }
      end
      assert_match(/no open adjacent approach/, error.message)
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
      script = event.pages.first.list.first.parameters.first
      refute_match(/Base64|JSON/, script)
      assert_match(/"battle"\s*=>/, script)
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

  def test_native_murkrow_event_hides_only_after_saved_quest_completion
    with_staged_project do |_root, plan|
      event = ShatteredMurkrowRescue.build_event(plan)
      assert_equal 2, event.pages.length
      assert_equal "Murkrow", event.pages.first.graphic.character_name
      assert_includes event.pages.first.list.first.parameters.first,
        "sync_event_self_switch!($game_map.map_id, @event_id)"
      assert event.pages.last.condition.self_switch_valid
      assert_equal "A", event.pages.last.condition.self_switch_ch
      assert event.pages.last.through
      assert_nil event.pages.last.graphic.character_name

      live = Struct.new(:event).new(event)
      $game_map = Struct.new(:map_id, :events, :need_refresh).new(
        plan["target_map_id"], { plan["event_id"] => live }, false)
      $game_self_switches = Hash.new(false)
      key = [plan["target_map_id"], plan["event_id"], "A"]
      $game_self_switches[key] = true # stale switch must NOT bypass the rescue
      assert ShatteredMurkrowRescue.reconcile_current_map
      refute $game_self_switches[key]
      assert $game_map.need_refresh

      ShatteredMurkrowRescue.discover!
      ShatteredMurkrowRescue.begin_battle!
      ShatteredMurkrowRescue.finish_battle!(true)
      assert ShatteredMurkrowRescue.recruit!
      assert ShatteredMurkrowRescue.claim_reward!({ "item" => "POTION", "quantity" => 1 })
      $game_map.need_refresh = false
      assert ShatteredMurkrowRescue.reconcile_current_map
      assert $game_self_switches[key]
      assert $game_map.need_refresh

      $PokemonGlobal = Marshal.load(Marshal.dump($PokemonGlobal))
      $game_self_switches[key] = false # normal Continue may restore stale state
      $game_map.need_refresh = false
      assert ShatteredMurkrowRescue.reconcile_current_map
      assert $game_self_switches[key]
      assert $game_map.need_refresh
    end
  end

  def test_murkrow_reconcile_ignores_unrelated_maps_and_invalid_event_ids
    $game_self_switches = Hash.new(false)
    ordinary = RPG::Event.new(1, 1)
    ordinary.id = 5
    ordinary.name = "Other event"
    $game_map = Struct.new(:map_id, :events, :need_refresh).new(
      16, { 5 => Struct.new(:event).new(ordinary) }, false)
    $game_self_switches[[16, 5, "A"]] = true
    refute ShatteredMurkrowRescue.reconcile_current_map
    assert $game_self_switches[[16, 5, "A"]]
    refute $game_map.need_refresh
    assert_raises(ArgumentError) do
      ShatteredMurkrowRescue.sync_event_self_switch!(16, 0)
    end
    assert_raises(RuntimeError) do
      ShatteredMurkrowRescue.sync_event_self_switch!(16, 5)
    end
  end

  def test_native_murkrow_reinstall_ignores_encoding_tags_but_rejects_event_drift
    with_staged_project do |root, plan|
      path = File.join(root, "Data/Map001.rxdata")
      assert_equal 1, Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) }["installed"]
      map = load_data(path)
      event = map.events[plan["event_id"]]
      event.pages.first.condition.self_switch_ch = "A".dup.force_encoding(Encoding::BINARY)
      event.pages.first.graphic.character_name = "Murkrow".dup.force_encoding(Encoding::BINARY)
      save_data(map, path)
      assert_equal 1, Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) }["unchanged"]
      event.pages.first.graphic.character_name = "WrongSprite"
      save_data(map, path)
      assert_raises(RuntimeError) do
        Dir.chdir(root) { ShatteredMurkrowRescue.install(plan) }
      end
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
      "battle" => { "hook" => "WildBattle.start_core",
                    "arguments" => [{ "symbol" => "MURKROW" }, 5] },
      "reward" => { "item" => "POTION", "quantity" => 1 }
    )
  end

  def with_staged_project
    Dir.mktmpdir("shattered-murkrow") do |root|
      FileUtils.mkdir_p(File.join(root, "Data"))
      FileUtils.mkdir_p(File.join(root, "Graphics/Characters"))
      File.write(File.join(root, "SHATTERED_STAGING_REPORT.json"), "{}")
      File.binwrite(File.join(root, "Graphics/Characters/Murkrow.png"), valid_murkrow_png)
      warp = RPG::Event.new(1, 1)
      warp.id = 3
      warp.name = "Reviewed Route 22 transfer"
      page = RPG::Event::Page.new
      page.list = [RPG::EventCommand.new(201, 0, [0, 2, 3, 4, 2, 0])]
      warp.pages = [page]
      tiles = TileTableStub.new({ [51, 16, 0] => 384, [50, 16, 0] => 384 })
      source = MapStub.new(67, 36, { 3 => warp }, 1, tiles)
      destination = MapStub.new(10, 10, {}, 1, tiles)
      File.binwrite(File.join(root, "Data/Map001.rxdata"), Marshal.dump(source))
      File.binwrite(File.join(root, "Data/Map002.rxdata"), Marshal.dump(destination))
      File.binwrite(File.join(root, "Data/MapInfos.rxdata"), Marshal.dump({ 1 => :source, 2 => :destination }))
      File.binwrite(File.join(root, "Data/Tilesets.rxdata"),
                    Marshal.dump([nil, TilesetStub.new({ 384 => 0 })]))
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
        "expected_tilesets_sha256" => Digest::SHA256.file(
          File.join(root, "Data/Tilesets.rxdata")
        ).hexdigest,
        "character" => "Murkrow",
        "expected_character_sha256" => Digest::SHA256.file(
          File.join(root, "Graphics/Characters/Murkrow.png")
        ).hexdigest,
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
          "hook" => "WildBattle.start_core",
          "arguments" => [{ "symbol" => "MURKROW" }, 5]
        },
        "reward" => { "item" => "POTION", "quantity" => 1 }
      }
      yield root, plan
    end
  end
end
