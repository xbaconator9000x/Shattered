# frozen_string_literal: true
# The confrontation payload is extracted from the authenticated ROM by the
# private builder. This runtime contains no ROM dialogue or art.
module ShatteredForestConfrontation
  MAP_ID = 24
  EVENT_PREFIX = "SHATTERED_FOREST:"
  ACTOR_PREFIX = "SHATTERED_FOREST_ACTOR:"
  OUTCOME_VARIABLE = 991
  IVAR = :@shattered_forest_confrontation
  DATA_PATH = "Data/shattered_forest_confrontation.dat"
  GUARD = Mutex.new
  module_function

  def state
    raise "Save metadata unavailable" unless defined?($PokemonGlobal) && $PokemonGlobal
    value = $PokemonGlobal.instance_variable_get(IVAR)
    unless value
      value = { :version => 1, :resolved => false, :won => false }
      $PokemonGlobal.instance_variable_set(IVAR, value)
    end
    raise "Invalid forest confrontation save" unless value.is_a?(Hash) &&
      value[:version] == 1 && [true, false].include?(value[:resolved]) &&
      [true, false].include?(value[:won]) && (!value[:won] || value[:resolved])
    value
  end

  def available?
    return false unless defined?(ShatteredViridianQuest)
    [:supplies, :reward_pending].include?(ShatteredViridianQuest.state[:stage])
  rescue StandardError
    false
  end

  def confrontation_resolved?
    state[:resolved]
  end

  def trigger
    acquired = false
    GUARD.synchronize do
      return false if @active
      @active = true
      acquired = true
    end
    begin
      return false unless available? && !state[:resolved]
      return false unless defined?($game_map) && $game_map && $game_map.map_id == MAP_ID
      return false unless defined?($player) && $player && $player.party.any? { |p| Shattered.human?(p) && p.able? }
      return false unless pbConfirmMessage("Three people have cornered a Pokémon. Step in?")
      payload = load_data(DATA_PATH)
      foe_data = payload.fetch("foe")
      dialogue = payload.fetch("dialogue")
      play_choreography(:approach)
      Array(dialogue["choice"]).each { |line| pbMessage(line) }
      Array(dialogue["intro"]).each { |line| pbMessage(line) }
      foe = Pokemon.new(foe_data.fetch("species").to_sym, foe_data.fetch("level"))
      foe.personalID = foe_data.fetch("personality")
      foe.moves.clear
      foe_data.fetch("moves").each { |move| foe.learn_move(move.to_sym) }
      foe.iv.each_key { |stat| foe.iv[stat] = foe_data.fetch("iv") }
      foe.calc_stats
      $game_variables[OUTCOME_VARIABLE] = 0
      setBattleRule("disablePokeBalls")
      setBattleRule("cannotRun")
      setBattleRule("canLose")
      setBattleRule("outcome", OUTCOME_VARIABLE)
      WildBattle.start(foe)
      decision = $game_variables[OUTCOME_VARIABLE]
      return false unless [1, 2].include?(decision)
      state[:resolved] = true
      state[:won] = decision == 1
      reconcile
      Array(dialogue[decision == 1 ? "won" : "lost"]).each { |line| pbMessage(line) }
      play_choreography(decision == 1 ? :retreat : :aftermath)
      Array(dialogue["after"]).each { |line| pbMessage(line) }
      true
    ensure
      $game_temp.clear_battle_rules if defined?($game_temp) && $game_temp &&
        $game_temp.respond_to?(:clear_battle_rules)
      GUARD.synchronize { @active = false } if acquired
    end
  end

  def reconcile
    return false unless defined?($game_map) && $game_map && $game_map.map_id == MAP_ID &&
      defined?($game_self_switches) && $game_self_switches
    visible = available? && !state[:resolved]
    changed = false
    $game_map.events.each do |id, event|
      next unless event.name.to_s.start_with?(EVENT_PREFIX)
      key = [MAP_ID, id, "A"]
      changed ||= $game_self_switches[key] != visible
      $game_self_switches[key] = visible
    end
    $game_map.need_refresh = true if changed
    true
  end

  # The private installer gives the optional staging actors these names.  The
  # actual event movement API belongs to Essentials; this small adapter only
  # asks existing actors to take a bounded, collision-aware step.  A map built
  # without the optional actors still presents the battle safely.
  def play_choreography(phase)
    return false unless defined?($game_map) && $game_map && $game_map.map_id == MAP_ID
    actors = $game_map.events.values.select { |event| event.name.to_s.start_with?(ACTOR_PREFIX) }
    return false if actors.empty?
    directions = case phase
                 when :approach then [4, 6, 2]
                 when :retreat then [6, 6, 4]
                 else [2, 4, 6]
                 end
    actors.each_with_index do |actor, index|
      next unless actor.respond_to?(:move_straight)
      actor.move_straight(directions[index % directions.length])
    end
    true
  rescue StandardError
    false
  end
end

if defined?(EventHandlers)
  EventHandlers.add(:on_game_map_setup, :shattered_forest_restore,
    proc { |*_| ShatteredForestConfrontation.reconcile })
  EventHandlers.add(:on_map_or_spriteset_change, :shattered_forest_continue,
    proc { |*_| ShatteredForestConfrontation.reconcile })
end
