require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../scripts/audit_native_project'

class NativeProjectAuditTest < Minitest::Test
  def instance(klass, **attrs)
    obj = klass.allocate
    attrs.each { |key, value| obj.instance_variable_set("@#{key}", value) }
    obj
  end

  def table(width, height = 1, depth = 1, values = nil)
    values ||= Array.new(width * height * depth, 0)
    Table._load([3, width, height, depth, values.size].pack('V5') + values.pack('s<*'))
  end

  def map(width, height, tile_id, events = {}, blocks = [])
    values = Array.new(width * height * 3, 0)
    width.times do |x|
      height.times do |y|
        values[x + width * y] = 385
      end
    end
    blocks.each { |x, y| values[x + width * y + width * height] = 1188 }
    instance(RPG::Map, width: width, height: height, tileset_id: tile_id,
             data: table(width, height, 3, values), events: events)
  end

  def event(x, y, script = nil)
    commands = script ? [instance(RPG::EventCommand, code: 355, parameters: [script])] : []
    page = instance(RPG::Event::Page, list: commands)
    instance(RPG::Event, x: x, y: y, pages: [page])
  end

  def write(path, obj)
    File.binwrite(File.join(@project, 'Data', path), Marshal.dump(obj))
  end

  def setup
    @project = Dir.mktmpdir('private-rmxp-test-')
    FileUtils.mkdir_p(File.join(@project, 'Data'))
    File.write(File.join(@project, 'Game.ini'), '[Game]')
    write('System.rxdata', instance(RPG::System, start_map_id: 222, start_x: 10, start_y: 14))
    infos = { 10 => instance(RPG::MapInfo, name: 'Viridian'),
              16 => instance(RPG::MapInfo, name: 'Route22'),
              222 => instance(RPG::MapInfo, name: 'Crystal Gate') }
    write('MapInfos.rxdata', infos)
    flags = Array.new(1300, 0)
    flags[1188] = 15
    tileset = instance(RPG::Tileset, passages: table(1300, 1, 1, flags))
    write('Tilesets.rxdata', [nil, tileset])
    write('Map010.rxdata', map(50, 40, 1))
    write('Map016.rxdata', map(54, 34, 1, { 3 => event(30, 17) }, [[36, 16], [39, 18]]))
    write('Map222.rxdata', map(20, 18, 1,
      { 1 => event(10, 14, 'h = Pokemon.new(:MACHOP, 5); h.name = "HUMAN"') }))
  end

  def teardown
    FileUtils.remove_entry(@project)
  end

  def test_actual_shape_and_placeholder_are_reported_without_event_scripts
    report = ShatteredNativeAudit.audit(@project)
    assert_equal({ 'map_id' => 222, 'x' => 10, 'y' => 14 }, report['new_game'])
    assert_equal 223, report['candidate_unoccupied_map_id']
    assert_equal [54, 34], report['maps']['16']['dimensions']
    assert_equal [20, 18], report['maps']['222']['dimensions']
    assert report['maps']['222']['legacy_machop_named_human']
    assert_includes report['warnings'], 'route22_not_pinned_48x24'
    assert_includes report['warnings'], 'original_gate_is_not_22x21_hns'
    refute_includes JSON.generate(report), 'Pokemon.new'
    refute report['gameplay_verified']
  end

  def test_route22_static_collision_report_and_event_occupancy
    report = ShatteredNativeAudit.audit(@project, route_positions: [[36, 16], [36, 17], [30, 17]])
    points = report['maps']['16']['proposed_route22_positions']
    assert_equal 'directional_or_blocked', points[0]['tile_status']
    assert_equal 'clear', points[1]['tile_status']
    assert_equal [3], points[2]['existing_event_ids']
    assert_includes report['warnings'], 'proposed_route22_events_overlap_existing_events'
    assert_includes report['warnings'], 'proposed_route22_events_on_directionally_blocked_tiles'
  end

  def test_no_false_warnings_when_reviewed_layout_matches
    write('Map016.rxdata', map(48, 24, 1))
    write('Map222.rxdata', map(22, 21, 1))
    report = ShatteredNativeAudit.audit(@project)
    assert_empty report['warnings']
    assert_equal 'clear', report['maps']['222']['current_new_game_start']['tile_status']
  end

  def test_rejects_missing_native_file
    File.delete(File.join(@project, 'Data', 'Tilesets.rxdata'))
    error = assert_raises(ArgumentError) { ShatteredNativeAudit.audit(@project) }
    assert_match(/missing native file/, error.message)
  end

  def test_rejects_corrupt_table_header
    assert_raises(ArgumentError) { Table._load([3, 2, 2, 1, 5].pack('V5') + '\0' * 10) }
  end
end
