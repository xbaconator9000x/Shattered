require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "zlib"
require_relative "../scripts/verify_private_plugin_coherence"

class PrivatePluginCoherenceTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("shattered-plugin-coherence-")
    FileUtils.mkdir_p(File.join(@root, "Data"))
    @plugin = File.join(@root, "Plugins", "Shattered Gate Story")
    FileUtils.mkdir_p(@plugin)
    File.write(File.join(@root, "SHATTERED_STAGING_REPORT.json"), "{}")
    @source = 'puts "real source"'
    File.write(File.join(@plugin, "001_GateStory.rb"), @source)
    File.write(File.join(@plugin, "meta.txt"),
      "Name = Shattered Gate Story\nVersion = 0.2.2\n")
    write_archive
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write_archive(filename = "001_GateStory.rb")
    entries = [["Shattered Gate Story",
      { :name => "Shattered Gate Story", :version => "0.2.2" },
      [[filename, Zlib::Deflate.deflate(@source)]]]]
    File.binwrite(File.join(@root, "Data", "PluginScripts.rxdata"), Marshal.dump(entries))
  end

  def test_matching_compiled_source_and_version_pass
    result = ShatteredPluginCoherence.verify!(@root)
    assert_equal 1, result.fetch("plugin_count")
    assert_equal "0.2.2", result.fetch("plugins").first.fetch("version")
    assert_equal "001_GateStory.rb", result.fetch("plugins").first.fetch("scripts").first.fetch("file")
  end

  def test_stale_loose_source_is_rejected
    File.write(File.join(@plugin, "001_GateStory.rb"), "old source")
    error = assert_raises(RuntimeError) { ShatteredPluginCoherence.verify!(@root) }
    assert_match(/STALE COMPILED\/LOOSE SOURCE/, error.message)
  end

  def test_stale_meta_version_is_rejected
    File.write(File.join(@plugin, "meta.txt"), "Version = 0.2.1\n")
    error = assert_raises(RuntimeError) { ShatteredPluginCoherence.verify!(@root) }
    assert_match(/Plugin version drift/, error.message)
  end

  def test_uncompiled_loose_ruby_is_rejected
    File.write(File.join(@plugin, "002_Install.rb"), "puts 'offline'")
    assert_raises(RuntimeError) { ShatteredPluginCoherence.verify!(@root) }
  end

  def test_symlinked_source_is_rejected
    File.delete(File.join(@plugin, "001_GateStory.rb"))
    File.symlink(File.join(@root, "SHATTERED_STAGING_REPORT.json"),
                 File.join(@plugin, "001_GateStory.rb"))
    assert_raises(RuntimeError) { ShatteredPluginCoherence.verify!(@root) }
  end

  def test_compiled_path_traversal_is_rejected
    write_archive("../escape.rb")
    assert_raises(RuntimeError) { ShatteredPluginCoherence.verify!(@root) }
  end

  def test_compiled_source_drift_is_rejected
    @source = "puts 'changed'"
    write_archive
    assert_raises(RuntimeError) { ShatteredPluginCoherence.verify!(@root) }
  end

  def test_uncompiled_shattered_directory_is_rejected
    FileUtils.mkdir_p(File.join(@root, "Plugins", "Shattered Orphan"))
    assert_raises(RuntimeError) { ShatteredPluginCoherence.verify!(@root) }
  end
end
