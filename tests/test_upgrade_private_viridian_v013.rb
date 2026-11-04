# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'zlib'
require_relative '../scripts/upgrade_private_viridian_v013'

class UpgradePrivateViridian013Test < Minitest::Test
  SRC = File.expand_path('../essentials/Plugins/Shattered Viridian', __dir__)
  OLD_META = "Name = Shattered Viridian\nVersion = 0.1.2\nEssentials = 21.1\nDescription = Native staged Viridian escort, rain and Center story events\n"

  def setup
    @dir = Dir.mktmpdir('shattered-viridian-test')
    @v013_dir = File.join(@dir, 'v013-source')
    FileUtils.mkdir_p(File.join(@dir, 'Data'))
    FileUtils.mkdir_p(File.join(@dir, 'Plugins', 'Shattered Viridian'))
    FileUtils.mkdir_p(@v013_dir)
    File.write(File.join(@dir, 'SHATTERED_STAGING_REPORT.json'), '{}')
    v013_source = source_v013
    @source = v013_source.sub(
      " &&\n      (!value[:arrived] || value[:started]) && (!value[:center] || value[:arrived])", '')
    assert_equal ShatteredPrivateViridian013::OLD_SOURCE_SHA, ShatteredPrivateViridian013.sha(@source)
    File.binwrite(File.join(@v013_dir, '001_Entry.rb'), v013_source)
    File.binwrite(File.join(@v013_dir, 'meta.txt'),
      OLD_META.sub('Version = 0.1.2', 'Version = 0.1.3'))
    assert_equal ShatteredPrivateViridian013::NEW_SOURCE_SHA,
      ShatteredPrivateViridian013.sha(v013_source)
    @other = ['Shattered Core', {version: '0.2.4'}, [['001_Core.rb', Zlib::Deflate.deflate('original core')]]]
    @plugin = ['Shattered Viridian', {name: 'Shattered Viridian', version: '0.1.2', essentials: ['21.1']},
               [['001_Entry.rb', Zlib::Deflate.deflate(@source)]]]
    File.binwrite(archive, Marshal.dump([@other, @plugin]))
    File.binwrite(loose, @source)
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
    result = ShatteredPrivateViridian013.update!(@dir, @v013_dir)
    assert result['changed']
    entries = Marshal.load(File.binread(archive))
    assert_equal @other, entries[0]
    assert_equal '0.1.3', entries[1][1][:version]
    assert_equal File.binread(File.join(@v013_dir, '001_Entry.rb')),
      Zlib::Inflate.inflate(entries[1][2][0][1])
    assert_equal ShatteredPrivateViridian013::NEW_SOURCE_SHA, ShatteredPrivateViridian013.sha(File.binread(loose))
    assert_equal ShatteredPrivateViridian013::NEW_META_SHA, ShatteredPrivateViridian013.sha(File.binread(meta))
    after = bytes
    refute ShatteredPrivateViridian013.update!(@dir, @v013_dir)['changed']
    assert_equal after, bytes
  end

  def test_tampered_source_is_rejected_without_any_changes
    File.binwrite(loose, 'tampered')
    before = bytes
    assert_raises(RuntimeError) { ShatteredPrivateViridian013.update!(@dir, @v013_dir) }
    assert_equal before, bytes
  end

  def test_partial_upgrade_is_rejected_without_any_changes
    entries = Marshal.load(File.binread(archive))
    entries[1][1][:version] = '0.1.3'
    File.binwrite(archive, Marshal.dump(entries))
    before = bytes
    assert_raises(RuntimeError) { ShatteredPrivateViridian013.update!(@dir, @v013_dir) }
    assert_equal before, bytes
  end

  def test_missing_staging_marker_is_rejected_without_mutation
    File.delete(File.join(@dir, 'SHATTERED_STAGING_REPORT.json'))
    before = bytes
    assert_raises(RuntimeError) { ShatteredPrivateViridian013.update!(@dir, @v013_dir) }
    assert_equal before, bytes
  end

  def test_symlinked_source_is_rejected_without_mutation
    File.delete(loose)
    File.symlink(File.join(SRC, '001_Entry.rb'), loose)
    before = [File.binread(archive), File.binread(meta)]
    assert_raises(RuntimeError) { ShatteredPrivateViridian013.update!(@dir, @v013_dir) }
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
