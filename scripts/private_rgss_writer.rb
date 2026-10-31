# frozen_string_literal: true
# Standalone, private-only RGSS Marshal writer for a *verified* local RMXP project.
# This is NOT a replacement for native mkxp-z gameplay or RPG Maker compilation.
require_relative "audit_native_project"

class Table
  def _dump(_depth = 0)
    raise "Cannot serialize unverified RMXP Table" unless @bytes && @shape
    @bytes
  end
  def xsize = @shape[0]
  def ysize = @shape[1]
  def zsize = @shape[2]
end

class Tone
  def self._load(bytes)
    raise "Invalid RGSS Tone" unless bytes.bytesize == 32
    obj = allocate
    obj.instance_variable_set(:@native_bytes, bytes)
    obj
  end
  def _dump(_depth = 0) = @native_bytes
end

class Color
  def self._load(bytes)
    raise "Invalid RGSS Color" unless bytes.bytesize == 32
    obj = allocate
    obj.instance_variable_set(:@native_bytes, bytes)
    obj
  end
  def _dump(_depth = 0) = @native_bytes
end

class RPG::Map
  attr_accessor :width, :height, :tileset_id, :events, :data
end

class RPG::Tileset
  attr_accessor :passages
end

class RPG::Event
  attr_accessor :id, :name, :x, :y, :pages
  def initialize(x, y)
    @id = 0
    @name = ""
    @x, @y = x, y
    @pages = [RPG::Event::Page.new]
  end
end

class RPG::Event::Page
  attr_accessor :condition, :graphic, :move_type, :move_speed, :move_frequency,
    :walk_anime, :step_anime, :direction_fix, :through, :always_on_top,
    :trigger, :list, :move_route
  def initialize
    @condition = RPG::Event::Page::Condition.new
    @graphic = RPG::Event::Page::Graphic.new
    @move_type, @move_speed, @move_frequency = 0, 3, 3
    @walk_anime, @step_anime, @direction_fix = true, false, false
    @through, @always_on_top, @trigger = false, false, 0
    @list = [RPG::EventCommand.new]
    @move_route = RPG::MoveRoute.new
  end
end

class RPG::Event::Page::Condition
  attr_accessor :switch1_valid, :switch2_valid, :variable_valid, :self_switch_valid,
    :switch1_id, :switch2_id, :variable_id, :variable_value, :self_switch_ch
  def initialize
    @switch1_valid = @switch2_valid = @variable_valid = @self_switch_valid = false
    @switch1_id, @switch2_id, @variable_id, @variable_value, @self_switch_ch = 1, 1, 1, 0, "A"
  end
end

class RPG::Event::Page::Graphic
  attr_accessor :tile_id, :character_name, :character_hue, :direction, :pattern,
    :opacity, :blend_type
  def initialize
    @tile_id, @character_name, @character_hue = 0, "", 0
    @direction, @pattern, @opacity, @blend_type = 2, 0, 255, 0
  end
end

class RPG::EventCommand
  attr_accessor :code, :indent, :parameters
  def initialize(code = 0, indent = 0, parameters = [])
    @code, @indent, @parameters = code, indent, parameters
  end
end

class RPG::MoveRoute
  attr_accessor :repeat, :skippable, :list
  def initialize
    @repeat, @skippable, @list = true, false, [RPG::MoveCommand.new]
  end
end

class RPG::MoveCommand
  attr_accessor :code, :parameters
  def initialize(code = 0, parameters = [])
    @code, @parameters = code, parameters
  end
end

def load_data(path)
  Marshal.load(File.binread(path))
end

def save_data(value, path)
  File.binwrite(path, Marshal.dump(value))
end
