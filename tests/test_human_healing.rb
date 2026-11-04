# frozen_string_literal: true
# Exact pinned Essentials 21.1 full-heal API regression (synthetic native entry points).
require 'minitest/autorun'

class Pokemon
  attr_accessor :species, :level
  attr_reader :healed
  def initialize(species, level = 5)
    @species, @level, @healed = species, level, 0
  end
  def heal; @healed += 1; end
end

class Trainer
  attr_reader :party
  def initialize(party); @party = party; end
  def heal_party
    @party.each(&:heal)
    :native_heal_complete
  end
end

# Essentials 21.1 Interpreter#command_314 with MECHANICS_GENERATION=8
# calls pbEachPokemon directly instead of Trainer#heal_party.
class Interpreter
  def initialize(mode); @parameters = [mode]; end
  def command_314
    $player.party.each(&:heal) if @parameters[0] == 0
    true
  end
end

require_relative '../essentials/Plugins/Shattered Core/001_Core'

class ShatteredHumanHealingTest < Minitest::Test
  def setup
    @human = Pokemon.new(:HUMAN, 15)
    @companion = Pokemon.new(:RATTATA)
    $player = Trainer.new([@human, @companion])
    $PokemonGlobal = Object.new
    Shattered.restore_stamina(@human)
    assert Shattered.spend_stamina(@human, :SLASH)
    assert_equal Shattered.max_stamina(@human.level) - 3, Shattered.stamina(@human)
  end

  def teardown
    $player = nil
    $PokemonGlobal = nil
  end

  def test_native_trainer_heal_restores_stamina_and_original_return_value
    assert_equal :native_heal_complete, $player.heal_party
    assert_equal Shattered.max_stamina(@human.level), Shattered.stamina(@human)
    assert_equal 1, @human.healed
    assert_equal 1, @companion.healed
  end

  def test_gen8_interpreter_recover_all_restores_stamina
    assert_equal true, Interpreter.new(0).command_314
    assert_equal Shattered.max_stamina(@human.level), Shattered.stamina(@human)
    assert_equal 1, @human.healed
  end

  def test_other_interpreter_target_does_not_restore_stamina
    assert_equal true, Interpreter.new(1).command_314
    assert_equal Shattered.max_stamina(@human.level) - 3, Shattered.stamina(@human)
  end

  def test_healing_another_trainer_does_not_restore_player_stamina
    other = Trainer.new([Pokemon.new(:HUMAN)])
    assert_equal :native_heal_complete, other.heal_party
    assert_equal Shattered.max_stamina(@human.level) - 3, Shattered.stamina(@human)
  end

  def test_hooks_idempotent_and_do_not_restore_without_human
    assert Shattered.install_healing_hooks
    assert Shattered.install_healing_hooks
    $player.party.delete(@human)
    assert_equal :native_heal_complete, $player.heal_party
    assert_equal Shattered.max_stamina(@human.level) - 3, Shattered.stamina(@human)
  end

  def test_missing_save_metadata_does_not_crash_healing
    $PokemonGlobal = nil
    assert_equal :native_heal_complete, $player.heal_party
    assert_equal true, Interpreter.new(0).command_314
  end
end
