# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"

module RPG
  class Map
    attr_accessor :width, :height, :events, :data
  end
  class Event
    attr_accessor :id, :name, :x, :y, :pages
    class Page
      attr_accessor :trigger, :through, :graphic, :list
      class Graphic
        attr_accessor :character_name, :direction
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

# Simulate a broken Table._load implementation that silently drops tile bytes.
class LossyNativeTable
  def initialize(raw); @raw = raw; end
  def self._load(_raw); new(""); end
  def _dump(_level); @raw; end
end

require_relative "../scripts/upgrade_approved_hns_opening"

class ApprovedHNSOpeningUpgradeTest < Minitest::Test
  U = ShatteredApprovedHNSOpening

  def event(id, name, x, y, commands, trigger: 0, second: false)
    e = RPG::Event.new
    e.id, e.name, e.x, e.y = id, name, x, y
    p = RPG::Event::Page.new
    p.trigger, p.through = trigger, true
    p.graphic = RPG::Event::Page::Graphic.new
    p.graphic.character_name = ""
    p.graphic.direction = 2
    p.list = commands
    e.pages = second ? [p, RPG::Event::Page.new] : [p]
    e
  end

  def setup
    @dir = Dir.mktmpdir("hns-upgrade-test-")
    FileUtils.mkdir_p(File.join(@dir, "Data"))
    FileUtils.mkdir_p(File.join(@dir, "PBS"))
    FileUtils.mkdir_p(File.join(@dir, "Audio/SE/Cries"))
    FileUtils.mkdir_p(File.join(@dir, "Graphics/Characters"))
    File.write(File.join(@dir, "SHATTERED_STAGING_REPORT.json"), "{}")
    File.write(File.join(@dir, "PBS/items.txt"), "[SHATTEREDGATEKEY]\nFlags = KeyItem\n")
    %w[Cries/TYRANITAR Cries/AIPOM].each do |sound|
      File.write(File.join(@dir, "Audio/SE/#{sound}.ogg"), "private")
    end
    File.write(File.join(@dir, "Audio/SE/Mining collapse.ogg"), "private")
    File.write(File.join(@dir, "Graphics/Characters/Aipom.png"), "private")
    @map = RPG::Map.new
    @map.width, @map.height, @map.data = 22, 21, "preserve-layer-bytes"
    @map.events = {
      1 => event(1, "HnS transfer Route26North_hns", 11, 19,
                 [U.cmd(101, "Rocks and structural debris block the entrance."), U.cmd(0)]),
      2 => event(2, "HnS transfer VictoryRoadKanto_B2F_hns", 11, 1,
                 [U.cmd(201, 0, 224, 30, 46, 8, 0), U.cmd(0)], trigger: 1),
      5 => event(5, "SHATTERED: Original Johto reception intro", 11, 14,
                 [U.cmd(101, "Twenty Years Later..."), U.cmd(355, "Shattered.ensure_human"), U.cmd(0)],
                 trigger: 3, second: true),
      6 => event(6, "SHATTERED: Aipom key", 11, 7,
                 [U.cmd(355, "$game_switches[990] = true"), U.cmd(0)], second: true),
      7 => event(7, "SHATTERED: Route 22 eastern exit", 20, 9,
                 [U.cmd(111, 12, "$game_switches[990]"), U.cmd(0)])
    }
    @map_path = File.join(@dir, "Data/Map223.rxdata")
    File.binwrite(@map_path, Marshal.dump(@map))
    @before = File.binread(@map_path)
    @pin = Digest::SHA256.hexdigest(@before)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_real_key_gate_and_collapse_preserve_unrelated_warp
    assert_equal "upgraded", U.upgrade!(@dir, expected_sha256: @pin)
    map = Marshal.load(File.binread(@map_path))
    assert_equal "preserve-layer-bytes", map.data
    assert_equal Marshal.dump(@map.events[2]), Marshal.dump(map.events[2])
    assert_equal 1, map.events[1].pages.first.trigger
    refute map.events[1].pages.first.through
    assert_equal 3, map.events[5].pages.first.trigger
    assert_includes map.events[5].pages.first.list.map(&:parameters).flatten.join(" "),
                    "ShatteredGateStory.run_collapse"
    assert_equal "Aipom", map.events[6].pages.first.graphic.character_name
    assert_equal 8, map.events[6].pages.first.graphic.direction
    assert_equal 1, map.events[6].pages.length
    assert_includes map.events[6].pages.first.list.first.parameters.first, "get_character(0)"
    assert_equal [12, "ShatteredGateStory.key_obtained?"],
                 map.events[7].pages.first.list.first.parameters
    # RMXP interpreter dispatches Conditional Branch commands by indent.
    # The transfer MUST live inside the true branch; a flat list makes
    # it run even if the player has not obtained Aipom's key.
    east_commands = map.events[7].pages.first.list
    assert_equal [111, 101, 201, 411, 101, 412, 0],
                 east_commands.map(&:code)
    assert_equal [0, 1, 1, 0, 1, 0, 0],
                 east_commands.map(&:indent)
    assert_equal [0, 16, 14, 10, 2, 0],
                 east_commands[2].parameters
    assert_equal "unchanged", U.upgrade!(@dir, expected_sha256: @pin)
  end

  def test_previous_native_aipom_script_migrates_without_changing_other_events
    assert_equal "upgraded", U.upgrade!(@dir, expected_sha256: @pin)
    map = Marshal.load(File.binread(@map_path))
    old_warp = Marshal.dump(map.events[2])
    map.events[6].pages.first.list = U.expected_commands(legacy_aipom: true)[6]
    assert U.upgraded?(map, legacy_aipom: true)
    refute U.upgraded?(map)
    File.binwrite(@map_path, Marshal.dump(map))
    legacy_sha = Digest::SHA256.file(@map_path).hexdigest
    assert_equal "upgraded", U.upgrade!(@dir, expected_sha256: @pin,
                                      expected_legacy_sha256: legacy_sha)
    repaired = Marshal.load(File.binread(@map_path))
    assert U.upgraded?(repaired)
    assert_equal old_warp, Marshal.dump(repaired.events[2])
    assert_equal "unchanged", U.upgrade!(@dir, expected_sha256: @pin)
  end

  def test_previous_aipom_migration_refuses_unrelated_map_drift
    assert_equal "upgraded", U.upgrade!(@dir, expected_sha256: @pin)
    map = Marshal.load(File.binread(@map_path))
    map.events[6].pages.first.list = U.expected_commands(legacy_aipom: true)[6]
    approved_legacy_sha = Digest::SHA256.hexdigest(Marshal.dump(map))
    map.events[2].name = "unreviewed altered warp"
    File.binwrite(@map_path, Marshal.dump(map))
    changed = File.binread(@map_path)
    assert_raises(RuntimeError) do
      U.upgrade!(@dir, expected_sha256: @pin,
                 expected_legacy_sha256: approved_legacy_sha)
    end
    assert_equal changed, File.binread(@map_path)
  end

  def test_legacy_flat_branch_is_not_mistaken_for_safe_upgrade
    assert_equal "upgraded", U.upgrade!(@dir, expected_sha256: @pin)
    map = Marshal.load(File.binread(@map_path))
    map.events[7].pages.first.list.each { |command| command.indent = 0 }
    File.binwrite(@map_path, Marshal.dump(map))
    unsafe = File.binread(@map_path)
    refute U.upgraded?(map)
    # Do not silently repair a different map revision; the separate private
    # SHA-guarded migration handles already-shipped unsafe candidate maps.
    assert_raises(RuntimeError) { U.upgrade!(@dir, expected_sha256: @pin) }
    assert_equal unsafe, File.binread(@map_path)
  end

  def test_rejects_lossy_native_table_codec_before_touching_map
    map = Marshal.load(@before)
    map.data = LossyNativeTable.new("actual tile layers")
    File.binwrite(@map_path, Marshal.dump(map))
    altered = File.binread(@map_path)
    error = assert_raises(RuntimeError) do
      U.upgrade!(@dir, expected_sha256: Digest::SHA256.hexdigest(altered))
    end
    assert_match(/cannot preserve original map layers/, error.message)
    assert_equal altered, File.binread(@map_path)
  end

  def test_missing_key_fails_without_writing
    File.write(File.join(@dir, "PBS/items.txt"), "[POTION]")
    assert_raises(RuntimeError) { U.upgrade!(@dir, expected_sha256: @pin) }
    assert_equal @before, File.binread(@map_path)
  end

  def test_missing_sprite_fails_without_writing
    File.delete(File.join(@dir, "Graphics/Characters/Aipom.png"))
    assert_raises(RuntimeError) { U.upgrade!(@dir, expected_sha256: @pin) }
    assert_equal @before, File.binread(@map_path)
  end

  def test_modified_source_event_rejected_without_writing
    map = Marshal.load(@before)
    map.events[7].name = "Other NPC"
    File.binwrite(@map_path, Marshal.dump(map))
    changed = File.binread(@map_path)
    assert_raises(RuntimeError) { U.upgrade!(@dir, expected_sha256: @pin) }
    assert_equal changed, File.binread(@map_path)
  end

  def test_failed_rename_restores_original
    old_rename = File.method(:rename)
    count = 0
    File.stub(:rename, lambda { |src, dst|
      count += 1
      raise IOError, "injected second rename failure" if count == 2
      old_rename.call(src, dst)
    }) do
      assert_raises(IOError) { U.upgrade!(@dir, expected_sha256: @pin) }
    end
    assert_equal @before, File.binread(@map_path)
    refute File.exist?(@map_path + ".shattered-opening.tmp")
    refute File.exist?(@map_path + ".shattered-opening.bak")
  end

  def test_post_rename_faults_restore_original_at_both_boundaries
    [1, 2].each do |fail_at|
      old_rename = File.method(:rename)
      count = 0
      File.stub(:rename, lambda { |src, dst|
        count += 1
        result = old_rename.call(src, dst)
        raise IOError, "post-rename fault #{fail_at}" if count == fail_at
        result
      }) do
        assert_raises(IOError) { U.upgrade!(@dir, expected_sha256: @pin) }
      end
      assert_equal @before, File.binread(@map_path)
      refute File.exist?(@map_path + ".shattered-opening.tmp")
      refute File.exist?(@map_path + ".shattered-opening.bak")
    end
  end
end

require_relative "../essentials/Plugins/Shattered Gate Story/001_GateStory"

class HNSRoarPathTest < Minitest::Test
  def test_real_essentials_cry_path_plays_in_collapse
    $PokemonGlobal = Object.new
    played = []
    [:pbSEPlay, :pbWait, :pbMessage, :_INTL].each do |name|
      ShatteredGateStory.define_singleton_method(name) { |value| value }
    end
    ShatteredGateStory.stub(:pbSEPlay, ->(name) { played << name }) do
      ShatteredGateStory.stub(:pbWait, ->(_frames) {}) do
        ShatteredGateStory.stub(:pbMessage, ->(_text) {}) do
          ShatteredGateStory.stub(:_INTL, ->(text) { text }) do
            assert ShatteredGateStory.run_collapse(
              ShatteredApprovedHNSOpening::IMPACTS,
              ShatteredApprovedHNSOpening::ROAR)
          end
        end
      end
    end
    assert_equal 7, played.length
    assert_equal "Cries/TYRANITAR", played.last
    assert_equal 6, ShatteredGateStory.state[:impacts]
    assert ShatteredGateStory.state[:final_roar]
  ensure
    $PokemonGlobal = nil
  end
end
