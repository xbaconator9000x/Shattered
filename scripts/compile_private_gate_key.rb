#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline native items.dat cutline for a rights-cleared PRIVATE Essentials v21.1
# staging copy. No Pokémon assets or proprietary game data belong in GitHub.
require 'digest'
require 'pathname'
require 'optparse'
require 'json'

module GameData
  class Item; end
end

module ShatteredPrivateGateKey
  ID = :SHATTEREDGATEKEY
  SOURCE_ITEMS_SHA256 = '47e985fe70263d80f70bb0ef5d596297280b33571229f189b9c08c04b8467906'
  EXPECTED_PBS = {
    'Name' => 'Gate Key',
    'NamePlural' => 'Gate Keys',
    'Pocket' => '8',
    'Price' => '0',
    'Flags' => 'KeyItem',
    'Description' => 'A small key entrusted to you by an Aipom near the ruined Johto gate.'
  }.freeze
  TEMPLATE_ID = :OAKSPARCEL
  ITEM_IVARS = %i[id real_name real_name_plural real_portion_name real_portion_name_plural
    pocket price sell_price bp_price field_use battle_use flags consumable
    show_quantity move real_description pbs_file_suffix].freeze
  module_function

  def check!(condition, message)
    raise "Private Gate Key compiler: #{message}" unless condition
  end

  def plain_file!(path, label)
    check!(path.file? && !path.symlink?, "missing or symlinked #{label}")
  end

  def validate_pbs!(path)
    plain_file!(path, 'PBS/items.txt')
    text = path.binread.force_encoding(Encoding::UTF_8)
    check!(text.valid_encoding?, 'invalid PBS UTF-8')
    sections = text.scan(/^\[SHATTEREDGATEKEY\][ \t]*\r?\n((?:(?!^\[).*(?:\n|\z))*)/)
    check!(sections.length == 1, 'expected exactly one [SHATTEREDGATEKEY] PBS section')
    properties = {}
    sections.first.first.lines.each do |line|
      next if line.strip.empty? || line.lstrip.start_with?('#')
      match = /\A\s*([A-Za-z]+)\s*=\s*(.*?)\s*\z/.match(line)
      check!(!match.nil?, 'malformed Gate Key PBS line')
      check!(!properties.key?(match[1]), "duplicate PBS property #{match[1]}")
      properties[match[1]] = match[2]
    end
    check!(properties == EXPECTED_PBS, 'Gate Key PBS differs from reviewed private item')
    true
  end

  def expected_item(template)
    check!(template.instance_of?(GameData::Item), 'original key item template class mismatch')
    check!(template.instance_variables.map { |v| v.to_s.delete_prefix('@').to_sym } == ITEM_IVARS,
           'original v21.1 item schema changed')
    check!(template.instance_variable_get(:@id) == TEMPLATE_ID &&
           template.instance_variable_get(:@pocket) == 8 &&
           template.instance_variable_get(:@flags) == ['KeyItem'] &&
           template.instance_variable_get(:@field_use) == 0 &&
           template.instance_variable_get(:@battle_use) == 0 &&
           template.instance_variable_get(:@consumable) == false,
           'original key item template is not a passive key item')
    item = Marshal.load(Marshal.dump(template))
    {
      :@id => ID,
      :@real_name => EXPECTED_PBS['Name'],
      :@real_name_plural => EXPECTED_PBS['NamePlural'],
      :@real_description => EXPECTED_PBS['Description'],
      :@price => 0,
      :@sell_price => 0,
      :@pocket => 8,
      :@flags => ['KeyItem'],
      :@field_use => 0,
      :@battle_use => 0,
      :@consumable => false
    }.each { |ivar, value| item.instance_variable_set(ivar, value) }
    item
  end

  def compile!(root)
    root = Pathname.new(root).expand_path
    check!(root.directory? && !root.symlink?, 'missing or symlinked staged project')
    plain_file!(root.join('SHATTERED_STAGING_REPORT.json'), 'staging report')
    validate_pbs!(root.join('PBS/items.txt'))
    path = root.join('Data/items.dat')
    plain_file!(path, 'native Data/items.dat')
    tmp = Pathname.new(path.to_s + '.shattered_gate_key.tmp')
    backup = Pathname.new(path.to_s + '.shattered_gate_key.bak')
    check!(!tmp.exist? && !tmp.symlink? && !backup.exist? && !backup.symlink?, 'stale transaction')
    raw = path.binread
    items = Marshal.load(raw)
    check!(items.instance_of?(Hash) && items.size >= 600 &&
           items.keys.all? { |id| id.instance_of?(Symbol) } &&
           items.values.all? { |v| v.instance_of?(GameData::Item) },
           'not the native Essentials v21.1 item registry')
    check!(Marshal.dump(items) == raw, 'native Marshal codec cannot roundtrip registry')
    template = items.fetch(TEMPLATE_ID)
    new_item = expected_item(template)
    if items.key?(ID)
      check!(Marshal.dump(items[ID]) == Marshal.dump(new_item),
             'existing Gate Key conflicts with reviewed PBS')
      return { 'status' => 'unchanged', 'items_sha256' => Digest::SHA256.hexdigest(raw),
               'item_id' => ID.to_s, 'runtime_verified' => false }
    end
    check!(Digest::SHA256.hexdigest(raw) == SOURCE_ITEMS_SHA256,
           'unreviewed compiled item registry; run native PBS compilation instead')
    original_entries = items.transform_values { |item| Marshal.dump(item) }
    items[ID] = new_item
    output = Marshal.dump(items)
    roundtrip = Marshal.load(output)
    check!(roundtrip.keys == items.keys &&
           roundtrip[ID].instance_of?(GameData::Item) &&
           Marshal.dump(roundtrip[ID]) == Marshal.dump(new_item),
           'new native item failed Marshal roundtrip')
    check!(original_entries.all? { |id, bytes| Marshal.dump(roundtrip.fetch(id)) == bytes },
           'existing compiled items mutated')
    moved = false
    begin
      File.open(tmp.to_s, 'wb') { |f| f.write(output); f.flush; f.fsync }
      check!(path.binread == raw, 'compiled registry changed during write')
      begin
        File.rename(path, backup)
        moved = true
      rescue StandardError
        moved = !path.exist? && backup.file?
        raise
      end
      File.rename(tmp, path)
      check!(Digest::SHA256.file(path).hexdigest == Digest::SHA256.hexdigest(output),
             'installed registry differs from verified bytes')
    rescue StandardError => error
      if moved && backup.file?
        File.delete(path) if path.file?
        File.rename(backup, path)
      end
      raise error
    ensure
      File.delete(tmp) if tmp.file?
    end
    File.delete(backup)
    { 'status' => 'compiled', 'source_sha256' => SOURCE_ITEMS_SHA256,
      'items_sha256' => Digest::SHA256.hexdigest(output),
      'item_id' => ID.to_s, 'original_items_preserved' => original_entries.length,
      'runtime_verified' => false, 'android_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  args = {}
  OptionParser.new { |parser| parser.on('--project DIR') { |dir| args[:project] = dir } }.parse!
  abort 'Usage: ruby scripts/compile_private_gate_key.rb --project PRIVATE_STAGED_GAME' unless args[:project]
  puts JSON.pretty_generate(ShatteredPrivateGateKey.compile!(args.fetch(:project)))
end
