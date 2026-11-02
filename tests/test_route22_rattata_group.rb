# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../scripts/install_private_route22_rattata_sprites'
load File.expand_path('../essentials/Plugins/Shattered Route22/001_Route22.rb', __dir__)

class Route22RattataGroupTest < Minitest::Test
  class Actor
    attr_reader :moves
    def initialize; @moves=[]; end
    def moveto(x,y); @moves << [:moveto,x,y]; end
    def move_right; @moves << [:right]; end
    def move_left; @moves << [:left]; end
  end
  class GameMap
    attr_accessor :map_id, :events
    def initialize(map_id,events);@map_id=map_id;@events=events;end
  end
  def setup
    $PokemonGlobal=Object.new
    $game_map=GameMap.new(16,(5..7).to_h{|id|[id,Actor.new]})
  end
  def teardown
    $PokemonGlobal=nil
    $game_map=nil
  end
  def test_scatter_moves_three_rattata_and_resets_each_retry
    assert ShatteredRoute22.scatter!
    assert_equal [[:moveto,31,17],[:right]],$game_map.events[5].moves
    assert_equal [[:moveto,31,18],[:left]],$game_map.events[6].moves
    assert_equal [[:moveto,32,18],[:right]],$game_map.events[7].moves
    assert ShatteredRoute22.scatter!
    assert_equal 4,$game_map.events[5].moves.length
  end
  def test_missing_actor_fails_before_moving_anyone
    $game_map.events.delete(7)
    assert_raises(RuntimeError){ShatteredRoute22.scatter!}
    assert_empty $game_map.events[5].moves
    assert_empty $game_map.events[6].moves
  end
  def test_wrong_map_rejected
    $game_map.map_id=10
    assert_raises(RuntimeError){ShatteredRoute22.scatter!}
  end
  def test_cleared_group_does_not_move
    ShatteredRoute22.state[:cleared]=true
    refute ShatteredRoute22.scatter!
    assert_empty $game_map.events[5].moves
  end
  def test_transform_creates_switch_hidden_events_without_changing_tiles
    map=fixture_map
    tiles=Marshal.dump(map.data)
    unrelated=[1,2].to_h{|id|[id,Marshal.dump(map.events[id])]}
    ShatteredRoute22Sprites.transform!(map)
    assert_equal (1..7).to_a,map.events.keys.sort
    assert_equal tiles,Marshal.dump(map.data)
    unrelated.each{|id,bytes|assert_equal bytes,Marshal.dump(map.events[id])}
    [5,6,7].each do |id|
      e=map.events[id]
      assert_equal 'Rattata',e.pages.first.graphic.character_name
      assert e.pages.first.through
      assert e.pages.last.condition.switch1_valid
      assert_equal 992,e.pages.last.condition.switch1_id
      assert_equal '',e.pages.last.graphic.character_name
    end
    assert_includes map.events[3].pages.first.list.first.parameters.first,'ShatteredRoute22.scatter!'
    assert_equal [12, ShatteredRoute22Sprites::WARP_NEW_CONDITION], map.events[4].pages.first.list.first.parameters
    assert_equal [0,10,25,20,2,0], map.events[4].pages.first.list[2].parameters
    assert_raises(RuntimeError){ShatteredRoute22Sprites.transform!(map)}
  end
  def test_transform_rejects_missing_encounter_without_changes
    map=fixture_map
    map.events[3].pages.first.list.first.parameters[0]='pbMessage("unrelated")'
    before=Marshal.dump(map)
    assert_raises(RuntimeError){ShatteredRoute22Sprites.transform!(map)}
    assert_equal before,Marshal.dump(map)
  end
  def test_rejects_unguarded_warp_without_mutating_native_map
    map = fixture_map
    map.events[4].pages.first.list.first.parameters[1] = 'true'
    before = Marshal.dump(map)
    assert_raises(RuntimeError) { ShatteredRoute22Sprites.transform!(map) }
    assert_equal before, Marshal.dump(map)
  end

  def test_rejects_warp_transfer_to_wrong_destination
    map = fixture_map
    map.events[4].pages.first.list[2].parameters[1] = 11
    before = Marshal.dump(map)
    assert_raises(RuntimeError) { ShatteredRoute22Sprites.transform!(map) }
    assert_equal before, Marshal.dump(map)
  end

  def fixture_map
    map=RPG::Map.allocate
    map.width=54;map.height=34;map.tileset_id=1
    count=54*34*3
    map.data=Table._load([3,54,34,3,count].pack('V5')+0.chr*(count*2))
    map.events={}
    {1=>[14,9],2=>[13,16],3=>[30,17],4=>[32,17]}.each do |id,(x,y)|
      event=RPG::Event.new(x,y);event.id=id
      if id==3
        event.pages.first.trigger=1
        event.pages.first.list=[RPG::EventCommand.new(355,0,['ShatteredRoute22.encounter(991, 992) || ShatteredRoute22.return_to_entry(16, 29, 17)']),RPG::EventCommand.new]
      end
      if id==4
        event.pages.first.trigger=1
        event.pages.first.list=[
          RPG::EventCommand.new(111,0,[12,ShatteredRoute22Sprites::WARP_OLD_CONDITION]),
          RPG::EventCommand.new(101,1,['The guards wave you towards the walled city.']),
          RPG::EventCommand.new(201,1,[0,10,25,20,2,0]),
          RPG::EventCommand.new(411,0,[]),
          RPG::EventCommand.new(355,1,['ShatteredRoute22.return_to_entry(16, 29, 17)']),
          RPG::EventCommand.new(412,0,[]),
          RPG::EventCommand.new(0,0,[])
        ]
      end
      map.events[id]=event
    end
    map
  end
end
