require 'minitest/autorun'
require 'ostruct'

module Shattered
  def self.human?(pokemon); pokemon.species == :HUMAN; end
end
module ShatteredViridianQuest
  def self.state; {stage: $chapter_stage}; end
  def self.say(lines); lines.each { |line| pbMessage(line) }; end
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
    @human = OpenStruct.new(species: :HUMAN, egg?: false, moves: [])
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
    assert_match(/reference/, $messages.first)
  end
end
