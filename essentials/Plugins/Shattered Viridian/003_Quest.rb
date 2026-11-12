# frozen_string_literal: true
# Viridian chapter progress is saved on PokemonGlobal. Native events provide
# dialogue recovered from the private ROM; no ROM dialogue is embedded here.
module ShatteredViridianQuest
  VERSION = 1
  IVAR = :@shattered_viridian_chapter
  STAGES = [:shelter, :rested, :tour, :supplies, :reward_pending, :supplied].freeze
  RESOURCES = { :berry => 3, :wood => 2, :apricorn => 2 }.freeze
  TOUR_LENGTH = 9
  NORTH_GATE_SWITCH = 1101
  class InvalidState < StandardError; end
  module_function

  def state(store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
    raise InvalidState, 'Save metadata unavailable' unless store
    value = store.instance_variable_get(IVAR)
    unless value
      value = { :version => VERSION, :stage => :shelter, :tour_index => 0,
                :collected => [], :tools_given => false, :kit_awarded => false }
      store.instance_variable_set(IVAR, value)
    end
    valid = value.is_a?(Hash) && value[:version] == VERSION && STAGES.include?(value[:stage]) &&
      value[:tour_index].is_a?(Integer) && value[:tour_index].between?(0, TOUR_LENGTH) &&
      value[:collected].is_a?(Array) && value[:collected].uniq == value[:collected] &&
      value[:collected].all? { |id| resource_ids.include?(id) } &&
      [true, false].include?(value[:kit_awarded]) && [true, false].include?(value[:tools_given])
    raise InvalidState, 'Invalid Viridian chapter save; refusing to reset progress' unless valid
    index = STAGES.index(value[:stage])
    consistent = (index >= 2 || value[:tour_index] == 0) &&
      (index < 3 || value[:tour_index] == TOUR_LENGTH) &&
      (index >= 3 || value[:collected].empty?) &&
      (index < 4 || value[:collected].sort == resource_ids.sort) &&
      (value[:kit_awarded] == (value[:stage] == :supplied)) &&
      (value[:tools_given] == (index >= 3))
    raise InvalidState, 'Viridian chapter flags exceed saved progress' unless consistent
    value
  end

  def resource_ids
    RESOURCES.flat_map { |kind, count| (1..count).map { |i| "#{kind}_#{i}" } }
  end

  def sheltered?
    defined?(ShatteredViridian) && ShatteredViridian.state[:center] == true
  end

  def heal_party!
    player = defined?($player) ? $player : nil
    return false unless player && player.respond_to?(:party) && !player.party.empty?
    player.party.each do |pokemon|
      next if pokemon.respond_to?(:egg?) && pokemon.egg?
      pokemon.heal
      Shattered.restore_stamina(pokemon) if defined?(Shattered) && Shattered.human?(pokemon)
    end
    true
  end

  def rest!
    return false unless sheltered? && state[:stage] == :shelter
    return false unless heal_party!
    state[:stage] = :rested
    true
  end

  def tour_step!(index)
    value = state
    return false unless sheltered? && [:rested, :tour].include?(value[:stage])
    raise ArgumentError, 'Invalid tour step' unless index.is_a?(Integer) && index.between?(0, TOUR_LENGTH - 1)
    return false unless index == value[:tour_index]
    value[:stage] = :tour
    value[:tour_index] += 1
    true
  end

  def accept_supplies!
    value = state
    return false unless value[:stage] == :tour && value[:tour_index] == TOUR_LENGTH
    return false unless defined?($bag) && $bag && $bag.respond_to?(:add) && $bag.respond_to?(:remove) &&
      defined?($player) && $player && $player.respond_to?(:has_running_shoes=) &&
      GameData::Item.exists?(:KNIFE) && GameData::Item.exists?(:SHATTEREDSUPPLYLIST)
    return false unless $bag.add(:KNIFE, 1)
    unless $bag.add(:SHATTEREDSUPPLYLIST, 1)
      $bag.remove(:KNIFE, 1)
      return false
    end
    $player.has_running_shoes = true
    value[:tools_given] = true
    value[:stage] = :supplies
    reconcile_north_gate
    true
  end

  def reconcile_north_gate
    return false unless defined?($game_switches) && $game_switches &&
      defined?($PokemonGlobal) && $PokemonGlobal
    expected = [:supplies, :reward_pending, :supplied].include?(state[:stage])
    changed = $game_switches[NORTH_GATE_SWITCH] != expected
    $game_switches[NORTH_GATE_SWITCH] = expected
    if changed && defined?($game_map) && $game_map && $game_map.respond_to?(:need_refresh=)
      $game_map.need_refresh = true
    end
    expected
  end

  def collect!(id)
    raise ArgumentError, 'Unknown quest supply' unless resource_ids.include?(id)
    value = state
    return false unless value[:stage] == :supplies && !value[:collected].include?(id)
    value[:collected] << id
    true
  end

  def reconcile_supplies
    return false unless defined?($game_map) && $game_map && defined?($game_self_switches) && $game_self_switches
    return false unless defined?($PokemonGlobal) && $PokemonGlobal
    changed = false
    $game_map.events.each do |event_id, event|
      name = event.name.to_s
      next unless name.start_with?('SHATTERED_SUPPLY:')
      id = name.delete_prefix('SHATTERED_SUPPLY:')
      next unless resource_ids.include?(id)
      key = [$game_map.map_id, event_id, 'A']
      expected = state[:collected].include?(id)
      changed ||= $game_self_switches[key] != expected
      $game_self_switches[key] = expected
    end
    $game_map.need_refresh = true if changed
    changed
  end

  def run_supply(id)
    return false unless collect!(id)
    reconcile_supplies
    pbMessage("Recovered #{id.split('_').first} for Mara.".dup)
    true
  end

  def turn_in!
    value = state
    return false unless value[:stage] == :supplies && value[:collected].sort == resource_ids.sort
    value[:stage] = :reward_pending
    true
  end

  def claim_kit!
    value = state
    return false unless value[:stage] == :reward_pending
    bag = defined?($bag) ? $bag : nil
    return false unless bag && bag.respond_to?(:add) &&
      defined?(GameData::Item) && GameData::Item.exists?(:CAMPINGKIT)
    return false unless bag.add(:CAMPINGKIT, 1)
    value[:kit_awarded] = true
    value[:stage] = :supplied
    true
  end

  def say(lines)
    raise ArgumentError, 'Missing recovered quest dialogue' unless
      lines.is_a?(Array) && !lines.empty? && lines.all? { |line| line.is_a?(String) && !line.empty? }
    lines.each { |line| pbMessage(line.gsub('{PLAYER}', $player.name).dup) }
  end

  def run_rest(dialogue)
    return false unless sheltered?
    if state[:stage] == :supplied && defined?(ShatteredViridianNightRaid)
      return ShatteredViridianNightRaid.run_rest
    end
    return false unless state[:stage] == :shelter
    say(dialogue.fetch('hana'))
    return false unless pbConfirmMessage('Lie down and rest?'.dup)
    return false unless rest!
    say(dialogue.fetch('morning'))
    true
  end

  def run_tour(dialogue)
    return false unless sheltered? && [:rested, :tour].include?(state[:stage])
    steps = dialogue.fetch('tour')
    raise ArgumentError, 'Recovered tour is incomplete' unless steps.length == TOUR_LENGTH
    while state[:tour_index] < TOUR_LENGTH
      index = state[:tour_index]
      say(steps[index])
      tour_step!(index)
    end
    say(dialogue.fetch('council'))
    true
  end

  def run_mara(dialogue)
    value = state
    if value[:stage] == :tour && value[:tour_index] == TOUR_LENGTH
      say(dialogue.fetch('request'))
      return false unless pbConfirmMessage('Help gather the supplies?'.dup)
      unless accept_supplies!
        say(dialogue.fetch('tools_full'))
        return false
      end
      say(dialogue.fetch('accepted'))
      return true
    end
    if value[:stage] == :supplies
      unless turn_in!
        say(dialogue.fetch('reminder'))
        return false
      end
    end
    if value[:stage] == :reward_pending
      unless claim_kit!
        say(dialogue.fetch('bag_full'))
        return false
      end
      say(dialogue.fetch('thanks'))
      return true
    end
    value[:stage] == :supplied
  end
end

if defined?(EventHandlers)
  EventHandlers.add(:on_game_map_setup, :shattered_supply_restore,
    proc { |*args| ShatteredViridianQuest.reconcile_north_gate; ShatteredViridianQuest.reconcile_supplies })
  EventHandlers.add(:on_map_or_spriteset_change, :shattered_supply_continue,
    proc { |*args| ShatteredViridianQuest.reconcile_north_gate; ShatteredViridianQuest.reconcile_supplies })
end

if defined?(ItemHandlers::UseInField)
  ItemHandlers::UseInField.add(:SHATTEREDSUPPLYLIST, proc { |_item|
    value = ShatteredViridianQuest.state
    ShatteredViridianQuest::RESOURCES.each do |kind, count|
      found = value[:collected].count { |id| id.start_with?(kind.to_s + '_') }
      pbMessage("#{kind.to_s.capitalize}: #{found}/#{count}".dup)
    end
    true
  })
  ItemHandlers::UseInField.add(:CAMPINGKIT, proc { |_item|
    next false unless pbConfirmMessage('Use the Camping Kit to restore the whole party?'.dup)
    ShatteredViridianQuest.heal_party!
  })
end
