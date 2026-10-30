#!/usr/bin/env ruby
# frozen_string_literal: true
# Source-grounded, local-only Essentials v21.1 PluginScripts.rxdata compiler.
# Mirrors PluginManager.compilePlugins from the authorised v0.4 Scripts.rxdata.
# Does not compile PBS, maps or the game, and does not establish gameplay.
require "json"
require "zlib"
require "digest"
require "optparse"
require "fileutils"

module ShatteredPrivatePluginCompiler
  module_function

  def check(condition, message)
    raise RuntimeError, message unless condition
  end

  def safe_file!(path)
    check(File.file?(path) && !File.symlink?(path), "Missing or unsafe file: #{path}")
    check(File.size(path) < 5 * 1024 * 1024, "Oversized source file: #{path}")
    path
  end

  def metadata(path)
    safe_file!(path)
    fields = {}
    File.foreach(path, encoding: "UTF-8") do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")
      match = line.match(/\A([A-Za-z][A-Za-z0-9]*)\s*=\s*(.*?)\s*\z/)
      check(match, "Malformed plugin metadata: #{path}")
      key, value = match.captures
      check(!fields.key?(key), "Duplicate metadata key #{key}")
      fields[key] = value
    end
    name = fields.fetch("Name")
    version = fields.fetch("Version")
    essentials = fields.fetch("Essentials").split(",").map(&:strip)
    check(name.match?(/\A[A-Za-z0-9 _-]{1,80}\z/), "Unsafe plugin name")
    check(version.match?(/\A\d+\.\d+\.\d+\z/), "Invalid plugin version")
    check(essentials.include?("21.1"), "Plugin not declared for Essentials 21.1")
    {
      :name => name, :version => version, :essentials => essentials,
      :link => fields["Website"], :credits => fields.fetch("Credits", "").split(",").map(&:strip)
    }.reject { |_key, value| value.nil? }
  end

  def source_entry(project, folder)
    check(folder.match?(/\AShattered [A-Za-z0-9 _-]{1,70}\z/), "Only Shattered plugins may be compiled")
    directory = File.join(project, "Plugins", folder)
    check(File.directory?(directory) && !File.symlink?(directory), "Unsafe plugin directory")
    meta = metadata(File.join(directory, "meta.txt"))
    check(meta[:name] == folder, "Plugin folder/name mismatch")
    scripts = Dir.children(directory).select { |name| name.end_with?(".rb") }.sort
    check(!scripts.empty?, "No Ruby plugin scripts")
    check(scripts.length <= 100, "Too many plugin scripts")
    packed = scripts.map do |name|
      check(name.match?(/\A[A-Za-z0-9 _-]+\.rb\z/), "Unsafe plugin filename")
      source = File.binread(safe_file!(File.join(directory, name)))
      check(source.valid_encoding?, "Invalid plugin script bytes")
      [name, Zlib::Deflate.deflate(source)]
    end
    [meta[:name], meta, packed]
  end

  def validate_existing!(entries)
    check(entries.is_a?(Array) && entries.length <= 100, "Invalid compiled plugin archive")
    names = []
    entries.each do |entry|
      check(entry.is_a?(Array) && entry.length == 3 &&
        entry[0].is_a?(String) && entry[1].is_a?(Hash) &&
        entry[2].is_a?(Array), "Invalid compiled plugin entry")
      check(!names.include?(entry[0]), "Duplicate compiled plugin")
      names << entry[0]
      entry[2].each do |script|
        check(script.is_a?(Array) && script.length == 2 &&
          script[0].is_a?(String) && script[1].is_a?(String),
          "Invalid compiled plugin script")
        Zlib::Inflate.inflate(script[1])
      end
    end
    true
  end

  def equivalent?(existing, proposed)
    return false unless existing[0] == proposed[0] &&
      existing[1][:version] == proposed[1][:version] &&
      existing[2].length == proposed[2].length
    existing[2].zip(proposed[2]).all? do |old, fresh|
      old[0] == fresh[0] &&
        Zlib::Inflate.inflate(old[1]) == Zlib::Inflate.inflate(fresh[1])
    end
  end

  def compile(project, folders)
    project = File.realpath(project)
    check(File.file?(File.join(project, "SHATTERED_STAGING_REPORT.json")),
      "Refusing to compile a project without a private staging report")
    data_dir = File.join(project, "Data")
    check(File.directory?(data_dir) && !File.symlink?(data_dir), "Unsafe Data directory")
    target = safe_file!(File.join(data_dir, "PluginScripts.rxdata"))
    original = File.binread(target)
    entries = Marshal.load(original)
    validate_existing!(entries)
    check(folders.is_a?(Array) && folders.length.between?(1, 15) &&
      folders.uniq == folders, "Invalid requested plugin list")
    added = []
    unchanged = []
    folders.each do |folder|
      proposed = source_entry(project, folder)
      old = entries.find { |entry| entry[0] == proposed[0] }
      if old
        check(equivalent?(old, proposed),
          "Plugin #{folder} is already compiled with different source; use a fresh stage")
        unchanged << folder
      else
        entries << proposed
        added << folder
      end
    end
    if added.any?
      backup = "#{target}.pre_shattered_#{Digest::SHA256.hexdigest(original)[0, 12]}.bak"
      check(!File.exist?(backup) && !File.symlink?(backup), "Existing backup needs review")
      temp = "#{target}.shattered.tmp"
      check(!File.exist?(temp) && !File.symlink?(temp), "Stale temporary compile file")
      File.binwrite(backup, original)
      begin
        File.binwrite(temp, Marshal.dump(entries))
        validate_existing!(Marshal.load(File.binread(temp)))
        File.rename(temp, target)
      ensure
        File.delete(temp) if File.exist?(temp)
      end
    end
    report = {
      "kind" => "native_format_plugin_archive_not_gameplay_acceptance",
      "added" => added, "unchanged" => unchanged,
      "plugin_names" => entries.map(&:first),
      "original_archive_sha256" => Digest::SHA256.hexdigest(original),
      "compiled_archive_sha256" => Digest::SHA256.file(target).hexdigest,
      "native_engine_launched" => false, "gameplay_verified" => false,
      "pbs_compiled" => false
    }
    report_path = File.join(project, "SHATTERED_NATIVE_COMPILE_REPORT.json")
    File.write(report_path, JSON.pretty_generate(report) + "\n")
    report
  end
end

if $PROGRAM_NAME == __FILE__
  options = { :plugins => [] }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby scripts/compile_private_plugins.rb --project PRIVATE_STAGED --plugin 'Shattered Core'"
    opts.on("--project PATH") { |value| options[:project] = value }
    opts.on("--plugin NAME") { |value| options[:plugins] << value }
  end
  parser.parse!
  abort parser.to_s unless options[:project]
  options[:plugins] = ["Shattered Core"] if options[:plugins].empty?
  puts JSON.pretty_generate(ShatteredPrivatePluginCompiler.compile(options[:project], options[:plugins]))
end
