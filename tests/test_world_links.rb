require "minitest/autorun"
require "tmpdir"
require "fileutils"
module RPG
  class Event
    attr_accessor :id, :name, :x, :y, :pages
    def initialize(x, y)
      @x, @y, @pages = x, y, []
    end
    class Page
      attr_accessor :trigger, :priority_type, :list
      def initialize
        @trigger, @list = 0, []
      end
    end
  end
  class EventCommand
    attr_accessor :code, :indent, :parameters
    def initialize(code, indent, parameters)
      @code, @indent, @parameters = code, indent, parameters
    end
  end
end
MapStub = Struct.new(:width, :height, :events)
def load_data(path)
  Marshal.load(File.binread(path))
end
def save_data(value, path)
  File.binwrite(path, Marshal.dump(value))
end
load File.expand_path("../essentials/Plugins/Shattered World Links/001_Install.rb", __dir__)

class WorldLinkInstallerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("shattered-world-links")
    @old_dir = Dir.pwd
    Dir.chdir(@dir)
    Dir.mkdir("Data")
    File.write("SHATTERED_STAGING_REPORT.json", "{}")
    save_data({10 => true, 11 => true}, "Data/MapInfos.rxdata")
    save_data(MapStub.new(20, 20, {}), "Data/Map010.rxdata")
    save_data(MapStub.new(12, 12, {}), "Data/Map011.rxdata")
    @plan = {
      "format" => "shattered-world-links", "format_version" => 1,
      "maps" => [{"map_id" => 10, "width" => 20, "height" => 20},
                 {"map_id" => 11, "width" => 12, "height" => 12}],
      "events" => [
        {"link_id" => "door-one", "side" => "F", "map_id" => 10, "x" => 3, "y" => 4,
         "destination" => {"map_id" => 11, "x" => 2, "y" => 4, "direction" => 8, "fade" => 0}},
        {"link_id" => "door-one", "side" => "R", "map_id" => 11, "x" => 2, "y" => 3,
         "destination" => {"map_id" => 10, "x" => 3, "y" => 5, "direction" => 2, "fade" => 0}}
      ]
    }
  end

  def teardown
    Dir.chdir(@old_dir)
    FileUtils.remove_entry(@dir)
  end

  def test_two_way_native_event_commands_and_idempotence
    report = ShatteredWorldLinks.install(@plan)
    assert_equal 2, report["created"]
    assert_equal [10, 11], report["changed_maps"]
    a = load_data("Data/Map010.rxdata").events.values.first
    b = load_data("Data/Map011.rxdata").events.values.first
    assert_equal "SHATTERED_LINK:door-one:F", a.name
    assert_equal 1, a.pages.first.trigger
    assert_equal 0, a.pages.first.priority_type
    assert_equal [0, 11, 2, 4, 8, 0], a.pages.first.list.first.parameters
    assert_equal [0, 10, 3, 5, 2, 0], b.pages.first.list.first.parameters
    second = ShatteredWorldLinks.install(@plan)
    assert_equal({"created" => 0, "unchanged" => 2, "changed_maps" => []}, second)
    assert_equal 1, load_data("Data/Map010.rxdata").events.size
  end

  def test_rejects_non_staged_project_without_changes
    File.delete("SHATTERED_STAGING_REPORT.json")
    before = File.binread("Data/Map010.rxdata")
    assert_raises(RuntimeError) { ShatteredWorldLinks.install(@plan) }
    assert_equal before, File.binread("Data/Map010.rxdata")
  end

  def test_rejects_missing_target_map_before_any_write
    @plan["events"][0]["destination"]["map_id"] = 12
    before = File.binread("Data/Map010.rxdata")
    assert_raises(ArgumentError) { ShatteredWorldLinks.install(@plan) }
    assert_equal before, File.binread("Data/Map010.rxdata")
  end

  def test_rejects_transfer_loop_before_any_write
    @plan["events"][0]["destination"]["y"] = 3
    before = File.binread("Data/Map010.rxdata")
    assert_raises(ArgumentError) { ShatteredWorldLinks.install(@plan) }
    assert_equal before, File.binread("Data/Map010.rxdata")
  end

  def test_rejects_occupied_door_without_changes
    map = load_data("Data/Map010.rxdata")
    existing = RPG::Event.new(3, 4)
    existing.id, existing.name = 1, "Existing quest"
    map.events[1] = existing
    save_data(map, "Data/Map010.rxdata")
    before = File.binread("Data/Map010.rxdata")
    assert_raises(RuntimeError) { ShatteredWorldLinks.install(@plan) }
    assert_equal before, File.binread("Data/Map010.rxdata")
  end

  def test_rejects_stale_backups
    File.write("Data/Map010.rxdata.shattered.bak", "stale")
    before = File.binread("Data/Map010.rxdata")
    assert_raises(RuntimeError) { ShatteredWorldLinks.install(@plan) }
    assert_equal before, File.binread("Data/Map010.rxdata")
  end

  def test_rejects_changed_existing_link
    ShatteredWorldLinks.install(@plan)
    @plan["events"][0]["destination"]["x"] = 5
    before = File.binread("Data/Map010.rxdata")
    assert_raises(RuntimeError) { ShatteredWorldLinks.install(@plan) }
    assert_equal before, File.binread("Data/Map010.rxdata")
  end
end
