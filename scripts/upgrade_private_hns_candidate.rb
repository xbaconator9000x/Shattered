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
      current = Dir.children(target).select { |file| file.end_with?(".rb") || file == "meta.txt" }.sort
      check(current.all? { |file| allowed.include?(file) },
        "Candidate contains unreviewed runtime file in #{name}")
      allowed.each do |file|
        from = File.join(source, file)
        check(File.file?(from) && !File.symlink?(from), "Missing reviewed source: #{name}/#{file}")
        FileUtils.cp(from, File.join(target, file))
      end
    end
  end

  def validate_candidate!(root)
    check(File.directory?(root) && !File.symlink?(root), "Unsafe candidate directory")
    %w[
      SHATTERED_STAGING_REPORT.json
      SHATTERED_NATIVE_CANDIDATE.json
      SHATTERED_HNS_REVIEW_IMPORT.json
      Data/PluginScripts.rxdata
      Data/Map223.rxdata
      Data/Map016.rxdata
      Data/Map010.rxdata
      Data/Map011.rxdata
    ].each { |path| regular(File.join(root, path)) }
    review = JSON.parse(File.read(File.join(root, "SHATTERED_HNS_REVIEW_IMPORT.json")))
    check(review.dig("maps", "ReceptionGate_hns") == 223 &&
          review.dig("maps", "VictoryRoadKanto_B2F_hns") == 224 &&
          review["new_game"].is_a?(Array) && review["new_game"][0] == 223,
      "Candidate does not contain the reviewed H&S opening map set")
    archive = Marshal.load(File.binread(File.join(root, "Data/PluginScripts.rxdata")))
    COMPILER.validate_existing!(archive)
    archive
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
    prior = validate_candidate!(input)
    FileUtils.cp_r(input, output)
    begin
      copied_prior = validate_candidate!(output)
      check(Marshal.dump(prior) == Marshal.dump(copied_prior),
        "Candidate archive changed during copy")
      copy_runtime_sources!(source_root, output)
      backup, entries = rebuild_archive!(output, copied_prior)
      report = {
        "kind" => "private_hns_candidate_runtime_upgrade_not_gameplay_acceptance",
        "source_runtime_plugins" => COMPILER::RUNTIME_FILES.keys,
        "prior_archive_sha256" => Digest::SHA256.file(backup).hexdigest,
        "compiled_archive_sha256" => digest(File.join(output, "Data", "PluginScripts.rxdata")),
        "preserved_hns_maps" => [223, 224, 225, 226, 227],
        "preserved_story_maps" => [16, 10, 11],
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
