# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../scripts/repair_private_route22_warp_scatter'

class PrivateRoute22WarpScatterTest < Minitest::Test
  V = ShatteredPrivateRoute22WarpScatter

  def fixture
    map = RPG::Map.allocate
    map.width = 54
    map.height = 34
    count = 54 * 34 * 3
    map.data = Table._load([3, 54, 34, 3, count].pack('V5') + "\0" * (count * 2))
    map.events = {}
    ambush = RPG::Event.new(30, 17)
    ambush.id = 3
    ambush.pages.first.trigger = 1
    ambush.pages.first.list = [
      RPG::EventCommand.new(355, 0, [
        'ShatteredRoute22.scatter!; ShatteredRoute22.encounter(991, 992) || ShatteredRoute22.return_to_entry(16, 29, 17)'
      ]),
      RPG::EventCommand.new(0, 0, [])
    ]
    map.events[3] = ambush
    warp = RPG::Event.new(32, 17)
    warp.id = 4
    warp.pages.first.trigger = 1
    warp.pages.first.list = [
      RPG::EventCommand.new(111, 0, [12, V::OLD_CONDITION]),
      RPG::EventCommand.new(101, 1, ['The guards wave you towards the walled city.']),
      RPG::EventCommand.new(201, 1, V::TRANSFER.dup),
      RPG::EventCommand.new(411, 0, []),
      RPG::EventCommand.new(355, 1, ['ShatteredRoute22.return_to_entry(16, 29, 17)']),
      RPG::EventCommand.new(412, 0, []),
      RPG::EventCommand.new(0, 0, [])
    ]
    map.events[4] = warp
    [5, 6, 7].each do |id|
      actor = RPG::Event.new(id + 26, 17)
      actor.id = id
      actor.name = "SHATTERED: Rattata scatter #{id - 4}"
      actor.pages << RPG::Event::Page.new
      actor.pages.last.condition.switch1_valid = true
      actor.pages.last.condition.switch1_id = 992
      map.events[id] = actor
    end
    map
  end

  def test_only_viridian_warp_guard_changes
    map = fixture
    tiles = Marshal.dump(map.data)
    others = map.events.transform_values { |e| Marshal.dump(e) }
    assert V.transform!(map)
    assert_equal [12, V::NEW_CONDITION], map.events[4].pages.first.list.first.parameters
    assert_equal V::TRANSFER, map.events[4].pages.first.list[2].parameters
    assert_equal tiles, Marshal.dump(map.data)
    others.each { |id, bytes| assert_equal bytes, Marshal.dump(map.events[id]) unless id == 4 }
    assert_raises(RuntimeError) { V.transform!(map) }
  end

  def test_wrong_transfer_destination_is_rejected_before_mutation
    map = fixture
    map.events[4].pages.first.list[2].parameters[1] = 11
    original = Marshal.dump(map)
    assert_raises(RuntimeError) { V.transform!(map) }
    assert_equal original, Marshal.dump(map)
  end

  def test_missing_scatter_actor_fails_closed
    map = fixture
    map.events.delete(7)
    original = Marshal.dump(map)
    assert_raises(RuntimeError) { V.transform!(map) }
    assert_equal original, Marshal.dump(map)
  end

  def test_wrong_branch_indent_is_rejected
    map = fixture
    map.events[4].pages.first.list[2].indent = 0
    original = Marshal.dump(map)
    assert_raises(RuntimeError) { V.transform!(map) }
    assert_equal original, Marshal.dump(map)
  end

  def test_never_modifies_unstaged_project
    Dir.mktmpdir do |dir|
      assert_raises(RuntimeError) { V.install!(dir) }
      assert_empty Dir.children(dir)
    end
  end

  def test_private_native_map_install_rollback_and_idempotence
    source = ENV['SHATTERED_PRIVATE_PROJECT']
    skip 'Private native Essentials candidate not supplied to public CI' unless source
    original = File.join(source, 'Data/Map016.rxdata')
    skip 'Private map is not the reviewed source version' unless File.file?(original) &&
      Digest::SHA256.file(original).hexdigest == V::MAP_SHA_BEFORE
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'Data'))
      File.write(File.join(dir, 'SHATTERED_STAGING_REPORT.json'), '{}')
      target = File.join(dir, 'Data/Map016.rxdata')
      FileUtils.cp(original, target)
      assert_raises(RuntimeError) do
        V.install!(dir, failure_hook: proc { |step| raise 'injected' if step == :after_backup })
      end
      assert_equal V::MAP_SHA_BEFORE, Digest::SHA256.file(target).hexdigest
      receipt = V.install!(dir)
      assert_equal 'installed', receipt['result']
      assert_equal V::MAP_SHA_AFTER, Digest::SHA256.file(target).hexdigest
      assert_equal 'already_installed', V.install!(dir)['result']
    end
  end
end
