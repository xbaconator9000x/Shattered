# frozen_string_literal: true
# Private staged-map repair for the Viridian escort. No maps or assets are tracked.
module RPG
  class Map; attr_accessor :events, :width, :height, :data, :tileset_id; end
  class Event
    attr_accessor :id, :name, :x, :y, :pages
    def initialize(x = 0, y = 0); @x = x; @y = y; @pages = []; end
    class Page
      attr_accessor :condition, :graphic, :list, :trigger, :through, :always_on_top
      class Condition; attr_accessor :switch1_valid, :switch1_id, :switch2_valid, :switch2_id; end
      class Graphic; attr_accessor :character_name; end
    end
  end
  class EventCommand
    attr_accessor :code, :indent, :parameters
    def initialize(code = 0, indent = 0, parameters = []); @code = code; @indent = indent; @parameters = parameters; end
  end
  class MoveRoute
    attr_accessor :repeat, :skippable, :list
    def initialize; @repeat = true; @skippable = false; @list = []; end
  end
  class MoveCommand
    attr_accessor :code, :parameters
    def initialize(code = 0, parameters = []); @code = code; @parameters = parameters; end
  end
  class AudioFile; end
end
class Tone
  def self._load(bytes); obj = allocate; obj.instance_variable_set(:@raw, bytes); obj; end
  def _dump(_level) = @raw
end
class Color
  def self._load(bytes); obj = allocate; obj.instance_variable_set(:@raw, bytes); obj; end
  def _dump(_level) = @raw
end
class Table
  def self._load(bytes); obj = allocate; obj.instance_variable_set(:@raw, bytes); obj; end
  def _dump(_level) = @raw
end

module ShatteredViridianEscortRepair
  ARRIVED = 994
  GUARD, NIDORAN, GUARD_END, NIDORAN_END = 25, 26, 28, 29
  GUARD_START, NIDORAN_START = [24, 20], [23, 20]
  GUARD_FINISH, NIDORAN_FINISH = [25, 27], [24, 27]
  GUARD_STEPS = [1, 1, 2, 1, 1, 1, 1, 1, 3, 3]
  NIDORAN_STEPS = [1, 1, 1, 1, 1, 1, 1, 3]
  module_function
  def cmd(code, parameters = [], indent = 0) = RPG::EventCommand.new(code, indent, parameters)
  def page(sprite = '', switch = nil)
    p = RPG::Event::Page.new
    p.trigger = 0; p.through = true; p.always_on_top = false
    p.condition = RPG::Event::Page::Condition.new
    p.graphic = RPG::Event::Page::Graphic.new; p.graphic.character_name = sprite
    p.condition.switch1_valid = true; p.condition.switch1_id = switch if switch
    p
  end
  def route(steps)
    r = RPG::MoveRoute.new; r.repeat = false; r.skippable = true
    r.list = steps.map { |step| RPG::MoveCommand.new(step) } + [RPG::MoveCommand.new(0)]; r
  end
  def finish_actor(id, name, point, sprite, text)
    e = RPG::Event.new(*point); e.id = id; e.name = name
    hidden = page; hidden.list = [cmd(0)]
    shown = page(sprite, ARRIVED); shown.through = false; shown.list = [cmd(101, [text]), cmd(0)]
    e.pages = [hidden, shown]; e
  end
  def install!(path)
    map = Marshal.load(File.binread(path))
    raise 'wrong map dimensions' unless [map.width, map.height] == [50, 40]
    arrival = map.events.fetch(23)
    raise 'unexpected arrival anchor' unless arrival.name == 'SHATTERED: Viridian arrival' && [arrival.x, arrival.y] == [25, 20]
    guard, nidoran = map.events.fetch(GUARD), map.events.fetch(NIDORAN)
    raise 'unexpected escort anchors' unless [guard.x, guard.y] == GUARD_START && [nidoran.x, nidoran.y] == NIDORAN_START
    raise 'finish actor collision' if [GUARD_END, NIDORAN_END].any? { |xy| map.events.values.any? { |e| [e.x, e.y] == xy } }
    first = arrival.pages.fetch(0); first.trigger = 3; first.through = true
    first.list = [
      cmd(111, [12, 'ShatteredViridian.start!(993, 996)']), cmd(236, [1, 6, 20], 1),
      cmd(101, ['Guard: Stay with us. Nidoran will help us reach the Center safely.'], 1),
      cmd(209, [GUARD, route(GUARD_STEPS)], 1), cmd(210, [], 1),
      cmd(209, [NIDORAN, route(NIDORAN_STEPS)], 1), cmd(210, [], 1),
      cmd(111, [12, 'ShatteredViridian.complete_route!(25, 26, [24, 20], [23, 20], [25, 27], [24, 27], 993, 996)'], 1),
      cmd(355, ['ShatteredViridian.arrive!(994)'], 2),
      cmd(101, ['Guard: The Center is just ahead. Get inside before the rain worsens.'], 2),
      cmd(411, [], 1), cmd(101, ['Guard: The route is blocked. We will try again when the way clears.'], 2),
      cmd(116, [], 2), cmd(412, [], 1), cmd(412), cmd(0)
    ]
    arrival.pages.fetch(1).condition.switch1_valid = true; arrival.pages.fetch(1).condition.switch1_id = ARRIVED
    map.events[GUARD_END] = finish_actor(GUARD_END, 'SHATTERED_VIRIDIAN:guard_at_center', GUARD_FINISH, 'NPC 07', 'Guard: Stay inside until we know the city is secure.')
    map.events[NIDORAN_END] = finish_actor(NIDORAN_END, 'SHATTERED_VIRIDIAN:nidoran_at_center', NIDORAN_FINISH, 'POKEMON_NidoranMale', 'Nidoran stands watch beside the Center.')
    bytes = Marshal.dump(map); raise 'roundtrip failed' unless Marshal.dump(Marshal.load(bytes)) == bytes
    File.binwrite(path, bytes)
  end
end
ShatteredViridianEscortRepair.install!(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
