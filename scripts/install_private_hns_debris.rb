#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline-only, rights-safe event installer. Never run against the original game.
require 'digest'
require 'pathname'
require_relative 'private_rgss_writer'

module ShatteredHNSDebris
  MAP_ID = 223
  SWITCH_ID = 997
  SOURCE_SHA256 = 'a972e7963d7c0ed4ab773e90dd054021e7e3a76801d79731fdd4eb669f1656cf'
  SPRITE = 'Object rock'
  PREFIX = 'SHATTERED_HNS_DEBRIS:'
  SOURCE_TILE_SHA256 = 'e45db0ad304e1de5378f6761fb58bce0c8a3cf3782d0ad190cc36709de0ed3de'
  PRESERVED_EVENT_SHA256 = {
    2 => '899787f343b9408186364f6785fbe630753650ea41292880a8d6a78c325e6362',
    3 => '6b7cdd8783e044d67740216936d8016db309775787d2ff4482d6f33935a61120',
    4 => '483332598dbaa0734d15abb540944eab798256d327b5821741a6a84a6fb6d232',
    5 => '2fb256b2c680d11e595da99cd7c3622ba493e5b22efb53f6159d2dcb4ecf64c2',
    6 => 'deec0f7d138775c79772e00fcd4112ec33e390cf0df7c917b62809a8b34e61f3',
    7 => 'e75453662824c5a4dfd09eb0676596dbd4e1ed37089eb6357ebbfadec751409e'
  }.freeze
  BLOCKERS = { 1 => [11, 19], 8 => [10, 19], 9 => [12, 19] }.freeze
  module_function

  def check!(condition, message)
    raise "HnS Johto debris: #{message}" unless condition
  end

  def command(code, *args)
    RPG::EventCommand.new(code, 0, args)
  end

  def rock_page
    page = RPG::Event::Page.new
    page.condition.switch1_valid = true
    page.condition.switch1_id = SWITCH_ID
    page.graphic.character_name = SPRITE
    page.graphic.direction = 2
    page.graphic.pattern = 0
    page.through = false
    page.trigger = 0
    page.list = [command(355, 'ShatteredGateStory.blocked_johto'), command(0)]
    page
  end

  def empty_page
    page = RPG::Event::Page.new
    page.through = true
    page.trigger = 0
    page.list = [command(0)]
    page
  end

  def installed?(map)
    return false unless map.is_a?(RPG::Map) && map.events.is_a?(Hash)
    BLOCKERS.all? do |id, (x, y)|
      event = map.events[id]
      next false unless event && event.x == x && event.y == y &&
        event.pages.is_a?(Array) && event.pages.length == 2
      next false unless id == 1 ? event.name == 'SHATTERED_HNS:1' : event.name == "#{PREFIX}#{id}"
      first, second = event.pages
      first.through == true && second.through == false &&
        second.condition.switch1_valid == true &&
        second.condition.switch1_id == SWITCH_ID &&
        second.graphic.character_name == SPRITE &&
        second.graphic.direction == 2 && second.graphic.pattern == 0 &&
        second.trigger == 0 &&
        second.list.map(&:code) == [355, 0] &&
        second.list.first.parameters == ['ShatteredGateStory.blocked_johto']
    end
  end

  def verify_preserved!(map)
    check!(Digest::SHA256.hexdigest(map.data.instance_variable_get(:@bytes)) == SOURCE_TILE_SHA256,
           'original tile layers changed')
    PRESERVED_EVENT_SHA256.each do |id, digest|
      check!(Digest::SHA256.hexdigest(Marshal.dump(map.events.fetch(id))) == digest,
             "unrelated native event #{id} changed")
    end
  end

  def install!(project, expected_sha256: SOURCE_SHA256)
    root = Pathname.new(project).expand_path
    check!(root.directory? && !root.symlink?, 'private project directory missing')
    check!(root.join('SHATTERED_STAGING_REPORT.json').file?, 'staging marker missing')
    image = root.join('Graphics/Characters/Object rock.png')
    check!(image.file? && !image.symlink?, 'reviewed private rock character sprite missing')
    # Verify the RGSS character sheet dimensions without reading/distributing pixels.
    png = image.binread(24)
    check!(png.byteslice(0, 8) == "\x89PNG\r\n\x1a\n".b &&
           png.byteslice(16, 8).unpack('N2') == [128, 128],
           'rock sprite must be a 128x128 RPG Maker XP character sheet')
    path = root.join('Data/Map223.rxdata')
    check!(path.file? && !path.symlink?, 'native Map223 missing')
    raw = path.binread
    map = Marshal.load(raw)
    check!(map.is_a?(RPG::Map) && map.width == 22 && map.height == 21 &&
           map.events.is_a?(Hash), 'unexpected native gate map')
    check!(Marshal.dump(map) == raw, 'unsafe native Marshal codec')
    if installed?(map)
      check!(map.events.keys.sort == (1..9).to_a, 'installed event inventory changed')
      verify_preserved!(map) if expected_sha256 == SOURCE_SHA256
      return 'unchanged'
    end
    check!(Digest::SHA256.hexdigest(raw) == expected_sha256,
           'unreviewed native Map223 revision; refusing to change it')
    check!(map.events.keys.sort == (1..7).to_a,
           'expected exact reviewed gate event inventory')
    verify_preserved!(map) if expected_sha256 == SOURCE_SHA256
    central = map.events.fetch(1)
    check!(central.name == 'SHATTERED_HNS:1' &&
           [central.x, central.y] == BLOCKERS.fetch(1) &&
           central.pages.length == 1 && central.pages[0].list.map(&:code) == [355, 0] &&
           central.pages[0].list.first.parameters == ['ShatteredGateStory.blocked_johto'],
           'Johto dialogue blocker changed')
    check!(BLOCKERS.values.all? { |x, y| x.between?(0, 21) && y.between?(0, 20) },
           'blocker outside native map')
    # Existing centre dialogue remains available before the collapse.
    central.pages[0].through = true
    central.pages << rock_page
    BLOCKERS.each do |id, (x, y)|
      next if id == 1
      event = RPG::Event.new(x, y)
      event.id = id
      event.name = "#{PREFIX}#{id}"
      event.pages = [empty_page, rock_page]
      map.events[id] = event
    end
    check!(installed?(map), 'post-install event verification failed')
    updated = Marshal.dump(map)
    check!(Marshal.load(updated).data.instance_variable_get(:@bytes) ==
           Marshal.load(raw).data.instance_variable_get(:@bytes),
           'map tile layers unexpectedly changed')
    tmp = Pathname.new(path.to_s + '.shattered-debris.tmp')
    backup = Pathname.new(path.to_s + '.shattered-debris.bak')
    check!(!tmp.exist? && !backup.exist? && !tmp.symlink? && !backup.symlink?,
           'stale transaction; manual recovery required')
    moved = false
    begin
      tmp.binwrite(updated)
      check!(path.binread == raw, 'map changed during installation')
      File.rename(path, backup)
      moved = true
      File.rename(tmp, path)
      check!(installed?(Marshal.load(path.binread)), 'installed map failed verification')
    rescue StandardError => error
      if moved && backup.file?
        File.delete(path) if path.exist?
        File.rename(backup, path)
      end
      raise error
    ensure
      File.delete(tmp) if tmp.exist?
    end
    File.delete(backup)
    'installed'
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby install_private_hns_debris.rb /private/staged/Essentials' unless ARGV.length == 1
  puts ShatteredHNSDebris.install!(ARGV.fetch(0))
end
