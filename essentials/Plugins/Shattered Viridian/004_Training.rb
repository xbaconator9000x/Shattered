# frozen_string_literal: true
# Curriculum data is extracted locally from the user's authenticated ROM.
module ShatteredRenTraining
  IVAR = :@shattered_ren_training
  DATA_PATH = 'Data/shattered_training.dat'
  TYPES = %w[Normal Fighting Flying Poison Ground Rock Bug Ghost Steel Human Fire Water Grass Electric Psychic Ice Dragon Dark].freeze
  module_function

  def state
    raise 'Save metadata unavailable' unless defined?($PokemonGlobal) && $PokemonGlobal
    value = $PokemonGlobal.instance_variable_get(IVAR)
    unless value
      value = { :version => 1, :manual => false, :lesson => false }
      $PokemonGlobal.instance_variable_set(IVAR, value)
    end
    raise 'Invalid Ren lesson save; refusing to reset progress' unless value.is_a?(Hash) &&
      value[:version] == 1 && [true, false].include?(value[:manual]) &&
      [true, false].include?(value[:lesson]) && (!value[:lesson] || value[:manual])
    value
  end

  def human
    return nil unless defined?($player) && $player && $player.respond_to?(:party)
    $player.party.find { |pokemon| Shattered.human?(pokemon) && !pokemon.egg? }
  end

  def knows_quick_attack?(pokemon)
    pokemon.moves.any? { |move| move.id == :QUICKATTACK }
  end

  def run_lesson
    return false unless ShatteredViridianQuest.state[:stage] == :supplied
    return false unless defined?(ShatteredViridianNightRaid) && ShatteredViridianNightRaid.state[:stage] == :rested
    pokemon = human
    return false unless pokemon
    value = state
    unless value[:manual]
      unless $bag.add(:SHATTEREDTRAININGMANUAL, 1)
        pbMessage('Make room in your Bag for the Training Manual, then speak with Ren again.'.dup)
        return false
      end
      value[:manual] = true
      pbMessage('Ren gave you the Training Manual. You can read it from your Bag.'.dup)
    end
    if value[:lesson]
      if defined?(ShatteredGameplay) && pokemon.level.to_i >= 30
        ShatteredGameplay.offer_specialisation!(pokemon)
      end
      pbMessage('Your Quick Attack lesson is complete. Keep practising, and read the manual from your Bag.'.dup)
      return true
    end
    data = load_data(DATA_PATH)
    ShatteredViridianQuest.say(data.fetch('lesson'))
    return false unless pbConfirmMessage('Practise Quick Attack with Ren?'.dup)
    # Essentials owns four-slot move selection and cancellation. Never record
    # completion from the dialogue or from pbLearnMove's return value alone.
    pbLearnMove(pokemon, :QUICKATTACK) unless knows_quick_attack?(pokemon)
    return false unless knows_quick_attack?(pokemon)
    value[:lesson] = true
    pbMessage('Quick Attack lesson complete.'.dup)
    if defined?(ShatteredGameplay) && pokemon.level.to_i >= 30
      ShatteredGameplay.offer_specialisation!(pokemon)
    end
    true
  end

  def read_manual
    data = load_data(DATA_PATH)
    entries = data.fetch('classes')
    pbMessage('Ren\'s Training Manual records the recovered class stats and techniques. At level 30, use it to choose a discipline; at level 55, return to advance it.'.dup)
    page = 0
    loop do
      first = page * 6
      group = entries[first, 6]
      commands = group.map { |entry| entry.fetch('name').dup }
      commands += ['Next page', 'Previous page']
      commands << 'Choose or advance specialisation' if specialisation_available?
      commands << 'Close'
      choice = pbMessage("Training Manual: page #{page + 1}/#{(entries.length + 5) / 6}".dup, commands, -1)
      break if choice < 0 || choice == commands.length - 1
      if choice == group.length
        page = (page + 1) % ((entries.length + 5) / 6)
      elsif choice == group.length + 1
        page = (page - 1) % ((entries.length + 5) / 6)
      elsif choice == group.length + 2 && specialisation_available?
        if ShatteredGameplay.offer_specialisation!(human)
          pbMessage('Your training path has been recorded. Your HUMAN stats and techniques now follow that discipline.'.dup)
        else
          pbMessage('No eligible discipline is available yet. Learn two techniques of a discipline, then return here.'.dup)
        end
      else
        entry = group.fetch(choice)
        text = [entry.fetch('name'), entry.fetch('description'),
          'Base HP/Atk/Def/Speed/Sp.Atk/Sp.Def: ' + entry.fetch('stats').join('/'),
          'Types: ' + entry.fetch('types').map { |id| TYPES.fetch(id) }.uniq.join('/'),
          'Passives: ' + entry.fetch('passives').join(' / ')]
        text.each { |line| pbMessage(line.dup) }
        entry.fetch('moves').each_slice(6) do |moves|
          pbMessage(moves.map { |level, _id, name| "Lv#{level}: #{name}" }.join("\n").dup)
        end
      end
    end
    true
  end

  # The manual is the persistent, map-independent event hook for the full
  # recovered class tree. It never presents a choice until the gameplay
  # adapter can validate the HUMAN's level and known moves itself.
  def specialisation_available?
    pokemon = human
    return false unless defined?(ShatteredGameplay) && pokemon && pokemon.respond_to?(:level) &&
      pokemon.level.to_i >= 30 && ShatteredGameplay.respond_to?(:offer_specialisation!)
    # Do not offer a dead-end command after the level-30 choice has been made
    # but before the level-55 advancement unlocks, nor after an advanced class
    # is complete.  Keep the small fallback for an older gameplay adapter so a
    # save can still be opened and upgraded rather than losing its manual UI.
    return true unless ShatteredGameplay.respond_to?(:class_id_for) &&
      ShatteredGameplay.respond_to?(:primary_choices) &&
      ShatteredGameplay.respond_to?(:advanced_choices)
    if ShatteredGameplay.class_id_for(pokemon) == 0
      !ShatteredGameplay.primary_choices(pokemon).empty?
    else
      !ShatteredGameplay.advanced_choices(pokemon).empty?
    end
  end
end

if defined?(ItemHandlers::UseInField)
  ItemHandlers::UseInField.add(:SHATTEREDTRAININGMANUAL,
    proc { |_item| ShatteredRenTraining.read_manual })
end
