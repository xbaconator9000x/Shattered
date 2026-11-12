#!/usr/bin/env ruby
# frozen_string_literal: true
# Rebuild a private, already-installed H&S candidate's runtime scripts without
# touching its licensed maps, tiles, audio or graphics. This is deliberately
# local-only: it accepts a user-held candidate and a checked-out Shattered source
# tree, then writes a separate output directory.
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require_relative "compile_private_plugins"

module ShatteredPrivateHnsUpgrade
  module_function
  COMPILER = ShatteredPrivatePluginCompiler
  REPORT = "SHATTERED_HNS_RUNTIME_UPGRADE_REPORT.json"
  # Every native map that makes up the installed initial slice. The upgrade
  # must never turn a compiled-runtime refresh into an unreviewed map mutation.
  HNS_MAPS = {
    "ReceptionGate_hns" => 223,
    "VictoryRoadKanto_B2F_hns" => 224,
    "Route26North_hns" => 225,
    "Route26_hns" => 226,
    "Route28_hns" => 227
  }.freeze
  STORY_MAP_IDS = [16, 10, 11].freeze
  # v14 staged the shared map identity as a loose Core script. The current
  # compiled Gate Story runtime owns that identity; accept only this exact
  # reviewed bridge and remove it before rebuilding the archive.
  LEGACY_RUNTIME_FILES = {
    "Shattered Core" => {
      "000_MapContract.rb" => "5ca669abe5460a3dde37ac898c083477c514a4cc80bee0e611d017ffacd5a8d2"
    }
  }.freeze

  def check(condition, message)
    raise RuntimeError, message unless condition
  end

  def regular(path)
    check(File.file?(path) && !File.symlink?(path), "Missing or unsafe file: #{path}")
    path
  end

  def digest(path)
    Digest::SHA256.file(regular(path)).hexdigest
  end

  def copy_runtime_sources!(source_root, target_root)
    plugins = File.join(target_root, "Plugins")
    COMPILER::RUNTIME_FILES.each do |name, files|
      source = File.join(source_root, "essentials", "Plugins", name)
      target = File.join(plugins, name)
      check(File.directory?(source) && !File.symlink?(source), "Missing source plugin: #{name}")
      check(File.directory?(target) && !File.symlink?(target), "Missing candidate plugin: #{name}")
      allowed = (files + ["meta.txt"]).sort
      legacy = LEGACY_RUNTIME_FILES.fetch(name, {})
      current = Dir.children(target).select { |file| file.end_with?(".rb") || file == "meta.txt" }.sort
      check(current.all? { |file| allowed.include?(file) || legacy.key?(file) },
        "Candidate contains unreviewed runtime file in #{name}")
      legacy.each do |file, expected_sha|
        legacy_path = File.join(target, file)
        next unless File.exist?(legacy_path)
        check(digest(legacy_path) == expected_sha,
          "Candidate legacy runtime source differs from reviewed migration: #{name}/#{file}")
        File.delete(legacy_path)
      end
      allowed.each do |file|
        from = File.join(source, file)
        check(File.file?(from) && !File.symlink?(from), "Missing reviewed source: #{name}/#{file}")
        FileUtils.cp(from, File.join(target, file))
      end
    end
  end

  def native_map_path(id)
    format("Data/Map%03d.rxdata", id)
  end

  def installed_map_digests!(root)
    review = JSON.parse(File.read(regular(File.join(root, "SHATTERED_HNS_REVIEW_IMPORT.json"))))
    check(review["maps"].is_a?(Hash) && HNS_MAPS.all? { |name, id| review["maps"][name] == id } &&
          review["new_game"].is_a?(Array) && review["new_game"][0] == HNS_MAPS["ReceptionGate_hns"],
      "Candidate does not contain the reviewed H&S opening map set")
    ids = HNS_MAPS.values + STORY_MAP_IDS
    ids.each_with_object({}) do |id, result|
      path = File.join(root, native_map_path(id))
      result[native_map_path(id)] = digest(path)
    end
  end

  def validate_candidate!(root)
    check(File.directory?(root) && !File.symlink?(root), "Unsafe candidate directory")
    %w[SHATTERED_STAGING_REPORT.json SHATTERED_NATIVE_CANDIDATE.json
       SHATTERED_HNS_REVIEW_IMPORT.json Data/PluginScripts.rxdata].each do |path|
      regular(File.join(root, path))
    end
    maps = installed_map_digests!(root)
    archive = Marshal.load(File.binread(File.join(root, "Data/PluginScripts.rxdata")))
    COMPILER.validate_existing!(archive)
    [archive, maps]
  end

  def rebuild_archive!(root, prior)
    proposals = COMPILER::RUNTIME_FILES.keys.map { |name| COMPILER.source_entry(root, name) }
    retained = prior.reject { |entry| entry.is_a?(Array) && entry[0].to_s.start_with?("Shattered ") }
    names = retained.map(&:first)
    proposals.each do |entry|
      check(!names.include?(entry[0]), "Duplicate retained runtime plugin: #{entry[0]}")
      names << entry[0]
    end
    result = retained + proposals
    COMPILER.validate_existing!(result)
    target = File.join(root, "Data", "PluginScripts.rxdata")
    backup = target + ".pre_hns_runtime_upgrade_#{Digest::SHA256.hexdigest(File.binread(target))[0, 12]}.bak"
    temp = target + ".hns-upgrade.tmp"
    check(!File.exist?(backup) && !File.symlink?(backup), "Existing archive backup requires review")
    check(!File.exist?(temp) && !File.symlink?(temp), "Stale runtime upgrade temporary file")
    File.binwrite(backup, File.binread(target))
    begin
      File.binwrite(temp, Marshal.dump(result))
      COMPILER.validate_existing!(Marshal.load(File.binread(temp)))
      File.rename(temp, target)
    ensure
      File.delete(temp) if File.exist?(temp)
    end
    [backup, result]
  end

  def upgrade(input, output, source_root)
    input = File.realpath(input)
    output = File.expand_path(output)
    source_root = File.realpath(source_root)
    check(input != output && !output.start_with?(input + File::SEPARATOR),
      "Output must be a separate directory")
    check(!File.exist?(output) && !File.symlink?(output), "Output already exists")
    check(File.directory?(File.join(source_root, "essentials", "Plugins")),
      "Source root is not a Shattered checkout")
    # Validate original before any copied bytes are changed.
    prior, map_digests = validate_candidate!(input)
    FileUtils.cp_r(input, output)
    begin
      copied_prior, copied_maps = validate_candidate!(output)
      check(Marshal.dump(prior) == Marshal.dump(copied_prior) && map_digests == copied_maps,
        "Candidate data changed during copy")
      copy_runtime_sources!(source_root, output)
      backup, entries = rebuild_archive!(output, copied_prior)
      check(map_digests == installed_map_digests!(output),
        "Runtime upgrade unexpectedly changed an installed native map")
      report = {
        "kind" => "private_hns_candidate_runtime_upgrade_not_gameplay_acceptance",
        "source_runtime_plugins" => COMPILER::RUNTIME_FILES.keys,
        "prior_archive_sha256" => Digest::SHA256.file(backup).hexdigest,
        "compiled_archive_sha256" => digest(File.join(output, "Data", "PluginScripts.rxdata")),
        "preserved_hns_maps" => HNS_MAPS.values,
        "preserved_story_maps" => STORY_MAP_IDS,
        "preserved_native_map_sha256" => map_digests,
        "native_engine_launched" => false,
        "gameplay_verified" => false,
        "save_reload_verified" => false
      }
      File.write(File.join(output, REPORT), JSON.pretty_generate(report) + "\n")
      report
    rescue Exception
      FileUtils.rm_rf(output)
      raise
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.on("--candidate DIR") { |value| options[:candidate] = value }
    parser.on("--output DIR") { |value| options[:output] = value }
    parser.on("--source DIR") { |value| options[:source] = value }
  end.parse!
  abort "Usage: ruby #{File.basename($PROGRAM_NAME)} --candidate V14 --output V15 --source CHECKOUT" unless
    options[:candidate] && options[:output] && options[:source]
  puts JSON.pretty_generate(ShatteredPrivateHnsUpgrade.upgrade(
    options[:candidate], options[:output], options[:source]
  ))
end
