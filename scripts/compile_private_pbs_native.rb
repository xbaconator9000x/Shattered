#!/usr/bin/env ruby
# frozen_string_literal: true
# Private, native Essentials PBS compilation. Never commit game RXData or assets.
# Executes the actual Essentials Compiler.compile_pbs_files inside mkxp-z, not CRuby.
require 'digest'
require 'json'
require 'optparse'
require 'timeout'
require 'zlib'

module ShatteredNativePBS
  module_function
  MARKER = 'SHATTERED_PRIVATE_PBS_NATIVE.ok'
  RECEIPT = 'SHATTERED_NATIVE_PBS_COMPILE_REPORT.json'
  ANCHOR = /    PluginManager\.runPlugins\r?\n    Compiler\.main/

  def require_regular!(path)
    raise "Missing or unsafe file: #{path}" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def digest(path)
    Digest::SHA256.file(require_regular!(path)).hexdigest
  end

  def instrument(scripts, marker = MARKER)
    raise 'Invalid private PBS marker' unless marker.match?(/\ASHATTERED_[A-Z_]+\.ok\z/)
    entries = Marshal.load(scripts)
    raise 'Invalid Scripts.rxdata' unless entries.is_a?(Array)
    mains = entries.select { |item| item.is_a?(Array) && item.length == 3 && item[1] == 'Main' }
    raise 'Expected exactly one Main script' unless mains.length == 1
    main = mains.first
    source = Zlib::Inflate.inflate(main[2])
    raise 'Expected exactly one original Essentials Main compiler hook' unless source.scan(ANCHOR).length == 1
    newline = source.include?("\r\n") ? "\r\n" : "\n"
    injected = [
      '    PluginManager.runPlugins',
      '    Compiler.compile_pbs_files',
      "    File.write(#{marker.inspect}, 'native_pbs_compiled')",
      '    exit',
      '    Compiler.main'
    ].join(newline)
    main[2] = Zlib::Deflate.deflate(source.sub(ANCHOR, injected))
    Marshal.dump(entries)
  end

  def compile(project, engine, timeout_seconds: 60, environment: ENV)
    root = File.realpath(project)
    raise 'Unsafe project root' if File.symlink?(project)
    engine = File.realpath(require_regular!(engine))
    raise 'Timeout must be 5..180 seconds' unless timeout_seconds.between?(5, 180)
    candidate_path = require_regular!(File.join(root, 'SHATTERED_NATIVE_CANDIDATE.json'))
    isolation_path = require_regular!(File.join(root, 'SHATTERED_RUNTIME_ISOLATION_REPORT.json'))
    candidate = JSON.parse(File.read(candidate_path))
    isolation = JSON.parse(File.read(isolation_path))
    archive = File.join(root, 'Data', 'PluginScripts.rxdata')
    raise 'Compiled archive changed after staging' unless
      digest(archive) == candidate.fetch('compiled_plugin_archive_sha256') &&
      digest(archive) == isolation.fetch('compiled_archive_sha256')
    scripts_path = require_regular!(File.join(root, 'Data', 'Scripts.rxdata'))
    species_path = require_regular!(File.join(root, 'Data', 'species.dat'))
    marker_path = File.join(root, MARKER)
    receipt_path = File.join(root, RECEIPT)
    log_path = File.join(root, 'SHATTERED_NATIVE_PBS_COMPILE.log')
    [marker_path, receipt_path, log_path].each do |path|
      raise "Existing probe output requires review: #{path}" if File.exist?(path) || File.symlink?(path)
    end
    backup_path = scripts_path + '.pre_shattered_pbs_probe.bak'
    raise 'Stale PBS probe backup requires recovery' if File.exist?(backup_path) || File.symlink?(backup_path)
    original = File.binread(scripts_path)
    before = digest(species_path)
    modified = instrument(original)
    status = nil
    pid = nil
    File.binwrite(backup_path, original)
    File.binwrite(scripts_path, modified)
    begin
      pid = Process.spawn(environment.to_h, engine, chdir: root, out: log_path, err: [:child, :out])
      begin
        _child, status = Timeout.timeout(timeout_seconds) { Process.waitpid2(pid) }
        pid = nil
      rescue Timeout::Error
        Process.kill('TERM', pid) rescue nil
        begin
          Timeout.timeout(3) { Process.waitpid(pid) }
        rescue Timeout::Error
          Process.kill('KILL', pid) rescue nil
          Process.waitpid(pid) rescue nil
        end
        pid = nil
        raise 'Native PBS compilation timed out'
      end
    ensure
      Process.kill('TERM', pid) rescue nil if pid
      Process.waitpid(pid) rescue nil if pid
      File.binwrite(scripts_path, original)
      raise 'Original Scripts.rxdata could not be restored' unless
        Digest::SHA256.file(scripts_path).hexdigest == Digest::SHA256.hexdigest(original)
      File.delete(backup_path)
    end
    raise "Native compiler exited unsuccessfully (#{status&.exitstatus})" unless status&.success?
    raise 'Native compiler completion marker absent' unless File.file?(marker_path) &&
      !File.symlink?(marker_path) && File.read(marker_path) == 'native_pbs_compiled'
    raise 'Compiled species.dat does not contain HUMAN' unless File.binread(species_path).include?('HUMAN')
    result = {
      'kind' => 'actual_private_essentials_native_pbs_compiler_not_gameplay_acceptance',
      'source_sha' => candidate.fetch('source_sha'),
      'original_scripts_sha256' => Digest::SHA256.hexdigest(original),
      'restored_scripts_sha256' => digest(scripts_path),
      'engine_sha256' => digest(engine),
      'species_before_sha256' => before,
      'species_after_sha256' => digest(species_path),
      'native_compiler_completed' => true,
      'human_species_bytes_present' => true,
      'engine_exit_code' => status.exitstatus,
      'log_sha256' => digest(log_path),
      'gameplay_verified' => false,
      'save_reload_verified' => false,
      'android_verified' => false,
      'distributable' => false
    }
    File.write(receipt_path, JSON.pretty_generate(result) + "\n")
    File.delete(marker_path)
    result
  end
end

if $PROGRAM_NAME == __FILE__
  options = { timeout: 60 }
  OptionParser.new do |opts|
    opts.banner = 'ruby scripts/compile_private_pbs_native.rb --project PRIVATE_CANDIDATE --engine /path/to/mkxp-z'
    opts.on('--project PATH') { |value| options[:project] = value }
    opts.on('--engine PATH') { |value| options[:engine] = value }
    opts.on('--timeout SECONDS', Integer) { |value| options[:timeout] = value }
  end.parse!
  abort 'Missing --project or --engine' unless options[:project] && options[:engine]
  puts JSON.pretty_generate(ShatteredNativePBS.compile(options[:project], options[:engine], timeout_seconds: options[:timeout]))
end
