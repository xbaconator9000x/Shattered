# frozen_string_literal: true
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'zlib'
require_relative '../scripts/install_private_initial_slice_native'

class PrivateInitialSliceNativeTest < Minitest::Test
  P = ShatteredPrivateInitialSliceNative

  def setup
    @root = Dir.mktmpdir('shattered-native-slice-')
    @data = File.join(@root, 'Data')
    FileUtils.mkdir_p(@data)
    @plan_path = File.join(@root, 'Plugins', 'Shattered Initial Slice Installer', 'initial_slice_plan.json')
    FileUtils.mkdir_p(File.dirname(@plan_path))
    @plan = { 'profile' => 'initial_slice', 'map_targets' => { 'reception_gate' => 223 } }
    @plan_bytes = JSON.generate(@plan)
    File.write(@plan_path, @plan_bytes)
    @plan_sha = Digest::SHA256.hexdigest(@plan_bytes)
    archive_sha = Digest::SHA256.hexdigest('compiled')
    File.write(File.join(@root, 'SHATTERED_NATIVE_CANDIDATE.json'),
      JSON.generate('source_sha' => 'a' * 40, 'compiled_plugin_archive_sha256' => archive_sha))
    File.write(File.join(@root, 'SHATTERED_RUNTIME_ISOLATION_REPORT.json'),
      JSON.generate('compiled_archive_sha256' => archive_sha))
    File.write(File.join(@root, 'SHATTERED_INTEGRATION_BUILD.json'),
      JSON.generate('native_install' => {
        'status' => 'native_install_pending',
        'entrypoint' => 'pbInstallShatteredInitialSlice',
        'plan_path' => 'Plugins/Shattered Initial Slice Installer/initial_slice_plan.json',
        'plan_sha256' => @plan_sha
      }))
    File.write(File.join(@root, 'SHATTERED_NATIVE_PBS_COMPILE_REPORT.json'),
      JSON.generate('native_compiler_completed' => true, 'source_sha' => 'a' * 40,
        'gameplay_verified' => false))
    File.binwrite(File.join(@data, 'PluginScripts.rxdata'), 'compiled')
    @scripts_path = File.join(@data, 'Scripts.rxdata')
    @scripts = Marshal.dump([
      [1, 'Main', Zlib::Deflate.deflate(
        "    PluginManager.runPlugins\n    Compiler.main\n"
      )]
    ])
    File.binwrite(@scripts_path, @scripts)
    @engine = File.join(@root, 'mkxp-z-test')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write_engine(contents)
    File.write(@engine, "#!/bin/sh\n#{contents}\n")
    File.chmod(0o755, @engine)
  end

  def test_instrument_runs_only_the_staged_installer_then_exits
    modified = Marshal.load(P.instrument(@scripts, @plan_sha))
    source = Zlib::Inflate.inflate(modified.first[2])
    assert_includes source, "    pbInstallShatteredInitialSlice\n"
    assert_includes source, "File.write(\"SHATTERED_PRIVATE_INITIAL_SLICE.ok\", \"#{@plan_sha}\")"
    assert_equal 1, source.scan('    Compiler.main').length
    assert_operator source.index('pbInstallShatteredInitialSlice'), :<, source.index('    Compiler.main')
  end

  def test_rejects_missing_or_ambiguous_main_hook
    assert_raises(RuntimeError) { P.instrument(Marshal.dump([]), @plan_sha) }
    ambiguous = Marshal.dump([
      [1, 'Main', Zlib::Deflate.deflate("    PluginManager.runPlugins\n    Compiler.main\n")],
      [2, 'Main', Zlib::Deflate.deflate("    PluginManager.runPlugins\n    Compiler.main\n")]
    ])
    assert_raises(RuntimeError) { P.instrument(ambiguous, @plan_sha) }
  end

  def test_native_install_restores_scripts_and_records_installer_receipt
    write_engine(<<~SH)
      printf '%s' '#{@plan_sha}' > SHATTERED_PRIVATE_INITIAL_SLICE.ok
      printf '%s' '{"status":"native_install_complete","plan_sha256":"#{@plan_sha}","gameplay_verified":false,"save_reload_verified":false}' > Data/.shattered_initial_slice.receipt.json
    SH

    report = P.install(@root, @engine)

    assert_equal true, report.fetch('native_map_install_completed')
    assert_equal false, report.fetch('gameplay_verified')
    assert_equal @scripts, File.binread(@scripts_path)
    assert File.file?(File.join(@root, P::MAP_RECEIPT))
    assert File.file?(File.join(@root, P::REPORT))
    refute File.exist?(@scripts_path + '.pre_shattered_initial_slice.bak')
    refute File.exist?(File.join(@root, P::MARKER))
  end

  def test_engine_failure_restores_scripts_without_publishing_success
    write_engine('exit 9')
    assert_raises(RuntimeError) { P.install(@root, @engine) }
    assert_equal @scripts, File.binread(@scripts_path)
    refute File.exist?(@scripts_path + '.pre_shattered_initial_slice.bak')
    refute File.exist?(File.join(@root, P::REPORT))
  end

  def test_stale_symlink_transaction_is_rejected_without_touching_scripts
    File.symlink(File.join(@root, 'missing-target'),
      @scripts_path + '.pre_shattered_initial_slice.bak')
    write_engine('exit 0')
    assert_raises(RuntimeError) { P.install(@root, @engine) }
    assert_equal @scripts, File.binread(@scripts_path)
  end
end
