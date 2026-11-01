# frozen_string_literal: true
# Offline upgrade for the privately approved HnS Map223 import. No game assets.
# Run only against a separate staged copy; the original v0.4 remains untouched.
require "digest"

module ShatteredApprovedHNSOpening
  MAP_ID = 223
  ORIGINAL_MAP_SHA256 = "c9cf23ce102cd2540ca8da4d36f1fe9f92e440ace0dc0371dffcc8d72d95b6f8"
  PREFIX = "SHATTERED_HNS:"
  IMPACTS = ["Cries/TYRANITAR", "Mining collapse", "Cries/TYRANITAR",
             "Mining collapse", "Cries/TYRANITAR", "Mining collapse"].freeze
  ROAR = "Cries/TYRANITAR"
  AIPOM_CRY = "Cries/AIPOM"
  AIPOM_SPRITE = "Aipom"
  EVENT_SPECS = {
    1 => ["HnS transfer Route26North_hns", 11, 19],
    5 => ["SHATTERED: Original Johto reception intro", 11, 14],
    6 => ["SHATTERED: Aipom key", 11, 7],
    7 => ["SHATTERED: Route 22 eastern exit", 20, 9]
  }.freeze

  module_function

  def check!(condition, message)
    raise "HnS opening upgrade: #{message}" unless condition
  end

  def cmd(code, *parameters)
    RPG::EventCommand.new(code, 0, parameters)
  end

  def expected_commands
    {
      1 => [cmd(355, "ShatteredGateStory.blocked_johto"), cmd(0)],
      5 => [cmd(101, "Twenty Years Later..."),
            cmd(101, "The old Johto League Reception Gate is deserted."),
            cmd(355, "Shattered.ensure_human"),
            cmd(355, "ShatteredGateStory.run_collapse(#{IMPACTS.inspect}, #{ROAR.inspect})"),
            cmd(123, "A", 0), cmd(0)],
      6 => [cmd(355, "ShatteredGateStory.run_aipom(#{AIPOM_CRY.inspect})"), cmd(0)],
      7 => [cmd(111, 12, "ShatteredGateStory.key_obtained?"),
            cmd(101, "The eastern Kanto door unlocks."),
            cmd(201, 0, 16, 14, 10, 2, 0),
            cmd(411),
            cmd(101, "The eastern Route 22 door is locked. You need the key."),
            cmd(412), cmd(0)]
    }
  end

  def commands_equal?(actual, expected)
    actual.is_a?(Array) && actual.length == expected.length &&
      actual.zip(expected).all? do |left, right|
        left.code == right.code && left.indent == right.indent &&
          left.parameters == right.parameters
      end
  end

  def upgraded?(map)
    expected = expected_commands
    EVENT_SPECS.all? do |id, (_old, x, y)|
      event = map.events[id]
      event && event.name == "#{PREFIX}#{id}" && event.x == x && event.y == y &&
        event.pages.is_a?(Array) && !event.pages.empty? &&
        commands_equal?(event.pages[0].list, expected[id])
    end && map.events[1].pages[0].trigger == 1 &&
      !map.events[1].pages[0].through &&
      map.events[5].pages[0].trigger == 3 &&
      map.events[6].pages.length == 1 &&
      map.events[6].pages[0].graphic.character_name == AIPOM_SPRITE &&
      map.events[6].pages[0].graphic.direction == 8 &&
      map.events[7].pages[0].trigger == 0
  end

  def validate_original!(map)
    check!(map.is_a?(RPG::Map) && map.width == 22 && map.height == 21 &&
           map.events.is_a?(Hash), "not the approved 22x21 native gate")
    EVENT_SPECS.each do |id, (name, x, y)|
      event = map.events[id]
      check!(event && event.id == id && event.name == name &&
             event.x == x && event.y == y, "event #{id} source identity changed")
    end
    check!(map.events[5].pages.length == 2 &&
           map.events[5].pages[0].trigger == 3 &&
           map.events[5].pages[0].list.any? { |c| c.code == 355 && c.parameters == ["Shattered.ensure_human"] },
           "original intro event changed")
    check!(map.events[6].pages.length == 2 &&
           map.events[6].pages[0].list.any? { |c| c.code == 355 && c.parameters == ["$game_switches[990] = true"] },
           "original Aipom placeholder changed")
    check!(map.events[7].pages.length == 1 &&
           map.events[7].pages[0].list.first.parameters == [12, "$game_switches[990]"],
           "original east-door key condition changed")
    check!(map.events[1].pages.length == 1 &&
           map.events[1].pages[0].list.first.parameters == ["Rocks and structural debris block the entrance."],
           "original south blocker changed")
  end

  def verify_inputs!(root)
    marker = File.join(root, "SHATTERED_STAGING_REPORT.json")
    check!(File.file?(marker) && !File.symlink?(marker), "not a staged project")
    pbs = File.join(root, "PBS/items.txt")
    check!(File.file?(pbs) && !File.symlink?(pbs) &&
           File.binread(pbs).scan(/^\[SHATTEREDGATEKEY\][ \t]*\r?$/n).length == 1,
           "real gate key missing from PBS/items.txt; run install_gate_key_pbs.py first")
    ["Audio/SE/Cries/TYRANITAR.ogg", "Audio/SE/Mining collapse.ogg",
     "Audio/SE/Cries/AIPOM.ogg", "Graphics/Characters/Aipom.png"].each do |relative|
      path = File.join(root, relative)
      check!(File.file?(path) && !File.symlink?(path), "missing private asset #{relative}")
    end
  end

  def upgrade!(root, expected_sha256: ORIGINAL_MAP_SHA256)
    root = File.expand_path(root)
    verify_inputs!(root)
    path = File.join(root, "Data/Map223.rxdata")
    check!(File.file?(path) && !File.symlink?(path), "native Map223 missing")
    raw = File.binread(path)
    map = Marshal.load(raw)
    check!(map.is_a?(RPG::Map) && map.width == 22 && map.height == 21,
           "not the approved native reception gate")
    return "unchanged" if upgraded?(map)
    check!(Digest::SHA256.hexdigest(raw) == expected_sha256,
           "Map223 differs from the reviewed private candidate; no changes made")
    validate_original!(map)
    commands = expected_commands
    EVENT_SPECS.each do |id, (_old, _x, _y)|
      event = map.events[id]
      event.name = "#{PREFIX}#{id}"
      event.pages[0].list = commands[id]
    end
    south = map.events[1].pages[0]
    south.trigger = 1
    south.through = false
    intro = map.events[5].pages[0]
    intro.trigger = 3
    aipom_event = map.events[6]
    aipom_event.pages = [aipom_event.pages[0]]
    aipom_event.pages[0].through = false
    aipom_event.pages[0].graphic.character_name = AIPOM_SPRITE
    aipom_event.pages[0].graphic.direction = 8
    check!(upgraded?(map), "upgraded native events failed postconditions")
    new_bytes = Marshal.dump(map)
    check!(Marshal.load(new_bytes).is_a?(RPG::Map), "cannot decode upgraded map")
    tmp, backup = path + ".shattered-opening.tmp", path + ".shattered-opening.bak"
    check!(!File.exist?(tmp) && !File.exist?(backup) &&
           !File.symlink?(tmp) && !File.symlink?(backup), "stale map transaction")
    moved = false
    begin
      File.binwrite(tmp, new_bytes)
      check!(File.binread(path) == raw, "map changed during upgrade")
      begin
        File.rename(path, backup)
        moved = true
      rescue StandardError
        moved = true if !File.exist?(path) && File.file?(backup)
        raise
      end
      File.rename(tmp, path)
      check!(upgraded?(Marshal.load(File.binread(path))), "installed map failed verification")
    rescue StandardError => error
      if moved && File.file?(backup)
        File.delete(path) if File.exist?(path)
        File.rename(backup, path)
      end
      raise error
    ensure
      File.delete(tmp) if File.exist?(tmp)
    end
    File.delete(backup)
    "upgraded"
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby upgrade_approved_hns_opening.rb /private/staged/Essentials" unless ARGV.length == 1
  puts ShatteredApprovedHNSOpening.upgrade!(ARGV.fetch(0))
end
