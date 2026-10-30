require "minitest/autorun"

class Pokemon
  MAX_MOVES = 4
  attr_accessor :species, :moves

  def initialize(species, moves = [])
    @species, @moves = species, moves
  end

  class Move
    attr_reader :id
    attr_accessor :pp

    def initialize(id)
      @id, @pp = id, 10
    end
  end
end

ItemData = Struct.new(:id)

module GameData
  class Item
    ITEMS = [:KNIFE, :BRAZIER, :SLING, :SPRAYGUN, :BUCKLER,
             :HELMET, :ARMOR, :HANDWRAPS, :TROUSERS, :BOOTS,
             :EMBERHAT, :BUBBLEARMOR, :CURLGLOVE, :THROWBOOTS].each_with_object({}) do |id, result|
      result[id] = ItemData.new(id)
    end

    def self.try_get(id)
      ITEMS[id]
    end
  end

  class Move
    MOVE_IDS = [:POUND, :DEFENSECURL, :QUICKATTACK, :ROCKTHROW,
                :SLASH, :EMBER, :BUBBLE]

    def self.exists?(id)
      MOVE_IDS.include?(id)
    end
  end
end

module Shattered
  TECHNIQUE_COSTS = {
    :POUND => 1, :DEFENSECURL => 1, :QUICKATTACK => 2,
    :ROCKTHROW => 3, :SLASH => 3, :EMBER => 3, :BUBBLE => 3
  }.freeze

  class << self
    attr_accessor :stamina, :spend_count

    def human?(pokemon)
      pokemon && pokemon.species == :HUMAN
    end

    def stamina_cost(move_id)
      TECHNIQUE_COSTS[move_id]
    end

    def can_spend_stamina?(pokemon, move_id)
      human?(pokemon) && @stamina.to_i >= stamina_cost(move_id).to_i
    end

    def spend_stamina(pokemon, move_id)
      return false unless can_spend_stamina?(pokemon, move_id)
      @stamina -= stamina_cost(move_id)
      @spend_count += 1
      true
    end

    def install_battle_hooks
      true
    end
  end
end

module Battle
  class Move
    attr_reader :id
    attr_accessor :pp

    def initialize(move)
      @id, @pp = move.id, move.pp
    end

    def self.from_pokemon_move(_battle, move)
      new(move)
    end
  end

  class Battler
    attr_reader :moves, :battle, :pokemon

    def initialize
      @battle = Object.new
      @moves = []
    end

    def pbInitPokemon(pokemon, _party_index)
      @pokemon = pokemon
      @moves = pokemon.moves.map { |move| Battle::Move.from_pokemon_move(@battle, move) }
      :initialized
    end

    def shattered_core_original_pb_can_choose_move
      true
    end

    def shattered_core_original_pb_try_use_move
      true
    end

    def pbCanChooseMove?(move, *_args)
      !Shattered.human?(@pokemon) || Shattered.can_spend_stamina?(@pokemon, move.id)
    end

    def pbReducePP(move)
      return false if move.pp <= 0
      move.pp -= 1
      true
    end

    def pbTryUseMove(move)
      return false unless pbCanChooseMove?(move)
      if Shattered.human?(@pokemon)
        Shattered.spend_stamina(@pokemon, move.id)
      else
        pbReducePP(move)
      end
    end
  end
end

load File.expand_path("../essentials/Plugins/Shattered Equipment/001_Equipment.rb", __dir__)

