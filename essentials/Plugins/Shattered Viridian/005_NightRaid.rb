# frozen_string_literal: true
# Encounters and dialogue are recovered locally from the authenticated ROM.
module ShatteredViridianNightRaid
  IDS = %w[ren cook saff mara resident].freeze
  IVAR = :@shattered_viridian_night_raid
  DATA_PATH = 'Data/shattered_night_raid.dat'
  EVENT_PREFIX = 'SHATTERED_NIGHT:'
  OUTCOME_VARIABLE = 990
  GUARD = Mutex.new
  module_function

  def state
    raise 'Save metadata unavailable' unless defined?($PokemonGlobal) && $PokemonGlobal
    value = $PokemonGlobal.instance_variable_get(IVAR)
    unless value
      value = { :version => 1, :stage => :dormant, :rescued => [] }
      $PokemonGlobal.instance_variable_set(IVAR, value)
    end
    raise 'Invalid night raid save; refusing to reset progress' unless value.is_a?(Hash) &&
      value[:version] == 1 && [:dormant, :active, :cleared, :rested].include?(value[:stage]) &&
      value[:rescued].is_a?(Array) && value[:rescued].uniq == value[:rescued] &&
      value[:rescued].all? { |id| IDS.include?(id) } &&
      (value[:stage] != :dormant || value[:rescued].empty?) &&
      ([:cleared, :rested].include?(value[:stage]) == (value[:rescued].sort == IDS.sort))
    value
  end

  def run_rest
    return false unless ShatteredViridianQuest.state[:stage] == :supplied
    value = state
    if value[:stage] == :dormant
      return false unless pbConfirmMessage('Rest at the bunkhouse?'.dup)
      return false unless ShatteredViridianQuest.heal_party!
      value[:stage] = :active
      pbMessage('Shouts wake the bunkhouse. Beedrill and raiders are attacking the settlement. Help the people outside!'.dup)
    elsif value[:stage] == :cleared
      return false unless pbConfirmMessage('Everyone is inside. Rest until morning?'.dup)
      return false unless ShatteredViridianQuest.heal_party!
      value[:stage] = :rested
      pbMessage('The settlement is safe for now. Speak with Ren at the dojo when you are ready.'.dup)
    elsif value[:stage] == :active
      pbMessage('People are still outside. Help Ren, the cook, Saff, Mara and the resident at the doors.'.dup)
      return false
    else
      return false
    end
    reconcile
    true
  end

  def able_human_leads?
    return false unless defined?($player) && $player && $player.respond_to?(:party)
    first = $player.party.find { |member| member.able? }
    first && Shattered.human?(first)
  end

  def trigger(id)
    raise ArgumentError, 'Unknown night raid encounter' unless IDS.include?(id)
    acquired = false
    GUARD.synchronize do
      return false if @battle_active
      @battle_active = true
      acquired = true
    end
    begin
      value = state
      return false unless value[:stage] == :active && !value[:rescued].include?(id)
      return false unless defined?($game_map) && $game_map && $game_map.map_id == 10
      unless able_human_leads?
        pbMessage('HUMAN must be able to fight and lead the party. Recover at the Center before trying again.'.dup)
        return false
      end
      return false if $DEBUG && defined?(Input::CTRL) && Input.press?(Input::CTRL)
      encounter = load_data(DATA_PATH).fetch('encounters').find { |entry| entry['id'] == id }
      raise 'Missing recovered encounter' unless encounter
      ShatteredViridianQuest.say(encounter.fetch('dialogue').fetch('intro'))
      foe = Pokemon.new(encounter.fetch('species').to_sym, encounter.fetch('level'))
      foe.personalID = encounter.fetch('personality')
      foe.moves.clear
      encounter.fetch('moves').each { |move| foe.learn_move(move.to_sym) }
      foe.iv.each_key { |stat| foe.iv[stat] = encounter.fetch('iv') }
      foe.calc_stats
      $game_variables[OUTCOME_VARIABLE] = 0
      setBattleRule('disablePokeBalls')
      setBattleRule('cannotRun')
      setBattleRule('canLose')
      setBattleRule('outcome', OUTCOME_VARIABLE)
      WildBattle.start(foe)
      decision = $game_variables[OUTCOME_VARIABLE]
      if decision == 1
        value[:rescued] << id
        value[:stage] = :cleared if value[:rescued].sort == IDS.sort
        reconcile
        ShatteredViridianQuest.say(encounter.fetch('dialogue').fetch('won'))
        pbMessage('Everyone is safely inside. Return to Hana at the Center.'.dup) if value[:stage] == :cleared
        return true
      end
      if [2, 5].include?(decision)
        # Essentials canLose restores HP/PP; HUMAN stamina is separate.
        $player.party.each { |member| Shattered.restore_stamina(member) if Shattered.human?(member) }
        ShatteredViridianQuest.say(encounter.fetch('dialogue').fetch('lost'))
      end
      false
    rescue StandardError
      $game_temp.clear_battle_rules if defined?($game_temp) && $game_temp &&
        $game_temp.respond_to?(:clear_battle_rules)
      raise
    ensure
      GUARD.synchronize { @battle_active = false } if acquired
    end
  end

  def reconcile
    return false unless defined?($PokemonGlobal) && $PokemonGlobal &&
      defined?($game_map) && $game_map && $game_map.map_id == 10 &&
      defined?($game_self_switches) && $game_self_switches
    value = state
    changed = false
    $game_map.events.each do |event_id, event|
      next unless event.name.to_s.start_with?(EVENT_PREFIX)
      id = event.name.delete_prefix(EVENT_PREFIX)
      next unless IDS.include?(id)
      expected = value[:stage] == :active && !value[:rescued].include?(id)
      key = [10, event_id, 'A']
      changed ||= $game_self_switches[key] != expected
      $game_self_switches[key] = expected
    end
    $game_map.need_refresh = true if changed
    true
  end
end

if defined?(EventHandlers)
  EventHandlers.add(:on_game_map_setup, :shattered_night_restore,
    proc { |*args| ShatteredViridianNightRaid.reconcile })
  EventHandlers.add(:on_map_or_spriteset_change, :shattered_night_continue,
    proc { |*args| ShatteredViridianNightRaid.reconcile })
end
