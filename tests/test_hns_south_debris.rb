# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'digest'
require_relative '../scripts/install_private_hns_debris'

class HNSSouthDebrisTest < Minitest::Test
  I = ShatteredHNSDebris
  def setup
    @root = Dir.mktmpdir('hns-debris-')
    FileUtils.mkdir_p(File.join(@root, 'Data'))
    FileUtils.mkdir_p(File.join(@root, 'Graphics/Characters'))
    File.write(File.join(@root, 'SHATTERED_STAGING_REPORT.json'), '{}')
    File.binwrite(File.join(@root, 'Graphics/Characters/Object rock.png'),
      "\x89PNG\r\n\x1a\n".b + "\x00".b * 8 + [128, 128].pack('N2'))
    @map = RPG::Map.new
    @map.width, @map.height = 22, 21
    table = Table._load([3, 22, 21, 3, 22 * 21 * 3].pack('V5') +
                        ("\x00".b * (22 * 21 * 3 * 2)))
    @map.data = table
    @map.events = {}
    {1 => [11, 19], 2 => [11, 1], 3 => [10, 1], 4 => [1, 9],
     5 => [11, 14], 6 => [11, 7], 7 => [20, 9]}.each do |id, (x, y)|
      event = RPG::Event.new(x, y)
      event.id = id
      event.name = id == 1 ? 'SHATTERED_HNS:1' : "SHATTERED_HNS:#{id}"
      event.pages.first.list = id == 1 ?
        [I.command(355, 'ShatteredGateStory.blocked_johto'), I.command(0)] :
        [I.command(0)]
      @map.events[id] = event
    end
    @path = File.join(@root, 'Data/Map223.rxdata')
    File.binwrite(@path, Marshal.dump(@map))
    @original = File.binread(@path)
    @sha = Digest::SHA256.hexdigest(@original)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_installs_solid_rock_pages_without_changing_existing_warps_or_tiles
    assert_equal 'installed', I.install!(@root, expected_sha256: @sha)
    map = Marshal.load(File.binread(@path))
    assert I.installed?(map)
    assert_equal [1, 8, 9], I::BLOCKERS.keys
    assert_equal [10, 11, 12], I::BLOCKERS.values.map(&:first).sort
    assert_equal Marshal.dump(@map.data), Marshal.dump(map.data)
    (2..7).each do |id|
      assert_equal Marshal.dump(@map.events[id]), Marshal.dump(map.events[id])
    end
    I::BLOCKERS.each do |id, point|
      event = map.events.fetch(id)
      assert_equal point, [event.x, event.y]
      assert event.pages.first.through
      refute event.pages.last.through
      assert event.pages.last.condition.switch1_valid
      assert_equal 997, event.pages.last.condition.switch1_id
      assert_equal 'Object rock', event.pages.last.graphic.character_name
    end
    installed = File.binread(@path)
    assert_equal 'unchanged', I.install!(@root, expected_sha256: @sha)
    assert_equal installed, File.binread(@path)
  end

  def test_rejects_unreviewed_map_and_preserves_bytes
    @map.events[7].name = 'other'
    File.binwrite(@path, Marshal.dump(@map))
    before = File.binread(@path)
    assert_raises(RuntimeError) { I.install!(@root, expected_sha256: @sha) }
    assert_equal before, File.binread(@path)
  end

  def test_missing_private_sprite_rejected_without_mutation
    File.delete(File.join(@root, 'Graphics/Characters/Object rock.png'))
    assert_raises(RuntimeError) { I.install!(@root, expected_sha256: @sha) }
    assert_equal @original, File.binread(@path)
  end

  def test_rejects_partial_install_without_mutation
    @map.events[8] = RPG::Event.new(10, 19)
    File.binwrite(@path, Marshal.dump(@map))
    before = File.binread(@path)
    assert_raises(RuntimeError) { I.install!(@root, expected_sha256: @sha) }
    assert_equal before, File.binread(@path)
  end

  def test_failed_second_rename_rolls_back
    original_rename = File.method(:rename)
    calls = 0
    File.stub(:rename, lambda { |src, dst|
      calls += 1
      raise IOError, 'injected failure' if calls == 2
      original_rename.call(src, dst)
    }) do
      assert_raises(IOError) { I.install!(@root, expected_sha256: @sha) }
    end
    assert_equal @original, File.binread(@path)
    refute File.exist?(@path + '.shattered-debris.tmp')
    refute File.exist?(@path + '.shattered-debris.bak')
  end
end
