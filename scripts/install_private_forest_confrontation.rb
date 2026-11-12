#!/usr/bin/env ruby
# frozen_string_literal: true
# Additive, hash-pinned forest scene installer for an already-built v18 copy.
require "digest"
require "json"
require_relative "private_rgss_writer"

module ShatteredPrivateForestConfrontation
  ROM_SHA = "e8664a1475126a1f37358c98e55c5236d55622306b127c81c9c46d43b6e415e2"
  MAP_ID = 24
  MAP_HASHES = ["ca94e7300a96335881ff237b0719c12ff47191bd65a6419b1367b6368f6fa132"].freeze
  POINT = [39, 60].freeze
  NAME = "SHATTERED_FOREST:confrontation".freeze
  module_function

  def script(text)
    RPG::EventCommand.new(355, 0, [text])
  end

  def install!(root, payload_path)
    root = File.realpath(root)
    map_path = File.join(root, format("Data/Map%03d.rxdata", MAP_ID))
    raise "Missing native forest map" unless File.file?(map_path) && !File.symlink?(map_path)
    original = File.binread(map_path)
    raise "Unreviewed forest map" unless MAP_HASHES.include?(Digest::SHA256.hexdigest(original))
    payload = JSON.parse(File.read(payload_path))
    raise "Wrong ROM forest payload" unless payload["rom_sha256"] == ROM_SHA &&
      payload.dig("foe", "species") == "RAIDER" && payload.dig("foe", "level") == 7
    map = Marshal.load(original)
    tilesets = load_data(File.join(root, "Data/Tilesets.rxdata"))
    raise "Forest event tile is blocked" unless ShatteredNativeAudit.tile_status(map, tilesets, *POINT) == "clear"
    raise "Forest event tile occupied" if map.events.values.any? { |event| [event.x, event.y] == POINT }
    raise "Forest confrontation already installed" if map.events.values.any? { |event| event.name == NAME }
    event = RPG::Event.new(*POINT)
    event.id = map.events.keys.max + 1
    event.name = NAME
    dormant = RPG::Event::Page.new
    dormant.through = true
    active = RPG::Event::Page.new
    active.condition.self_switch_valid = true
    active.condition.self_switch_ch = "A"
    active.list = [script("ShatteredForestConfrontation.trigger"), RPG::EventCommand.new]
    event.pages = [dormant, active]
    map.events[event.id] = event
    data_path = File.join(root, "Data/shattered_forest_confrontation.dat")
    raise "Forest payload already installed" if File.exist?(data_path) || File.symlink?(data_path)
    outputs = {map_path => Marshal.dump(map), data_path => Marshal.dump(payload)}
    outputs.each do |path, bytes|
      temp = path + ".forest.tmp"
      File.binwrite(temp, bytes)
      File.rename(temp, path)
    ensure
      File.delete(temp) if defined?(temp) && File.exist?(temp)
    end
    { "map" => MAP_ID, "event" => event.id, "point" => POINT,
      "payload_sha256" => Digest::SHA256.hexdigest(outputs.fetch(data_path)),
      "native_gameplay_verified" => false }
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby install_private_forest_confrontation.rb PRIVATE_COPY FOREST_JSON" unless ARGV.length == 2
  puts JSON.pretty_generate(ShatteredPrivateForestConfrontation.install!(*ARGV))
end
