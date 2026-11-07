#!/usr/bin/env ruby
# frozen_string_literal: true
# Execute the staged initial-slice installer inside private Essentials/mkxp-z.
require 'digest'
require 'json'
require 'optparse'
require 'timeout'
require 'zlib'

module ShatteredPrivateInitialSliceNative
  module_function

  MARKER = 'SHATTERED_PRIVATE_INITIAL_SLICE.ok'
  REPORT = 'SHATTERED_NATIVE_INITIAL_SLICE_INSTALL_REPORT.json'
  MAP_RECEIPT = 'Data/.shattered_initial_slice.receipt.json'
  MAIN_ANCHOR = /    PluginManager\.runPlugins\r?\n    Compiler\.main/

  def regular!(path)
    raise "Missing or unsafe private file: #{path}" unless File.file?(path) && !File.symlink?(path)
    path
  end

  def digest(path)
    Digest::SHA256.file(regular!(path)).hexdigest
  end

  def instrument(scripts, plan_sha256)
    raise 'Invalid native installer plan SHA256' unless
      plan_sha256.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(plan_sha256)
    entries = Marshal.load(scripts)
    raise 'Invalid native Scripts.rxdata' unless entries.is_a?(Array)
    mains = entries.select do |item|
      item.is_a?(Array) && item.length == 3 && item[1] == 'Main'
    end
    raise 'Expected exactly one native Main script' unless mains.length == 1
    main = mains.first
    source = Zlib::Inflate.inflate(main[2])
    raise 'Expected exactly one original Essentials Main installer hook' unless
      source.scan(MAIN_ANCHOR).length == 1
    newline = source.include?("\r\n") ? "\r\n" : "\n"
    injected = [
      '    PluginManager.runPlugins',
      '    pbInstallShatteredInitialSlice',
      "    File.write(#{MARKER.inspect}, #{plan_sha256.inspect})",
      '    exit',
      '    Compiler.main'
    ].join(newline)
    main[2] = Zlib::Deflate.deflate(source.sub(MAIN_ANCHOR, injected))
    Marshal.dump(entries)
  end

  def write_report(path, report)
    temporary = path + '.tmp'
    raise "Existing native install report path: #{path}" if File.exist?(path) ||
      File.symlink?(path) || File.exist?(temporary) || File.symlink?(temporary)
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.pretty_generate(report) + "\n")
    end
    File.rename(temporary, path)
  ensure
    File.delete(temporary) if temporary && File.file?(temporary) && !File.symlink?(temporary)
  end

  def install(project, engine, timeout_seconds: 180, environment: ENV)
    raise 'Timeout must be 5..300 seconds' unless timeout_seconds.between?(5, 300)
    raise 'Unsafe staged project root' unless File.directory?(project) && !File.symlink?(project)
    root = File.realpath(project)
    candidate_path = regular!(File.join(root, 'SHATTERED_NATIVE_CANDIDATE.json'))
    isolation_path = regular!(File.join(root, 'SHATTERED_RUNTIME_ISOLATION_REPORT.json'))
    build_path = regular!(File.join(root, 'SHATTERED_INTEGRATION_BUILD.json'))
    candidate = JSON.parse(File.read(candidate_path))
    isolation = JSON.parse(File.read(isolation_path))
    build = JSON.parse(File.read(build_path))
    native_install = build.fetch('native_install')
    raise 'Native initial-slice handoff is not pending' unless
      native_install['status'] == 'native_install_pending' &&
      native_install['entrypoint'] == 'pbInstallShatteredInitialSlice'
    plan_path = File.join(root, native_install.fetch('plan_path'))
    plan_bytes = File.binread(regular!(plan_path))
    plan_sha = Digest::SHA256.hexdigest(plan_bytes)
    raise 'Native installer plan differs from staged handoff receipt' unless
      plan_sha == native_install.fetch('plan_sha256')
    pbs_path = regular!(File.join(root, 'SHATTERED_NATIVE_PBS_COMPILE_REPORT.json'))
    pbs = JSON.parse(File.read(pbs_path))
    raise 'Native Essentials PBS compilation has not completed for this source' unless
      pbs['native_compiler_completed'] == true &&
      pbs['source_sha'] == candidate.fetch('source_sha') &&
      pbs['gameplay_verified'] == false
    archive_path = regular!(File.join(root, 'Data/PluginScripts.rxdata'))
    raise 'Compiled plugins changed after runtime isolation' unless
      digest(archive_path) == candidate.fetch('compiled_plugin_archive_sha256') &&
      digest(archive_path) == isolation.fetch('compiled_archive_sha256')
    engine_path = File.realpath(regular!(engine))
    scripts_path = regular!(File.join(root, 'Data/Scripts.rxdata'))
    map_receipt = File.join(root, MAP_RECEIPT)
    report_path = File.join(root, REPORT)
    marker_path = File.join(root, MARKER)
    log_path = File.join(root, 'SHATTERED_NATIVE_INITIAL_SLICE_INSTALL.log')
    [map_receipt, report_path, marker_path, log_path].each do |path|
      raise "Existing native install output requires review: #{path}" if
        File.exist?(path) || File.symlink?(path)
    end
    backup_path = scripts_path + '.pre_shattered_initial_slice.bak'
    temporary_path = scripts_path + '.shattered_initial_slice.tmp'
    [backup_path, temporary_path].each do |path|
      raise "Stale native installer transaction requires recovery: #{path}" if
        File.exist?(path) || File.symlink?(path)
    end

    original = File.binread(scripts_path)
    modified = instrument(original, plan_sha)
    original_sha = Digest::SHA256.hexdigest(original)
    File.open(temporary_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(modified)
    end
    moved = false
    pid = nil
    status = nil
    begin
      File.rename(scripts_path, backup_path)
      moved = true
      File.rename(temporary_path, scripts_path)
      pid = Process.spawn(environment.to_h, engine_path, chdir: root,
        out: log_path, err: [:child, :out])
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
        raise 'Native initial-slice installation timed out'
      end
    ensure
      if pid
        Process.kill('TERM', pid) rescue nil
        Process.waitpid(pid) rescue nil
      end
      if moved && File.file?(backup_path) && !File.symlink?(backup_path)
        File.delete(scripts_path) if File.exist?(scripts_path) && !File.symlink?(scripts_path)
        File.rename(backup_path, scripts_path)
      end
      File.delete(temporary_path) if File.file?(temporary_path) && !File.symlink?(temporary_path)
    end

    raise "Native installer engine exited unsuccessfully (#{status&.exitstatus})" unless
      status&.success?
    raise 'Original Scripts.rxdata was not restored' unless digest(scripts_path) == original_sha
    raise 'Native installer completion marker is missing or incorrect' unless
      File.file?(marker_path) && !File.symlink?(marker_path) && File.read(marker_path) == plan_sha
    receipt = JSON.parse(File.read(regular!(map_receipt)))
    raise 'Native map installer receipt does not match the reviewed plan' unless
      receipt['status'] == 'native_install_complete' &&
      receipt['plan_sha256'] == plan_sha &&
      receipt['gameplay_verified'] == false &&
      receipt['save_reload_verified'] == false
    regular!(log_path)
    report = {
      'kind' => 'actual_private_essentials_native_initial_slice_install_not_gameplay_acceptance',
      'source_sha' => candidate.fetch('source_sha'),
      'plan_sha256' => plan_sha,
      'engine_sha256' => digest(engine_path),
      'scripts_sha256' => original_sha,
      'restored_scripts_sha256' => digest(scripts_path),
      'map_receipt_sha256' => digest(map_receipt),
      'log_sha256' => digest(log_path),
      'native_map_install_completed' => true,
      'gameplay_verified' => false,
      'save_reload_verified' => false,
      'android_verified' => false,
      'distributable' => false
    }
    write_report(File.join(root, REPORT), report)
    File.delete(marker_path)
    report
  end
end

if $PROGRAM_NAME == __FILE__
  options = { timeout: 180 }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/install_private_initial_slice_native.rb --project PRIVATE_CANDIDATE --engine /path/to/mkxp-z'
    parser.on('--project PATH') { |value| options[:project] = value }
    parser.on('--engine PATH') { |value| options[:engine] = value }
    parser.on('--timeout SECONDS', Integer) { |value| options[:timeout] = value }
  end.parse!
  abort 'Missing --project or --engine' unless options[:project] && options[:engine]
  puts JSON.pretty_generate(ShatteredPrivateInitialSliceNative.install(
    options[:project], options[:engine], timeout_seconds: options[:timeout]
  ))
end
