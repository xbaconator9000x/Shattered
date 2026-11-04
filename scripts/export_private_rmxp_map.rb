#!/usr/bin/env ruby
# frozen_string_literal: true
# Export a real, privately staged RMXP map for pixel-accurate visual review.
# Never commit the generated tile bytes, previews, or third-party game artwork.
require 'json'
require 'pathname'
require 'optparse'
require_relative 'private_rgss_writer'

module ShatteredNativeMapPreviewExport
  module_function
  def export(project, map_id, output)
    project = Pathname.new(project).expand_path
    output = Pathname.new(output).expand_path
    raise ArgumentError, 'private project missing' unless project.directory? && !project.symlink?
    raise ArgumentError, 'private output directory must exist' unless output.directory? && !output.symlink?
    raise ArgumentError, 'invalid map ID' unless map_id.instance_of?(Integer) && map_id.between?(1, 999)
    map = ShatteredNativeAudit.read_rxdata(project, format('Data/Map%03d.rxdata', map_id))
    tilesets = ShatteredNativeAudit.read_rxdata(project, 'Data/Tilesets.rxdata')
    raise 'not a native RPG Maker XP map' unless map.is_a?(RPG::Map)
    width, height = map.width, map.height
    raise 'invalid map dimensions' unless width.instance_of?(Integer) && height.instance_of?(Integer) &&
      width.between?(1, 256) && height.between?(1, 256)
    table = map.data
    raise 'invalid native 3-layer tile table' unless table.is_a?(Table) && table.shape == [width, height, 3]
    tileset = tilesets[map.tileset_id] if tilesets.is_a?(Array)
    raise 'missing native tileset' unless tileset.is_a?(RPG::Tileset)
    name = tileset.instance_variable_get(:@tileset_name)
    raise 'unsafe tileset filename' unless name.is_a?(String) && name.match?(/\A[A-Za-z0-9_ -]+\z/)
    graphic = project.join('Graphics', 'Tilesets', name + '.png')
    raise 'missing/symlinked private tileset PNG' unless graphic.file? && !graphic.symlink?
    raise 'invalid event inventory' unless map.events.is_a?(Hash) && map.events.all? do |id, event|
      id.instance_of?(Integer) && event.is_a?(RPG::Event) &&
        event.x.instance_of?(Integer) && event.y.instance_of?(Integer) &&
        event.x.between?(0, width - 1) && event.y.between?(0, height - 1)
    end
    basename = format('map%03d', map_id)
    binary = output.join(basename + '_tiles.bin')
    metadata = output.join(basename + '_metadata.json')
    raise 'refusing to overwrite private export' if binary.exist? || metadata.exist? || binary.symlink? || metadata.symlink?
    File.binwrite(binary, table.instance_variable_get(:@bytes))
    File.write(metadata, JSON.pretty_generate({
      'map_id' => map_id, 'width' => width, 'height' => height,
      'tileset_name' => name, 'tileset_path' => graphic.to_s,
      'events' => map.events.sort.map { |id, e|
        graphic = e.pages&.first&.graphic
        { 'id' => id, 'x' => e.x, 'y' => e.y, 'name' => e.name.to_s,
          'character_name' => graphic&.character_name.to_s,
          'direction' => graphic&.direction || 2,
          'pattern' => graphic&.pattern || 0 }
      }
    }) + "\n")
    metadata
  end
end

if $PROGRAM_NAME == __FILE__
  args = {}
  OptionParser.new do |p|
    p.on('--project DIR') { |v| args[:project] = v }
    p.on('--map-id ID', Integer) { |v| args[:map_id] = v }
    p.on('--output-dir DIR') { |v| args[:output] = v }
  end.parse!
  abort 'Usage: ruby export_private_rmxp_map.rb --project PRIVATE --map-id ID --output-dir DIR' unless args.values_at(:project, :map_id, :output).all?
  puts ShatteredNativeMapPreviewExport.export(args[:project], args[:map_id], args[:output])
end
