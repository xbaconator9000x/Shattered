# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'digest'
require_relative '../scripts/upgrade_private_viridian_handoff'
require_relative '../essentials/Plugins/Shattered Viridian/001_Entry'

class PrivateViridianHandoffTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, 'Data'))
    File.write(File.join(@dir, 'SHATTERED_STAGING_REPORT.json'), '{}')
    city = RPG::Map.new
    city.width = 50
    city.height = 40
    city.events = {}
    (1..23).each do |id|
      e = RPG::Event.new(0, 0)
      e.id = id
      e.name = "existing #{id}"
      e.pages = [RPG::Event::Page.new]
      city.events[id] = e
    end
    arrival = city.events[23]
    arrival.name = 'SHATTERED: Viridian arrival'
    arrival.x, arrival.y = 25, 20
    arrival.pages.first.trigger = 3
    arrival.pages.first.list = [RPG::EventCommand.new(101, 0,
      ['End of Shattered Essentials prototype 0.1.'])]
    done = RPG::Event::Page.new
    done.condition.self_switch_valid = true
    arrival.pages << done

    center = RPG::Map.new
    center.width = 20
    center.height = 15
    center.events = {}
    (1..10).each do |id|
      e = RPG::Event.new(0, 0)
      e.id = id
      e.name = "center #{id}"
      e.pages = [RPG::Event::Page.new]
      center.events[id] = e
    end
    center.events[1].pages.first.list = [
      RPG::EventCommand.new(201, 0, [0, 10, 26, 27, 0, 1])]
    system = RPG::System.new
    system.instance_variable_set(:@switches, Array.new(1000))
    @city_path = File.join(@dir, 'Data/Map010.rxdata')
    @center_path = File.join(@dir, 'Data/Map011.rxdata')
    @system_path = File.join(@dir, 'Data/System.rxdata')
    File.binwrite(@city_path, Marshal.dump(city))
    File.binwrite(@center_path, Marshal.dump(center))
    File.binwrite(@system_path, Marshal.dump(system))
    @original_city = ShatteredPrivateViridianHandoff::CITY_SHA
    @original_center = ShatteredPrivateViridianHandoff::CENTER_SHA
    pin(:CITY_SHA, Digest::SHA256.file(@city_path).hexdigest)
    pin(:CENTER_SHA, Digest::SHA256.file(@center_path).hexdigest)
    $PokemonGlobal = Object.new
    $game_switches = Hash.new(false)
  end

  def teardown
    pin(:CITY_SHA, @original_city)
    pin(:CENTER_SHA, @original_center)
    FileUtils.remove_entry(@dir)
  end

  def pin(key, value)
    ShatteredPrivateViridianHandoff.send(:remove_const, key)
    ShatteredPrivateViridianHandoff.const_set(key, value)
  end

  def test_native_event_pages_and_persistent_story_handoff
    result = ShatteredPrivateViridianHandoff.install!(@dir)
    assert result['prototype_end_marker_removed']
    assert_equal 2, result['native_events_added']
    city = Marshal.load(File.binread(@city_path))
    center = Marshal.load(File.binread(@center_path))
    assert_equal [23, 24], city.events.keys.sort.last(2)
    assert_equal 11, center.events.keys.max
    assert_equal 3, city.events[23].pages.first.trigger
    assert city.events[23].pages.last.condition.switch1_valid
    assert_equal 993, city.events[23].pages.last.condition.switch1_id
    assert_equal 996, city.events[24].pages.last.condition.switch1_id
    assert_equal 3, center.events[11].pages[1].trigger
    assert_equal 995, center.events[11].pages.last.condition.switch1_id

    eval(city.events[23].pages.first.list.find { |c| c.code == 355 }.parameters.first)
    assert_equal [true, true, false, true],
      [993, 994, 995, 996].map { |id| $game_switches[id] }
    eval(center.events[11].pages[1].list.find { |c| c.code == 355 }.parameters.first)
    assert_equal [true, true, true, false],
      [993, 994, 995, 996].map { |id| $game_switches[id] }
    assert_raises(RuntimeError) { ShatteredPrivateViridianHandoff.install!(@dir) }
  end

  def test_unreviewed_map_refused_without_any_native_mutation
    File.binwrite(@city_path, File.binread(@city_path) + 'corrupt')
    original = [@city_path, @center_path, @system_path].map { |p| File.binread(p) }
    assert_raises(RuntimeError) { ShatteredPrivateViridianHandoff.install!(@dir) }
    assert_equal original,
      [@city_path, @center_path, @system_path].map { |p| File.binread(p) }
  end

  def test_preoccupied_reserved_switch_refused_without_mutation
    system = Marshal.load(File.binread(@system_path))
    system.instance_variable_get(:@switches)[993] = 'Reserved elsewhere'
    File.binwrite(@system_path, Marshal.dump(system))
    original = [@city_path, @center_path, @system_path].map { |p| File.binread(p) }
    assert_raises(RuntimeError) { ShatteredPrivateViridianHandoff.install!(@dir) }
    assert_equal original,
      [@city_path, @center_path, @system_path].map { |p| File.binread(p) }
  end
end
