require "minitest/autorun"

class Pokemon
  attr_accessor :species, :level, :name
  def initialize(species, level)
    @species, @level = species, level
  end
end

PlayerStub = Struct.new(:party)
MoveStub = Struct.new(:id, :name, :pp)

class BattleStub
  attr_reader :messages
  def initialize
    @messages = []
  end
  def pbDisplay(message)
    @messages << message
  end
  def pbDisplayPaused(message)
    @messages << message
  end
end

module SaveData
  class << self
    attr_accessor :next_player
    def load_new_game_values
      $player = @next_player
      :new_game
    end
    def load_all_values(save_data)
      $player = save_data[:player]
      :loaded
    end
  end
end

module EventHandlers
  @handlers = {}
  def self.add(event, key, callback)
    @handlers[event] ||= {}
    @handlers[event][key] = callback
  end
  def self.trigger(event, *args)
    (@handlers[event] || {}).each_value { |callback| callback.call(*args) }
  end
end

module GameData
  class ItemData
    attr_reader :id
    def initialize(id, poke_ball = false)
      @id, @poke_ball = id, poke_ball
    end
    def is_poke_ball?
      @poke_ball
    end
  end
  class Item
    @items = [ItemData.new(:POKEBALL, true), ItemData.new(:POTION)]
    def self.each
      @items.each { |item| yield item }
    end
  end
end

module ItemHandlers
  module CanUseInBattle
    @handlers = {}
    def self.add(item, handler)
      @handlers[item] = handler
    end
    def self.get(item)
      @handlers[item]
    end
    def self.trigger(item, *args)
      @handlers[item].call(item, *args)
    end
  end
end
ItemHandlers::CanUseInBattle.add(:POTION, proc { true })

module Battle
  class Battler
    attr_reader :base_try_calls, :battle
    attr_accessor :base_allowed, :base_result
    def initialize(pokemon)
      @pokemon = pokemon
      @battle = BattleStub.new
      @base_allowed = true
      @base_result = true
      @base_try_calls = 0
    end
    def pbCanChooseMove?(move, commandPhase, showMessages = true, specialUsage = false)
      @base_allowed
    end
    def pbReducePP(move)
      return false if move.pp == 0
      move.pp -= 1
      true
    end
    def pbTryUseMove(choice, move, specialUsage, skipAccuracyCheck)
      @base_try_calls += 1
      return false unless pbCanChooseMove?(move, false, true, specialUsage)
      return false if !specialUsage && !pbReducePP(move)
      @base_result
    end
  end
end

def _INTL(message, *args)
  message.gsub(/\{(\d+)\}/) { args[$1.to_i - 1].to_s }
end

load File.expand_path("../essentials/Plugins/Shattered Core/001_Core.rb", __dir__)

