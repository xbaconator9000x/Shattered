# frozen_string_literal: true
# Synthetic Ruby fixture tests only. The actual private v0.2.16 repair is
# independently executed on the rights-held staged project, never in CI.
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'zlib'
require_relative '../scripts/repair_private_v0216_runtime_sources'

class PrivateV0216RuntimeCoherenceTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('shattered-private-coherence')
    @dir = File.join(@root, 'Plugins', 'Shattered Fixture')
    FileUtils.mkdir_p(@dir)
    @source = File.join(@dir, '001_Fixture.rb')
    @meta = File.join(@dir, 'meta.txt')
    File.binwrite(@source, "module Fixture; end\n")
    File.binwrite(@meta, "Name = Shattered Fixture\nVersion = 0.1.0\n")
    @entries = [['Shattered Fixture', { version: '0.1.0' },
      [['001_Fixture.rb', Zlib::Deflate.deflate("module Fixture; end\n")]]]]
  end

  def teardown
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  def test_exact_compiled_source_and_metadata_match
    assert ShatteredPrivateV0216RuntimeSources.verify_all!(Pathname.new(@root), @entries)
  end

  def test_changed_filesystem_script_is_rejected
    File.binwrite(@source, "module Fixture; HACK = true; end\n")
    assert_raises(RuntimeError) do
      ShatteredPrivateV0216RuntimeSources.verify_all!(Pathname.new(@root), @entries)
    end
  end

  def test_wrong_metadata_version_is_rejected
    File.binwrite(@meta, "Name = Shattered Fixture\nVersion = 0.0.9\n")
    assert_raises(RuntimeError) do
      ShatteredPrivateV0216RuntimeSources.verify_all!(Pathname.new(@root), @entries)
    end
  end

  def test_symlinked_script_is_rejected
    original = File.join(@root, 'other.rb')
    File.binwrite(original, "module Fixture; end\n")
    File.delete(@source)
    File.symlink(original, @source)
    assert_raises(RuntimeError) do
      ShatteredPrivateV0216RuntimeSources.verify_all!(Pathname.new(@root), @entries)
    end
  end

  def test_missing_staging_marker_cannot_be_repaired
    assert_raises(RuntimeError) do
      ShatteredPrivateV0216RuntimeSources.repair!(@root)
    end
    assert_equal "module Fixture; end\n", File.binread(@source)
  end

  def test_wrong_compiled_archive_is_rejected_before_mutation
    File.binwrite(File.join(@root, 'SHATTERED_STAGING_REPORT.json'), '{}')
    FileUtils.mkdir_p(File.join(@root, 'Data'))
    File.binwrite(File.join(@root, 'Data', 'PluginScripts.rxdata'), Marshal.dump(@entries))
    assert_raises(RuntimeError) do
      ShatteredPrivateV0216RuntimeSources.repair!(@root)
    end
    assert_equal "module Fixture; end\n", File.binread(@source)
  end

  def test_private_pins_are_exact_digests_not_game_assets
    pins = ShatteredPrivateV0216RuntimeSources::PINS
    assert_equal ['Shattered Gate Story', 'Shattered Route22'], pins.keys.sort
    pins.each_value do |pin|
      [:old_source, :source, :old_meta].each do |key|
        assert_match(/\A[0-9a-f]{64}\z/, pin.fetch(key))
      end
    end
    assert_match(/\A[0-9a-f]{64}\z/, ShatteredPrivateV0216RuntimeSources::ARCHIVE_SHA)
  end
end
