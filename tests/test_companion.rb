require "minitest/autorun"

class Pokemon
  attr_reader :species

  def initialize(species, egg = false)
    @species = species
    @egg = egg
  end

  def egg?
    @egg
  end
end

class TestPlayer
  attr_accessor :party

  def initialize(*party)
    @party = party
  end
end

class TestMap
  attr_reader :map_id

  def initialize(map_id)
    @map_id = map_id
  end
end

MapMetadataRecord = Struct.new(:outdoor_map)

module GameData
  class MapMetadata
    RECORDS = {
      1 => MapMetadataRecord.new(true),
      2 => MapMetadataRecord.new(false)
    }.freeze

    def self.try_get(id)
      RECORDS[id]
    end
  end
end

module Shattered
  def self.human?(pokemon)
    pokemon && pokemon.species == :HUMAN
  end
end

load File.expand_path("../essentials/Plugins/Shattered Companion/001_Companion.rb", __dir__)

class ShatteredCompanionTest < Minitest::Test
  def test_first_non_human_partner_is_party_order_safe
    player = TestPlayer.new(Pokemon.new(:HUMAN), Pokemon.new(:VULPIX))
    assert_equal :VULPIX, ShatteredCompanion.partner(player).species

    reversed = TestPlayer.new(Pokemon.new(:VULPIX), Pokemon.new(:HUMAN))
    assert_equal :VULPIX, ShatteredCompanion.partner(reversed).species
  end

  def test_eggs_and_human_are_never_field_companions
    player = TestPlayer.new(Pokemon.new(:HUMAN), Pokemon.new(:VULPIX, true))
    assert_nil ShatteredCompanion.partner(player)
    assert_equal :none, ShatteredCompanion.mode(TestMap.new(1), player)
  end

  def test_normal_partner_follows_indoor_and_outdoor
    player = TestPlayer.new(Pokemon.new(:HUMAN), Pokemon.new(:STARYU))
    assert_equal :following, ShatteredCompanion.mode(TestMap.new(1), player)
    assert_equal :following, ShatteredCompanion.mode(TestMap.new(2), player)
  end

  def test_rideable_is_mounted_outdoors_and_hidden_indoors
    player = TestPlayer.new(Pokemon.new(:HUMAN), Pokemon.new(:ONIX))
    assert_equal :mounted, ShatteredCompanion.mode(TestMap.new(1), player)
    assert_equal :hidden, ShatteredCompanion.mode(TestMap.new(2), player)
  end

  def test_all_declared_mounts_use_same_policy
    [:ONIX, :CRYSTALONIX, :CRYSTALIX, :BULLGRUM].each do |species|
      player = TestPlayer.new(Pokemon.new(:HUMAN), Pokemon.new(species))
      assert ShatteredCompanion.rideable?(ShatteredCompanion.partner(player))
      assert_equal :mounted, ShatteredCompanion.mode(TestMap.new(1), player)
      assert_equal :hidden, ShatteredCompanion.mode(TestMap.new(2), player)
    end
  end

  def test_legacy_multi_partner_party_is_detected_not_silently_reordered
    player = TestPlayer.new(Pokemon.new(:HUMAN), Pokemon.new(:VULPIX), Pokemon.new(:STARYU))
    refute ShatteredCompanion.valid_party?(player)
    assert_equal :VULPIX, ShatteredCompanion.partner(player).species
  end
end