class ShatteredCoreTest < Minitest::Test
  def setup
    @player = PlayerStub.new([])
    @store = Object.new
    $PokemonGlobal = @store
    $player = @player
  end

  def begin_battle
    EventHandlers.trigger(:on_start_battle, Object.new)
  end

  def test_creates_one_true_human_and_reuses_it
    human = Shattered.ensure_human(@player, 5)
    assert_instance_of Pokemon, human
    assert_equal :HUMAN, human.species
    assert_equal "HUMAN", human.name
    assert_same human, Shattered.ensure_human(@player, 5)
    assert_equal [human], @player.party
  end

  def test_duplicate_humans_are_removed_without_losing_other_members
    first = Pokemon.new(:HUMAN, 5)
    other = Pokemon.new(:PIKACHU, 8)
    @player.party = [first, other, Pokemon.new(:HUMAN, 10)]
    assert_same first, Shattered.ensure_human(@player)
    assert_equal [first, other], @player.party
  end

  def test_full_party_without_human_returns_clear_error
    @player.party = Array.new(6) { Pokemon.new(:PIDGEY, 3) }
    error = assert_raises(ArgumentError) { Shattered.ensure_human(@player) }
    assert_match(/party full/, error.message)
  end

  def test_missing_player_returns_clear_error
    error = assert_raises(ArgumentError) { Shattered.ensure_human(nil) }
    assert_match(/player party unavailable/, error.message)
  end

  def test_new_game_lifecycle_adds_human
    SaveData.next_player = @player
    assert_equal :new_game, SaveData.load_new_game_values
    assert_equal 1, @player.party.length
    assert Shattered.human?(@player.party.first)
  end

  def test_load_lifecycle_restores_exactly_one_human
    human = Pokemon.new(:HUMAN, 7)
    @player.party = [Pokemon.new(:PIKACHU, 3), human, Pokemon.new(:HUMAN, 8)]
    assert_equal :loaded, SaveData.load_all_values(:player => @player)
    assert_equal [@player.party.first, human], @player.party
    assert_equal 1, @player.party.count { |pkmn| Shattered.human?(pkmn) }
  end

  def test_stamina_costs_exhaustion_and_unknown_moves
    human = Shattered.ensure_human(@player, 10)
    assert_equal 65, Shattered.restore_stamina(human, @store)
    assert Shattered.spend_stamina(human, :ROCKTHROW, @store)
    assert_equal 62, Shattered.stamina(human, @store)
    62.times { assert Shattered.spend_stamina(human, :POUND, @store) }
    refute Shattered.spend_stamina(human, :POUND, @store)
    assert_nil Shattered.stamina_cost(nil)
    assert_nil Shattered.stamina_cost(:NOT_A_MOVE)
    refute Shattered.can_spend_stamina?(human, :NOT_A_MOVE, @store)
    refute Shattered.spend_stamina(human, :NOT_A_MOVE, @store)
  end

  def test_level_scaled_cap_and_saved_stamina_survive_marshal_round_trip
    human = Shattered.ensure_human(@player, 20)
    Shattered.restore_stamina(human, @store)
    Shattered.spend_stamina(human, :EMBER, @store)
    restored_store = Marshal.load(Marshal.dump(@store))
    assert_equal 67, Shattered.stamina(human, restored_store)
    assert_equal 70, Shattered.max_stamina(20)
    assert_equal 100, Shattered.max_stamina(100)
  end

  def test_battle_move_spends_once_without_reducing_human_pp
    human = Shattered.ensure_human(@player, 10)
    Shattered.restore_stamina(human, @store)
    2.times { begin_battle }
    battler = Battle::Battler.new(human)
    move = MoveStub.new(:ROCKTHROW, "Rock Throw", 10)
    assert battler.pbCanChooseMove?(move, true, false)
    assert battler.pbTryUseMove([:UseMove, 0, move], move, false, false)
    assert_equal 62, Shattered.stamina(human, @store)
    assert_equal 10, move.pp
    assert_equal 1, battler.base_try_calls
  end

  def test_insufficient_stamina_refuses_human_move
    human = Shattered.ensure_human(@player, 5)
    Shattered.restore_stamina(human, @store)
    @store.instance_variable_set(:@shattered_stamina, 0)
    begin_battle
    battler = Battle::Battler.new(human)
    move = MoveStub.new(:ROCKTHROW, "Rock Throw", 10)
    refute battler.pbCanChooseMove?(move, true, true)
    refute battler.pbTryUseMove([:UseMove, 0, move], move, false, false)
    assert_equal 0, Shattered.stamina(human, @store)
    assert_equal 10, move.pp
    assert battler.battle.messages.any? { |message| message.include?("stamina") }
  end

  def test_unmapped_human_move_is_refused
    human = Shattered.ensure_human(@player, 5)
    Shattered.restore_stamina(human, @store)
    begin_battle
    battler = Battle::Battler.new(human)
    move = MoveStub.new(:UNMAPPED, "Unmapped", 10)
    refute battler.pbCanChooseMove?(move, true, false)
    refute battler.pbTryUseMove([:UseMove, 0, move], move, false, false)
    assert_equal 60, Shattered.stamina(human, @store)
    assert_equal 10, move.pp
  end

  def test_failed_or_fled_battle_does_not_spend_stamina
    human = Shattered.ensure_human(@player, 5)
    Shattered.restore_stamina(human, @store)
    begin_battle
    battler = Battle::Battler.new(human)
    battler.base_result = false
    move = MoveStub.new(:POUND, "Pound", 10)
    refute battler.pbTryUseMove([:UseMove, 0, move], move, false, false)
    current = Shattered.stamina(human, @store)
    assert_equal 60, current
    assert_equal current, Shattered.stamina(human, @store)
  end

  def test_normal_pokemon_retains_normal_pp_behavior
    pokemon = Pokemon.new(:PIKACHU, 5)
    Shattered.restore_stamina(Shattered.ensure_human(@player), @store)
    before = Shattered.stamina(@player.party.first, @store)
    begin_battle
    battler = Battle::Battler.new(pokemon)
    move = MoveStub.new(:QUICKATTACK, "Quick Attack", 10)
    assert battler.pbCanChooseMove?(move, true, false)
    assert battler.pbTryUseMove([:UseMove, 0, move], move, false, false)
    assert_equal 9, move.pp
    assert_equal before, Shattered.stamina(@player.party.first, @store)
  end

  def test_battle_capture_handler_blocks_balls_only
    begin_battle
    scene = BattleStub.new
    assert_equal false, ItemHandlers::CanUseInBattle.trigger(
      :POKEBALL, nil, nil, nil, true, nil, scene, true
    )
    assert_match(/Poké Balls/, scene.messages.first)
    assert_equal true, ItemHandlers::CanUseInBattle.trigger(
      :POTION, nil, nil, nil, true, nil, scene, true
    )
  end

  def test_befriending_grants_one_genuine_companion
    friend = Shattered.befriend(:AIPOM, 6, @player)
    assert_instance_of Pokemon, friend
    assert_same friend, Shattered.befriend(:AIPOM, 9, @player)
    assert_equal [friend], @player.party
    assert_raises(ArgumentError) { Shattered.befriend(:HUMAN, 5, @player) }
  end

  def test_befriending_respects_full_party
    @player.party = Array.new(6) { Pokemon.new(:PIDGEY, 3) }
    error = assert_raises(ArgumentError) { Shattered.befriend(:AIPOM, 5, @player) }
    assert_match(/party full/, error.message)
  end

  def test_healing_restores_current_level_cap
    human = Shattered.ensure_human(@player, 10)
    Shattered.restore_stamina(human, @store)
    Shattered.spend_stamina(human, :SLASH, @store)
    assert_equal 62, Shattered.stamina(human, @store)
    assert_equal 65, Shattered.restore_stamina(human, @store)
    assert_equal 65, Shattered.stamina(human, @store)
  end

  def test_equipment_contract
    assert_equal 6, Shattered::EQUIPMENT_SLOTS.length
    assert_includes Shattered::HUMAN_MATCHUPS[:immune], :GHOST
    assert_equal [30, 55], Shattered::SPECIALISATION_LEVELS
  end
end
