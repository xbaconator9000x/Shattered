# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'digest'
require_relative '../scripts/compile_private_gate_key'

class PrivateGateKeyCompilerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('shattered-gate-key-')
    FileUtils.mkdir_p(File.join(@root, 'Data'))
    FileUtils.mkdir_p(File.join(@root, 'PBS'))
    File.write(File.join(@root, 'SHATTERED_STAGING_REPORT.json'), '{}')
    File.write(File.join(@root, 'PBS/items.txt'),
      "[OAKSPARCEL]\nName = Parcel\n\n[SHATTEREDGATEKEY]\n" +
      ShatteredPrivateGateKey::EXPECTED_PBS.map { |k,v| "#{k} = #{v}\n" }.join)
    template = GameData::Item.allocate
    {
      :id => :OAKSPARCEL, :real_name => 'Parcel', :real_name_plural => 'Parcels',
      :real_portion_name => nil, :real_portion_name_plural => nil, :pocket => 8,
      :price => 0, :sell_price => 0, :bp_price => 1, :field_use => 0,
      :battle_use => 0, :flags => ['KeyItem'], :consumable => false,
      :show_quantity => nil, :move => nil, :real_description => 'Parcel',
      :pbs_file_suffix => ''
    }.each { |key,value| template.instance_variable_set("@#{key}",value) }
    items = { :OAKSPARCEL => template }
    652.times do |i|
      item = Marshal.load(Marshal.dump(template))
      id = "SYNTHETIC#{i}".to_sym
      item.instance_variable_set(:@id,id)
      items[id] = item
    end
    @path = File.join(@root, 'Data/items.dat')
    @raw = Marshal.dump(items)
    File.binwrite(@path, @raw)
    @old_sha = ShatteredPrivateGateKey::SOURCE_ITEMS_SHA256
    ShatteredPrivateGateKey.send(:remove_const, :SOURCE_ITEMS_SHA256)
    ShatteredPrivateGateKey.const_set(:SOURCE_ITEMS_SHA256, Digest::SHA256.hexdigest(@raw))
  end

  def teardown
    ShatteredPrivateGateKey.send(:remove_const, :SOURCE_ITEMS_SHA256)
    ShatteredPrivateGateKey.const_set(:SOURCE_ITEMS_SHA256, @old_sha)
    FileUtils.remove_entry(@root)
  end

  def test_compiles_one_real_native_item_without_changing_653_originals
    before = Marshal.load(@raw)
    result = ShatteredPrivateGateKey.compile!(@root)
    assert_equal 'compiled', result.fetch('status')
    assert_equal 653, result.fetch('original_items_preserved')
    compiled = Marshal.load(File.binread(@path))
    assert_equal 654, compiled.size
    assert_equal ShatteredPrivateGateKey::ID, compiled.fetch(:SHATTEREDGATEKEY).instance_variable_get(:@id)
    assert_equal ['KeyItem'], compiled.fetch(:SHATTEREDGATEKEY).instance_variable_get(:@flags)
    assert_equal false, compiled.fetch(:SHATTEREDGATEKEY).instance_variable_get(:@consumable)
    assert_equal ShatteredPrivateGateKey::EXPECTED_PBS['Description'],
      compiled.fetch(:SHATTEREDGATEKEY).instance_variable_get(:@real_description)
    before.each { |id, item| assert_equal Marshal.dump(item), Marshal.dump(compiled.fetch(id)) }
    assert_equal 'unchanged', ShatteredPrivateGateKey.compile!(@root).fetch('status')
    refute File.exist?(@path + '.shattered_gate_key.bak')
  end

  def test_rejects_missing_or_duplicate_pbs_entry_without_mutation
    pbs = File.join(@root, 'PBS/items.txt')
    original = File.read(pbs)
    File.write(pbs, original + "\n[SHATTEREDGATEKEY]\nName = Wrong\n")
    assert_raises(RuntimeError) { ShatteredPrivateGateKey.compile!(@root) }
    assert_equal @raw, File.binread(@path)
    File.write(pbs, original.sub('Pocket = 8', 'Pocket = 4'))
    assert_raises(RuntimeError) { ShatteredPrivateGateKey.compile!(@root) }
    assert_equal @raw, File.binread(@path)
  end

  def test_rejects_unreviewed_registry_or_existing_conflicting_key
    File.binwrite(@path, @raw + 'tamper')
    assert_raises(StandardError) { ShatteredPrivateGateKey.compile!(@root) }
    File.binwrite(@path, @raw)
    ShatteredPrivateGateKey.compile!(@root)
    items = Marshal.load(File.binread(@path))
    items.fetch(:SHATTEREDGATEKEY).instance_variable_set(:@real_name, 'Fake Key')
    modified = Marshal.dump(items)
    File.binwrite(@path, modified)
    assert_raises(RuntimeError) { ShatteredPrivateGateKey.compile!(@root) }
    assert_equal modified, File.binread(@path)
  end

  def test_stale_transaction_and_missing_staging_marker_are_fail_closed
    backup = @path + '.shattered_gate_key.bak'
    File.write(backup, 'recovery')
    assert_raises(RuntimeError) { ShatteredPrivateGateKey.compile!(@root) }
    assert_equal @raw, File.binread(@path)
    File.delete(backup)
    File.delete(File.join(@root, 'SHATTERED_STAGING_REPORT.json'))
    assert_raises(RuntimeError) { ShatteredPrivateGateKey.compile!(@root) }
    assert_equal @raw, File.binread(@path)
  end

  def test_rename_failure_after_original_move_restores_registry
    original_rename = File.method(:rename)
    calls = 0
    File.define_singleton_method(:rename) do |src,dst|
      calls += 1
      raise IOError, 'simulated second rename failure' if calls == 2
      original_rename.call(src,dst)
    end
    assert_raises(IOError) { ShatteredPrivateGateKey.compile!(@root) }
    assert_equal @raw, File.binread(@path)
    refute File.exist?(@path + '.shattered_gate_key.bak')
    refute File.exist?(@path + '.shattered_gate_key.tmp')
  ensure
    File.define_singleton_method(:rename, original_rename) if original_rename
  end
end
