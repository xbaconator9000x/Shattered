# frozen_string_literal: true
require 'minitest/autorun'
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
