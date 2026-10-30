require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"
require "zlib"
require_relative "../scripts/compile_private_plugins"

class PrivatePluginCompilerTest < Minitest::Test
  def with_stage
    Dir.mktmpdir("shattered-compiled-stage") do |root|
      FileUtils.mkdir_p(File.join(root, "Data"))
      FileUtils.mkdir_p(File.join(root, "Plugins/Shattered Core"))
      File.write(File.join(root, "SHATTERED_STAGING_REPORT.json"), "{}")
      File.write(File.join(root, "Plugins/Shattered Core/meta.txt"), <<~META)
        Name       = Shattered Core
        Version    = 0.2.3
        Essentials = 21.1
        Website    = https://github.com/xbaconator9000x/Shattered
        Credits    = Shattered contributors
      META
      File.write(File.join(root, "Plugins/Shattered Core/001_Core.rb"),
        "module Shattered; CORE_TEST = true; end\n")
      old = [["v21.1 Hotfixes",
        { :name => "v21.1 Hotfixes", :version => "1.0.3", :essentials => ["21.1"] },
        [["Battle bug fixes.rb", Zlib::Deflate.deflate("HOTFIX_TEST = true\n")]]]]
      File.binwrite(File.join(root, "Data/PluginScripts.rxdata"), Marshal.dump(old))
      yield root
    end
  end

  def add_staged_plugin(root, name, sources)
    folder = File.join(root, "Plugins", name)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "meta.txt"), <<~META)
      Name = #{name}
      Version = 0.1.0
      Essentials = 21.1
    META
    sources.each { |filename, code| File.write(File.join(folder, filename), code) }
  end

  def test_excludes_offline_installers_from_native_script_archive
    with_stage do |root|
      add_staged_plugin(root, "Shattered Gate Story", {
        "001_GateStory.rb" => "module GateRuntime; end\n",
        "002_Install.rb" => "require 'json'\nraise 'offline installer executed'\n"
      })
      report = ShatteredPrivatePluginCompiler.compile(root, ["Shattered Gate Story"])
      assert_equal ["Shattered Gate Story"], report["added"]
      entries = Marshal.load(File.binread(File.join(root, "Data/PluginScripts.rxdata")))
      assert_equal ["001_GateStory.rb"], entries.last[2].map(&:first)
      refute_includes Zlib::Inflate.inflate(entries.last[2].first.last), "offline installer"
    end
  end

  def test_offline_only_plugins_are_reported_and_not_compiled
    with_stage do |root|
      add_staged_plugin(root, "Shattered World Links", {
        "001_Install.rb" => "require 'json'\nraise 'offline only'\n"
      })
      target = File.join(root, "Data/PluginScripts.rxdata")
      before = File.binread(target)
      report = ShatteredPrivatePluginCompiler.compile(root, ["Shattered World Links"])
      assert_equal ["Shattered World Links"], report["offline_only"]
      assert_empty report["added"]
      assert_equal before, File.binread(target)
      assert_empty Dir.glob(target + ".pre_shattered_*.bak")
    end
  end

  def test_refuses_top_level_runtime_require_before_any_archive_write
    with_stage do |root|
      source = File.join(root, "Plugins/Shattered Core/001_Core.rb")
      File.write(source, "require 'json'\nmodule Shattered; end\n")
      target = File.join(root, "Data/PluginScripts.rxdata")
      before = File.binread(target)
      error = assert_raises(RuntimeError) do
        ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      end
      assert_match(/top-level library/, error.message)
      assert_equal before, File.binread(target)
    end
  end

  def test_refuses_unreviewed_runtime_source_file
    with_stage do |root|
      File.write(File.join(root, "Plugins/Shattered Core/002_Unknown.rb"), "raise 'unsafe'\n")
      target = File.join(root, "Data/PluginScripts.rxdata")
      before = File.binread(target)
      error = assert_raises(RuntimeError) do
        ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      end
      assert_match(/Unreviewed plugin source inventory/, error.message)
      assert_equal before, File.binread(target)
    end
  end

  def test_refuses_existing_compiled_offline_only_plugin
    with_stage do |root|
      add_staged_plugin(root, "Shattered HnS Gate", {
        "001_Import.rb" => "require 'json'\n"
      })
      target = File.join(root, "Data/PluginScripts.rxdata")
      entries = Marshal.load(File.binread(target))
      entries << ["Shattered HnS Gate", { :version => "0.1.0" },
        [["001_Import.rb", Zlib::Deflate.deflate("require 'json'\n")]]]
      File.binwrite(target, Marshal.dump(entries))
      before = File.binread(target)
      assert_raises(RuntimeError) do
        ShatteredPrivatePluginCompiler.compile(root, ["Shattered HnS Gate"])
      end
      assert_equal before, File.binread(target)
    end
  end

  def test_compiles_native_archive_and_preserves_hotfixes_and_backup
    with_stage do |root|
      target = File.join(root, "Data/PluginScripts.rxdata")
      before = File.binread(target)
      report = ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      assert_equal ["Shattered Core"], report["added"]
      assert_equal ["v21.1 Hotfixes", "Shattered Core"], report["plugin_names"]
      entries = Marshal.load(File.binread(target))
      assert_equal 2, entries.length
      assert_equal "0.2.3", entries.last[1][:version]
      assert_equal ["21.1"], entries.last[1][:essentials]
      assert_equal "001_Core.rb", entries.last[2][0][0]
      assert_equal "module Shattered; CORE_TEST = true; end\n",
        Zlib::Inflate.inflate(entries.last[2][0][1])
      assert_equal before, File.binread(Dir.glob(target + ".pre_shattered_*.bak").fetch(0))
      assert File.file?(File.join(root, "SHATTERED_NATIVE_COMPILE_REPORT.json"))
      refute report["gameplay_verified"]
      refute report["pbs_compiled"]
    end
  end

  def test_rerun_is_idempotent_and_does_not_touch_compiled_archive
    with_stage do |root|
      target = File.join(root, "Data/PluginScripts.rxdata")
      ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      sha = Digest::SHA256.file(target).hexdigest
      report = ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      assert_empty report["added"]
      assert_equal ["Shattered Core"], report["unchanged"]
      assert_equal sha, Digest::SHA256.file(target).hexdigest
      assert_equal 1, Dir.glob(target + ".pre_shattered_*.bak").length
    end
  end

  def test_rejects_modified_existing_plugin_without_overwrite
    with_stage do |root|
      target = File.join(root, "Data/PluginScripts.rxdata")
      ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      sha = Digest::SHA256.file(target).hexdigest
      File.write(File.join(root, "Plugins/Shattered Core/001_Core.rb"), "different")
      assert_raises(RuntimeError) do
        ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      end
      assert_equal sha, Digest::SHA256.file(target).hexdigest
    end
  end

  def test_requires_private_staging_report
    with_stage do |root|
      target = File.join(root, "Data/PluginScripts.rxdata")
      sha = Digest::SHA256.file(target).hexdigest
      File.delete(File.join(root, "SHATTERED_STAGING_REPORT.json"))
      assert_raises(RuntimeError) do
        ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      end
      assert_equal sha, Digest::SHA256.file(target).hexdigest
    end
  end

  def test_rejects_corrupted_existing_archive_and_unsafe_source
    with_stage do |root|
      target = File.join(root, "Data/PluginScripts.rxdata")
      File.binwrite(target, Marshal.dump([["bad", {}, [["broken.rb", "not-zlib"]]]]))
      before = File.binread(target)
      assert_raises(Zlib::DataError) do
        ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      end
      assert_equal before, File.binread(target)
    end
    with_stage do |root|
      source = File.join(root, "Plugins/Shattered Core/001_Core.rb")
      File.delete(source)
      File.symlink("/etc/passwd", source)
      target = File.join(root, "Data/PluginScripts.rxdata")
      sha = Digest::SHA256.file(target).hexdigest
      assert_raises(RuntimeError) do
        ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      end
      assert_equal sha, Digest::SHA256.file(target).hexdigest
    end
  end

  def test_rejects_missing_or_duplicate_plugin_requests
    with_stage do |root|
      assert_raises(RuntimeError) do
        ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core", "Shattered Core"])
      end
      assert_raises(RuntimeError) do
        ShatteredPrivatePluginCompiler.compile(root, ["Other Plugin"])
      end
    end
  end
end
