# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../scripts/verify_private_route22_viridian_guard'

class PrivateRoute22ViridianGuardTest < Minitest::Test
  P = ShatteredNativeRoute22GuardProbe

  def command(code, indent, parameters = [])
    c = RPG::EventCommand.allocate
    c.code, c.indent, c.parameters = code, indent, parameters
    c
  end

  def native_fixture
    map = RPG::Map.allocate
    map.instance_variable_set(:@width, 54)
    map.instance_variable_set(:@height, 34)
    events = (1..7).to_h { |id| [id, RPG::Event.allocate] }
    gate = events[4]
    gate.instance_variable_set(:@name, 'SHATTERED: Viridian gate')
    gate.instance_variable_set(:@x, 32)
    gate.instance_variable_set(:@y, 17)
    page = RPG::Event::Page.allocate
    page.instance_variable_set(:@trigger, 1)
    page.instance_variable_set(:@through, true)
    page.instance_variable_set(:@list, [
      command(111, 0, [12, P::EXPECTED_CONDITION]),
      command(101, 1, ['The guards wave you towards the walled city.']),
      command(201, 1, P::EXPECTED_TRANSFER.dup),
      command(411, 0),
      command(355, 1, [P::EXPECTED_RETURN]),
      command(412, 0),
      command(0, 0)
    ])
    gate.instance_variable_set(:@pages, [page])
    map.instance_variable_set(:@events, events)
    map
  end

  def commands(map)
    map.instance_variable_get(:@events)[4].instance_variable_get(:@pages)[0].instance_variable_get(:@list)
  end

  def test_exact_guard_and_transfer_accepted
    assert_equal P::EXPECTED_CODES, P.native_commands!(native_fixture).map(&:code)
  end

  def test_unguarded_transfer_indentation_rejected
    map = native_fixture
    commands(map)[2].indent = 0
    assert_raises(RuntimeError) { P.native_commands!(map) }
  end

  def test_wrong_destination_rejected
    map = native_fixture
    commands(map)[2].parameters[1] = 99
    assert_raises(RuntimeError) { P.native_commands!(map) }
  end

  def test_return_after_loss_must_be_in_else_branch
    map = native_fixture
    commands(map)[4].indent = 0
    assert_raises(RuntimeError) { P.native_commands!(map) }
  end

  def test_wrong_event_identity_rejected
    map = native_fixture
    map.instance_variable_get(:@events)[4].instance_variable_set(:@name, 'Unreviewed warp')
    assert_raises(RuntimeError) { P.native_commands!(map) }
  end

  def test_wrong_map_dimensions_rejected
    map = native_fixture
    map.instance_variable_set(:@width, 48)
    assert_raises(RuntimeError) { P.native_commands!(map) }
  end

  def test_unknown_engine_scripts_rejected_before_eval
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'Scripts.rxdata')
      File.binwrite(path, Marshal.dump([[1, 'Interpreter', 'fake']]))
      assert_raises(RuntimeError) { P.engine_sources!(path) }
    end
  end
end
