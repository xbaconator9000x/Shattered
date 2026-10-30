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
      attr_accessor :trigger, :through, :always_on_top, :list, :graphic, :condition
      def initialize
        @trigger=0; @through=false; @always_on_top=false; @list=[]
        @graphic=OpenStruct.new(:character_name=>"")
        @condition=OpenStruct.new(:switch1_valid=>false, :switch1_id=>1)
      end
    end
  end
  class EventCommand
    attr_accessor :code, :indent, :parameters
    def initialize(code,indent,parameters); @code=code; @indent=indent; @parameters=parameters; end
  end
  class MoveRoute
    attr_accessor :repeat, :skippable, :list
    def initialize; @repeat=true; @skippable=false; @list=[]; end
  end
  class MoveCommand
    attr_accessor :code, :parameters
    def initialize(code,parameters=[]); @code=code; @parameters=parameters; end
  end
end
ViridianMap = Struct.new(:width,:height,:events,:tileset_id,:data)
ViridianTileset = Struct.new(:passages)
class ViridianTileData
  attr_accessor :blocked
  def initialize; @blocked=[]; end
  def [](x,y,z)
    return 0 unless z==0
    @blocked.include?([x,y]) ? 385 : 384
  end
end
def load_data(path); Marshal.load(File.binread(path)); end
def save_data(value,path); File.binwrite(path, Marshal.dump(value)); end
load File.expand_path("../essentials/Plugins/Shattered Viridian/001_Entry.rb",__dir__)
load File.expand_path("../essentials/Plugins/Shattered Viridian/002_Install.rb",__dir__)

MovingNPC = Struct.new(:x,:y) do
  def moveto(x,y); self.x=x; self.y=y; end
end

class ViridianStateTest < Minitest::Test
  def setup
    $PokemonGlobal=Object.new
    $game_switches=Hash.new(false)
  end
  def test_state_survives_serialization_and_reconciles_switches
    assert ShatteredViridian.start!(101,104)
    refute ShatteredViridian.start!(101,104)
    assert ShatteredViridian.arrive!(102)
    refute ShatteredViridian.arrive!(102)
    $PokemonGlobal=Marshal.load(Marshal.dump($PokemonGlobal))
    $game_switches.clear
    value=ShatteredViridian.sync!(:started=>101,:arrived=>102,:center=>103,:rain=>104)
    assert value[:started]
    assert value[:arrived]
    assert $game_switches[101]
    assert $game_switches[102]
    assert $game_switches[104]
    refute $game_switches[103]
    assert ShatteredViridian.center!(103,104)
    refute ShatteredViridian.center!(103,104)
    refute $game_switches[104]
    $game_switches.clear
    ShatteredViridian.sync!(:started=>101,:arrived=>102,:center=>103,:rain=>104)
    assert $game_switches[103]
    refute $game_switches[104]
  end
  def test_arrival_and_center_cannot_precede_entry
    refute ShatteredViridian.arrive!(102)
    refute ShatteredViridian.center!(103,104)
    refute $game_switches[102]
    refute $game_switches[103]
  end
  def test_escort_only_starts_when_both_npcs_reach_destination
    guard=MovingNPC.new(10,17)
    nidoran=MovingNPC.new(17,9)
    $game_map=OpenStruct.new(:events=>{11=>guard,12=>nidoran})
    refute ShatteredViridian.complete_route!(11,12,[9,16],[18,9],[10,17],[17,10],101,104)
    assert_equal [9,16],[guard.x,guard.y]
    assert_equal [18,9],[nidoran.x,nidoran.y]
    refute $game_switches[101]
    guard.moveto(10,17)
    nidoran.moveto(17,10)
    assert ShatteredViridian.complete_route!(11,12,[9,16],[18,9],[10,17],[17,10],101,104)
    assert $game_switches[101]
    assert $game_switches[104]
  end
  def test_corrupt_state_refuses_to_reset_and_duplicate_switches_rejected
    $PokemonGlobal.instance_variable_set(:@shattered_viridian_entry,{:version=>1,:started=>"yes",:arrived=>false,:center=>false})
    assert_raises(RuntimeError) { ShatteredViridian.start!(101,104) }
    $PokemonGlobal=Object.new
    assert_raises(ArgumentError) { ShatteredViridian.start!(101,101) }
    assert_raises(ArgumentError) { ShatteredViridian.sync!(:started=>101,:arrived=>101,:center=>103,:rain=>104) }
  end
end

