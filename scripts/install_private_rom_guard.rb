#!/usr/bin/env ruby
# Install ROM-derived guard art in the reviewed private v14 Viridian map.
require 'digest'
require 'json'
require 'fileutils'
require_relative 'private_rgss_writer'

module ShatteredPrivateRomGuard
  MAP_SHA = '6ad04d25da9862e74875f6263cd7a674c7231abb64a1abcc9c8fd00e77e3f189'
  ROM_SHA = 'e8664a1475126a1f37358c98e55c5236d55622306b127c81c9c46d43b6e415e2'
  NAME = 'SHATTERED_ROM_Guard'
  ACTORS = {25 => 'SHATTERED_VIRIDIAN:escort_guard',
            28 => 'SHATTERED_VIRIDIAN:guard_at_center'}.freeze
  module_function

  def transform!(map)
    actors = ACTORS.map do |id, name|
      actor = map.events.fetch(id)
      raise 'Guard event identity changed' unless actor.name == name && actor.pages.length == 2
      page = actor.pages.find { |p| p.graphic.character_name == 'NPC 07' }
      raise 'Guard source graphic changed' unless page
      page
    end
    actors.each { |page| page.graphic.character_name = NAME }
  end

  def install!(project, extracted)
    root = File.realpath(project)
    raise 'Private staging marker missing' unless File.file?(File.join(root, 'SHATTERED_STAGING_REPORT.json'))
    map_path = File.join(root, 'Data', 'Map010.rxdata')
    source = File.join(extracted, NAME + '.png')
    provenance_path = File.join(extracted, 'guard_provenance.json')
    [map_path, source, provenance_path].each do |p|
      raise 'Missing or unsafe guard input' unless File.file?(p) && !File.symlink?(p)
    end
    provenance = JSON.parse(File.read(provenance_path))
    raise 'Unreviewed ROM extraction' unless provenance['rom_sha256'] == ROM_SHA &&
      provenance['character'] == NAME && provenance['dimensions'] == [128, 128] &&
      provenance['source_event'].values_at('map', 'local_id', 'position', 'graphics_id') ==
        [[3, 1], 1, [9, 16], 60] &&
      provenance['sheet_sha256'] == Digest::SHA256.file(source).hexdigest
    raise 'Viridian map changed since review' unless Digest::SHA256.file(map_path).hexdigest == MAP_SHA
    original = File.binread(map_path)
    map = Marshal.load(original)
    # This reviewed candidate contains ordinary empty Tone objects in door
    # commands, rather than RGSS user-marshalled Tone payloads. Preserve that
    # exact representation; never invent colour values during an art update.
    [Tone, Color].each do |klass|
      objects = ObjectSpace.each_object(klass).to_a
      next if objects.empty? || objects.all? { |obj| obj.instance_variable_defined?(:@native_bytes) }
      raise 'Mixed native and ordinary colour objects require review' unless
        objects.all? { |obj| obj.instance_variables.empty? }
      klass.class_eval { remove_method :_dump }
    end
    tiles = Marshal.dump(map.data)
    before = map.events.transform_values { |e| Marshal.dump(e) }
    transform!(map)
    raise 'Unrelated native content changed' unless Marshal.dump(map.data) == tiles &&
      before.all? { |id, bytes| ACTORS.key?(id) || Marshal.dump(map.events[id]) == bytes }
    output = Marshal.dump(map)
    raise 'Native table roundtrip failed' unless Marshal.dump(Marshal.load(output)) == output
    target = File.join(root, 'Graphics', 'Characters', NAME + '.png')
    temp = map_path + '.rom-guard.tmp'
    raise 'Guard output already exists' if File.exist?(target) || File.symlink?(target) || File.exist?(temp)
    begin
      FileUtils.cp(source, target)
      File.binwrite(temp, output)
      File.rename(temp, map_path)
    rescue Exception
      File.delete(target) if File.file?(target)
      raise
    ensure
      File.delete(temp) if File.file?(temp)
    end
    report = provenance.merge('map_before_sha256' => MAP_SHA,
      'map_after_sha256' => Digest::SHA256.hexdigest(output), 'events' => ACTORS.keys)
    File.write(File.join(root, 'SHATTERED_ROM_GUARD_REPORT.json'), JSON.pretty_generate(report) + "\n")
    report
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby install_private_rom_guard.rb PRIVATE_PROJECT EXTRACTED_GUARD' unless ARGV.length == 2
  puts JSON.pretty_generate(ShatteredPrivateRomGuard.install!(*ARGV))
end
