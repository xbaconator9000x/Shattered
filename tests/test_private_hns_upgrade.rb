require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "zlib"
require "base64"
require_relative "../scripts/upgrade_private_hns_candidate"

class PrivateHnsUpgradeTest < Minitest::Test
  REVIEWED_LEGACY_MAP_CONTRACT = Base64.strict_decode64(
    "IyBmcm96ZW5fc3RyaW5nX2xpdGVyYWw6IHRydWUKIwojIFRoZSBwcml2YXRlIG5hdGl2ZSBjYW5kaWRhdGUgaGFzIHR3byB2YWxpZCBsYXlvdXRzOgojICogdGhlIGZ1bGwgUk1YUCBpbXBvcnQsIHdoZXJlIHRoZSBIJlMgcmVjZXB0aW9uIGdhdGUgaXMgTWFwMjIzOyBhbmQKIyAqIHRoZSBBbmRyb2lkIGJvb3QgbGF5b3V0LCB3aGVyZSBleGFjdGx5IHRoYXQgcmV2aWV3ZWQgbWFwIGlzIE1hcDAwMS4KIwojIFN0b3J5IGNvZGUgbXVzdCBhc2sgdGhpcyBjb250cmFjdCBmb3IgSURzLiAgSGFyZC1jb2RpbmcgTWFwMjIzIGluIG9uZSBwbHVnaW4KIyBhbmQgTWFwMDAxIGluIGFub3RoZXIgd2FzIHRoZSBjYXVzZSBvZiB0aGUgQW5kcm9pZC1vbmx5IG9wZW5pbmc6IHRoZSBwbGF5ZXIKIyBzcGF3bmVkIG9uIGEgY29weSBvZiB0aGUgbWFwLCB3aGlsZSB0aGUgY29sbGFwc2UvZGVicmlzIGNvZGUgd2FzIGxvb2tpbmcgYXQgYQojIGRpZmZlcmVudCBtYXAgaW5zdGFuY2UuCm1vZHVsZSBTaGF0dGVyZWRNYXBDb250cmFjdAogIEFORFJPSURfQk9PVF9HQVRFX01BUF9JRCA9IDEKICBOQVRJVkVfR0FURV9NQVBfSUQgPSAyMjMKICBST1VURTIyX01BUF9JRCA9IDE2CiAgVklSSURJQU5fQ0lUWV9NQVBfSUQgPSAxMAogIFZJUklESUFOX0NFTlRFUl9NQVBfSUQgPSAxMQoKICBtb2R1bGVfZnVuY3Rpb24KCiAgZGVmIGdhdGVfbWFwX2lkCiAgICAjIE1hcDAwMSBpcyBkZWxpYmVyYXRlbHkgdGhlIGF1dGhvcml0YXRpdmUgYm9vdCBtYXAgaW4gdGhlIGRpc3RyaWJ1dGFibGUKICAgICMgQW5kcm9pZCBwcm9qZWN0LiAgQSBmdWxsIG5hdGl2ZSBpbXBvcnQgZG9lcyBub3QgbG9hZCB0aGlzIGFkYXB0ZXIuCiAgICBBTkRST0lEX0JPT1RfR0FURV9NQVBfSUQKICBlbmQKCiAgZGVmIGdhdGVfbWFwX2lkcwogICAgIyBTeXN0ZW0ucnhkYXRhIGluIHRoZSBzdXBwbGllZCBkZXNrdG9wIHByb2plY3Qgc3RhcnRzIE5ldyBHYW1lIG9uIE1hcDIyMywKICAgICMgd2hpbGUgdGhlIEFuZHJvaWQtY29tcGF0aWJsZSBkaXN0cmlidXRpb24gc3RhcnRzIG9uIGl0cyBieXRlLWlkZW50aWNhbAogICAgIyBNYXAwMDEgY29weS4gQm90aCBhcmUgdGhlIHNhbWUgcmV2aWV3ZWQgSCZTIHJlY2VwdGlvbiBnYXRlIGFuZCBtdXN0IHJ1bgogICAgIyBvbmUgc2hhcmVkIG9wZW5pbmcvc2F2ZS1zdGF0ZSBmbG93LiBUcmVhdGluZyBvbmx5IE1hcDAxIGFzIHRoZSBnYXRlCiAgICAjIHNpbGVudGx5IHNraXBwZWQgdGhlIE1ld3R3byBvcGVuaW5nIG9uIHRoZSBkZXNrdG9wIGxhdW5jaCBwYXRoLgogICAgW0FORFJPSURfQk9PVF9HQVRFX01BUF9JRCwgTkFUSVZFX0dBVEVfTUFQX0lEXQogIGVuZAoKICBkZWYgZ2F0ZV9tYXA/KG1hcCkKICAgIG1hcCAmJiBtYXAucmVzcG9uZF90bz8oOm1hcF9pZCkgJiYgZ2F0ZV9tYXBfaWRzLmluY2x1ZGU/KG1hcC5tYXBfaWQpCiAgZW5kCmVuZAo="
  ).freeze

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
      [223, 224, 225, 226, 227, 16, 10, 11].each { |id| File.binwrite(File.join(input, "Data/Map%03d.rxdata" % id), "map-#{id}") }
      original = [["v21.1 Hotfixes", { :name => "v21.1 Hotfixes",
        :version => "1.0.3", :essentials => ["21.1"] },
        [["Hotfix.rb", Zlib::Deflate.deflate("HOTFIX_TEST = true\n")]]]]
      File.binwrite(File.join(input, "Data/PluginScripts.rxdata"), Marshal.dump(original))
      source = File.expand_path("..", __dir__)
      ShatteredPrivatePluginCompiler::RUNTIME_FILES.each_key do |name|
        FileUtils.cp_r(File.join(source, "essentials", "Plugins", name),
                       File.join(input, "Plugins", name))
      end
      File.binwrite(File.join(input, "Plugins", "Shattered Core", "000_MapContract.rb"),
                    REVIEWED_LEGACY_MAP_CONTRACT)
      yield root, input, source
    end
  end

  def test_rebuilds_runtime_without_changing_installed_maps
    with_candidate do |root, input, source|
      maps_before = ShatteredPrivateHnsUpgrade.installed_map_digests!(input)
      output = File.join(root, "v15")
      report = ShatteredPrivateHnsUpgrade.upgrade(input, output, source)
      assert_equal maps_before, ShatteredPrivateHnsUpgrade.installed_map_digests!(output)
      assert_equal maps_before, report["preserved_native_map_sha256"]
      assert_equal [223, 224, 225, 226, 227], report["preserved_hns_maps"]
      archive = Marshal.load(File.binread(File.join(output, "Data/PluginScripts.rxdata")))
      assert_equal ["v21.1 Hotfixes"], archive.take(1).map(&:first)
      assert_equal ShatteredPrivatePluginCompiler::RUNTIME_FILES.keys.sort,
        archive.drop(1).map(&:first).sort
      gate = archive.find { |entry| entry[0] == "Shattered Gate Story" }
      assert_equal ["001_GateStory.rb", "002_Opening.rb"], gate[2].map(&:first)
      assert File.file?(File.join(output, ShatteredPrivateHnsUpgrade::REPORT))
      refute File.exist?(File.join(output, "Plugins", "Shattered Core", "000_MapContract.rb"))
    end
  end
end
