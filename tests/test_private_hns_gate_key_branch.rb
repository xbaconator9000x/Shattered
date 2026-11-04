# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'digest'
require_relative '../scripts/repair_private_hns_gate_key_branch'

class HnsGateKeyBranchTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('shattered-hns-key-')
    FileUtils.mkdir_p(File.join(@root, 'Data'))
    File.write(File.join(@root, 'SHATTERED_STAGING_REPORT.json'), '{}')
    @path = File.join(@root, 'Data', 'Map223.rxdata')
    File.binwrite(File.join(@root, 'Data', 'MapInfos.rxdata'), Marshal.dump({ 223 => RPG::MapInfo.new }))
    @map = RPG::Map.new
    @map.width, @map.height, @map.tileset_id = 22, 21, 1
    @map.data = 'synthetic tile data only'
    @event = RPG::Event.new(20, 9)
    @event.id, @event.name = 7, 'SHATTERED_HNS:7'
    page = RPG::Event::Page.new
    page.trigger, page.through = 0, false
    page.list = [
      RPG::EventCommand.new(111, 0, [12, 'ShatteredGateStory.key_obtained?']),
      RPG::EventCommand.new(101, 0, ['The eastern Kanto door unlocks.']),
      RPG::EventCommand.new(201, 0, [0, 16, 14, 10, 2, 0]),
      RPG::EventCommand.new(411, 0, []),
      RPG::EventCommand.new(101, 0, ['The eastern Route 22 door is locked. You need the key.']),
      RPG::EventCommand.new(412, 0, []),
      RPG::EventCommand.new(0, 0, [])
    ]
    @event.pages = [page]
    @other = RPG::Event.new(5, 6)
    @other.id, @other.name = 3, 'source map sentinel'
    @map.events = { 3 => @other, 7 => @event }
    save_map
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def save_map
    File.binwrite(@path, Marshal.dump(@map))
    @sha = Digest::SHA256.file(@path).hexdigest
  end

  def repair(sha = @sha)
    ShatteredGateEastGuardRepair.repair!(@root, sha)
  end

  def test_unguarded_native_transfer_becomes_true_branch_only
    result = repair
    assert result['changed']
    after = load_data(@path)
    assert_equal [0, 1, 1, 0, 1, 0, 0], after.events[7].pages.first.list.map(&:indent)
    assert_equal [0, 16, 14, 10, 2, 0], after.events[7].pages.first.list[2].parameters
    assert_equal 'synthetic tile data only', after.data
    assert_equal Marshal.dump(@other), Marshal.dump(after.events[3])
    assert_equal :safe, ShatteredGateEastGuardRepair.event_status!(after.events[7])
  end

  def test_second_run_is_idempotent_without_rewriting_map
    repair
    before = File.binread(@path)
    refute repair['changed']
    assert_equal before, File.binread(@path)
  end

  def test_map_sha_mismatch_fails_closed
    assert_raises(RuntimeError) { repair('0' * 64) }
    assert_equal [0] * 7, load_data(@path).events[7].pages.first.list.map(&:indent)
  end

  def test_foreign_transfer_or_script_fails_closed
    @event.pages.first.list[2].parameters[1] = 10
    save_map
    assert_raises(RuntimeError) { repair }
    assert_equal 10, load_data(@path).events[7].pages.first.list[2].parameters[1]
  end

  def test_partial_indentation_fails_closed
    @event.pages.first.list[1].indent = 1
    save_map
    assert_raises(RuntimeError) { repair }
    assert_equal [0, 1, 0, 0, 0, 0, 0], load_data(@path).events[7].pages.first.list.map(&:indent)
  end

  def test_stale_backup_blocks_and_preserves_map
    File.write(@path + '.shattered_gate_guard.bak', 'unrecovered')
    before = File.binread(@path)
    assert_raises(RuntimeError) { repair }
    assert_equal before, File.binread(@path)
  end

  def test_non_staged_project_fails_closed
    File.delete(File.join(@root, 'SHATTERED_STAGING_REPORT.json'))
    assert_raises(RuntimeError) { repair }
  end
end
