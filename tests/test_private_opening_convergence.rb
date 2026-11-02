# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../scripts/verify_private_opening_convergence'

class PrivateOpeningConvergenceTest < Minitest::Test
  V = ShatteredPrivateOpeningConvergence

  def test_git_blob_matches_git_content_identity
    assert_equal 'ce013625030ba8dba906f756967f9e9ca394464a', V.git_blob('hello\n'.gsub('\\n', "\n"))
  end

  def test_rejects_unstaged_or_missing_project
    Dir.mktmpdir do |dir|
      assert_raises(RuntimeError) { V.verify!(dir) }
    end
  end

  def test_requires_actual_native_event
    assert_raises(RuntimeError) { V.commands(nil) }
  end

  def test_private_compiled_opening_and_rejects_source_tampering
    source = ENV['SHATTERED_PRIVATE_PROJECT']
    skip 'Private user-held game not present in public CI' unless source && File.directory?(source)
    Dir.mktmpdir do |dir|
      files = ['SHATTERED_STAGING_REPORT.json', 'Data/PluginScripts.rxdata',
               'Data/Map223.rxdata', 'Data/Map016.rxdata', 'Data/Map010.rxdata']
      V::SOURCES.each do |name, (script, _pin, _version)|
        files << "Plugins/#{name}/#{script}"
        files << "Plugins/#{name}/meta.txt"
      end
      files.each do |relative|
        FileUtils.mkdir_p(File.dirname(File.join(dir, relative)))
        FileUtils.cp(File.join(source, relative), File.join(dir, relative))
      end
      report = V.verify!(dir)
      assert_equal 3, report.fetch('checked_plugins').length
      assert_equal 2, report.fetch('gate_north_landings').uniq.length
      refute report.fetch('native_game_launched')
      gate_source = File.join(dir, 'Plugins/Shattered Gate Story/001_GateStory.rb')
      File.open(gate_source, 'ab') { |f| f.write('# tampered') }
      error = assert_raises(RuntimeError) { V.verify!(dir) }
      assert_match(/Source Git blob mismatch/, error.message)
    end
  end
end
