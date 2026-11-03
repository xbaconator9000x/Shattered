# frozen_string_literal: true
# Private Essentials v21.1 release gate: compiled Shattered runtime scripts must
# match their editable Plugins/ sources byte-for-byte. No game assets are uploaded.
require "digest"
require "json"
require "zlib"

module ShatteredPluginCoherence
  module_function

  def regular!(path)
    raise "Missing or unsafe private source: #{path}" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def verify!(project)
    project = File.expand_path(project)
    regular!(File.join(project, "SHATTERED_STAGING_REPORT.json"))
    archive = File.join(project, "Data", "PluginScripts.rxdata")
    raw = File.binread(regular!(archive))
    entries = Marshal.load(raw)
    raise "Invalid native plugin archive" unless entries.is_a?(Array)
    names = {}
    report = { "kind" => "private_shattered_plugin_source_coherence",
               "archive_sha256" => Digest::SHA256.hexdigest(raw), "plugins" => [] }
    entries.each do |entry|
      raise "Invalid compiled plugin entry" unless entry.is_a?(Array) && entry.length == 3
      name, metadata, scripts = entry
      raise "Invalid compiled plugin name" unless name.is_a?(String) && !name.empty?
      raise "Duplicate compiled plugin #{name}" if names[name]
      names[name] = true
      next unless name.start_with?("Shattered ")
      raise "Unsafe Shattered plugin name" unless /\AShattered [A-Za-z0-9 _-]+\z/.match?(name)
      raise "Invalid compiled metadata for #{name}" unless metadata.is_a?(Hash) &&
        metadata[:name] == name && metadata[:version].is_a?(String) &&
        /\A\d+\.\d+\.\d+\z/.match?(metadata[:version])
      raise "No compiled scripts for #{name}" unless scripts.is_a?(Array) && !scripts.empty?
      directory = File.join(project, "Plugins", name)
      raise "Missing or unsafe plugin directory #{name}" unless
        File.directory?(directory) && !File.symlink?(directory)
      meta = File.binread(regular!(File.join(directory, "meta.txt")))
      version = meta[/^\s*Version\s*=\s*(\S+)\s*$/i, 1]
      raise "Plugin version drift: #{name}" unless version == metadata[:version]
      script_names = []
      script_records = []
      scripts.each do |script|
        raise "Invalid script entry in #{name}" unless script.is_a?(Array) &&
          script.length == 2 && script[0].is_a?(String) && script[1].is_a?(String)
        filename, compressed = script
        raise "Unsafe script filename in #{name}" unless /\A[A-Za-z0-9_-]+\.rb\z/.match?(filename)
        raise "Duplicate script #{filename} in #{name}" if script_names.include?(filename)
        script_names << filename
        source = File.binread(regular!(File.join(directory, filename)))
        begin
          compiled = Zlib::Inflate.inflate(compressed)
        rescue Zlib::Error => error
          raise "Corrupt compiled #{name}/#{filename}: #{error.message}"
        end
        raise "Compiled script is unreasonably large: #{name}/#{filename}" if compiled.bytesize > 1_000_000
        raise "STALE COMPILED/LOOSE SOURCE: #{name}/#{filename}" unless source == compiled
        script_records << { "file" => filename, "sha256" => Digest::SHA256.hexdigest(source) }
      end
      loose = Dir.children(directory).select { |filename| filename.end_with?(".rb") }.sort
      raise "Uncompiled loose Ruby files in #{name}" unless loose == script_names.sort
      report["plugins"] << { "name" => name, "version" => version, "scripts" => script_records }
    end
    raise "No Shattered runtime plugins found" if report["plugins"].empty?
    plugin_root = File.join(project, "Plugins")
    Dir.children(plugin_root).grep(/\AShattered /).each do |name|
      raise "Loose Shattered plugin absent from compiled archive: #{name}" unless names[name]
    end
    report["plugin_count"] = report["plugins"].length
    report
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: ruby verify_private_plugin_coherence.rb /private/staged/project" unless ARGV.length == 1
  puts JSON.pretty_generate(ShatteredPluginCoherence.verify!(ARGV.fetch(0)))
end
