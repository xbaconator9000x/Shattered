require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "zlib"
require_relative "../scripts/upgrade_private_hns_candidate"

class PrivateHnsUpgradeTest < Minitest::Test
  def with_candidate
    Dir.mktmpdir("shattered-hns-upgrade") do |root|
      input = File.join(root, "v14")
      FileUtils.mkdir_p(File.join(input, "Data"))
      FileUtils.mkdir_p(File.join(input, "Plugins"))
      File.write(File.join(input, "SHATTERED_STAGING_REPORT.json"), "{}")
      File.write(File.join(input, "SHATTERED_NATIVE_CANDIDATE.json"), "{}")
      File.write(File.join(input, "SHATTERED_HNS_REVIEW_IMPORT.json"), JSON.generate(
        "maps" => {
          "ReceptionGate_hns" => 223,
          "VictoryRoadKanto_B2F_hns" => 224,
          "Route26North_hns" => 225, "Route26_hns" => 226, "Route28_hns" => 227
        },
        "new_game" => [223, 11, 14]
      ))
      [223, 16, 10, 11].each { |id| File.binwrite(File.join(input, "Data/Map%03d.rxdata" % id), "map-#{id}") }
      original = [["v21.1 Hotfixes", { :name => "v21.1 Hotfixes",
        :version => "1.0.3", :essentials => ["21.1"] },
        [["Hotfix.rb", Zlib::Deflate.deflate("HOTFIX_TEST = true\n")]]]]
      File.binwrite(File.join(input, "Data/PluginScripts.rxdata"), Marshal.dump(original))
      source = File.expand_path("..", __dir__)
      ShatteredPrivatePluginCompiler::RUNTIME_FILES.each_key do |name|
        FileUtils.cp_r(File.join(source, "essentials", "Plugins", name),
                       File.join(input, "Plugins", name))
      end
      yield root, input, source
    end
  end

  def test_rebuilds_runtime_without_changing_installed_maps
    with_candidate do |root, input, source|
      map_before = Digest::SHA256.file(File.join(input, "Data/Map223.rxdata")).hexdigest
      output = File.join(root, "v15")
      report = ShatteredPrivateHnsUpgrade.upgrade(input, output, source)
      assert_equal map_before, Digest::SHA256.file(File.join(output, "Data/Map223.rxdata")).hexdigest
      assert_equal [223, 224, 225, 226, 227], report["preserved_hns_maps"]
      archive = Marshal.load(File.binread(File.join(output, "Data/PluginScripts.rxdata")))
      assert_equal ["v21.1 Hotfixes"], archive.take(1).map(&:first)
      assert_equal ShatteredPrivatePluginCompiler::RUNTIME_FILES.keys.sort,
        archive.drop(1).map(&:first).sort
      gate = archive.find { |entry| entry[0] == "Shattered Gate Story" }
      assert_equal ["001_GateStory.rb", "002_Opening.rb"], gate[2].map(&:first)
      assert File.file?(File.join(output, ShatteredPrivateHnsUpgrade::REPORT))
    end
  end
end
