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

  def events
    @events ||= {}
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

# Register native callbacks before loading the plugin so they can be exercised
# without a full Essentials runtime.
module EventHandlers
  HANDLERS = {}
  def self.add(event, name, callback)
    HANDLERS[[event, name]] = callback
  end

  def self.trigger(event)
    HANDLERS.each { |(registered, _name), callback| callback.call if registered == event }
  end
end

load File.expand_path("../essentials/Plugins/Shattered Companion/001_Companion.rb", __dir__)

# Minimal contract of Essentials' native follower API. This is intentionally
# not a sprite mock: it proves the plugin asks the factory to own the event.
module RPG
  class Event
    Page = Struct.new(:through, :graphic)
    Graphic = Struct.new(:character_name)

    attr_accessor :id, :name
    attr_reader :pages

    def initialize(_x, _y)
      @pages = [Page.new(false, Graphic.new(nil))]
    end
  end
end

class Game_Event
  attr_reader :character_name, :source

  def initialize(_map_id, source, _map)
    @source = source
    @character_name = source.pages[0].graphic.character_name
  end
end

class RuntimeFollowers
  def initialize
    @followers = {}
  end

  def add_follower(event, name = nil, _common_event_id = nil)
    @followers[name] = event
  end

  def get_follower_by_name(name)
    @followers[name]
  end

  def remove_follower_by_name(name)
    @followers.delete(name)
  end
end

class RuntimeTemp
  attr_reader :followers

  def initialize
    @followers = RuntimeFollowers.new
  end
end

RuntimeAvatar = Struct.new(:x, :y)

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

  def test_player_step_refreshes_the_native_follower_after_a_party_swap
    old_temp, old_avatar, old_map, old_player = $game_temp, $game_player, $game_map, $player
    $game_temp = RuntimeTemp.new
    $game_player = RuntimeAvatar.new(8, 9)
    $game_map = TestMap.new(1)
    $player = TestPlayer.new(Pokemon.new(:HUMAN), Pokemon.new(:VULPIX))

    ShatteredCompanion.stub(:character_sheet_exists?, true) do
      EventHandlers.trigger(:on_player_step_taken)
      assert_equal "POKEMON_Vulpix", $game_temp.followers.get_follower_by_name(ShatteredCompanion::FOLLOWER_NAME).character_name
      $player.party[1] = Pokemon.new(:STARYU)
      EventHandlers.trigger(:on_player_step_taken)
    end
    assert_equal "POKEMON_Staryu", $game_temp.followers.get_follower_by_name(ShatteredCompanion::FOLLOWER_NAME).character_name
  ensure
    $game_temp, $game_player, $game_map, $player = old_temp, old_avatar, old_map, old_player
  end

  def test_native_follower_factory_receives_real_companion_event_only_with_sheet
    old_temp, old_player = $game_temp, $game_player
    $game_temp = RuntimeTemp.new
    $game_player = RuntimeAvatar.new(8, 9)
    map = TestMap.new(1)
    player = TestPlayer.new(Pokemon.new(:HUMAN), Pokemon.new(:VULPIX))

    ShatteredCompanion.stub(:character_sheet_exists?, true) do
      assert_equal :following, ShatteredCompanion.reconcile_runtime(map, player)
    end
    follower = $game_temp.followers.get_follower_by_name(ShatteredCompanion::FOLLOWER_NAME)
    refute_nil follower
    assert_equal "POKEMON_Vulpix", follower.character_name
    assert follower.source.pages[0].through

    player.party[1] = Pokemon.new(:STARYU)
    assert_equal :following, ShatteredCompanion.reconcile_runtime(map, player)
    assert_nil $game_temp.followers.get_follower_by_name(ShatteredCompanion::FOLLOWER_NAME)
  ensure
    $game_temp, $game_player = old_temp, old_player
  end
end