class ViridianInstallerTest < Minitest::Test
  def setup
    @old=Dir.pwd
    @tmp=Dir.mktmpdir
    Dir.chdir(@tmp)
    FileUtils.mkdir_p(["Data","Graphics/Characters"])
    File.write("SHATTERED_STAGING_REPORT.json","{}")
    File.write("Graphics/Characters/Guard.png","local fixture")
    File.write("Graphics/Characters/Nidoran.png","local fixture")
    save_data({41=>true,42=>true},"Data/MapInfos.rxdata")
    save_data(ViridianMap.new(50,40,{},1,ViridianTileData.new),"Data/Map041.rxdata")
    save_data(ViridianMap.new(15,10,{},1,ViridianTileData.new),"Data/Map042.rxdata")
    passage=Hash.new(0); passage[385]=15
    save_data([nil,ViridianTileset.new(passage)],"Data/Tilesets.rxdata")
    @config={
      "schema_version"=>1,
      "source_map_uuid"=>ShatteredViridian::SOURCE_UUID,
      "roles_reviewed"=>true,
      "path_passability_reviewed"=>true,
      "city_map_id"=>41,"center_map_id"=>42,"native_city_dimensions"=>[50,40],"center_dimensions"=>[15,10],
      "native_entrance_reviewed"=>true,
      "expected_city_sha256"=>Digest::SHA256.file("Data/Map041.rxdata").hexdigest,
      "expected_center_sha256"=>Digest::SHA256.file("Data/Map042.rxdata").hexdigest,
      "guard"=>{"source_event_id"=>"3.1:npc:1","source_position"=>[9,16],"x"=>9,"y"=>16,"character"=>"Guard"},
      "nidoran"=>{"source_event_id"=>"3.1:npc:8","source_position"=>[18,9],"x"=>18,"y"=>9,"character"=>"Nidoran"},
      "guard_path"=>[[9,16],[10,16],[10,17]],
      "nidoran_path"=>[[18,9],[17,9],[17,10]],
      "entry_source_marker"=>[0,17],"entry_trigger"=>[2,17],
      "finish_trigger"=>[12,16],"rain_controller"=>[3,3],
      "center_trigger"=>[7,5],
      "switches"=>{"started"=>101,"arrived"=>102,"center"=>103,"rain"=>104}
    }
  end
  def teardown
    Dir.chdir(@old)
    FileUtils.remove_entry(@tmp)
  end
  def test_installs_six_events_and_idempotent_reinstall
    assert_equal 6, ShatteredViridian.install(@config)["installed"]
    city=load_data("Data/Map041.rxdata")
    center=load_data("Data/Map042.rxdata")
    assert_equal 5, city.events.size
    assert_equal 1, center.events.size
    entry=city.events.values.find { |e| e.name.end_with?(":entry") }
    assert_equal [2,2], entry.pages.map(&:trigger)
    refute entry.pages[0].through
    assert entry.pages[1].through
    assert city.events.values.find { |e| e.name.end_with?(":guard") }.pages[0].through == false
    assert entry.pages[0].list[1].parameters[1].skippable
    assert_match(/complete_route!/,entry.pages[0].list[4].parameters[0])
    finish=city.events.values.find { |e| e.name.end_with?(":finish") }
    refute finish.pages[1].through
    assert finish.pages[2].through
    assert_equal [236,209,209,210,355,0], entry.pages[0].list.map(&:code)
    assert_equal [1,6,20], entry.pages[0].list.first.parameters
    assert_equal [3,1,0], entry.pages[0].list[1].parameters[1].list.map(&:code)
    assert_equal [2,1,0], entry.pages[0].list[2].parameters[1].list.map(&:code)
    assert_equal 101, entry.pages[1].condition.switch1_id
    rain=city.events.values.find { |e| e.name.end_with?(":rain") }
    assert_equal 4, rain.pages[1].trigger
    assert_equal [236,106,0], rain.pages[1].list.map(&:code)
    center_event=center.events.values.first
    assert_equal [0,3,0], center_event.pages.map(&:trigger)
    assert_equal [236,355,0], center_event.pages[1].list.map(&:code)
    assert_equal [0,0,20], center_event.pages[1].list.first.parameters
    before=[File.binread("Data/Map041.rxdata"),File.binread("Data/Map042.rxdata")]
    assert_equal 6, ShatteredViridian.install(@config)["unchanged"]
    assert_equal before,[File.binread("Data/Map041.rxdata"),File.binread("Data/Map042.rxdata")]
    refute File.exist?("Data/Map041.rxdata.shattered_viridian.bak")
  end
  def test_source_anchor_or_role_review_cannot_be_faked
    @config["nidoran"]["source_position"]=[19,9]
    assert_raises(ArgumentError) { ShatteredViridian.install(@config) }
    @config["nidoran"]["source_position"]=[18,9]
    @config["roles_reviewed"]=false
    assert_raises(ArgumentError) { ShatteredViridian.install(@config) }
  end
  def test_native_50x40_coordinates_can_differ_from_48x40_source_anchors
    @config["guard"]["x"], @config["guard"]["y"] = 27, 20
    @config["nidoran"]["x"], @config["nidoran"]["y"] = 28, 21
    @config["guard_path"] = [[27,20],[28,20],[28,19]]
    @config["nidoran_path"] = [[28,21],[29,21],[29,20]]
    @config["entry_trigger"] = [25,20]
    @config["finish_trigger"] = [30,20]
    assert_equal 6, ShatteredViridian.install(@config)["installed"]
    city = load_data("Data/Map041.rxdata")
    assert_equal [50,40], [city.width,city.height]
    assert_equal [27,20], [city.events.values.find { |e| e.name.end_with?(":guard") }.x,
                           city.events.values.find { |e| e.name.end_with?(":guard") }.y]
  end
  def test_native_entrance_review_and_dimensions_are_required
    @config["native_entrance_reviewed"] = false
    assert_raises(ArgumentError) { ShatteredViridian.install(@config) }
    @config["native_entrance_reviewed"] = true
    @config["native_city_dimensions"] = [48,40]
    assert_raises(RuntimeError) { ShatteredViridian.install(@config) }
  end
  def test_bad_route_and_unreviewed_passability_rejected
    @config["guard_path"]=[[9,16],[12,16]]
    assert_raises(ArgumentError) { ShatteredViridian.install(@config) }
    @config["guard_path"]=[[9,16],[10,16]]
    @config["path_passability_reviewed"]=false
    assert_raises(ArgumentError) { ShatteredViridian.install(@config) }
  end
  def test_native_tile_collision_refuses_blocked_escort_path_without_writing
    city=load_data("Data/Map041.rxdata")
    city.data.blocked << [10,16]
    save_data(city,"Data/Map041.rxdata")
    @config["expected_city_sha256"]=Digest::SHA256.file("Data/Map041.rxdata").hexdigest
    before=[File.binread("Data/Map041.rxdata"),File.binread("Data/Map042.rxdata")]
    error=assert_raises(RuntimeError) { ShatteredViridian.install(@config) }
    assert_match(/Blocked or unknown native Viridian tile/,error.message)
    assert_equal before,[File.binread("Data/Map041.rxdata"),File.binread("Data/Map042.rxdata")]
  end
  def test_escort_path_cannot_cross_existing_native_event
    city=load_data("Data/Map041.rxdata")
    e=RPG::Event.new(10,16); e.id=1; e.name="Existing NPC"
    city.events[1]=e
    save_data(city,"Data/Map041.rxdata")
    @config["expected_city_sha256"]=Digest::SHA256.file("Data/Map041.rxdata").hexdigest
    error=assert_raises(RuntimeError) { ShatteredViridian.install(@config) }
    assert_match(/Escort path intersects/,error.message)
  end
  def test_wrong_hash_blocks_both_map_writes
    @config["expected_city_sha256"]="0"*64
    before=File.binread("Data/Map042.rxdata")
    assert_raises(RuntimeError) { ShatteredViridian.install(@config) }
    assert_equal before,File.binread("Data/Map042.rxdata")
  end
  def test_occupied_city_event_refuses_all_writes
    city=load_data("Data/Map041.rxdata")
    e=RPG::Event.new(2,17); e.id=1; e.name="Existing"
    city.events[1]=e
    save_data(city,"Data/Map041.rxdata")
    @config["expected_city_sha256"]=Digest::SHA256.file("Data/Map041.rxdata").hexdigest
    before=File.binread("Data/Map042.rxdata")
    assert_raises(RuntimeError) { ShatteredViridian.install(@config) }
    assert_equal before,File.binread("Data/Map042.rxdata")
  end
  def test_partial_install_refused
    city=load_data("Data/Map041.rxdata")
    e=RPG::Event.new(9,16); e.id=1; e.name=ShatteredViridian::PREFIX+"guard"
    city.events[1]=e
    save_data(city,"Data/Map041.rxdata")
    assert_raises(RuntimeError) { ShatteredViridian.install(@config) }
  end
  def test_stale_backup_refused_even_after_successful_install
    ShatteredViridian.install(@config)
    File.write("Data/Map042.rxdata.shattered_viridian.bak","recovery")
    assert_raises(RuntimeError) { ShatteredViridian.install(@config) }
  end
  def test_no_marker_or_sprite_refuses
    File.delete("SHATTERED_STAGING_REPORT.json")
    assert_raises(RuntimeError) { ShatteredViridian.install(@config) }
    File.write("SHATTERED_STAGING_REPORT.json","{}")
    File.delete("Graphics/Characters/Nidoran.png")
    assert_raises(RuntimeError) { ShatteredViridian.install(@config) }
  end
  def test_second_map_write_failure_restores_both_original_maps
    before=[File.binread("Data/Map041.rxdata"),File.binread("Data/Map042.rxdata")]
    original=File.method(:rename)
    File.stub(:rename, lambda { |src,dst|
      raise IOError, "simulated second-map replacement failure" if src == "Data/Map042.rxdata.shattered_viridian.tmp"
      original.call(src,dst)
    }) do
      assert_raises(IOError) { ShatteredViridian.install(@config) }
    end
    assert_equal before,[File.binread("Data/Map041.rxdata"),File.binread("Data/Map042.rxdata")]
    refute File.exist?("Data/Map041.rxdata.shattered_viridian.bak")
    refute File.exist?("Data/Map042.rxdata.shattered_viridian.bak")
  end
  def test_metadata_is_native_essentials_format
    text=File.read(File.expand_path("../essentials/Plugins/Shattered Viridian/meta.txt",__dir__))
    assert_match(/\AName\s*=/,text)
    assert_match(/^Essentials\s*= 21\.1$/,text)
  end
end
