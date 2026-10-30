require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require "ostruct"
require "digest"

module RPG
  class Event
    attr_accessor :id, :name, :x, :y, :pages
    def initialize(x,y); @id=0; @name=""; @x=x; @y=y; @pages=[]; end
    class Page
      attr_accessor :trigger, :through, :always_on_top, :graphic, :list
      def initialize
        @trigger=0; @through=false; @always_on_top=false
        @graphic=OpenStruct.new(:character_name=>""); @list=[]
      end
    end
  end
  class EventCommand
    attr_accessor :code, :indent, :parameters
    def initialize(code,indent,params); @code=code; @indent=indent; @parameters=params; end
  end
end
DojoMap = Struct.new(:width, :height, :events, :tileset_id, :data)
DojoTileset = Struct.new(:passages)
class DojoTileData
  attr_accessor :blocked
  def initialize; @blocked=[]; end
  def [](x,y,z)
    return 0 unless z == 0
    @blocked.include?([x,y]) ? 385 : 384
  end
end
class DojoPokemon
  attr_accessor :species, :level
  def initialize(species, level=5); @species=species; @level=level; end
end
module GameData
  module Species
    def self.exists?(species); [:VULPIX,:STARYU,:EXEGGCUTE].include?(species); end
  end
end
module Shattered
  def self.human?(pokemon); pokemon.species == :HUMAN; end
  def self.befriend(species,level,player)
    pokemon=DojoPokemon.new(species,level)
    player.party << pokemon
    pokemon
  end
end
def load_data(path); Marshal.load(File.binread(path)); end
def save_data(value,path); File.binwrite(path,Marshal.dump(value)); end
load File.expand_path("../essentials/Plugins/Shattered Dojo/001_Starter.rb",__dir__)
load File.expand_path("../essentials/Plugins/Shattered Dojo/002_Install.rb",__dir__)

class DojoStateTest < Minitest::Test
  def setup
    $PokemonGlobal=Object.new
    $player=OpenStruct.new(:party=>[DojoPokemon.new(:HUMAN)])
    @s=ShatteredDojo
  end
  def complete(answers=[0,1,2])
    answers.each_with_index { |answer,index| @s.answer!(index,answer) }
  end
  def test_append_only_and_save_restore
    assert @s.answer!(0,0)
    assert @s.answer!(0,0)
    refute @s.answer!(0,1)
    assert_raises(ShatteredDojo::InvalidState) { @s.answer!(2,1) }
    $PokemonGlobal=Marshal.load(Marshal.dump($PokemonGlobal))
    assert_equal [0],@s.state[:answers]
  end
  def test_deterministic_tie_break_and_choice_persists
    complete([0,1,2])
    assert_equal :VULPIX,@s.choice
    $PokemonGlobal=Marshal.load(Marshal.dump($PokemonGlobal))
    assert_equal :VULPIX,@s.choice
    assert_raises(ShatteredDojo::InvalidState) { @s.answer!(0,0) }
  end
  def test_unanimous_choice
    complete([1,1,1])
    assert_equal :STARYU,@s.choice
  end
  def test_cannot_award_without_questionnaire
    refute @s.recruit!
    assert_equal 1,$player.party.length
  end
  def test_one_award_and_marshal_roundtrip
    complete([2,2,2])
    starter=@s.recruit!
    assert_equal :EXEGGCUTE,starter.species
    assert @s.starter_tagged?(starter)
    assert_same starter,@s.recruit!
    assert_equal 2,$player.party.length
    $PokemonGlobal=Marshal.load(Marshal.dump($PokemonGlobal))
    $player=Marshal.load(Marshal.dump($player))
    assert_equal :EXEGGCUTE,@s.recruit!.species
    assert_equal 2,$player.party.length
  end
  def test_full_party_retry_preserves_choice
    complete([0,0,0])
    5.times { $player.party << DojoPokemon.new(:PIDGEY) }
    assert_equal false,@s.recruit!
    assert_equal :VULPIX,@s.choice
    $player.party.pop
    assert_equal :VULPIX,@s.recruit!.species
  end
  def test_unrelated_existing_species_is_not_adopted
    complete([0,0,0])
    $player.party << DojoPokemon.new(:VULPIX)
    assert_raises(ShatteredDojo::InvalidState) { @s.recruit! }
  end
  def test_interrupted_award_recovers_tagged_companion
    complete([1,1,1])
    tagged=DojoPokemon.new(:STARYU)
    tagged.instance_variable_set(:@shattered_dojo_starter_award,1)
    $player.party << tagged
    assert_same tagged,@s.recruit!
    assert @s.state[:recruited]
  end
  def test_recruited_starter_removed_does_not_duplicate
    complete([0,0,0])
    @s.recruit!
    $player.party.pop
    assert_raises(ShatteredDojo::MissingStarter) { @s.recruit! }
    assert_equal 1,$player.party.length
  end
  def test_corrupt_state_is_not_silently_reset
    $PokemonGlobal.instance_variable_set(:@shattered_dojo_starter,
      {:version=>99,:answers=>[],:choice=>nil,:recruited=>false})
    assert_raises(ShatteredDojo::InvalidState) { @s.state }
  end
end

