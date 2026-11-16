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
        "002_Opening.rb" => "module OpeningRuntime; end\n",
        "002_Install.rb" => "require 'json'\nraise 'offline installer executed'\n"
      })
      report = ShatteredPrivatePluginCompiler.compile(root, ["Shattered Gate Story"])
      assert_equal ["Shattered Gate Story"], report["added"]
      entries = Marshal.load(File.binread(File.join(root, "Data/PluginScripts.rxdata")))
      assert_equal ["001_GateStory.rb", "002_Opening.rb"], entries.last[2].map(&:first)
      refute_includes entries.last[2].map { |item| Zlib::Inflate.inflate(item.last) }.join, "offline installer"
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

  def test_all_actual_repository_plugins_compile_only_runtime_scripts_and_load
    with_stage do |root|
      names = ShatteredPrivatePluginCompiler::RUNTIME_FILES.keys +
        (ShatteredPrivatePluginCompiler::INSTALLER_FILES.keys -
         ShatteredPrivatePluginCompiler::RUNTIME_FILES.keys)
      source_root = File.expand_path("../essentials/Plugins", __dir__)
      names.each do |name|
        FileUtils.rm_rf(File.join(root, "Plugins", name))
        FileUtils.cp_r(File.join(source_root, name), File.join(root, "Plugins", name))
      end
      report = ShatteredPrivatePluginCompiler.compile(root, names)
      assert_equal ShatteredPrivatePluginCompiler::RUNTIME_FILES.keys, report["added"]
      assert_equal ["Shattered HnS Gate", "Shattered World Links"].sort,
        report["offline_only"].sort
      entries = Marshal.load(File.binread(File.join(root, "Data/PluginScripts.rxdata")))
      assert_equal 1 + ShatteredPrivatePluginCompiler::RUNTIME_FILES.length, entries.length
      # Existing Hotfixes plus every explicitly declared Shattered runtime plugin.
      entries.drop(1).each do |name, _metadata, scripts|
        assert_equal ShatteredPrivatePluginCompiler::RUNTIME_FILES.fetch(name),
          scripts.map(&:first)
        scripts.each do |filename, compressed|
          source = Zlib::Inflate.inflate(compressed)
          RubyVM::InstructionSequence.compile(source, filename)
          refute_match(/^require\s+["']/, source)
        end
      end
      # This is MRI source-load compatibility, NOT mkxp-z gameplay or PBS compilation.
      # Fork isolates global module and hook definitions from the test runner.
      pid = fork do
        begin
          entries.drop(1).each do |_name, _metadata, scripts|
            scripts.each do |filename, compressed|
              eval(Zlib::Inflate.inflate(compressed), TOPLEVEL_BINDING, filename)
            end
          end
          exit! 0
        rescue Exception => error
          warn "Native source smoke: #{error.class}: #{error.message}"
          warn error.backtrace.first(6).join("\n")
          exit! 1
        end
      end
      _child, status = Process.waitpid2(pid)
      assert status.success?, "All declared source plugins must load without installer dependencies"
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

  def test_explicit_rebuild_replaces_only_requested_shattered_entries
    with_stage do |root|
      target = File.join(root, "Data/PluginScripts.rxdata")
      ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      entries = Marshal.load(File.binread(target))
      upstream = ["Other Plugin", { :version => "1.0.0", :essentials => ["21.1"] },
                  [["other.rb", Zlib::Deflate.deflate("OTHER = true\n")]]]
      entries << upstream
      File.binwrite(target, Marshal.dump(entries))
      File.write(File.join(root, "Plugins/Shattered Core/001_Core.rb"),
        "module Shattered; CORE_TEST = :rebuilt; end\n")
      report = ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"], rebuild_existing: true)
      assert_equal ["Shattered Core"], report.fetch("removed").map { |entry| entry.fetch("plugin") }
      assert_equal ["Shattered Core"], report.fetch("added")
      rebuilt = Marshal.load(File.binread(target))
      assert_equal Marshal.dump(upstream), Marshal.dump(rebuilt.find { |entry| entry[0] == "Other Plugin" })
      source = Zlib::Inflate.inflate(rebuilt.find { |entry| entry[0] == "Shattered Core" }[2][0][1])
      assert_includes source, "CORE_TEST = :rebuilt"
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

  def test_pinned_single_script_replacement_preserves_other_plugins_and_backup
    with_stage do |root|
      target = File.join(root, "Data/PluginScripts.rxdata")
      ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      original = File.binread(target)
      entries = Marshal.load(original)
      hotfix_bytes = Marshal.dump(entries.first)
      prior = "module Shattered; CORE_TEST = true; end\n"
      approved_sha = Digest::SHA256.hexdigest(prior)
      File.write(File.join(root, "Plugins/Shattered Core/001_Core.rb"),
        "module Shattered; CORE_TEST = false; end\n")
      report = ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"],
        replace_pins: { "Shattered Core" => approved_sha })
      assert_equal "Shattered Core", report.fetch("replaced").first.fetch("plugin")
      assert_equal approved_sha, report.fetch("replaced").first.fetch("previous_source_sha256")
      updated = Marshal.load(File.binread(target))
      assert_equal hotfix_bytes, Marshal.dump(updated.first)
      assert_includes Zlib::Inflate.inflate(updated.last[2].first.last), "CORE_TEST = false"
      backups = Dir.glob(target + ".pre_shattered_*.bak")
      assert_equal 2, backups.length
      assert backups.any? { |path| File.binread(path) == original }
      unchanged = ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      assert_equal ["Shattered Core"], unchanged["unchanged"]
    end
  end

  def test_pinned_replacement_rejects_wrong_digest_without_archive_change
    with_stage do |root|
      target = File.join(root, "Data/PluginScripts.rxdata")
      ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      original = File.binread(target)
      File.write(File.join(root, "Plugins/Shattered Core/001_Core.rb"),
        "module Shattered; CORE_TEST = false; end\n")
      error = assert_raises(RuntimeError) do
        ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"],
          replace_pins: { "Shattered Core" => "0" * 64 })
      end
      assert_match(/digest differs/, error.message)
      assert_equal original, File.binread(target)
    end
  end

  def test_pinned_route22_refresh_after_offline_installer_isolated
    with_stage do |root|
      add_staged_plugin(root, "Shattered Route22", {
        "001_Route22.rb" => "module ShatteredRoute22; VERSION = 1; end\n",
        "002_Install.rb" => "require 'json'\n"
      })
      ShatteredPrivatePluginCompiler.compile(root, ["Shattered Route22"])
      plugin_dir = File.join(root, "Plugins/Shattered Route22")
      offline = File.join(root, "SHATTERED_OFFLINE_TOOLS/Shattered Route22")
      FileUtils.mkdir_p(offline)
      FileUtils.mv(File.join(plugin_dir, "002_Install.rb"), File.join(offline, "002_Install.rb"))
      previous = "module ShatteredRoute22; VERSION = 1; end\n"
      File.write(File.join(plugin_dir, "001_Route22.rb"),
        "module ShatteredRoute22; VERSION = 2; end\n")
      result = ShatteredPrivatePluginCompiler.compile(root, ["Shattered Route22"],
        replace_pins: { "Shattered Route22" => Digest::SHA256.hexdigest(previous) })
      assert_equal "Shattered Route22", result["replaced"].first["plugin"]
      entries = Marshal.load(File.binread(File.join(root, "Data/PluginScripts.rxdata")))
      actual = entries.find { |entry| entry[0] == "Shattered Route22" }
      assert_includes Zlib::Inflate.inflate(actual[2][0][1]), "VERSION = 2"
    end
  end

  def test_pinned_version_upgrade_replaces_only_selected_plugin
    with_stage do |root|
      target = File.join(root, "Data/PluginScripts.rxdata")
      ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      original = Marshal.load(File.binread(target))
      original_hotfix = Marshal.dump(original.first)
      old_source = File.read(File.join(root, "Plugins/Shattered Core/001_Core.rb"))
      File.write(File.join(root, "Plugins/Shattered Core/meta.txt"),
        File.read(File.join(root, "Plugins/Shattered Core/meta.txt")).sub("0.2.3", "0.2.4"))
      File.write(File.join(root, "Plugins/Shattered Core/001_Core.rb"),
        "module Shattered; CORE_TEST = :upgraded; end\\n")
      report = ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"],
        replace_pins: { "Shattered Core" => Digest::SHA256.hexdigest(old_source) })
      assert_equal ["Shattered Core"], report.fetch("replaced").map { |entry| entry["plugin"] }
      entries = Marshal.load(File.binread(target))
      assert_equal original_hotfix, Marshal.dump(entries.first)
      assert_equal "0.2.4", entries.last[1][:version]
      assert_includes Zlib::Inflate.inflate(entries.last[2].first.last), "CORE_TEST = :upgraded"
    end
  end

  def test_pinned_version_downgrade_and_metadata_drift_are_refused
    with_stage do |root|
      target = File.join(root, "Data/PluginScripts.rxdata")
      ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"])
      original = File.binread(target)
      meta = File.join(root, "Plugins/Shattered Core/meta.txt")
      source = File.join(root, "Plugins/Shattered Core/001_Core.rb")
      old_source = File.read(source)
      pin = Digest::SHA256.hexdigest(old_source)
      File.write(source, "module Shattered; CORE_TEST = :changed; end\\n")
      File.write(meta, File.read(meta).sub("0.2.3", "0.2.2"))
      assert_raises(RuntimeError) do
        ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"],
          replace_pins: { "Shattered Core" => pin })
      end
      assert_equal original, File.binread(target)
      File.write(meta, File.read(meta).sub("0.2.2", "0.2.4").sub("Shattered contributors", "Unreviewed authors"))
      assert_raises(RuntimeError) do
        ShatteredPrivatePluginCompiler.compile(root, ["Shattered Core"],
          replace_pins: { "Shattered Core" => pin })
      end
      assert_equal original, File.binread(target)
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
