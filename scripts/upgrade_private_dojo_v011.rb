#!/usr/bin/env ruby
# frozen_string_literal: true
# SE-019: exact-source-pinned private Essentials v21.1 Dojo 0.1.0 -> 0.1.1
# compiled + loose source migration. Run ONLY on a fresh, private staging copy.
# No game assets or compiled archives belong in the GitHub repository.
require 'digest'
require 'fileutils'
require 'optparse'
require 'zlib'

module ShatteredPrivateDojo011
  NAME = 'Shattered Dojo'
  SCRIPT = '001_Starter.rb'
  OLD_SOURCE_SHA = '4ec57f99784ae6e87a98b0654963ee1fda9d8e76fc3e58a9d1f38d0530bcb018'
  NEW_SOURCE_SHA = '18bc13a7cc8c904f21eb114a61252a6ff33c7ac943da5287106ec103b7b25fcd'
  OLD_META_SHA = '34de09081070b1dabf12339424a256854a99f46c8f862f5672e462f85ba38686'
  NEW_META_SHA = 'a5ff70f05493eb3d9692b91ad4fe2ef6caca699d0c38d7a6012dd67972518a22'
  module_function

  def sha(bytes) = Digest::SHA256.hexdigest(bytes)

  def regular!(path)
    raise "Missing or symlinked private file: #{path}" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def update!(project, source_dir)
    root = File.realpath(project)
    raise 'Refusing a symlinked private project directory' if File.symlink?(project)
    marker = File.join(root, 'SHATTERED_STAGING_REPORT.json')
    regular!(marker)
    archive_path = File.join(root, 'Data', 'PluginScripts.rxdata')
    loose_path = File.join(root, 'Plugins', NAME, SCRIPT)
    meta_path = File.join(root, 'Plugins', NAME, 'meta.txt')
    source_path = File.join(source_dir, SCRIPT)
    new_meta_path = File.join(source_dir, 'meta.txt')
    paths = [archive_path, loose_path, meta_path]
    (paths + [source_path, new_meta_path]).each { |p| regular!(p) }
    raise 'Private compiled plugin archive too large' if File.size(archive_path) > 20_000_000
    new_source, new_meta = [source_path, new_meta_path].map { |p| File.binread(p) }
    raise 'Unexpected reviewed Dojo v0.1.1 source' unless sha(new_source) == NEW_SOURCE_SHA
    raise 'Unexpected reviewed Dojo v0.1.1 metadata' unless sha(new_meta) == NEW_META_SHA
    original = paths.map { |p| File.binread(p) }
    entries = Marshal.load(original[0])
    raise 'Invalid native plugin archive' unless entries.is_a?(Array)
    hits = entries.each_index.select { |i| entries[i].is_a?(Array) && entries[i][0] == NAME }
    raise 'Missing or duplicate Dojo compiled plugin' unless hits.length == 1
    idx = hits.first
    entry = entries[idx]
    raise 'Unexpected native plugin structure' unless entry.length == 3 && entry[1].is_a?(Hash) &&
      entry[2].is_a?(Array) && entry[2].length == 1 && entry[2][0].is_a?(Array) &&
      entry[2][0].length == 2 && entry[2][0][0] == SCRIPT
    compiled = Zlib::Inflate.inflate(entry[2][0][1])
    version = entry[1][:version]
    if version == '0.1.1' && sha(compiled) == NEW_SOURCE_SHA &&
       sha(original[1]) == NEW_SOURCE_SHA && sha(original[2]) == NEW_META_SHA
      return { 'changed' => false, 'archive_sha256' => sha(original[0]), 'version' => version }
    end
    raise 'Unreviewed or partially migrated Dojo input; refusing overwrite' unless
      version == '0.1.0' && sha(compiled) == OLD_SOURCE_SHA &&
      sha(original[1]) == OLD_SOURCE_SHA && sha(original[2]) == OLD_META_SHA
    # Preserve every other compiled plugin and the original source directory.
    entry[1] = entry[1].merge(:version => '0.1.1')
    entry[2][0] = [SCRIPT, Zlib::Deflate.deflate(new_source)]
    updated = [Marshal.dump(entries), new_source, new_meta]
    check = Marshal.load(updated[0])
    raise 'Compiled archive roundtrip failed' unless check[idx][1][:version] == '0.1.1' &&
      Zlib::Inflate.inflate(check[idx][2][0][1]) == new_source
    # All validations happen before the first write. Roll back if a filesystem
    # write/rename fails. The caller must use a fresh staged copy, not the base.
    tmp = []
    begin
      paths.each_with_index do |path, i|
        target = "#{path}.dojo011.tmp"
        raise "Stale transaction file: #{target}" if File.exist?(target)
        File.binwrite(target, updated[i])
        tmp << target
      end
      paths.each_with_index { |path, i| File.rename(tmp[i], path) }
    rescue StandardError
      paths.each_with_index { |path, i| File.binwrite(path, original[i]) }
      raise
    ensure
      tmp.each { |p| File.delete(p) if File.exist?(p) }
    end
    { 'changed' => true, 'archive_sha256' => sha(updated[0]), 'version' => '0.1.1' }
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.on('--project DIR') { |v| options[:project] = v }
    parser.on('--source DIR') { |v| options[:source] = v }
  end.parse!
  abort 'Usage: upgrade_private_dojo_v011.rb --project STAGED_DIR --source REPO/essentials/Plugins/Shattered\ Dojo' unless
    options[:project] && options[:source]
  puts ShatteredPrivateDojo011.update!(options[:project], options[:source]).inspect
end
