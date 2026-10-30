require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'zlib'
require_relative '../scripts/audit_native_script_syntax'

class NativeScriptSyntaxTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir('shattered-native-script-syntax')
    FileUtils.mkdir_p(File.join(@tmp, 'Data'))
    File.write(File.join(@tmp, 'Game.ini'), '[Game]')
    write_scripts([[1, 'valid', Zlib::Deflate.deflate('module Hello; end')]])
    write_plugins([['Hotfix', { version: '1.0.3' }, [['patch.rb', Zlib::Deflate.deflate('def hello; true; end')]]]])
  end
  def teardown
    FileUtils.remove_entry(@tmp)
  end
  def write_scripts(entries)
    File.binwrite(File.join(@tmp, 'Data/Scripts.rxdata'), Marshal.dump(entries))
  end
  def write_plugins(entries)
    File.binwrite(File.join(@tmp, 'Data/PluginScripts.rxdata'), Marshal.dump(entries))
  end
  def test_compiles_native_scripts_and_plugin_scripts
    report = ShatteredNativeScriptSyntax.audit(@tmp)
    assert report['syntax_pass']
    assert_equal 1, report['native_script_count']
    assert_equal 1, report['native_plugin_script_count']
    assert_equal '1.0.3', report['plugin_metadata'][0]['version']
    refute report['native_runtime_verified']
    refute report['save_reload_verified']
  end
  def test_syntax_error_does_not_emit_script_source
    write_scripts([[1, 'broken', Zlib::Deflate.deflate('def copyright_sensitive secret value end')]])
    report = ShatteredNativeScriptSyntax.audit(@tmp)
    refute report['syntax_pass']
    assert_equal 'SyntaxError', report['syntax_failures'][0]['error_class']
    refute JSON.generate(report).include?('copyright_sensitive')
  end
  def test_invalid_compression_rejected
    write_scripts([[1, 'bad', 'not zlib']])
    assert_raises(Zlib::DataError) { ShatteredNativeScriptSyntax.audit(@tmp) }
  end
  def test_decompression_bomb_rejected
    write_scripts([[1, 'bomb', Zlib::Deflate.deflate('x' * (ShatteredNativeScriptSyntax::MAX_SOURCE_BYTES + 1))]])
    assert_raises(ArgumentError) { ShatteredNativeScriptSyntax.audit(@tmp) }
  end
  def test_missing_plugin_archive_rejected
    File.delete(File.join(@tmp, 'Data/PluginScripts.rxdata'))
    assert_raises(ArgumentError) { ShatteredNativeScriptSyntax.audit(@tmp) }
  end
  def test_unexpected_plugin_entry_rejected
    write_plugins([['Hotfix', {}, [['bad.rb', nil]]]])
    assert_raises(ArgumentError) { ShatteredNativeScriptSyntax.audit(@tmp) }
  end
  def test_symlink_archive_rejected
    source = File.join(@tmp, 'Data/Scripts.rxdata')
    File.rename(source, source + '.source')
    File.symlink(source + '.source', source)
    assert_raises(ArgumentError) { ShatteredNativeScriptSyntax.audit(@tmp) }
  end
end
