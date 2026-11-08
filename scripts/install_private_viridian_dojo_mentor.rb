# frozen_string_literal: true
# Installs the existing ShatteredDojo questionnaire in the reviewed Viridian school.
# Run after repair_private_viridian_escort.rb has supplied the private Marshal shims.
require_relative 'repair_private_viridian_escort'

module ShatteredDojoMentorInstall
  module_function
  def install!(path)
    map = Marshal.load(File.binread(path))
    raise 'unexpected school map' unless [map.width, map.height] == [20, 15]
    prior = map.events.values.find { |event| event.name == 'SHATTERED_DOJO:questionnaire' }
    return false if prior
    raise 'mentor tile occupied' if map.events.values.any? { |event| [event.x, event.y] == [6, 5] }
    event = RPG::Event.new(6, 5)
    event.id = (map.events.keys.max || 0) + 1
    event.name = 'SHATTERED_DOJO:questionnaire'
    page = RPG::Event::Page.new
    page.trigger = 0; page.through = false; page.always_on_top = false
    page.condition = RPG::Event::Page::Condition.new
    page.graphic = RPG::Event::Page::Graphic.new
    page.graphic.character_name = 'trainer_AROMALADY'
    page.list = [RPG::EventCommand.new(355, 0, ['ShatteredDojo.run_quiz']), RPG::EventCommand.new(0, 0, [])]
    event.pages = [page]
    map.events[event.id] = event
    bytes = Marshal.dump(map)
    raise 'marshal verification failed' unless Marshal.dump(Marshal.load(bytes)) == bytes
    File.binwrite(path, bytes)
    true
  end
end

if $PROGRAM_NAME == __FILE__
  ShatteredDojoMentorInstall.install!(ARGV.fetch(0))
end
