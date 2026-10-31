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
  class Table
    attr_reader :xsize, :ysize, :zsize
    def initialize(xsize, ysize, zsize)
      @xsize, @ysize, @zsize = xsize, ysize, zsize
      @tiles = Hash.new(0)
    end
    def [](x, y, z); @tiles[[x, y, z]]; end
    def []=(x, y, z, value); @tiles[[x, y, z]] = value; end
  end
  class Map
    attr_accessor :width, :height, :tileset_id, :data, :events
    def initialize(width, height)
      @width, @height, @tileset_id = width, height, 1
      @data, @events = Table.new(width, height, 3), {}
      width.times { |x| height.times { |y| @data[x, y, 0] = 1 } }
    end
  end
  class Tileset
    attr_accessor :passages
    def initialize; @passages = Array.new(256, 0); end
  end
  class MapInfo
    attr_accessor :name, :parent_id, :order, :expanded, :scroll_x, :scroll_y
    def initialize(name); @name = name; end
  end
end
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
    ShatteredGateStory.run_collapse(%w[rum1 rum2 rum3 rum4 rum5 rum6], "roar")
    assert_equal %w[rum3 rum4 rum5 rum6 roar], $sounds
    assert ShatteredGateStory.collapsed?
    assert_equal 6, ShatteredGateStory.state[:impacts]
    assert ShatteredGateStory.state[:final_roar]
    ShatteredGateStory.run_collapse(%w[rum1 rum2 rum3 rum4 rum5 rum6], "roar")
    assert_equal 5, $sounds.length
    assert_equal 1, $messages.count { |message| message.include?("blocked") }
  end
  def test_resume_announces_johto_blocked_after_saved_third_impact
    3.times { ShatteredGateStory.impact! }
    ShatteredGateStory.run_collapse(%w[rum1 rum2 rum3 rum4 rum5 rum6], "roar")
    assert_equal 1, $messages.count { |message| message.include?("blocked") }
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
  def test_original_private_aipom_cry_subdirectory_and_path_safety
    6.times { ShatteredGateStory.impact! }
    assert ShatteredGateStory.run_aipom("Cries/AIPOM")
    assert_includes $sounds, "Cries/AIPOM"
    ["../AIPOM", "Cries/../AIPOM", "Cries//AIPOM", "Other/AIPOM"].each do |unsafe|
      assert_raises(ArgumentError) { ShatteredGateStory.run_aipom(unsafe) }
    end
  end

  def test_unknown_version_and_malformed_gate_save_fail_closed
    value = ShatteredGateStory.state
    value[:version] = 2
    original = $PokemonGlobal.instance_variable_get(:@shattered_gate_story)
    assert_raises(ShatteredGateStory::InvalidState) { ShatteredGateStory.state }
    assert_same original, $PokemonGlobal.instance_variable_get(:@shattered_gate_story)
    assert_equal 2, original[:version]

    value[:version] = 1
    value[:impacts] = true
    assert_raises(ShatteredGateStory::InvalidState) { ShatteredGateStory.impact! }
    assert_equal true, value[:impacts]
    value[:impacts] = 0
    value[:key] = "yes"
    assert_raises(ShatteredGateStory::InvalidState) { ShatteredGateStory.award_key! }
    assert_equal 0, $bag.added
  end

  def test_impossible_gate_progress_does_not_replay_or_reaward
    6.times { ShatteredGateStory.impact! }
    ShatteredGateStory.clue!
    assert ShatteredGateStory.award_key!
    assert_equal 1, $bag.added
    saved = Marshal.load(Marshal.dump($PokemonGlobal))
    $PokemonGlobal = saved
    value = saved.instance_variable_get(:@shattered_gate_story)
    value[:impacts] = 2
    assert_raises(ShatteredGateStory::InvalidState) do
      ShatteredGateStory.run_collapse(%w[rum1 rum2 rum3 rum4 rum5 rum6], "roar")
    end
    assert_equal 1, $bag.added
    assert_empty $sounds
    assert_equal 2, value[:impacts]
  end

  def test_optional_legacy_gate_flags_migrate_without_losing_progress
    legacy = { :version => 1, :impacts => 3, :aipom_clue => false, :key => false }
    $PokemonGlobal.instance_variable_set(:@shattered_gate_story, legacy)
    assert_same legacy, ShatteredGateStory.state
    assert_equal 3, legacy[:impacts]
    assert_equal false, legacy[:johto_blocked_message]
    assert_equal false, legacy[:final_roar]
    ShatteredGateStory.run_collapse(%w[rum1 rum2 rum3 rum4 rum5 rum6], "roar")
    assert_equal %w[rum4 rum5 rum6 roar], $sounds
    assert_equal 6, legacy[:impacts]
  end

  def test_invalid_optional_flags_and_early_key_or_clue_are_rejected
    raw = ShatteredGateStory.state
    raw[:final_roar] = "done"
    assert_raises(ShatteredGateStory::InvalidState) { ShatteredGateStory.state }
    raw[:final_roar] = false
    raw[:johto_blocked_message] = true
    assert_raises(ShatteredGateStory::InvalidState) { ShatteredGateStory.state }
    raw[:johto_blocked_message] = false
    raw[:aipom_clue] = true
    assert_raises(ShatteredGateStory::InvalidState) { ShatteredGateStory.state }
    raw[:aipom_clue] = false
    raw[:key] = true
    assert_raises(ShatteredGateStory::InvalidState) { ShatteredGateStory.state }
    raw[:key] = false
    assert_equal 0, ShatteredGateStory.state[:impacts]
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
    %w[rum1 rum2 rum3 rum4 rum5 rum6 cry roar].each { |n| File.write("Audio/SE/#{n}.ogg", "private") }
    File.write("Graphics/Characters/Aipom.png", "private")
    save_data({10=>RPG::MapInfo.new("Reception Gate")}, "Data/MapInfos.rxdata")
    save_data([nil, RPG::Tileset.new], "Data/Tilesets.rxdata")
    south = RPG::Event.new(11,19)
    south.id = 1
    south.name = "Exit south"
    page = RPG::Event::Page.new
    page.trigger = 1
    page.list = [RPG::EventCommand.new(201,0,[0,20,10,1,2,0]), RPG::EventCommand.new(0,0,[])]
    south.pages = [page]
    north = RPG::Event.new(11,1)
    north.id = 2
    north.name = "Exit north"
    north_page = RPG::Event::Page.new
    north_page.list = [RPG::EventCommand.new(201,0,[0,21,10,11,19,0]), RPG::EventCommand.new(0,0,[])]
    north.pages = [north_page]
    map = RPG::Map.new(22,21)
    map.events = {1=>south,2=>north}
    save_data(map, "Data/Map010.rxdata")
    @config = {"schema_version"=>1,"map_id"=>10,
      "positions"=>{"collapse"=>{"x"=>9,"y"=>11},"aipom"=>{"x"=>11,"y"=>2},"johto_block"=>{"x"=>11,"y"=>19}},
      "flag_plan"=>"shattered_gate_story_v1",
      "collapse_sounds"=>%w[rum1 rum2 rum3 rum4 rum5 rum6],"final_roar_sound"=>"roar",
      "aipom_cry"=>"cry","aipom_character"=>"Aipom",
      "expected_south_transfer"=>[0,20,10,1,2,0]}
  end
  def teardown
    Dir.chdir(@old)
    FileUtils.remove_entry(@tmp)
  end
  def test_native_tilesets_array_is_preserved_byte_for_byte
    original_tilesets = File.binread("Data/Tilesets.rxdata")
    assert_instance_of Array, load_data("Data/Tilesets.rxdata")
    result = ShatteredGateStory.install(@config)
    assert_equal 3, result.fetch("installed").length
    assert_equal original_tilesets, File.binread("Data/Tilesets.rxdata")
    assert_instance_of Array, load_data("Data/Tilesets.rxdata")
  end

  def test_installs_real_native_script_events
    result = ShatteredGateStory.install(@config)
    assert_equal 3, result["installed"].length
    map = load_data("Data/Map010.rxdata")
    assert_instance_of RPG::Map, map
    assert_equal 4, map.events.size
    assert_equal "SHATTERED_GATE:johto_block", map.events[1].name
    assert_equal 355, map.events[1].pages[0].list[0].code
    assert_equal 1, map.events[1].pages[0].trigger
    assert_equal [0,21,10,11,19,0], map.events[2].pages[0].list[0].parameters
    assert_equal "Exit north", map.events[2].name
    aipom = map.events.values.find { |e| e.name == "SHATTERED_GATE:aipom" }
    assert_equal "Aipom", aipom.pages[0].graphic.character_name
    assert_equal 0, aipom.pages[0].trigger
    assert_equal 6, @config["collapse_sounds"].length
    collapse_script = map.events.values.find { |e| e.name == "SHATTERED_GATE:collapse" }.pages[0].list[0].parameters[0]
    assert_includes collapse_script, '"roar"'
    refute File.exist?("Data/Map010.rxdata.shattered_gate.bak")
    before = File.binread("Data/Map010.rxdata")
    assert_equal 3, ShatteredGateStory.install(@config)["unchanged"]
    assert_equal before, File.binread("Data/Map010.rxdata")
  end
  def test_installs_aipom_using_existing_cries_subdirectory
    FileUtils.mkdir_p("Audio/SE/Cries")
    File.write("Audio/SE/Cries/AIPOM.ogg", "private")
    @config["aipom_cry"] = "Cries/AIPOM"
    assert_equal 3, ShatteredGateStory.install(@config)["installed"].length
    installed = load_data("Data/Map010.rxdata")
    aipom = installed.events.values.find { |event| event.name == "SHATTERED_GATE:aipom" }
    assert_includes aipom.pages.first.list.first.parameters.first, '"Cries/AIPOM"'
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
  def test_rejects_malformed_event_ids_before_writing
    map = load_data("Data/Map010.rxdata")
    map.events[2].id = 20
    save_data(map,"Data/Map010.rxdata")
    original = File.binread("Data/Map010.rxdata")
    assert_raises(RuntimeError) { ShatteredGateStory.install(@config) }
    assert_equal original, File.binread("Data/Map010.rxdata")
  end
  def test_rejects_impassable_story_tiles
    tilesets = load_data("Data/Tilesets.rxdata")
    tilesets[1].passages[1] = 0x0F
    save_data(tilesets, "Data/Tilesets.rxdata")
    original = File.binread("Data/Map010.rxdata")
    assert_raises(RuntimeError) { ShatteredGateStory.install(@config) }
    assert_equal original, File.binread("Data/Map010.rxdata")
  end
  def test_allows_impassable_south_exit_if_northern_approach_is_walkable
    map = load_data("Data/Map010.rxdata")
    map.data[11, 19, 0] = 2
    save_data(map, "Data/Map010.rxdata")
    tilesets = load_data("Data/Tilesets.rxdata")
    tilesets[1].passages[2] = 0x0F
    save_data(tilesets, "Data/Tilesets.rxdata")

    assert_equal 3, ShatteredGateStory.install(@config)["installed"].length
    installed = load_data("Data/Map010.rxdata")
    assert_equal "SHATTERED_GATE:johto_block", installed.events[1].name
    assert_equal 2, installed.data[11, 19, 0]
  end

  def test_rejects_south_blocker_without_walkable_northern_approach
    map = load_data("Data/Map010.rxdata")
    map.data[11, 18, 0] = 2
    save_data(map, "Data/Map010.rxdata")
    tilesets = load_data("Data/Tilesets.rxdata")
    tilesets[1].passages[2] = 0x0F
    save_data(tilesets, "Data/Tilesets.rxdata")

    original = File.binread("Data/Map010.rxdata")
    assert_raises(RuntimeError) { ShatteredGateStory.install(@config) }
    assert_equal original, File.binread("Data/Map010.rxdata")
  end

  def test_rejects_bad_asset_name_and_flag_plan
    original = File.binread("Data/Map010.rxdata")
    @config["final_roar_sound"] = "../roar"
    assert_raises(ArgumentError) { ShatteredGateStory.install(@config) }
    @config["final_roar_sound"] = "roar"
    @config["flag_plan"] = "unknown"
    assert_raises(ArgumentError) { ShatteredGateStory.install(@config) }
    assert_equal original, File.binread("Data/Map010.rxdata")
  end
  def test_rolls_back_original_map_and_cleans_files_after_write_failure
    original = File.binread("Data/Map010.rxdata")
    rename = File.method(:rename)
    calls = 0
    File.stub(:rename, lambda { |source, destination|
      calls += 1
      raise IOError, "injected rename failure" if calls == 2
      rename.call(source, destination)
    }) do
      assert_raises(IOError) { ShatteredGateStory.install(@config) }
    end
    assert_equal original, File.binread("Data/Map010.rxdata")
    refute File.exist?("Data/Map010.rxdata.shattered_gate.tmp")
    refute File.exist?("Data/Map010.rxdata.shattered_gate.bak")
  end
end
