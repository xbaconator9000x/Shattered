require "minitest/autorun"

class OpeningStore; end
class OpeningMap
  attr_reader :map_id
  def initialize(id) @map_id = id end
end

$messages = []
def _INTL(text, *args)
  args.empty? ? text : format(text, *args)
end
def pbMessage(text, *_args)
  $messages << text
  0
end

module ShatteredGateStory
  class << self
    attr_accessor :collapse_calls
    def run_collapse(sounds, roar)
      self.collapse_calls ||= []
      self.collapse_calls << [sounds, roar]
      true
    end
  end
end

module Shattered
  class << self
    attr_accessor :human_setup_calls
    def ensure_human
      self.human_setup_calls = (human_setup_calls || 0) + 1
    end
  end
end

load File.expand_path("../essentials/Plugins/Shattered Gate Story/002_Opening.rb", __dir__)

class ShatteredOpeningTest < Minitest::Test
  def setup
    $PokemonGlobal = OpeningStore.new
    $messages = []
    ShatteredGateStory.collapse_calls = []
    Shattered.human_setup_calls = 0
  end

  def test_native_gate_runs_mewtwo_once_and_persists_completion
    $game_map = OpeningMap.new(223)
    assert ShatteredOpening.run_if_pending
    assert_equal ShatteredOpening::MEWTWO_LINES + ["Twenty Five Years Later..."], $messages
    assert_equal 1, Shattered.human_setup_calls
    assert_equal 1, ShatteredGateStory.collapse_calls.length
    assert_equal :complete, ShatteredOpening.state[:phase]
    refute ShatteredOpening.run_if_pending
    assert_equal 1, ShatteredGateStory.collapse_calls.length
  end

  def test_android_gate_uses_the_same_opening_contract
    $game_map = OpeningMap.new(1)
    assert ShatteredOpening.run_if_pending
    assert_equal :complete, ShatteredOpening.state[:phase]
  end

  def test_non_gate_map_does_not_initialize_story_state
    $game_map = OpeningMap.new(16)
    refute ShatteredOpening.run_if_pending
    assert_nil $PokemonGlobal.instance_variable_get(:@shattered_opening)
  end
end
