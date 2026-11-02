#!/usr/bin/env ruby
# frozen_string_literal: true
# Install a reversible, provisional Viridian school mentor in the PRIVATE game.
# This does not claim original Shattered dojo scene/location parity.
# No commercial art, map bytes or third-party source belongs in GitHub.
require "digest"
require "json"
require "pathname"
require_relative "private_rgss_writer"
require_relative "../essentials/Plugins/Shattered Dojo/002_Install"

module ShatteredPrivateViridianMentor
  MAP_ID = 15
  MAP_SHA256 = "d93611107f9f0a14372604ea5f2e585e7d18e2981626b75db374689d931f6860"
  TILESETS_SHA256 = "9e6310a10b0cf0510b6d4d2b58fb2d7662f9d181d809164bec6cf7b3ec2af69b"
  POSITION = [6, 5].freeze
  SPRITE = "trainer_AROMALADY"
  module_function

  def install!(project)
    root = Pathname.new(project).expand_path
    raise "Missing safe private staged project" unless root.directory? && !root.symlink? &&
      root.join("SHATTERED_STAGING_REPORT.json").file?
    map_path = root.join("Data/Map015.rxdata")
    tilesets_path = root.join("Data/Tilesets.rxdata")
    sprite_path = root.join("Graphics/Characters", SPRITE + ".png")
    [map_path, tilesets_path, sprite_path].each do |path|
      raise "Missing or unsafe private file: #{path.basename}" unless path.file? && !path.symlink?
    end
    raise "Native tilesets changed since review" unless
      Digest::SHA256.file(tilesets_path).hexdigest == TILESETS_SHA256
    map = load_data(map_path.to_s)
    raise "Unexpected Viridian school native geometry" unless map.is_a?(RPG::Map) &&
      [map.width, map.height] == [20, 15] && map.events.is_a?(Hash)
    teacher = map.events.fetch(1)
    raise "School teacher identity changed" unless teacher.name == "Teacher" &&
      [teacher.x, teacher.y] == [6, 2] &&
      teacher.pages.first.graphic.character_name == SPRITE
    event = ShatteredDojo.build_event("event_position" => POSITION, "character" => SPRITE)
    installed = map.events.values.select { |e| e.name == event.name }
    if installed.any?
      raise "Ambiguous private mentor installation" unless installed.length == 1
      event.id = installed.first.id
      raise "Private mentor event drift" unless Marshal.dump(event) == Marshal.dump(installed.first)
      return { "status" => "unchanged", "map_id" => MAP_ID, "event_id" => event.id }
    end
    raise "Viridian school map changed since review" unless
      Digest::SHA256.file(map_path).hexdigest == MAP_SHA256
    raise "Mentor tile occupied" if map.events.values.any? { |e| [e.x, e.y] == POSITION }
    tilesets = load_data(tilesets_path.to_s)
    raise "Mentor tile blocked" unless ShatteredDojo.native_tile_clear?(map, tilesets, *POSITION)
    raise "No clear approach to mentor" unless [[6, 6], [7, 5], [6, 4]].any? do |xy|
      ShatteredDojo.native_tile_clear?(map, tilesets, *xy) &&
        map.events.values.none? { |e| [e.x, e.y] == xy }
    end
    event.id = (map.events.keys.max || 0) + 1
    map.events[event.id] = event
    tmp = map_path.to_s + ".shattered_mentor.tmp"
    backup = map_path.to_s + ".shattered_mentor.bak"
    raise "Stale mentor recovery files" if File.exist?(tmp) || File.exist?(backup)
    begin
      save_data(map, tmp)
      File.rename(map_path, backup)
      File.rename(tmp, map_path)
      File.delete(backup)
    rescue Exception
      if File.exist?(backup)
        File.delete(map_path) if File.exist?(map_path)
        File.rename(backup, map_path)
      end
      raise
    ensure
      File.delete(tmp) if File.exist?(tmp)
    end
    { "status" => "installed", "map_id" => MAP_ID, "event_id" => event.id,
      "placement" => "provisional Viridian school mentor; original dojo parity unverified" }
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby install_private_viridian_mentor.rb PRIVATE_PROJECT" unless ARGV.length == 1
  puts JSON.pretty_generate(ShatteredPrivateViridianMentor.install!(ARGV.first))
end
