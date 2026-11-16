require 'minitest/autorun'
require_relative '../scripts/install_private_rom_guard'

class PrivateRomGuardTest < Minitest::Test
  G = ShatteredPrivateRomGuard
  def fixture
    map = RPG::Map.allocate
    map.events = G::ACTORS.to_h do |id, name|
      actor = RPG::Event.new(id, 20)
      actor.id = id
      actor.name = name
      actor.pages = [RPG::Event::Page.new, RPG::Event::Page.new]
      actor.pages[id == 25 ? 0 : 1].graphic.character_name = 'NPC 07'
      [id, actor]
    end
    map.events[26] = RPG::Event.new(23, 20)
    map.events[26].name = 'Nidoran'
    map
  end

  def test_only_guard_graphics_change
    map = fixture
    other = Marshal.dump(map.events[26])
    lists = G::ACTORS.keys.map { |id| Marshal.dump(map.events[id].pages.map(&:list)) }
    G.transform!(map)
    assert_equal other, Marshal.dump(map.events[26])
    assert_equal lists, G::ACTORS.keys.map { |id| Marshal.dump(map.events[id].pages.map(&:list)) }
    assert_equal ['SHATTERED_ROM_Guard', ''], map.events[25].pages.map { |p| p.graphic.character_name }
    assert_equal ['', 'SHATTERED_ROM_Guard'], map.events[28].pages.map { |p| p.graphic.character_name }
  end

  def test_actor_drift_rejected_before_any_change
    map = fixture
    map.events[28].name = 'Different actor'
    before = Marshal.dump(map)
    assert_raises(RuntimeError) { G.transform!(map) }
    assert_equal before, Marshal.dump(map)
  end
end