class DojoInstallerTest < Minitest::Test
  def setup
    @dir=Dir.mktmpdir
    @old=Dir.pwd
    Dir.chdir(@dir)
    FileUtils.mkdir_p("Data")
    FileUtils.mkdir_p("Graphics/Characters")
    File.write("SHATTERED_STAGING_REPORT.json","{}")
    File.write("Graphics/Characters/Instructor.png","stub")
    save_data({45=>Object.new},"Data/MapInfos.rxdata")
    save_data(DojoMap.new(10,9,{},1,DojoTileData.new),"Data/Map045.rxdata")
    passage=Hash.new(0);passage[385]=15
    save_data([nil,DojoTileset.new(passage)],"Data/Tilesets.rxdata")
    @plan={
      "schema_version"=>1,
      "source_map_uuid"=>ShatteredDojo::SOURCE_MAP_UUID,
      "role_reviewed"=>true,
      "passability_reviewed"=>true,
      "dojo_map_id"=>45,
      "source_event_id"=>"5.2:npc:1",
      "source_position"=>[6,4],
      "native_map_reviewed"=>true,
      "native_map_dimensions"=>[10,9],
      "event_position"=>[6,4],
      "character"=>"Instructor",
      "expected_map_sha256"=>Digest::SHA256.file("Data/Map045.rxdata").hexdigest
    }
  end
  def teardown
    Dir.chdir(@old)
    FileUtils.remove_entry(@dir)
  end
  def test_install_creates_native_event_and_is_idempotent
    result=ShatteredDojo.install(@plan)
    assert_equal 1,result["installed"]
    map=load_data("Data/Map045.rxdata")
    event=map.events.values.first
    assert_equal [6,4],[event.x,event.y]
    assert_equal "SHATTERED_DOJO:questionnaire",event.name
    assert_equal 0,event.pages.first.trigger
    assert_equal 355,event.pages.first.list.first.code
    assert_equal ["ShatteredDojo.run_quiz"],event.pages.first.list.first.parameters
    assert_equal 1,ShatteredDojo.install(@plan)["unchanged"]
  end
  def test_unreviewed_role_and_wrong_source_anchor_fail
    @plan["role_reviewed"]=false
    assert_raises(ArgumentError) { ShatteredDojo.install(@plan) }
    @plan["role_reviewed"]=true
    @plan["source_position"]=[3,5]
    assert_raises(ArgumentError) { ShatteredDojo.install(@plan) }
  end
  def test_native_dojo_map_can_differ_from_rom_source_size_and_position
    map=DojoMap.new(20,12,{},1,DojoTileData.new)
    save_data(map,"Data/Map045.rxdata")
    @plan["expected_map_sha256"]=Digest::SHA256.file("Data/Map045.rxdata").hexdigest
    @plan["native_map_dimensions"]=[20,12]
    @plan["event_position"]=[10,6]
    assert_equal 1,ShatteredDojo.install(@plan)["installed"]
    event=load_data("Data/Map045.rxdata").events.values.first
    assert_equal [10,6],[event.x,event.y]
    assert_equal [6,4],@plan["source_position"]
  end
  def test_native_geometry_review_is_mandatory
    @plan["native_map_reviewed"]=false
    assert_raises(ArgumentError) { ShatteredDojo.install(@plan) }
    @plan["native_map_reviewed"]=true
    @plan["event_position"]=[10,6]
    assert_raises(ArgumentError) { ShatteredDojo.install(@plan) }
    @plan["event_position"]=[6,4]
    @plan["native_map_dimensions"]=[20,12]
    assert_raises(RuntimeError) { ShatteredDojo.install(@plan) }
  end
  def test_native_dojo_blocked_tile_refused_without_writing
    map=load_data("Data/Map045.rxdata")
    map.data.blocked << [6,4]
    save_data(map,"Data/Map045.rxdata")
    @plan["expected_map_sha256"]=Digest::SHA256.file("Data/Map045.rxdata").hexdigest
    before=File.binread("Data/Map045.rxdata")
    error=assert_raises(RuntimeError) { ShatteredDojo.install(@plan) }
    assert_match(/blocked or unverified/,error.message)
    assert_equal before,File.binread("Data/Map045.rxdata")
  end
  def test_missing_staging_or_sprite_fail_closed
    File.delete("SHATTERED_STAGING_REPORT.json")
    assert_raises(RuntimeError) { ShatteredDojo.install(@plan) }
    File.write("SHATTERED_STAGING_REPORT.json","{}")
    File.delete("Graphics/Characters/Instructor.png")
    assert_raises(RuntimeError) { ShatteredDojo.install(@plan) }
  end
  def test_occupied_tile_or_modified_map_refused
    map=load_data("Data/Map045.rxdata")
    event=RPG::Event.new(6,4); event.id=1; event.name="ORIGINAL"
    map.events[1]=event
    save_data(map,"Data/Map045.rxdata")
    assert_raises(RuntimeError) { ShatteredDojo.install(@plan) }
    map.events.clear
    other=RPG::Event.new(0,0); other.id=2; other.name="NONOVERLAPPING"
    map.events[2]=other
    save_data(map,"Data/Map045.rxdata")
    assert_raises(RuntimeError) { ShatteredDojo.install(@plan) }
  end
  def test_failed_replacement_restores_original_bytes
    before=File.binread("Data/Map045.rxdata")
    original=File.method(:rename)
    File.stub(:rename, lambda { |src,dst|
      raise IOError,"simulated failure" if src.end_with?(".shattered_dojo.tmp")
      original.call(src,dst)
    }) do
      assert_raises(IOError) { ShatteredDojo.install(@plan) }
    end
    assert_equal before,File.binread("Data/Map045.rxdata")
    refute File.exist?("Data/Map045.rxdata.shattered_dojo.bak")
  end
  def test_stale_backup_refused
    File.write("Data/Map045.rxdata.shattered_dojo.bak","recovery")
    assert_raises(RuntimeError) { ShatteredDojo.install(@plan) }
  end
  def test_metadata_is_essentials_format
    content=File.read(File.expand_path("../essentials/Plugins/Shattered Dojo/meta.txt",__dir__))
    assert_match(/\AName\s*=/,content)
    assert_match(/^Essentials\s*= 21\.1$/,content)
  end
end