class ShatteredEquipmentTest < Minitest::Test
  def setup
    Shattered.stamina = 60
    Shattered.spend_count = 0
    @human = Pokemon.new(:HUMAN, [
      Pokemon::Move.new(:POUND),
      Pokemon::Move.new(:DEFENSECURL),
      Pokemon::Move.new(:QUICKATTACK),
      Pokemon::Move.new(:ROCKTHROW)
    ])
    @companion = Pokemon.new(:AIPOM)
  end

  def test_slots_are_canonical_and_equipment_persists_by_slot
    assert_equal [:head, :torso, :left_hand, :right_hand, :legs, :feet],
                 ShatteredEquipment.slots
    assert ShatteredEquipment.equip(@human, :KNIFE)
    assert_equal :KNIFE, ShatteredEquipment.equipment(@human)[:right_hand]

    loaded_human = Marshal.load(Marshal.dump(@human))
    assert_equal ShatteredEquipment.equipment(@human),
                 ShatteredEquipment.equipment(loaded_human)
  end

  def test_all_slots_can_hold_native_gear
    [
      [:HELMET, :head], [:ARMOR, :torso], [:HANDWRAPS, :left_hand],
      [:KNIFE, :right_hand], [:TROUSERS, :legs], [:BOOTS, :feet]
    ].each do |item_id, slot|
      assert ShatteredEquipment.register_gear(item_id, slot) unless item_id == :KNIFE
      assert ShatteredEquipment.equip(@human, item_id)
    end
    assert_equal [:head, :torso, :left_hand, :right_hand, :legs, :feet],
                 ShatteredEquipment.equipment(@human).keys
    assert_equal 6, ShatteredEquipment.equipment(@human).values.compact.length
  end

  def test_invalid_missing_and_non_human_equipment_are_denied
    refute ShatteredEquipment.equip(@human, :UNKNOWN_ITEM)
    refute ShatteredEquipment.equip(@companion, :KNIFE)
    refute ShatteredEquipment.register_gear(:UNKNOWN_ITEM, :head)
    refute ShatteredEquipment.register_gear(:HELMET, :unknown)
    refute ShatteredEquipment.register_gear(:HELMET, :head, :UNKNOWN_MOVE)
  end

  def test_conflicts_and_replacement_are_explicit_and_safe
    assert ShatteredEquipment.equip(@human, :KNIFE)
    assert ShatteredEquipment.equip(@human, :SPRAYGUN)
    assert_equal :SPRAYGUN, ShatteredEquipment.equipped_item(@human, :right_hand)

    refute ShatteredEquipment.equip(@human, :SLING)
    assert ShatteredEquipment.unequip(@human, :right_hand)
    assert ShatteredEquipment.equip(@human, :SLING)
    assert_equal :SLING, ShatteredEquipment.equipped_item(@human, :right_hand)
    before = ShatteredEquipment.equipment(@human)
    refute ShatteredEquipment.equip(@human, :KNIFE)
    assert_equal before, ShatteredEquipment.equipment(@human)
    assert ShatteredEquipment.unequip(@human, :right_hand)
    refute ShatteredEquipment.equipped_item(@human, :left_hand)
  end

  def test_missing_move_data_denies_gear_and_stale_grants
    assert ShatteredEquipment.equip(@human, :KNIFE)
    original = GameData::Move::MOVE_IDS.dup
    GameData::Move.send(:remove_const, :MOVE_IDS)
    GameData::Move.const_set(:MOVE_IDS, original - [:SLASH])
    assert_empty ShatteredEquipment.granted_move_ids(@human)
    battler = Battle::Battler.new
    battler.pbInitPokemon(@human, 0)
    refute_includes battler.moves.map(&:id), :SLASH
  ensure
    GameData::Move.send(:remove_const, :MOVE_IDS)
    GameData::Move.const_set(:MOVE_IDS, original)
  end

  def test_battle_moves_are_temporary_deduplicated_and_only_added_to_human
    assert ShatteredEquipment.equip(@human, :KNIFE)
    original_party_moves = @human.moves.dup
    battler = Battle::Battler.new
    assert_equal :initialized, battler.pbInitPokemon(@human, 0)
    assert_equal 1, battler.moves.count { |move| move.id == :SLASH }
    assert_equal Pokemon::MAX_MOVES, battler.moves.length
    refute_includes battler.moves.map(&:id), :ROCKTHROW
    assert_equal original_party_moves, @human.moves
    assert_equal 0, Shattered.spend_count

    companion_battler = Battle::Battler.new
    companion_battler.pbInitPokemon(@companion, 1)
    refute_includes companion_battler.moves.map(&:id), :SLASH
  end

  def test_all_equipped_grants_fit_visible_battle_menu_capacity
    assert ShatteredEquipment.equip(@human, :KNIFE)
    [
      [:EMBERHAT, :head, :EMBER],
      [:BUBBLEARMOR, :torso, :BUBBLE],
      [:CURLGLOVE, :left_hand, :DEFENSECURL]
    ].each do |item_id, slot, move_id|
      assert ShatteredEquipment.register_gear(item_id, slot, move_id)
      assert ShatteredEquipment.equip(@human, item_id)
    end
    assert ShatteredEquipment.register_gear(:THROWBOOTS, :legs, :ROCKTHROW)
    refute ShatteredEquipment.equip(@human, :THROWBOOTS)

    battler = Battle::Battler.new
    battler.pbInitPokemon(@human, 0)
    assert_equal Pokemon::MAX_MOVES, battler.moves.length
    assert_equal [:EMBER, :BUBBLE, :DEFENSECURL, :SLASH],
                 ShatteredEquipment.granted_move_ids(@human)
    assert_includes battler.moves.map(&:id), :SLASH
    assert_includes battler.moves.map(&:id), :EMBER
    assert_includes battler.moves.map(&:id), :BUBBLE
    assert_includes battler.moves.map(&:id), :DEFENSECURL
  end

  def test_core_stamina_gate_handles_exhaustion_without_adapter_spending
    assert ShatteredEquipment.equip(@human, :KNIFE)
    battler = Battle::Battler.new
    battler.pbInitPokemon(@human, 0)
    slash = battler.moves.find { |move| move.id == :SLASH }
    assert battler.pbCanChooseMove?(slash, true, false)
    assert battler.pbTryUseMove(slash)
    assert_equal 57, Shattered.stamina
    assert_equal 1, Shattered.spend_count
    assert_equal 10, slash.pp
    Shattered.stamina = 0
    refute battler.pbCanChooseMove?(slash, true, false)
    refute battler.pbTryUseMove(slash)
    assert_equal 1, Shattered.spend_count
  end

  def test_companion_keeps_normal_pp_behavior
    @companion.moves = [Pokemon::Move.new(:POUND)]
    battler = Battle::Battler.new
    battler.pbInitPokemon(@companion, 0)
    move = battler.moves.first
    assert battler.pbTryUseMove(move)
    assert_equal 9, move.pp
    assert_equal 0, Shattered.spend_count
  end

  def test_unequipping_removes_grant_from_next_battler_initialization
    assert ShatteredEquipment.equip(@human, :KNIFE)
    battler = Battle::Battler.new
    battler.pbInitPokemon(@human, 0)
    assert_includes battler.moves.map(&:id), :SLASH

    assert ShatteredEquipment.unequip(@human, :right_hand)
    battler.pbInitPokemon(@human, 0)
    refute_includes battler.moves.map(&:id), :SLASH
  end

  def test_runtime_hook_reports_unavailable_api_without_raising
    klass = Class.new
    refute ShatteredEquipment.install_battle_hook(klass)
    assert_equal :unavailable, ShatteredEquipment.runtime_hook_status
  end

  def test_missing_core_stamina_api_fails_closed
    assert ShatteredEquipment.equip(@human, :KNIFE)
    original = Shattered.method(:stamina_cost)
    Shattered.singleton_class.remove_method(:stamina_cost)
    refute ShatteredEquipment.install_battle_hook
    battler = Battle::Battler.new
    battler.pbInitPokemon(@human, 0)
    refute_includes battler.moves.map(&:id), :SLASH
    assert_equal :unavailable, ShatteredEquipment.runtime_hook_status
  ensure
    Shattered.define_singleton_method(:stamina_cost, original)
    ShatteredEquipment.install_battle_hook
  end
end
