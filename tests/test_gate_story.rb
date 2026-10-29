require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "ostruct"

module GameData
  module Item
    def self.exists?(id); id == :SHATTEREDGATEKEY; end
  end
end
class BagStub
  attr_reader :added
  def initialize; @added = 0; @items = {}; @can_add = true; end
  def reject!; @can_add = false; end
  def has?(id); !!@items[id]; end
  def add(id, qty); return false unless @can_add; @items[id] = true; @added += qty; true; end
end
module RPG
  class Event
    attr_accessor :id, :name, :x, :y, :pages
    def initialize(x,y); @x,@y,@pages = x,y,[]; end
    class Page
      attr_accessor :trigger, :through, :always_on_top, :list, :graphic
      def initialize; @list=[]; @graphic = OpenStruct.new; end
    end
  end
  class EventCommand
    attr_accessor :code, :indent, :parameters
    def initialize(code, indent, parameters); @code,@indent,@parameters = code,indent,parameters; end
  end
end
MapStub = Struct.new(:width, :height, :events)
def load_data(path); Marshal.load(File.binread(path)); end
def save_data(value, path); File.binwrite(path, Marshal.dump(value)); end

def pbMessage(msg); ($messages ||= []) << msg; end
def _INTL(msg); msg; end
def pbSEPlay(name); ($sounds ||= []) << name; end
def pbWait(frames); ($waits ||= []) << frames; end

load File.expand_path("../essentials/Plugins/Shattered Gate Story/001_GateStory.rb", __dir__)
load File.expand_path("../essentials/Plugins/Shattered Gate Story/002_Install.rb", __dir__)

class GateStoryTest < Minitest::Test
  def setup
    $PokemonGlobal = Object.new
    $bag = BagStub.new
    $messages, $sounds, $waits = [], [], []
  end
  def test_six_impacts_resume_and_collapse_persist_in_save
    assert_equal false, ShatteredGateStory.collapsed?
    2.times { ShatteredGateStory.impact! }
    assert_equal 2, ShatteredGateStory.state[:impacts]
    Marshal.load(Marshal.dump($PokemonGlobal)).tap { |loaded| $PokemonGlobal = loaded }
    ShatteredGateStory.run_collapse(%w[rum1 rum2 rum3 rum4 rum5 rum6])
    assert_equal %w[rum3 rum4 rum5 rum6], $sounds
    assert ShatteredGateStory.collapsed?
    assert_equal 6, ShatteredGateStory.state[:impacts]
    ShatteredGateStory.run_collapse(%w[rum1 rum2 rum3 rum4 rum5 rum6])
    assert_equal 4, $sounds.length
  end
  def test_clue_required_and_key_only_added_once
    refute ShatteredGateStory.clue!
    refute ShatteredGateStory.award_key!
    6.times { ShatteredGateStory.impact! }
    assert ShatteredGateStory.clue!
    assert ShatteredGateStory.award_key!
    assert ShatteredGateStory.award_key!
    assert_equal 1, $bag.added
    assert ShatteredGateStory.key_obtained?
  end
  def test_bag_rejection_never_marks_key_and_recovery_is_possible
    6.times { ShatteredGateStory.impact! }
    ShatteredGateStory.clue!
    $bag.reject!
    refute ShatteredGateStory.award_key!
    refute ShatteredGateStory.key_obtained?
    $bag = BagStub.new
    assert ShatteredGateStory.award_key!
  end
  def test_aipom_cannot_award_before_collapse
    refute ShatteredGateStory.run_aipom("cry")
    assert_equal 0, $bag.added
    6.times { ShatteredGateStory.impact! }
    assert ShatteredGateStory.run_aipom("cry")
    assert_equal 1, $bag.added
    assert ShatteredGateStory.run_aipom("cry")
    assert_equal 1, $bag.added
  end
  def test_reconcile_bag_item_if_save_interrupted
    6.times { ShatteredGateStory.impact! }
    ShatteredGateStory.clue!
    $bag.add(:SHATTEREDGATEKEY,1)
    assert ShatteredGateStory.award_key!
    assert_equal 1, $bag.added
  end
