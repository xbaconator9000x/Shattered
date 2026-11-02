# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../scripts/verify_private_opening_convergence'

class PrivateOpeningConvergenceTest < Minitest::Test
  V = ShatteredPrivateOpeningConvergence

  def test_git_blob_matches_git_content_identity
    assert_equal 'ce013625030ba8dba906f756967f9e9ca394464a', V.git_blob('hello\n'.gsub('\\n', "\n"))
  end

  def test_rejects_unstaged_or_missing_project
    Dir.mktmpdir do |dir|
      assert_raises(RuntimeError) { V.verify!(dir) }
    end
  end

  def test_requires_actual_native_event
    assert_raises(RuntimeError) { V.commands(nil) }
  end

  def test_native_raid_pages_require_center_gate_and_unique_story_switches
    city = RPG::Map.allocate
    city.events = {}
    3.times do |index|
      city.events[29 + index] = ShatteredPrivateViridianBeedrill.event(index)
    end
    assert V.verify_raid_pages!(city)
    assert_equal [1001, 1002, 1003],
      (0..2).map { |i| city.events[29 + i].pages.last.condition.switch1_id }
    first = city.events[29].pages.first
    assert first.condition.switch1_valid
    assert_equal 995, first.condition.switch1_id
    city.events[29].pages.first.condition.switch1_id = 997
    assert_raises(RuntimeError) { V.verify_raid_pages!(city) }
    city.events[29] = ShatteredPrivateViridianBeedrill.event(0)
    city.events[30].pages[1].condition.switch2_id = 997
    assert_raises(RuntimeError) { V.verify_raid_pages!(city) }
    city.events[30] = ShatteredPrivateViridianBeedrill.event(1)
    city.events[31].pages[1].list[0].parameters[0] = 'ShatteredRaid.trigger(2, {})'
    assert_raises(RuntimeError) { V.verify_raid_pages!(city) }
  end

  def test_center_autorun_cannot_start_before_completed_escort
    center = RPG::Map.allocate
    center.width = 20
    center.height = 15
    center.events = {}
    event = RPG::Event.new(8, 7)
    event.id = 11
    event.name = 'SHATTERED_VIRIDIAN:center_first_visit'
    start_page = RPG::Event::Page.new
    start_page.trigger = 3
    start_page.condition.switch1_valid = true
    start_page.condition.switch1_id = 994
    start_page.list = [RPG::EventCommand.new(355, 0,
      ['ShatteredViridian.center!(995, 996)'])]
    done = RPG::Event::Page.new
    done.condition.switch1_valid = true
    done.condition.switch1_id = 995
    event.pages = [RPG::Event::Page.new, start_page, done]
    center.events[11] = event
    assert V.verify_center_arrival!(center)
    start_page.condition.switch1_id = 993
    assert_raises(RuntimeError) { V.verify_center_arrival!(center) }
    start_page.condition.switch1_id = 994
    done.condition.switch1_id = 997
    assert_raises(RuntimeError) { V.verify_center_arrival!(center) }
  end

  def test_transfer_requires_scatter_even_if_ambush_tile_is_bypassed
    route = RPG::Map.allocate
    route.width = 54
    route.height = 34
    route.events = {}
    warp = RPG::Event.new(32, 17)
    warp.id = 4
    warp.pages.first.trigger = 1
    warp.pages.first.list = [
      RPG::EventCommand.new(111, 0, [12,
        'ShatteredRoute22.cleared? || (ShatteredRoute22.scatter! && ShatteredRoute22.encounter(991, 992))']),
      RPG::EventCommand.new(101, 1, ['Proceed to Viridian']),
      RPG::EventCommand.new(201, 1, [0, 10, 25, 20, 2, 0]),
      RPG::EventCommand.new(411, 0, []),
      RPG::EventCommand.new(355, 1, ['ShatteredRoute22.return_to_entry(16, 29, 17)']),
      RPG::EventCommand.new(412, 0, []),
      RPG::EventCommand.new(0, 0, [])
    ]
    route.events[4] = warp
    [5, 6, 7].each do |id|
      actor = RPG::Event.new(id + 26, 17)
      actor.id = id
      actor.name = "SHATTERED: Rattata scatter #{id - 4}"
      actor.pages << RPG::Event::Page.new
      actor.pages.last.condition.switch1_valid = true
      actor.pages.last.condition.switch1_id = 992
      route.events[id] = actor
    end
    assert V.verify_route22_transfer_scatter!(route)
    warp.pages.first.list.first.parameters[1] =
      'ShatteredRoute22.cleared? || ShatteredRoute22.encounter(991, 992)'
    assert_raises(RuntimeError) { V.verify_route22_transfer_scatter!(route) }
    warp.pages.first.list.first.parameters[1] =
      'ShatteredRoute22.cleared? || (ShatteredRoute22.scatter! && ShatteredRoute22.encounter(991, 992))'
    warp.pages.first.list[2].indent = 0
    assert_raises(RuntimeError) { V.verify_route22_transfer_scatter!(route) }
    warp.pages.first.list[2].indent = 1
    route.events.delete(7)
    assert_raises(RuntimeError) { V.verify_route22_transfer_scatter!(route) }
  end

  def test_native_viridian_escort_requires_both_waited_routes_and_arrival_guard
    city = RPG::Map.allocate
    city.width = 50
    city.height = 40
    city.events = {}
    arrival = RPG::Event.new(25, 20)
    arrival.id = 23
    arrival.name = 'SHATTERED: Viridian arrival'
    arrival.pages << RPG::Event::Page.new
    arrival.pages[0].trigger = 3
    arrival.pages[1].condition.switch1_valid = true
    arrival.pages[1].condition.switch1_id = 994
    guard = RPG::Event.new(24, 20)
    guard.id = 25
    nidoran = RPG::Event.new(23, 20)
    nidoran.id = 26
    [guard, nidoran].each do |npc|
      npc.pages << RPG::Event::Page.new
      npc.pages.each { |page| page.through = true }
      npc.pages.last.condition.switch1_valid = true
      npc.pages.last.condition.switch1_id = 994
      city.events[npc.id] = npc
    end
    route = lambda do |codes|
      result = RPG::MoveRoute.new
      result.repeat = false
      result.skippable = true
      result.list = codes.map { |code| RPG::MoveCommand.new(code) }
      result
    end
    guard_route = route.call([1, 1, 2, 1, 1, 1, 1, 1, 3, 3, 0])
    nidoran_route = route.call([1, 1, 1, 1, 1, 1, 1, 3, 0])
    arrival.pages[0].list = [
      RPG::EventCommand.new(355, 0, ['ShatteredViridian.start!(993, 996)']),
      RPG::EventCommand.new(236, 0, [1, 6, 20]),
      RPG::EventCommand.new(101, 0, ['Escort']),
      RPG::EventCommand.new(209, 0, [25, guard_route]),
      RPG::EventCommand.new(210, 0, []),
      RPG::EventCommand.new(209, 0, [26, nidoran_route]),
      RPG::EventCommand.new(210, 0, []),
      RPG::EventCommand.new(111, 0,
        [12, 'ShatteredViridian.complete_route!(25, 26, [24, 20], [23, 20], [25, 27], [24, 27], 993, 996)']),
      RPG::EventCommand.new(355, 1, ['ShatteredViridian.arrive!(994)']),
      RPG::EventCommand.new(101, 1, ['Center ahead']),
      RPG::EventCommand.new(411, 0, []),
      RPG::EventCommand.new(101, 1, ['Retry later']),
      RPG::EventCommand.new(116, 1, []),
      RPG::EventCommand.new(412, 0, []),
      RPG::EventCommand.new(0, 0, [])
    ]
    city.events[23] = arrival
    result = V.verify_viridian_escort!(city)
    assert result['arrival_requires_both_routes']
    assert_equal [[25, 27], [24, 27]], result['endpoints']
    arrival.pages[0].list[6].code = 101
    assert_raises(RuntimeError) { V.verify_viridian_escort!(city) }
    arrival.pages[0].list[6].code = 210
    nidoran_route.list[7].instance_variable_set(:@code, 2)
    assert_raises(RuntimeError) { V.verify_viridian_escort!(city) }
    nidoran_route.list[7].instance_variable_set(:@code, 3)
    arrival.pages[0].list[8].indent = 0
    assert_raises(RuntimeError) { V.verify_viridian_escort!(city) }
    arrival.pages[0].list[8].indent = 1
    guard.pages.last.condition.switch1_id = 993
    assert_raises(RuntimeError) { V.verify_viridian_escort!(city) }
  end

  def test_private_compiled_opening_and_rejects_source_tampering
    source = ENV['SHATTERED_PRIVATE_PROJECT']
    skip 'Private user-held game not present in public CI' unless source && File.directory?(source)
    Dir.mktmpdir do |dir|
      files = ['SHATTERED_STAGING_REPORT.json', 'Data/PluginScripts.rxdata',
               'Data/Map223.rxdata', 'Data/Map016.rxdata', 'Data/Map010.rxdata',
               'Data/Map011.rxdata']
      V::SOURCES.each do |name, (script, _pin, _version)|
        files << "Plugins/#{name}/#{script}"
        files << "Plugins/#{name}/meta.txt"
      end
      files.each do |relative|
        FileUtils.mkdir_p(File.dirname(File.join(dir, relative)))
        FileUtils.cp(File.join(source, relative), File.join(dir, relative))
      end
      report = V.verify!(dir)
      assert_equal 5, report.fetch('checked_plugins').length
      assert report.fetch('center_autorun_requires_escort_arrival')
      assert report.fetch('route22_warp_scatter_guarded')
      assert report.fetch('viridian_escort_route_guarded').fetch('arrival_requires_both_routes')
      assert_equal 2, report.fetch('gate_north_landings').uniq.length
      refute report.fetch('native_game_launched')
      gate_source = File.join(dir, 'Plugins/Shattered Gate Story/001_GateStory.rb')
      File.open(gate_source, 'ab') { |f| f.write('# tampered') }
      error = assert_raises(RuntimeError) { V.verify!(dir) }
      assert_match(/Source Git blob mismatch/, error.message)
      FileUtils.cp(File.join(source, 'Plugins/Shattered Gate Story/001_GateStory.rb'), gate_source)
      archive_path = File.join(dir, 'Data/PluginScripts.rxdata')
      entries = Marshal.load(File.binread(archive_path))
      compiled = entries.find { |entry| entry[0] == 'Shattered Route22' }
      compiled[2][0][1] = Zlib::Deflate.deflate('# stale compiled script')
      File.binwrite(archive_path, Marshal.dump(entries))
      error = assert_raises(RuntimeError) { V.verify!(dir) }
      assert_match(/Stale compiled source/, error.message)
      FileUtils.cp(File.join(source, 'Data/PluginScripts.rxdata'), archive_path)
      gate_map_path = File.join(dir, 'Data/Map223.rxdata')
      gate = Marshal.load(File.binread(gate_map_path))
      north_a = V.commands(gate.events[2]).find { |command| command.code == 201 }
      north_b = V.commands(gate.events[3]).find { |command| command.code == 201 }
      north_b.parameters[2, 2] = north_a.parameters[2, 2]
      File.binwrite(gate_map_path, Marshal.dump(gate))
      error = assert_raises(RuntimeError) { V.verify!(dir) }
      assert_match(/north exits collapse/, error.message)
    end
  end
end
