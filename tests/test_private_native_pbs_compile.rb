require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'zlib'
require_relative '../scripts/compile_private_pbs_native'

class NativePBSCompileTest < Minitest::Test
  def fixture(main)
    Marshal.dump([[1, 'Other', Zlib::Deflate.deflate('X = 1')], [2, 'Main', Zlib::Deflate.deflate(main)]])
  end

  def test_instrument_preserves_non_main_scripts_and_injects_native_compiler
    original = fixture("    PluginManager.runPlugins\r\n    Compiler.main\r\n")
    changed = Marshal.load(ShatteredNativePBS.instrument(original))
    assert_equal 'X = 1', Zlib::Inflate.inflate(changed[0][2])
    source = Zlib::Inflate.inflate(changed[1][2])
    assert_includes source, 'Compiler.compile_pbs_files'
    assert_includes source, 'SHATTERED_PRIVATE_PBS_NATIVE.ok'
    assert_operator source.index('Compiler.compile_pbs_files'), :<, source.index('    exit')
    assert_equal "    PluginManager.runPlugins\r\n    Compiler.main\r\n", Zlib::Inflate.inflate(Marshal.load(original)[1][2])
  end

  def test_refuses_ambiguous_or_missing_main_hook
    assert_raises(RuntimeError) { ShatteredNativePBS.instrument(fixture('puts :hello')) }
    duplicate = Marshal.load(fixture("    PluginManager.runPlugins\n    Compiler.main\n"))
    duplicate << duplicate.last.dup
    assert_raises(RuntimeError) { ShatteredNativePBS.instrument(Marshal.dump(duplicate)) }
  end

  def test_rejects_invalid_marker
    assert_raises(RuntimeError) do
      ShatteredNativePBS.instrument(fixture("    PluginManager.runPlugins\n    Compiler.main\n"), '../escape')
    end
  end

  def test_failed_engine_restores_original_scripts
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, 'Data'))
      scripts = File.join(root, 'Data', 'Scripts.rxdata')
      original = fixture("    PluginManager.runPlugins\n    Compiler.main\n")
      File.binwrite(scripts, original)
      File.binwrite(File.join(root, 'Data', 'species.dat'), 'not compiled')
      File.binwrite(File.join(root, 'Data', 'PluginScripts.rxdata'), 'archive')
      hash = ShatteredNativePBS.digest(File.join(root, 'Data', 'PluginScripts.rxdata'))
      File.write(File.join(root, 'SHATTERED_NATIVE_CANDIDATE.json'), JSON.generate({source_sha: 'a' * 40, compiled_plugin_archive_sha256: hash}))
      File.write(File.join(root, 'SHATTERED_RUNTIME_ISOLATION_REPORT.json'), JSON.generate({compiled_archive_sha256: hash}))
      engine = File.join(root, 'fake-engine')
      File.write(engine, "#!/bin/sh\nexit 9\n")
      File.chmod(0755, engine)
      assert_raises(RuntimeError) { ShatteredNativePBS.compile(root, engine) }
      assert_equal original, File.binread(scripts)
      refute File.exist?(scripts + '.pre_shattered_pbs_probe.bak')
      refute File.exist?(File.join(root, ShatteredNativePBS::RECEIPT))
    end
  end
end
