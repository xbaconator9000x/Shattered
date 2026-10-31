require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "digest"
require "zlib"
require_relative "../scripts/finalize_private_runtime"

class PrivateRuntimeIsolationTest < Minitest::Test
  COMPILER = ShatteredPrivatePluginCompiler
  ISOLATION = ShatteredRuntimeIsolation

  def with_stage
    Dir.mktmpdir("shattered-private-runtime") do |root|
      FileUtils.mkdir_p(File.join(root, "Data"))
      FileUtils.mkdir_p(File.join(root, "Plugins"))
      File.write(File.join(root, "SHATTERED_STAGING_REPORT.json"), "{}")
      original = [["v21.1 Hotfixes",
        { :name => "v21.1 Hotfixes", :version => "1.0.3", :essentials => ["21.1"] },
        [["Hotfix.rb", Zlib::Deflate.deflate("HOTFIX_TEST = true\n")]]]]
      File.binwrite(File.join(root, "Data/PluginScripts.rxdata"), Marshal.dump(original))
      yield root
    end
  end

  def add_plugin(root, name, source)
    folder = File.join(root, "Plugins", name)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "meta.txt"),
      "Name = #{name}\nVersion = 0.1.0\nEssentials = 21.1\n")
    source.each { |file, code| File.write(File.join(folder, file), code) }
  end

  def test_moves_offline_installer_and_preserves_compiled_runtime
    with_stage do |root|
      add_plugin(root, "Shattered Gate Story", {
        "001_GateStory.rb" => "module ShatteredGateStory; end\n",
        "002_Install.rb" => "require 'json'\nraise 'offline only'\n"
      })
      add_plugin(root, "Shattered World Links", {
        "001_Install.rb" => "require 'json'\nraise 'offline only'\n"
      })
      File.write(File.join(root, "Plugins/Shattered World Links", "map_plan.json"), "{}")
      FileUtils.mkdir_p(File.join(root, "Plugins/Unrelated Plugin"))
      File.write(File.join(root, "Plugins/Unrelated Plugin", "001_Unrelated.rb"), "true")
      names = ["Shattered Gate Story", "Shattered World Links"]
      COMPILER.compile(root, names)
      archive = File.join(root, "Data/PluginScripts.rxdata")
      before = Digest::SHA256.file(archive).hexdigest
      receipt = ISOLATION.finalize(root)
      assert_equal before, Digest::SHA256.file(archive).hexdigest
      assert_equal ["Shattered Gate Story"], receipt.fetch("runtime_plugin_names")
      assert_equal 4, receipt.fetch("moved").length # two installers + metadata + JSON
      assert File.file?(File.join(root, "Plugins/Shattered Gate Story/001_GateStory.rb"))
      refute File.exist?(File.join(root, "Plugins/Shattered Gate Story/002_Install.rb"))
      refute File.exist?(File.join(root, "Plugins/Shattered World Links"))
      assert File.file?(File.join(root, "SHATTERED_OFFLINE_TOOLS/Shattered World Links/map_plan.json"))
      assert File.file?(File.join(root, "SHATTERED_OFFLINE_TOOLS/Shattered Gate Story/002_Install.rb"))
      assert File.file?(File.join(root, "Plugins/Unrelated Plugin/001_Unrelated.rb"))
      assert_equal receipt, ISOLATION.finalize(root), "Idempotent verification must not rewrite files"
      refute receipt.fetch("gameplay_verified")
    end
  end

  def test_fails_closed_on_compiled_runtime_source_mismatch_without_mutation
    with_stage do |root|
      add_plugin(root, "Shattered Gate Story", {
        "001_GateStory.rb" => "module ShatteredGateStory; end\n",
        "002_Install.rb" => "require 'json'\n"
      })
      COMPILER.compile(root, ["Shattered Gate Story"])
      File.write(File.join(root, "Plugins/Shattered Gate Story/001_GateStory.rb"), "changed")
      assert_raises(RuntimeError) { ISOLATION.finalize(root) }
      assert File.file?(File.join(root, "Plugins/Shattered Gate Story/002_Install.rb"))
      refute File.exist?(File.join(root, "SHATTERED_OFFLINE_TOOLS"))
    end
  end

  def test_refuses_uncompiled_runtime_plugin
    with_stage do |root|
      add_plugin(root, "Shattered Core", { "001_Core.rb" => "module Shattered; end\n" })
      add_plugin(root, "Shattered Gate Story", {
        "001_GateStory.rb" => "module ShatteredGateStory; end\n",
        "002_Install.rb" => "require 'json'\n"
      })
      COMPILER.compile(root, ["Shattered Core"])
      assert_raises(RuntimeError) { ISOLATION.finalize(root) }
      assert File.file?(File.join(root, "Plugins/Shattered Gate Story/002_Install.rb"))
    end
  end

  def test_refuses_modified_archive_and_missing_compile_receipt
    with_stage do |root|
      add_plugin(root, "Shattered Core", { "001_Core.rb" => "module Shattered; end\n" })
      assert_raises(RuntimeError) { ISOLATION.finalize(root) }
      COMPILER.compile(root, ["Shattered Core"])
      File.binwrite(File.join(root, "Data/PluginScripts.rxdata"), "tampered")
      assert_raises(RuntimeError) { ISOLATION.finalize(root) }
    end
  end

  def test_refuses_symlinked_offline_file
    with_stage do |root|
      add_plugin(root, "Shattered Gate Story", {
        "001_GateStory.rb" => "module ShatteredGateStory; end\n",
        "002_Install.rb" => "require 'json'\n"
      })
      COMPILER.compile(root, ["Shattered Gate Story"])
      File.delete(File.join(root, "Plugins/Shattered Gate Story/002_Install.rb"))
      File.symlink("/etc/passwd", File.join(root, "Plugins/Shattered Gate Story/002_Install.rb"))
      assert_raises(RuntimeError) { ISOLATION.finalize(root) }
      refute File.exist?(File.join(root, "SHATTERED_OFFLINE_TOOLS"))
    end
  end

  def test_refuses_reintroduced_offline_installer_after_finalization
    with_stage do |root|
      add_plugin(root, "Shattered Gate Story", {
        "001_GateStory.rb" => "module ShatteredGateStory; end\n",
        "002_Install.rb" => "require 'json'\n"
      })
      COMPILER.compile(root, ["Shattered Gate Story"])
      ISOLATION.finalize(root)
      File.write(File.join(root, "Plugins/Shattered Gate Story/002_Install.rb"), "require 'json'\n")
      assert_raises(RuntimeError) { ISOLATION.finalize(root) }
    end
  end

  def test_actual_eight_repository_runtime_plugins_can_be_isolated
    with_stage do |root|
      source_root = File.expand_path("../essentials/Plugins", __dir__)
      names = (COMPILER::RUNTIME_FILES.keys + COMPILER::INSTALLER_FILES.keys).uniq
      names.each do |name|
        FileUtils.cp_r(File.join(source_root, name), File.join(root, "Plugins", name))
      end
      COMPILER.compile(root, names)
      receipt = ISOLATION.finalize(root)
      assert_equal 8, receipt.fetch("runtime_plugin_names").length
      assert_equal 2, names.count { |name| !COMPILER::RUNTIME_FILES.key?(name) }
      assert_equal receipt, ISOLATION.finalize(root)
      Dir.glob(File.join(root, "Plugins/Shattered *", "**", "*.rb")).each do |path|
        name = File.basename(File.dirname(path))
        assert_includes COMPILER::RUNTIME_FILES.fetch(name), File.basename(path)
      end
    end
  end
end
