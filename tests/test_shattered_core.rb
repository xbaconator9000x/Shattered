require "minitest/autorun"
class Pokemon
  attr_accessor :species, :level, :name
  def initialize(species, level)
    @species, @level = species, level
  end
end
PlayerStub = Struct.new(:party)
load File.expand_path("../essentials/Plugins/Shattered Core/001_Core.rb", __dir__)
class ShatteredCoreTest < Minitest::Test
  def setup
    @player = PlayerStub.new([])
    @store = Object.new
  end
  def test_creates_human_only_once
    x = Shattered.ensure_human(@player, 5)
    assert_equal :HUMAN, x.species
    assert_equal "HUMAN", x.name
    assert_same x, Shattered.ensure_human(@player, 5)
    assert_equal 1, @player.party.size
  end
  def test_human_cannot_fill_full_party
    @player.party = Array.new(6) { Pokemon.new(:PIDGEY, 3) }
    assert_raises(ArgumentError) { Shattered.ensure_human(@player) }
  end
  def test_stamina_persists_and_tracks_costs
    h = Shattered.ensure_human(@player, 10)
    assert_equal 65, Shattered.restore_stamina(h, @store)
    assert Shattered.spend_stamina(h, :ROCKTHROW, @store)
    assert_equal 62, Shattered.stamina(h, @store)
    62.times { Shattered.spend_stamina(h, :POUND, @store) }
    refute Shattered.spend_stamina(h, :POUND, @store)
  end
  def test_friendship_without_pokeball
    p = Shattered.befriend(:AIPOM, 6, @player)
    assert_equal :AIPOM, p.species
    assert_equal 1, @player.party.length
    assert_raises(ArgumentError) { Shattered.befriend(:HUMAN, 5, @player) }
  end
  def test_equipment_contract
    assert_equal 6, Shattered::EQUIPMENT_SLOTS.length
    assert_includes Shattered::HUMAN_MATCHUPS[:immune], :GHOST
    assert_equal [30, 55], Shattered::SPECIALISATION_LEVELS
  end
end
