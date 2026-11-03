# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'zlib'
require_relative '../scripts/verify_private_hns_east_door'

class PrivateHnsEastDoorProbeTest < Minitest::Test
  P = ShatteredNativeGateBranchProbe

  def node(klass, fields)
    klass.new.tap { |object| fields.each { |name, value| object.instance_variable_set("@#{name}", value) } }
  end

  def native_fixture
    commands = P::EXPECTED_CODES.zip(P::SAFE_INDENTS).map do |code, indent|
      node(RPG::EventCommand, code: code, indent: indent, parameters: [])
    end
    commands[0].instance_variable_set(:@parameters, [12, 'ShatteredGateStory.key_obtained?'])
    commands[1].instance_variable_set(:@parameters, ['The eastern Kanto door unlocks.'])
    commands[2].instance_variable_set(:@parameters, P::EXPECTED_TRANSFER.dup)
    commands[4].instance_variable_set(:@parameters, ['The eastern Route 22 door is locked. You need the key.'])
    page = node(RPG::Event::Page, trigger: 0, through: false, list: commands)
    event = node(RPG::Event, name: 'SHATTERED_HNS:7', x: 20, y: 9, pages: [page])
    map = node(RPG::Map, width: 22, height: 21, events: { 7 => event })
    [map, commands]
  end

  def test_accepts_only_nested_native_east_door_transfer
    map, commands = native_fixture
    assert_same commands, P.validated_commands!(map)
    assert_equal [0, 1, 1, 0, 1, 0, 0],
                 commands.map { |c| c.instance_variable_get(:@indent) }
  end

  def test_rejects_legacy_flat_branch_and_changed_destination
    map, commands = native_fixture
    commands.each { |command| command.instance_variable_set(:@indent, 0) }
    assert_raises(RuntimeError) { P.validated_commands!(map) }
    commands.each_with_index { |command, index| command.instance_variable_set(:@indent, P::SAFE_INDENTS[index]) }
    commands[2].instance_variable_set(:@parameters, [0, 10, 14, 10, 2, 0])
    assert_raises(RuntimeError) { P.validated_commands!(map) }
  end

  def test_rejects_foreign_event_identity_and_page_trigger
    map, _ = native_fixture
    event = map.instance_variable_get(:@events)[7]
    event.instance_variable_set(:@name, 'Other NPC')
    assert_raises(RuntimeError) { P.validated_commands!(map) }
    event.instance_variable_set(:@name, 'SHATTERED_HNS:7')
    event.instance_variable_get(:@pages).first.instance_variable_set(:@trigger, 1)
    assert_raises(RuntimeError) { P.validated_commands!(map) }
  end

  def test_rejects_unpinned_engine_script_before_eval
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'Scripts.rxdata')
      scripts = [
        [33, 'Interpreter', Zlib::Deflate.deflate('class Interpreter; end')],
        [34, 'Interpreter_Commands', Zlib::Deflate.deflate('class Interpreter; end')]
      ]
      File.binwrite(path, Marshal.dump(scripts))
      assert_raises(RuntimeError) { P.source_scripts!(path) }
    end
  end

  def test_rejects_missing_private_input
    assert_raises(RuntimeError) { P.regular!('/path/that/does/not/exist') }
  end
end