end

class GateInstallerTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @old = Dir.pwd
    Dir.chdir(@tmp)
    FileUtils.mkdir_p(%w[Data PBS Audio/SE Graphics/Characters])
    File.write("SHATTERED_STAGING_REPORT.json", "{}")
    File.write("PBS/items.txt", "[SHATTEREDGATEKEY]\nName = Shattered Gate Key\n")
    %w[rum1 rum2 rum3 rum4 rum5 rum6 cry].each { |n| File.write("Audio/SE/#{n}.ogg", "private") }
    File.write("Graphics/Characters/Aipom.png", "private")
    save_data({10=>true}, "Data/MapInfos.rxdata")
    south = RPG::Event.new(11,19)
    south.id = 1
    south.name = "Exit south"
    page = RPG::Event::Page.new
    page.list = [RPG::EventCommand.new(201,0,[0,20,10,1,2,0]), RPG::EventCommand.new(0,0,[])]
    south.pages = [page]
    save_data(MapStub.new(22,21,{1=>south}), "Data/Map010.rxdata")
    @config = {"schema_version"=>1,"map_id"=>10,
      "positions"=>{"collapse"=>{"x"=>9,"y"=>11},"aipom"=>{"x"=>11,"y"=>2},"johto_block"=>{"x"=>11,"y"=>19}},
      "collapse_sounds"=>%w[rum1 rum2 rum3 rum4 rum5 rum6],"aipom_cry"=>"cry","aipom_character"=>"Aipom",
      "expected_south_transfer"=>[0,20,10,1,2,0]}
  end
  def teardown
    Dir.chdir(@old)
    FileUtils.remove_entry(@tmp)
  end
  def test_installs_real_native_script_events
    result = ShatteredGateStory.install(@config)
    assert_equal 3, result["installed"].length
    map = load_data("Data/Map010.rxdata")
    assert_equal 3, map.events.size
    assert_equal "SHATTERED_GATE:johto_block", map.events[1].name
    assert_equal 355, map.events[1].pages[0].list[0].code
    assert_equal 1, map.events[1].pages[0].trigger
    aipom = map.events.values.find { |e| e.name == "SHATTERED_GATE:aipom" }
    assert_equal "Aipom", aipom.pages[0].graphic.character_name
    assert_equal 0, aipom.pages[0].trigger
    assert_equal 6, @config["collapse_sounds"].length
    refute File.exist?("Data/Map010.rxdata.shattered_gate.bak")
    before = File.binread("Data/Map010.rxdata")
    assert_equal 3, ShatteredGateStory.install(@config)["unchanged"]
    assert_equal before, File.binread("Data/Map010.rxdata")
  end
  def test_rejects_wrong_exit_without_touching_map
    @config["expected_south_transfer"] = [0,99,0,0,2,0]
    original = File.binread("Data/Map010.rxdata")
    assert_raises(RuntimeError) { ShatteredGateStory.install(@config) }
    assert_equal original, File.binread("Data/Map010.rxdata")
  end
  def test_rejects_missing_sprite_and_sound_without_touching_map
    File.delete("Graphics/Characters/Aipom.png")
    original = File.binread("Data/Map010.rxdata")
    assert_raises(RuntimeError) { ShatteredGateStory.install(@config) }
    assert_equal original, File.binread("Data/Map010.rxdata")
  end
  def test_rejects_non_staged_project
    File.delete("SHATTERED_STAGING_REPORT.json")
    assert_raises(RuntimeError) { ShatteredGateStory.install(@config) }
  end
  def test_rejects_occupied_aipom_tile
    map = load_data("Data/Map010.rxdata")
    npc = RPG::Event.new(11,2)
    npc.id=2; npc.name="Existing NPC"; map.events[2]=npc
    save_data(map,"Data/Map010.rxdata")
    original = File.binread("Data/Map010.rxdata")
    assert_raises(RuntimeError) { ShatteredGateStory.install(@config) }
    assert_equal original, File.binread("Data/Map010.rxdata")
  end
end
