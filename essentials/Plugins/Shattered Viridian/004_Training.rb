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
    pbMessage('ROM curriculum reference: these are the original class stats and techniques. This book does not unlock unported specialisations.'.dup)
    page = 0
    loop do
      first = page * 6
      group = entries[first, 6]
      commands = group.map { |entry| entry.fetch('name').dup }
      commands += ['Next page', 'Previous page', 'Close']
      choice = pbMessage("Training Manual: page #{page + 1}/#{(entries.length + 5) / 6}".dup, commands, -1)
      break if choice < 0 || choice == group.length + 2
      if choice == group.length
        page = (page + 1) % ((entries.length + 5) / 6)
      elsif choice == group.length + 1
        page = (page - 1) % ((entries.length + 5) / 6)
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
end

if defined?(ItemHandlers::UseInField)
  ItemHandlers::UseInField.add(:SHATTEREDTRAININGMANUAL,
    proc { |_item| ShatteredRenTraining.read_manual })
end
