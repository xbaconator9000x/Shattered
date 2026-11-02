# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'digest'
require_relative '../scripts/repair_private_hns_player_avatar'

class PrivateHNSPlayerAvatarTest < Minitest::Test
  M = ShatteredPrivateHNSPlayerAvatar

  def fixture
    map = RPG::Map.allocate
    map.width = 22; map.height = 21; map.data = 'preserve native tiles'
    event = RPG::Event.allocate
    event.id = 5; event.name = 'SHATTERED_HNS:5'; event.x = 11; event.y = 14
    page = RPG::Event::Page.allocate
    page.trigger = 3
    page.list = [
      RPG::EventCommand.new(101, 0, ['Twenty Years Later...']),
      RPG::EventCommand.new(101, 0, ['The old Johto League Reception Gate is deserted.']),
      RPG::EventCommand.new(355, 0, [M::OLD_SCRIPT]),
      RPG::EventCommand.new(355, 0, ['ShatteredGateStory.run_collapse(["Cries/TYRANITAR"], "Cries/TYRANITAR")']),
      RPG::EventCommand.new(123, 0, ['A', 0]),
      RPG::EventCommand.new(0, 0, [])
    ]
    done = RPG::Event::Page.allocate
    cond = RPG::Event::Page::Condition.allocate
    cond.self_switch_valid = true; cond.self_switch_ch = 'A'
    done.condition = cond
    event.pages = [page, done]
    other = RPG::Event.allocate
    other.id = 2; other.name = 'Unrelated exit'; other.x = 11; other.y = 1
    other.pages = []
    map.events = {2 => other, 5 => event}
    map
  end

  def with_fixture
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'Data'))
      File.write(File.join(dir, 'SHATTERED_STAGING_REPORT.json'), '{}')
      map = fixture
      before = Marshal.dump(map)
      transformed = Marshal.load(before)
      M.transform!(transformed)
      after = Marshal.dump(transformed)
      original_before, original_after = M::BEFORE_SHA256, M::AFTER_SHA256
      M.send(:remove_const, :BEFORE_SHA256)
      M.const_set(:BEFORE_SHA256, Digest::SHA256.hexdigest(before))
      M.send(:remove_const, :AFTER_SHA256)
      M.const_set(:AFTER_SHA256, Digest::SHA256.hexdigest(after))
      path = File.join(dir, 'Data/Map223.rxdata')
      File.binwrite(path, before)
      begin
        yield dir, path, before, after
      ensure
        M.send(:remove_const, :BEFORE_SHA256)
        M.const_set(:BEFORE_SHA256, original_before)
        M.send(:remove_const, :AFTER_SHA256)
        M.const_set(:AFTER_SHA256, original_after)
      end
    end
  end

  def test_transforms_only_intro_command_and_preserves_existing_player_choice
    map = fixture
    before_tiles = Marshal.dump(map.data)
    before_exit = Marshal.dump(map.events[2])
    assert M.transform!(map)
    assert M.verify!(map, M::NEW_SCRIPT)
    assert_equal before_tiles, Marshal.dump(map.data)
    assert_equal before_exit, Marshal.dump(map.events[2])
    assert_equal M::NEW_SCRIPT, map.events[5].pages.first.list[2].parameters.first
    assert_match(/character_ID < 1/, M::NEW_SCRIPT)
  end

  def test_refuses_modified_event_without_rewriting
    map = fixture
    map.events[5].pages.first.list[1].parameters = ['Wrong introduction']
    before = Marshal.dump(map)
    assert_raises(RuntimeError) { M.transform!(map) }
    assert_equal before, Marshal.dump(map)
  end

  def test_installs_once_and_refuses_unreviewed_map
    with_fixture do |dir, path, before, after|
      assert_equal 'installed', M.install!(dir)['result']
      assert_equal after, File.binread(path)
      assert_equal 'already_installed', M.install!(dir)['result']
      File.binwrite(path, before + 'unknown')
      assert_raises(RuntimeError) { M.install!(dir) }
      assert_equal before + 'unknown', File.binread(path)
    end
  end

  def test_rolls_back_after_backup_failure
    with_fixture do |dir, path, before, _after|
      assert_raises(IOError) do
        M.install!(dir, failure_hook: proc { |stage| raise IOError, 'simulated crash' if stage == :after_backup })
      end
      assert_equal before, File.binread(path)
      refute File.exist?(path + '.player-avatar.tmp')
      refute File.exist?(path + '.player-avatar.bak')
    end
  end
end
