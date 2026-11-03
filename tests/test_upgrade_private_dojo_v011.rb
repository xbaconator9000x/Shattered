# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'zlib'
require_relative '../scripts/upgrade_private_dojo_v011'

class UpgradePrivateDojo011Test < Minitest::Test
  SRC = File.expand_path('../essentials/Plugins/Shattered Dojo', __dir__)
  OLD_META = "Name = Shattered Dojo\nVersion = 0.1.0\nEssentials = 21.1\nDescription = Saved dojo questionnaire and native no-ball starter recruitment event\n"

  def setup
    @dir = Dir.mktmpdir('shattered-dojo-test')
    FileUtils.mkdir_p(File.join(@dir, 'Data'))
    FileUtils.mkdir_p(File.join(@dir, 'Plugins', 'Shattered Dojo'))
    File.write(File.join(@dir, 'SHATTERED_STAGING_REPORT.json'), '{}')
    # The private v0.2.18 candidate carried the original source with one
    # extra trailing newline; the exact SHA pin prevents any silent fallback.
    @source = File.binread(File.expand_path('fixtures/private_dojo_v010.rb', __dir__)) + "\n"
    assert_equal ShatteredPrivateDojo011::OLD_SOURCE_SHA, ShatteredPrivateDojo011.sha(@source)
    @other = ['Shattered Core', {version: '0.2.4'}, [['001_Core.rb', Zlib::Deflate.deflate('original core')]]]
    @plugin = ['Shattered Dojo', {name: 'Shattered Dojo', version: '0.1.0', essentials: ['21.1']},
               [['001_Starter.rb', Zlib::Deflate.deflate(@source)]]]
    File.binwrite(archive, Marshal.dump([@other, @plugin]))
    File.binwrite(loose, @source)
    File.binwrite(meta, OLD_META)
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def archive = File.join(@dir, 'Data', 'PluginScripts.rxdata')
  def loose = File.join(@dir, 'Plugins', 'Shattered Dojo', '001_Starter.rb')
  def meta = File.join(@dir, 'Plugins', 'Shattered Dojo', 'meta.txt')
  def bytes = [archive, loose, meta].map { |p| File.binread(p) }

  def test_upgrades_compiled_and_loose_sources_and_is_idempotent
    result = ShatteredPrivateDojo011.update!(@dir, SRC)
    assert result['changed']
    entries = Marshal.load(File.binread(archive))
    assert_equal @other, entries[0]
    assert_equal '0.1.1', entries[1][1][:version]
    assert_equal File.binread(File.join(SRC, '001_Starter.rb')), Zlib::Inflate.inflate(entries[1][2][0][1])
    assert_equal ShatteredPrivateDojo011::NEW_SOURCE_SHA, ShatteredPrivateDojo011.sha(File.binread(loose))
    assert_equal ShatteredPrivateDojo011::NEW_META_SHA, ShatteredPrivateDojo011.sha(File.binread(meta))
    after = bytes
    refute ShatteredPrivateDojo011.update!(@dir, SRC)['changed']
    assert_equal after, bytes
  end

  def test_tampered_source_is_rejected_without_any_changes
    File.binwrite(loose, 'tampered')
    before = bytes
    assert_raises(RuntimeError) { ShatteredPrivateDojo011.update!(@dir, SRC) }
    assert_equal before, bytes
  end

  def test_partial_upgrade_is_rejected_without_any_changes
    entries = Marshal.load(File.binread(archive))
    entries[1][1][:version] = '0.1.1'
    File.binwrite(archive, Marshal.dump(entries))
    before = bytes
    assert_raises(RuntimeError) { ShatteredPrivateDojo011.update!(@dir, SRC) }
    assert_equal before, bytes
  end

  def test_missing_staging_marker_is_rejected_without_mutation
    File.delete(File.join(@dir, 'SHATTERED_STAGING_REPORT.json'))
    before = bytes
    assert_raises(RuntimeError) { ShatteredPrivateDojo011.update!(@dir, SRC) }
    assert_equal before, bytes
  end

  def test_symlinked_source_is_rejected_without_mutation
    File.delete(loose)
    File.symlink(File.join(SRC, '001_Starter.rb'), loose)
    before = [File.binread(archive), File.binread(meta)]
    assert_raises(RuntimeError) { ShatteredPrivateDojo011.update!(@dir, SRC) }
    assert_equal before, [File.binread(archive), File.binread(meta)]
  end
end
