#!/usr/bin/env ruby
# frozen_string_literal: true
# Native Viridian arrival/Center handoff for a PRIVATE staged Essentials v21.1 project.
# Removes the v0.4 prototype-ending autorun, starts rain on arrival and ends it
# on first Center entry. Does NOT install the walled city or completed escort.
# Never upload the resulting RPG Maker map/system binaries or Pokémon assets.
require 'json'
require 'digest'
require 'pathname'
require_relative 'private_rgss_writer'

module ShatteredPrivateViridianHandoff
  CITY_SHA = '0fc83d0c1d55d9286727fc948759730d23d792b9e34524dbe6669f0076879b25'
  CENTER_SHA = 'cd6bd89cb6b06307422058882eade1ca916a1a263a6ccd919dee2a9639cdbe03'
  SWITCHES = { started: 993, arrived: 994, center: 995, rain: 996 }.freeze
  NAMES = { 993 => 'Shattered Viridian entered', 994 => 'Shattered Viridian arrival',
            995 => 'Shattered Center visited', 996 => 'Shattered Viridian rain' }.freeze
  module_function

  def cmd(code, args = [])
    RPG::EventCommand.new(code, 0, args)
  end

  def page(trigger = 0, switch = nil)
    p = RPG::Event::Page.new
    p.trigger = trigger
    p.through = true
    if switch
      p.condition.switch1_valid = true
      p.condition.switch1_id = switch
    end
    p
  end

  def event(name, x, y, pages)
    e = RPG::Event.new(x, y)
    e.name = name
    e.pages = pages
    e
  end

  def install!(project)
    project = Pathname.new(project).expand_path
    raise 'Unsafe/nonstaged project' unless project.directory? && !project.symlink? &&
      project.join('SHATTERED_STAGING_REPORT.json').file?
    root = project.join('Data')
    city_path = root.join('Map010.rxdata')
    center_path = root.join('Map011.rxdata')
    system_path = root.join('System.rxdata')
    files = [city_path, center_path, system_path]
    files.each { |p| raise "Missing/symlinked file #{p}" unless p.file? && !p.symlink? }
    raise 'Unreviewed city map' unless Digest::SHA256.file(city_path).hexdigest == CITY_SHA
    raise 'Unreviewed Center map' unless Digest::SHA256.file(center_path).hexdigest == CENTER_SHA
    city = Marshal.load(city_path.binread)
    center = Marshal.load(center_path.binread)
    system = Marshal.load(system_path.binread)
    raise 'Wrong native map dimensions' unless
      [city.width, city.height, center.width, center.height] == [50, 40, 20, 15]
    arrival = city.events[23]
    raise 'Unreviewed arrival event' unless arrival &&
      arrival.name == 'SHATTERED: Viridian arrival' &&
      [arrival.x, arrival.y] == [25, 20] && arrival.pages.length == 2 &&
      arrival.pages[0].trigger == 3 &&
      arrival.pages[0].list.any? { |c| c.code == 101 &&
        c.parameters.join.include?('End of Shattered Essentials prototype 0.1.') }
    raise 'Unreviewed Center exit' unless center.events[1] &&
      center.events[1].pages.any? { |p| p.list.any? { |c|
        c.code == 201 && c.parameters == [0, 10, 26, 27, 0, 1] } }
    raise 'Unreviewed native event slots' unless city.events.keys.max == 23 &&
      center.events.keys.max == 10
    switches = system.instance_variable_get(:@switches)
    raise 'Switch table missing or reserved IDs occupied' unless switches.is_a?(Array) &&
      NAMES.keys.all? { |id| switches[id].to_s.strip.empty? }

    # Refuse switch collisions with existing map pages and switch commands.
    Dir.glob(root.join('Map[0-9][0-9][0-9].rxdata').to_s).each do |path|
      map = Marshal.load(File.binread(path))
      next unless map.is_a?(RPG::Map)
      map.events.each_value do |e|
        e.pages.each do |p|
          cond = p.condition
          raise "Reserved switch already used in #{path}" if
            (cond.switch1_valid && NAMES.key?(cond.switch1_id)) ||
            (cond.switch2_valid && NAMES.key?(cond.switch2_id)) ||
            p.list.any? { |c| c.code == 121 && c.parameters[0].is_a?(Integer) &&
              c.parameters[1].is_a?(Integer) &&
              NAMES.keys.any? { |id| id.between?(c.parameters[0], c.parameters[1]) } }
        end
      end
    end

    first = page(3)
    first.list = [
      cmd(101, ['Viridian City. The guards are keeping watch near the entrance.']),
      cmd(101, ['Guard: Stay close. The wild Pokemon are becoming more aggressive.']),
      cmd(236, [1, 6, 20]),
      cmd(355, ['ShatteredViridian.start!(993, 996); ShatteredViridian.arrive!(994)']),
      cmd(0)
    ]
    done = page(0, 993)
    done.list = [cmd(0)]
    arrival.pages = [first, done]

    rain = page(4, 996)
    rain.list = [cmd(236, [1, 6, 0]), cmd(106, [600]), cmd(0)]
    rain_event = event('SHATTERED_VIRIDIAN:rain_restore', 1, 1, [page, rain])
    rain_event.id = 24
    city.events[24] = rain_event

    start = page(3, 993)
    start.list = [cmd(236, [0, 0, 20]),
                  cmd(355, ['ShatteredViridian.center!(995, 996)']), cmd(0)]
    finish = page(0, 995)
    finish.list = [cmd(0)]
    center_event = event('SHATTERED_VIRIDIAN:center_first_visit',
                         8, 7, [page, start, finish])
    center_event.id = 11
    center.events[11] = center_event
    NAMES.each { |id, name| switches[id] = name }

    updated = { city_path => Marshal.dump(city), center_path => Marshal.dump(center),
                system_path => Marshal.dump(system) }
    updated.each { |_path, bytes|
      raise 'Invalid native Marshal roundtrip' unless Marshal.dump(Marshal.load(bytes)) == bytes
    }
    backups = files.to_h { |path| [path, Pathname.new(path.to_s + '.shattered_viridian.bak')] }
    raise 'Stale private transaction' if backups.values.any? { |p| p.exist? || p.symlink? }
    staged = []
    begin
      files.each { |path| File.rename(path, backups.fetch(path)); staged << path }
      updated.each { |path, bytes| File.binwrite(path, bytes) }
    rescue Exception
      staged.each { |path| File.delete(path) if path.file? }
      staged.each { |path| File.rename(backups.fetch(path), path) if backups.fetch(path).file? }
      raise
    end
    backups.each_value { |path| File.delete(path) }
    {
      'city_sha256' => Digest::SHA256.file(city_path).hexdigest,
      'center_sha256' => Digest::SHA256.file(center_path).hexdigest,
      'system_sha256' => Digest::SHA256.file(system_path).hexdigest,
      'native_events_added' => 2, 'prototype_end_marker_removed' => true,
      'weather_center_handoff_installed' => true,
      'escort_runtime_verified' => false, 'native_gameplay_verified' => false,
      'android_verified' => false
    }
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby upgrade_private_viridian_handoff.rb PRIVATE_STAGED_PROJECT' unless ARGV.length == 1
  puts JSON.pretty_generate(ShatteredPrivateViridianHandoff.install!(ARGV[0]))
end
