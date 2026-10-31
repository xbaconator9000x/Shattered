#!/usr/bin/env ruby
# frozen_string_literal: true
# Private post-compile isolation: keep RMXP installers out of Essentials debug
# PluginManager's filesystem scan. Run AFTER compile_private_plugins.rb.
# Does not compile PBS, maps, or establish gameplay acceptance.
require "json"
require "digest"
require "zlib"
require "fileutils"
require "optparse"
require "find"
require_relative "compile_private_plugins"

module ShatteredRuntimeIsolation
  module_function
  COMPILER = ShatteredPrivatePluginCompiler
  RECEIPT = "SHATTERED_RUNTIME_ISOLATION_REPORT.json"

  def check(value, message)
    raise RuntimeError, message unless value
  end

  def regular!(path)
    check(File.file?(path) && !File.symlink?(path), "Missing or unsafe file: #{path}")
    path
  end

  def sha(path)
    Digest::SHA256.file(regular!(path)).hexdigest
  end

  def staged_root!(project)
    check(File.directory?(project) && !File.symlink?(project), "Unsafe project root")
    root = File.realpath(project)
    regular!(File.join(root, "SHATTERED_STAGING_REPORT.json"))
    root
  end

  def compiled_entries!(root)
    report_file = regular!(File.join(root, "SHATTERED_NATIVE_COMPILE_REPORT.json"))
    report = JSON.parse(File.read(report_file))
    archive = regular!(File.join(root, "Data", "PluginScripts.rxdata"))
    check(sha(archive) == report.fetch("compiled_archive_sha256"),
      "Compiled plugin archive changed since private compilation")
    entries = Marshal.load(File.binread(archive))
    COMPILER.validate_existing!(entries)
    check(entries.map(&:first) == report.fetch("plugin_names"),
      "Compiled plugin inventory differs from report")
    [report, entries]
  end

  def verify_receipt!(root, receipt, entries)
    check(receipt["kind"] == "private_runtime_plugin_isolation_not_gameplay_acceptance",
      "Invalid isolation receipt")
    check(receipt["compiled_archive_sha256"] == sha(File.join(root, "Data", "PluginScripts.rxdata")),
      "Compiled archive changed after isolation")
    check(receipt["runtime_plugin_names"] == entries.map(&:first).grep(/\AShattered /),
      "Compiled runtime plugin names changed")
    receipt.fetch("runtime_files").each do |relative, expected|
      check(relative.match?(/\APlugins\/Shattered [A-Za-z0-9 _-]+\/[A-Za-z0-9_-]+\.rb\z/),
        "Unsafe runtime receipt path")
      check(sha(File.join(root, relative)) == expected, "Runtime plugin source changed: #{relative}")
    end
    receipt.fetch("moved").each do |entry|
      src, dst, expected = entry.values_at("from", "to", "sha256")
      check(src.match?(/\APlugins\/Shattered [A-Za-z0-9 _-]+\/[A-Za-z0-9_.\/-]+\z/) &&
        dst == src.sub(/\APlugins\//, "SHATTERED_OFFLINE_TOOLS/") &&
        !src.split("/").include?(".."), "Unsafe isolation receipt path")
      check(!File.exist?(File.join(root, src)), "Offline file returned to Plugins: #{src}")
      check(sha(File.join(root, dst)) == expected, "Offline file changed: #{dst}")
    end
    check(!Dir.glob(File.join(root, "Plugins", "Shattered *", "**", "*.rb")).any? do |file|
      name = File.basename(File.dirname(file))
      !COMPILER::RUNTIME_FILES.fetch(name, []).include?(File.basename(file))
    end, "Unreviewed or offline Ruby file remains in runtime Plugins")
    receipt
  end

  def finalize(project)
    root = staged_root!(project)
    report, entries = compiled_entries!(root)
    receipt_path = File.join(root, RECEIPT)
    if File.exist?(receipt_path)
      return verify_receipt!(root, JSON.parse(File.read(regular!(receipt_path))), entries)
    end
    offline_root = File.join(root, "SHATTERED_OFFLINE_TOOLS")
    check(!File.exist?(offline_root) && !File.symlink?(offline_root),
      "Existing offline tools directory requires manual review")
    plugins_dir = File.join(root, "Plugins")
    check(File.directory?(plugins_dir) && !File.symlink?(plugins_dir), "Unsafe Plugins directory")
    folders = Dir.children(plugins_dir).select { |name| name.start_with?("Shattered ") }.sort
    runtime_names = entries.map(&:first).grep(/\AShattered /)
    expected_runtime = folders.select { |name| COMPILER::RUNTIME_FILES.key?(name) }
    check(runtime_names.sort == expected_runtime.sort,
      "Every staged Shattered runtime plugin must be compiled exactly once")
    offline_only = folders - expected_runtime
    check(offline_only.sort == report.fetch("offline_only").sort,
      "Offline-only staged plugins must be recorded by native compiler")
    compiled = entries.to_h { |entry| [entry[0], entry[2]] }
    moves = []
    runtime_files = {}
    folders.each do |name|
      folder = File.join(plugins_dir, name)
      check(File.directory?(folder) && !File.symlink?(folder), "Unsafe Shattered plugin folder")
      COMPILER.source_entry(root, name) # Strict reviewed .rb inventory and metadata.
      scripts = COMPILER::RUNTIME_FILES.fetch(name, [])
      if scripts.any?
        packed = compiled.fetch(name)
        check(packed.map(&:first) == scripts, "Compiled script names differ for #{name}")
        scripts.each do |filename|
          relative = File.join("Plugins", name, filename)
          source = File.binread(regular!(File.join(root, relative)))
          archived = Zlib::Inflate.inflate(packed.find { |item| item[0] == filename }[1])
          check(source == archived, "Compiled source differs for #{relative}")
          runtime_files[relative] = sha(File.join(root, relative))
        end
      end
      if scripts.empty?
        Find.find(folder) do |path|
          next if path == folder
          check(!File.symlink?(path), "Symlink in offline-only plugin: #{path}")
          next if File.directory?(path)
          regular!(path)
          relative = path.delete_prefix(root + File::SEPARATOR)
          moves << relative
        end
      else
        COMPILER::INSTALLER_FILES.fetch(name, []).each do |filename|
          relative = File.join("Plugins", name, filename)
          regular!(File.join(root, relative))
          moves << relative
        end
      end
    end
    check(moves.uniq == moves, "Duplicate offline tool paths")
    moved = []
    begin
      moves.sort.each do |src|
        dst = src.sub(/\APlugins\//, "SHATTERED_OFFLINE_TOOLS/")
        original = File.join(root, src)
        destination = File.join(root, dst)
        check(!File.exist?(destination) && !File.symlink?(destination),
          "Offline tool destination already exists")
        digest = sha(original)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.mv(original, destination)
        moved << { "from" => src, "to" => dst, "sha256" => digest }
      end
      offline_only.each { |name| FileUtils.rm_rf(File.join(plugins_dir, name)) }
      receipt = {
        "kind" => "private_runtime_plugin_isolation_not_gameplay_acceptance",
        "compiled_archive_sha256" => sha(File.join(root, "Data", "PluginScripts.rxdata")),
        "runtime_plugin_names" => runtime_names,
        "runtime_files" => runtime_files,
        "moved" => moved,
        "native_engine_launched" => false,
        "pbs_compiled" => false,
        "gameplay_verified" => false,
        "android_verified" => false
      }
      temp = receipt_path + ".tmp"
      check(!File.exist?(temp) && !File.symlink?(temp), "Stale isolation receipt temp")
      File.write(temp, JSON.pretty_generate(receipt) + "\n")
      File.rename(temp, receipt_path)
      verify_receipt!(root, receipt, entries)
    rescue Exception
      moved.reverse_each do |item|
        source = File.join(root, item.fetch("to"))
        destination = File.join(root, item.fetch("from"))
        next unless File.file?(source)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.mv(source, destination)
      end
      File.delete(receipt_path) if File.file?(receipt_path)
      File.delete(receipt_path + ".tmp") if File.file?(receipt_path + ".tmp")
      raise
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: ruby scripts/finalize_private_runtime.rb --project PRIVATE_COMPILED_STAGE"
    opts.on("--project PATH") { |value| options[:project] = value }
  end.parse!
  abort "Missing --project" unless options[:project]
  puts JSON.pretty_generate(ShatteredRuntimeIsolation.finalize(options[:project]))
end
