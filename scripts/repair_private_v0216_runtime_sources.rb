#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline-only, exact-source-pinned repair for the private v0.2.16 game.
# NEVER commit the private project, PluginScripts.rxdata, graphics or audio.
require 'digest'
require 'json'
require 'pathname'
require 'zlib'

module ShatteredPrivateV0216RuntimeSources
  ARCHIVE_SHA = '6a29d16cd9ad4e955575a09f5d99b222ebe39700bab8ed4f53637229dbaa0eda'
  PINS = {
    'Shattered Gate Story' => {
      file: '001_GateStory.rb', old_version: '0.2.3', version: '0.2.4',
      old_source: '67bf74f69fc68f9097047793a16caaf5637f9bd6cd2ed89524fde317d1236317',
      source: '1e321ac88b55fbd67555384c0e6f60bacf25d3232d3155007a5eb0c49ac2aeea',
      old_meta: '762fcf8c5e8c7bbbfa229e93bda44f3b9f4a4ca41acbf2d13e0ccf91b79f607b'
    },
    'Shattered Route22' => {
      file: '001_Route22.rb', old_version: '0.1.5', version: '0.1.6',
      old_source: '909e1060bd27e65f5e2d6c0e815b56acdb2aa0e00463246675e77c9c33c24a07',
      source: '8de3741dc193d2d862932577d096c52ef54b2a9134f1b92c1736cbd7e6277f50',
      old_meta: '1c3875fc6411d73a7e9a1d296be86410e7b1d9eb3d431704f61f25943ded5a91'
    }
  }.freeze
  module_function

  def sha(bytes) = Digest::SHA256.hexdigest(bytes)

  def regular!(path)
    raise "Missing or symlinked private input: #{path}" unless path.file? && !path.symlink?
    path
  end

  def compiled!(project)
    path = regular!(project.join('Data/PluginScripts.rxdata'))
    raise 'Wrong private compiled archive SHA' unless Digest::SHA256.file(path).hexdigest == ARCHIVE_SHA
    entries = Marshal.load(path.binread)
    raise 'Unexpected native plugin archive structure' unless entries.is_a?(Array)
    names = entries.map { |e| e.is_a?(Array) ? e[0] : nil }
    raise 'Duplicate native plugin names' unless names.uniq.length == names.length
    entries
  end

  def expected_sources!(entries)
    PINS.to_h do |name, pin|
      matches = entries.select { |e| e[0] == name }
      raise "Missing native plugin #{name}" unless matches.length == 1
      entry = matches.first
      raise "Wrong compiled plugin version #{name}" unless entry[1].is_a?(Hash) &&
        entry[1][:version] == pin[:version] && entry[2].is_a?(Array) && entry[2].length == 1
      file, compressed = entry[2].first
      raise "Wrong compiled script #{name}" unless file == pin[:file] &&
        compressed.is_a?(String) && compressed.bytesize < 1_000_000
      source = Zlib::Inflate.inflate(compressed)
      raise "Wrong compiled source #{name}" unless sha(source) == pin[:source]
      [name, source]
    end
  end

  def proposed!(project, sources)
    updates = {}
    PINS.each do |name, pin|
      dir = project.join('Plugins', name)
      raise "Unsafe plugin directory #{name}" unless dir.directory? && !dir.symlink?
      script = regular!(dir.join(pin[:file]))
      meta = regular!(dir.join('meta.txt'))
      old_script = script.binread
      old_meta = meta.binread
      raise "Unreviewed runtime source #{name}" unless [pin[:old_source], pin[:source]].include?(sha(old_script))
      expected_meta = old_meta.sub(/^(Version\s*=\s*)#{Regexp.escape(pin[:old_version])}(\s*)$/,
        "\\1#{pin[:version]}\\2")
      if sha(old_meta) == pin[:old_meta]
        raise "Unrecognised metadata version #{name}" if expected_meta == old_meta
      else
        raise "Unreviewed upgraded metadata #{name}" unless
          old_meta.match?(/^Version\s*=\s*#{Regexp.escape(pin[:version])}\s*$/) &&
          sha(old_meta.sub(/^(Version\s*=\s*)#{Regexp.escape(pin[:version])}(\s*)$/,
            "\\1#{pin[:old_version]}\\2")) == pin[:old_meta]
        expected_meta = old_meta
      end
      updates[script] = sources.fetch(name) if old_script != sources.fetch(name)
      updates[meta] = expected_meta if old_meta != expected_meta
    end
    updates
  end

  def verify_all!(project, entries)
    entries.each do |entry|
      name, metadata, scripts = entry
      next unless name.is_a?(String) && name.start_with?('Shattered ')
      raise "Unexpected plugin archive entry #{name}" unless metadata.is_a?(Hash) && scripts.is_a?(Array)
      dir = project.join('Plugins', name)
      regular!(dir.join('meta.txt'))
      raise "Filesystem version differs from compiled #{name}" unless
        dir.join('meta.txt').binread.match?(/^Version\s*=\s*#{Regexp.escape(metadata[:version].to_s)}\s*$/)
      scripts.each do |file, compressed|
        raise "Unsafe runtime script name #{file}" unless file.is_a?(String) &&
          /\A[0-9A-Za-z_-]+\.rb\z/.match?(file)
        disk = regular!(dir.join(file)).binread
        raise "Compiled/runtime source mismatch #{name}/#{file}" unless disk == Zlib::Inflate.inflate(compressed)
      end
    end
    true
  end

  def repair!(path)
    project = Pathname.new(path).expand_path
    raise 'Not an authorised staged private project' unless project.directory? &&
      !project.symlink? && regular!(project.join('SHATTERED_STAGING_REPORT.json'))
    entries = compiled!(project)
    sources = expected_sources!(entries)
    updates = proposed!(project, sources)
    backups = {}
    staged = {}
    updates.each_key do |file|
      backup = Pathname.new(file.to_s + '.shattered_v0216_sync.bak')
      temp = Pathname.new(file.to_s + '.shattered_v0216_sync.tmp')
      raise 'Stale or symlinked coherence transaction' if
        backup.exist? || backup.symlink? || temp.exist? || temp.symlink?
      backups[file] = backup
      staged[file] = temp
    end
    begin
      updates.each do |file, bytes|
        File.binwrite(staged.fetch(file), bytes)
        File.chmod(file.stat.mode & 0o777, staged.fetch(file))
      end
      updates.each_key do |file|
        File.rename(file, backups.fetch(file))
        File.rename(staged.fetch(file), file)
      end
      verify_all!(project, entries)
    rescue Exception
      updates.each_key do |file|
        File.delete(file) if backups.fetch(file).file? && file.file?
        File.rename(backups.fetch(file), file) if backups.fetch(file).file?
      end
      raise
    ensure
      staged.each_value { |temp| File.delete(temp) if temp.file? }
    end
    backups.each_value { |backup| File.delete(backup) if backup.file? }
    { 'archive_sha256' => ARCHIVE_SHA,
      'repaired_paths' => updates.keys.map { |p| p.relative_path_from(project).to_s },
      'compiled_filesystem_coherent' => true, 'native_gameplay_verified' => false,
      'android_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby scripts/repair_private_v0216_runtime_sources.rb PRIVATE_STAGED_PROJECT' unless ARGV.length == 1
  puts JSON.pretty_generate(ShatteredPrivateV0216RuntimeSources.repair!(ARGV.first))
end
