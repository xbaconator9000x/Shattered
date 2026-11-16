require 'minitest/autorun'
require 'ostruct'

module Shattered
  def self.human?(pokemon); pokemon.species == :HUMAN; end
end
module ShatteredViridianQuest
  def self.state; {stage: $chapter_stage}; end
  def self.say(lines); lines.each { |line| pbMessage(line) }; end
end
module ShatteredViridianNightRaid
  def self.state; {stage: $night_stage}; end
end
def pbMessage(text, commands = nil, _cancel = nil)
  $messages << text
  commands ? $choices.shift : nil
end
def pbConfirmMessage(_text); $confirm; end
def pbLearnMove(pokemon, move)
  $learn_calls += 1
  pokemon.moves << OpenStruct.new(id: move) if $learn_success
  true # Deliberately misleading: completion must inspect the real move slots.
end
def load_data(_path); $curriculum; end
require_relative '../essentials/Plugins/Shattered Viridian/004_Training'

class RenTrainingTest < Minitest::Test
  Q = ShatteredRenTraining
  class Bag
    attr_accessor :full
    attr_reader :items
    def initialize; @items = []; end
    def add(item, count)
      return false if full
      @items.concat([item] * count)
      true
    end
  end
  def setup
    $PokemonGlobal = Object.new
    $chapter_stage = :supplied
    $night_stage = :rested
    @human = OpenStruct.new(species: :HUMAN, egg?: false, level: 5, moves: [])
    $player = OpenStruct.new(party: [OpenStruct.new(species: :AIPOM, egg?: false, moves: []), @human])
    $bag = Bag.new
    $messages = []
    $confirm = true
    $learn_success = true
    $learn_calls = 0
    $curriculum = {'lesson' => ['Recovered lesson'], 'classes' => Array.new(171) { |i|
      {'name' => "Class #{i}", 'description' => 'Description', 'stats' => [1]*6,
       'types' => [9, 10], 'passives' => ['None'], 'moves' => [[1, 98, 'Quick Attack']]}
    }}
  end
  def reload
    $PokemonGlobal = Marshal.load(Marshal.dump($PokemonGlobal))
  end
  def test_full_bag_then_cancelled_learning_retries_without_duplicate_book
    $bag.full = true
    refute Q.run_lesson
    refute Q.state[:manual]
    assert_equal 0, $learn_calls
    $bag.full = false
    $learn_success = false
    refute Q.run_lesson
    assert Q.state[:manual]
    refute Q.state[:lesson]
    reload
    $learn_success = true
    assert Q.run_lesson
    assert Q.state[:lesson]
    assert_equal [:SHATTEREDTRAININGMANUAL], $bag.items
    reload
    assert Q.run_lesson
    assert_equal 2, $learn_calls
    assert_empty $player.party.first.moves
  end
  def test_declining_training_preserves_move_slots
    $confirm = false
    refute Q.run_lesson
    assert Q.state[:manual]
    refute Q.state[:lesson]
    assert_empty @human.moves
    assert_equal 0, $learn_calls
  end
  def test_prerequisite_and_missing_human
    $night_stage = :active
    refute Q.run_lesson
    assert_empty $bag.items
    $night_stage = :rested
    $chapter_stage = :supplies
    refute Q.run_lesson
    assert_empty $bag.items
    $chapter_stage = :supplied
    $player.party.delete(@human)
    refute Q.run_lesson
    assert_empty $bag.items
  end
  def test_known_move_is_not_taught_twice_and_corrupt_save_is_rejected
    @human.moves << OpenStruct.new(id: :QUICKATTACK)
    assert Q.run_lesson
    assert_equal 0, $learn_calls
    Q.state[:manual] = false
    assert_raises(RuntimeError) { Q.state }
  end
  def test_manual_navigation_reaches_final_class_and_cancels
    # Previous from the first page wraps to the last page (three classes).
    $choices = [7, 2, -1]
    assert Q.read_manual
    assert_includes $messages, 'Class 170'
    assert_includes $messages, 'Types: Human/Fire'
    assert_includes $messages, 'Lv1: Quick Attack'
    assert_match(/Training Manual/, $messages.first)
  end

  def test_manual_offers_the_real_specialisation_hook_at_level_30
    Object.const_set(:ShatteredGameplay, Module.new) unless defined?(ShatteredGameplay)
    ShatteredGameplay.singleton_class.class_eval do
      attr_accessor :offered_human
      define_method(:offer_specialisation!) { |pokemon| self.offered_human = pokemon; :FIREBREATHER }
    end
    @human.level = 30
    # Six classes, Next, Previous, specialisation, Close.
    $choices = [8, -1]
    assert Q.read_manual
    assert_same @human, ShatteredGameplay.offered_human
    assert_includes $messages, 'Your training path has been recorded. Your HUMAN stats and techniques now follow that discipline.'
  ensure
    ShatteredGameplay.offered_human = nil if defined?(ShatteredGameplay) && ShatteredGameplay.respond_to?(:offered_human=)
  end

  def test_manual_hides_specialisation_between_primary_and_advanced_levels
    Object.const_set(:ShatteredGameplay, Module.new) unless defined?(ShatteredGameplay)
    ShatteredGameplay.singleton_class.class_eval do
      define_method(:offer_specialisation!) { |_pokemon| raise 'should not be offered' }
      define_method(:class_id_for) { |_pokemon| 1 }
      define_method(:primary_choices) { |_pokemon| [] }
      define_method(:advanced_choices) { |_pokemon| [] }
    end
    @human.level = 40
    # Six classes, Next, Previous, Close.  There must be no specialisation
    # entry between the established primary discipline and level 55.
    $choices = [8]
    assert Q.read_manual
    refute_includes $messages, 'Your training path has been recorded. Your HUMAN stats and techniques now follow that discipline.'
  end
end
