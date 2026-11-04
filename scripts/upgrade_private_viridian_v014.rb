#!/usr/bin/env ruby
# frozen_string_literal: true
# Exact-source-pinned private Essentials v21.1 Viridian 0.1.3 -> 0.1.4
# compiled + loose source migration. Run ONLY on a fresh, private staging copy.
# No game assets or compiled archives belong in the GitHub repository.
require 'digest'
require 'fileutils'
require 'optparse'
require 'zlib'

module ShatteredPrivateViridian014
  NAME = 'Shattered Viridian'
  SCRIPT = '001_Entry.rb'
  OLD_SOURCE_SHA = 'd42520b60fa77affe226b7aed3c11072a67e2550b8cd290a01b3382311ab6e67'
  NEW_SOURCE_SHA = 'f476e9fc2c29fc66efd74c47c99fcbe0c6a7a2b59b5eb4b7da8a845fbf9cfac7'
  OLD_META_SHA = 'fb6ea88af113949fa47a30c6aafcf6518c0ecb3e66c0439153af7e46ce757220'
  NEW_META_SHA = '61f2047ae726a838aa6ab509cb5145ef25feca50d2cabcb13577e22054b151d8'
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
    raise 'Unexpected reviewed Viridian v0.1.4 source' unless sha(new_source) == NEW_SOURCE_SHA
    raise 'Unexpected reviewed Viridian v0.1.4 metadata' unless sha(new_meta) == NEW_META_SHA
    original = paths.map { |p| File.binread(p) }
    entries = Marshal.load(original[0])
    raise 'Invalid native plugin archive' unless entries.is_a?(Array)
    hits = entries.each_index.select { |i| entries[i].is_a?(Array) && entries[i][0] == NAME }
    raise 'Missing or duplicate Viridian compiled plugin' unless hits.length == 1
    idx = hits.first
    entry = entries[idx]
    raise 'Unexpected native plugin structure' unless entry.length == 3 && entry[1].is_a?(Hash) &&
      entry[2].is_a?(Array) && entry[2].length == 1 && entry[2][0].is_a?(Array) &&
      entry[2][0].length == 2 && entry[2][0][0] == SCRIPT
    compiled = Zlib::Inflate.inflate(entry[2][0][1])
    version = entry[1][:version]
    if version == '0.1.4' && sha(compiled) == NEW_SOURCE_SHA &&
       sha(original[1]) == NEW_SOURCE_SHA && sha(original[2]) == NEW_META_SHA
      return { 'changed' => false, 'archive_sha256' => sha(original[0]), 'version' => version }
    end
    raise 'Unreviewed or partially migrated Viridian input; refusing overwrite' unless
      version == '0.1.3' && sha(compiled) == OLD_SOURCE_SHA &&
      sha(original[1]) == OLD_SOURCE_SHA && sha(original[2]) == OLD_META_SHA
    # Preserve every other compiled plugin and the original source directory.
    entry[1] = entry[1].merge(:version => '0.1.4')
    entry[2][0] = [SCRIPT, Zlib::Deflate.deflate(new_source)]
    updated = [Marshal.dump(entries), new_source, new_meta]
    check = Marshal.load(updated[0])
    raise 'Compiled archive roundtrip failed' unless check[idx][1][:version] == '0.1.4' &&
      Zlib::Inflate.inflate(check[idx][2][0][1]) == new_source
    # All validations happen before the first write. Roll back if a filesystem
    # write/rename fails. The caller must use a fresh staged copy, not the base.
    tmp = []
    begin
      paths.each_with_index do |path, i|
        target = "#{path}.viridian014.tmp"
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
    { 'changed' => true, 'archive_sha256' => sha(updated[0]), 'version' => '0.1.4' }
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.on('--project DIR') { |v| options[:project] = v }
    parser.on('--source DIR') { |v| options[:source] = v }
  end.parse!
  abort 'Usage: upgrade_private_viridian_v014.rb --project STAGED_DIR --source REPO/essentials/Plugins/Shattered\ Viridian' unless
    options[:project] && options[:source]
  puts ShatteredPrivateViridian014.update!(options[:project], options[:source]).inspect
end
