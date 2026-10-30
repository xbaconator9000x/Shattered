# frozen_string_literal: true
# Exercise the REAL merged Shattered Core v0.2.3 together with the equipment
# adapter, using narrow Essentials API doubles. This is NOT engine execution.
require "minitest/autorun"

module Effectiveness
  NORMAL_EFFECTIVE_MULTIPLIER = 2
end

class Pokemon
  MAX_MOVES = 4
  attr_accessor :species, :level, :moves, :name

  def initialize(species, level = 5, moves = [])
    @species, @level, @moves = species, level, moves
  end

  class Move
    attr_reader :id
    attr_accessor :pp

    def initialize(id, pp = 10)
      @id, @pp = id, pp
    end
  end
end

ItemRecord = Struct.new(:id)
module GameData
  class Item
    ITEMS = [:KNIFE, :BRAZIER, :SLING, :SPRAYGUN, :BUCKLER].each_with_object({}) do |id, result|
      result[id] = ItemRecord.new(id)
    end
    def self.try_get(id)
      ITEMS[id]
    end
  end

  class Move
    def self.exists?(id)
      [:POUND, :QUICKATTACK, :DEFENSECURL, :ROCKTHROW, :SLASH, :EMBER, :BUBBLE].include?(id)
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

    def pbCalcTypeMod(_move_type, _user, _target)
      Effectiveness::NORMAL_EFFECTIVE_MULTIPLIER
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

    def pbCanChooseMove?(move, _command_phase, _show_messages = true, _special_usage = false)
      move.pp > 0
    end

    def pbReducePP(move)
      return false if move.pp <= 0
      move.pp -= 1
      true
    end

    def pbReducePPOther(move)
      pbReducePP(move)
    end

    def pbTryUseMove(_choice, move, _special_usage, _skip_accuracy_check)
      return false unless pbCanChooseMove?(move, false, false)
      pbReducePP(move)
    end
  end
end

load File.expand_path("../essentials/Plugins/Shattered Core/001_Core.rb", __dir__)
load File.expand_path("../essentials/Plugins/Shattered Equipment/001_Equipment.rb", __dir__)

class EquipmentMergedCoreIntegrationTest < Minitest::Test
  def setup
    $PokemonGlobal = Object.new
    @human = Pokemon.new(:HUMAN, 5, [
      Pokemon::Move.new(:POUND),
      Pokemon::Move.new(:DEFENSECURL),
      Pokemon::Move.new(:QUICKATTACK),
      Pokemon::Move.new(:ROCKTHROW)
    ])
    @companion = Pokemon.new(:AIPOM, 5, [Pokemon::Move.new(:POUND)])
  end

  def test_equipment_grants_battle_only_move_with_real_core_single_stamina_debit
    assert ShatteredEquipment.equip(@human, :KNIFE)
    saved_moves = @human.moves.map(&:id)
    battler = Battle::Battler.new
    assert_equal :initialized, battler.pbInitPokemon(@human, 0)
    assert_equal 4, battler.moves.length
    slash = battler.moves.find { |move| move.id == :SLASH }
    refute_nil slash
    assert_equal saved_moves, @human.moves.map(&:id)
    assert Shattered.install_battle_hooks
    assert battler.pbCanChooseMove?(slash, true, false)
    assert battler.pbTryUseMove([nil, nil, slash], slash, false, false)
    assert_equal 57, Shattered.stamina(@human)
    assert_equal 10, slash.pp
    assert_equal saved_moves, @human.moves.map(&:id)

    # A second successful use spends exactly one more technique cost.
    assert battler.pbTryUseMove([nil, nil, slash], slash, false, false)
    assert_equal 54, Shattered.stamina(@human)
  end

  def test_exhaustion_blocks_equipment_move_without_touching_companion_pp
    assert ShatteredEquipment.equip(@human, :KNIFE)
    battler = Battle::Battler.new
    battler.pbInitPokemon(@human, 0)
    slash = battler.moves.find { |move| move.id == :SLASH }
    $PokemonGlobal.instance_variable_set(:@shattered_stamina, 0)
    refute battler.pbCanChooseMove?(slash, true, false)
    refute battler.pbTryUseMove([nil, nil, slash], slash, false, false)
    assert_equal 0, Shattered.stamina(@human)

    companion = Battle::Battler.new
    companion.pbInitPokemon(@companion, 1)
    pound = companion.moves.first
    assert companion.pbTryUseMove([nil, nil, pound], pound, false, false)
    assert_equal 9, pound.pp
    assert_equal 10, @companion.moves.first.pp
  end

  def test_core_human_type_hook_and_equipment_hook_coexist
    assert ShatteredEquipment.equip(@human, :KNIFE)
    battler = Battle::Battler.new
    battler.pbInitPokemon(@human, 0)
    assert Battle::Move.method_defined?(:shattered_core_original_pb_calc_type_mod)
    assert Battle::Battler.method_defined?(:shattered_equipment_original_pb_init_pokemon)
    target = Struct.new(:pokemon).new(@human)
    move = battler.moves.first
    assert_equal 0, move.pbCalcTypeMod(:GHOST, nil, target)
    assert_equal 1, move.pbCalcTypeMod(:DARK, nil, target)
    assert_equal 4, move.pbCalcTypeMod(:FIRE, nil, target)
    assert_equal 2, move.pbCalcTypeMod(:NORMAL, nil, target)
  end

  def test_save_roundtrip_and_unequip_do_not_persist_temporary_moves
    assert ShatteredEquipment.equip(@human, :KNIFE)
    battler = Battle::Battler.new
    battler.pbInitPokemon(@human, 0)
    assert_includes battler.moves.map(&:id), :SLASH
    reloaded = Marshal.load(Marshal.dump(@human))
    assert_equal :KNIFE, ShatteredEquipment.equipped_item(reloaded, :right_hand)
    refute_includes reloaded.moves.map(&:id), :SLASH
    assert ShatteredEquipment.unequip(reloaded, :right_hand)
    fresh = Battle::Battler.new
    fresh.pbInitPokemon(reloaded, 0)
    refute_includes fresh.moves.map(&:id), :SLASH
  end
end
