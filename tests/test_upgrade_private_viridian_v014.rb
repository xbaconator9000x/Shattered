# frozen_string_literal: true
require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require 'fileutils'
require 'zlib'
require_relative '../scripts/upgrade_private_viridian_v014'

class UpgradePrivateViridian014Test < Minitest::Test
  SRC = File.expand_path('../essentials/Plugins/Shattered Viridian', __dir__)
  OLD_META = "Name = Shattered Viridian\nVersion = 0.1.3\nEssentials = 21.1\nDescription = Native staged Viridian escort, rain and Center story events\n"

  def setup
    @dir = Dir.mktmpdir('shattered-viridian-test')
    FileUtils.mkdir_p(File.join(@dir, 'Data'))
    FileUtils.mkdir_p(File.join(@dir, 'Plugins', 'Shattered Viridian'))
    File.write(File.join(@dir, 'SHATTERED_STAGING_REPORT.json'), '{}')
    @old_source = source_v013
    assert_equal ShatteredPrivateViridian014::OLD_SOURCE_SHA, ShatteredPrivateViridian014.sha(@old_source)
    @other = ['Shattered Core', {version: '0.2.4'}, [['001_Core.rb', Zlib::Deflate.deflate('original core')]]]
    @plugin = ['Shattered Viridian', {name: 'Shattered Viridian', version: '0.1.3', essentials: ['21.1']},
               [['001_Entry.rb', Zlib::Deflate.deflate(@old_source)]]]
    File.binwrite(archive, Marshal.dump([@other, @plugin]))
    File.binwrite(loose, @old_source)
    File.binwrite(meta, OLD_META)
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def archive = File.join(@dir, 'Data', 'PluginScripts.rxdata')
  def loose = File.join(@dir, 'Plugins', 'Shattered Viridian', '001_Entry.rb')
  def meta = File.join(@dir, 'Plugins', 'Shattered Viridian', 'meta.txt')
  def bytes = [archive, loose, meta].map { |p| File.binread(p) }

  def test_upgrades_compiled_and_loose_sources_and_is_idempotent
    result = ShatteredPrivateViridian014.update!(@dir, SRC)
    assert result['changed']
    entries = Marshal.load(File.binread(archive))
    assert_equal @other, entries[0]
    assert_equal '0.1.4', entries[1][1][:version]
    assert_equal File.binread(File.join(SRC, '001_Entry.rb')),
      Zlib::Inflate.inflate(entries[1][2][0][1])
    assert_equal ShatteredPrivateViridian014::NEW_SOURCE_SHA, ShatteredPrivateViridian014.sha(File.binread(loose))
    assert_equal ShatteredPrivateViridian014::NEW_META_SHA, ShatteredPrivateViridian014.sha(File.binread(meta))
    after = bytes
    refute ShatteredPrivateViridian014.update!(@dir, SRC)['changed']
    assert_equal after, bytes
  end

  def test_tampered_source_and_partial_upgrade_are_rejected_without_changes
    File.binwrite(loose, 'tampered')
    before = bytes
    assert_raises(RuntimeError) { ShatteredPrivateViridian014.update!(@dir, SRC) }
    assert_equal before, bytes

    File.binwrite(loose, @old_source)
    entries = Marshal.load(File.binread(archive))
    entries[1][1][:version] = '0.1.4'
    File.binwrite(archive, Marshal.dump(entries))
    before = bytes
    assert_raises(RuntimeError) { ShatteredPrivateViridian014.update!(@dir, SRC) }
    assert_equal before, bytes
  end

  def test_missing_staging_marker_and_symlinked_source_are_rejected_without_mutation
    File.delete(File.join(@dir, 'SHATTERED_STAGING_REPORT.json'))
    before = bytes
    assert_raises(RuntimeError) { ShatteredPrivateViridian014.update!(@dir, SRC) }
    assert_equal before, bytes

    File.write(File.join(@dir, 'SHATTERED_STAGING_REPORT.json'), '{}')
    File.delete(loose)
    File.symlink(File.join(SRC, '001_Entry.rb'), loose)
    before = [File.binread(archive), File.binread(meta)]
    assert_raises(RuntimeError) { ShatteredPrivateViridian014.update!(@dir, SRC) }
    assert_equal before, [File.binread(archive), File.binread(meta)]
  end

  def test_dangling_temp_symlink_is_rejected_without_writing_through_it
    temp = "#{loose}.viridian014.tmp"
    Dir.mktmpdir('shattered-outside') do |outside|
      target = File.join(outside, 'outside-staged-project')
      File.symlink(target, temp)
      before = bytes

      assert_raises(RuntimeError) { ShatteredPrivateViridian014.update!(@dir, SRC) }

      assert File.symlink?(temp)
      refute File.exist?(target)
      assert_equal before, bytes
    end
  end

  def test_staging_failure_leaves_originals_untouched
    write_temp = ShatteredPrivateViridian014.method(:write_temp!)
    failing_writer = lambda do |path, content|
      raise IOError, 'injected staging failure' if path == "#{loose}.viridian014.tmp"
      write_temp.call(path, content)
    end
    before = bytes

    ShatteredPrivateViridian014.stub(:write_temp!, failing_writer) do
      error = assert_raises(IOError) { ShatteredPrivateViridian014.update!(@dir, SRC) }
      assert_equal 'injected staging failure', error.message
    end

    assert_equal before, bytes
    refute File.exist?("#{archive}.viridian014.tmp")
  end

  def test_failed_replacement_restores_originals_with_rename_backups
    rename = File.method(:rename)
    failing_rename = lambda do |source, destination|
      raise IOError, 'injected replacement failure' if
        source == "#{loose}.viridian014.tmp" && destination == loose
      rename.call(source, destination)
    end
    before = bytes

    File.stub(:rename, failing_rename) do
      assert_raises(IOError) { ShatteredPrivateViridian014.update!(@dir, SRC) }
    end

    assert_equal before, bytes
    [archive, loose, meta].each { |path| refute File.exist?("#{path}.viridian014.bak") }
  end

  def test_failed_rollback_preserves_recovery_backup
    rename = File.method(:rename)
    failing_rename = lambda do |source, destination|
      if (source == "#{loose}.viridian014.tmp" && destination == loose) ||
         (source == "#{loose}.viridian014.bak" && destination == loose)
        raise IOError, 'injected rename failure'
      end
      rename.call(source, destination)
    end
    before = bytes

    File.stub(:rename, failing_rename) do
      error = assert_raises(RuntimeError) { ShatteredPrivateViridian014.update!(@dir, SRC) }
      assert_match(/recovery backups retained/, error.message)
      assert_match(/#{Regexp.escape("#{loose}.viridian014.bak")}/, error.message)
    end

    assert_equal before[0], File.binread(archive)
    assert_equal before[2], File.binread(meta)
    refute File.exist?(loose)
    assert_equal before[1], File.binread("#{loose}.viridian014.bak")
  end

  private

  def source_v013
    source = File.binread(File.join(SRC, '001_Entry.rb'))
    source.sub!("  def self.route22_cleared?\n    defined?(ShatteredRoute22) && ShatteredRoute22.respond_to?(:cleared?) &&\n      ShatteredRoute22.cleared?\n  end\n\n", '')
    prerequisite = "    value = state\n    return false unless route22_cleared?\n"
    assert_equal 3, source.scan(prerequisite).length
    source.gsub!(prerequisite, "    value = state\n")
    source.sub!("    value = state\n    unless route22_cleared?\n      ids.each { |id| $game_switches[id] = false }\n      return false\n    end\n", "    value = state\n")
    source.sub!("    return false unless defined?($PokemonGlobal) && $PokemonGlobal\n    state\n    return false unless route22_cleared?\n", '')
    source
  end
end
