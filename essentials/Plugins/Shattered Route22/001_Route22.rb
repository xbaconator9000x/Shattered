# frozen_string_literal: true
# SE-017: one mandatory, non-capturable Route 22 level-five Rattata.
# Requires a real HUMAN battler and Pokémon Essentials v21.1 WildBattle.
module ShatteredRoute22
  SPECIES = :RATTATA
  LEVEL = 5

  def self.state(store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
    raise "Route 22 requires saved PokemonGlobal" unless store
    value = store.instance_variable_get(:@shattered_route22_rattata)
    if value.nil?
      value = { :version => 1, :cleared => false }
      store.instance_variable_set(:@shattered_route22_rattata, value)
    elsif !value.is_a?(Hash) || value[:version] != 1 ||
          ![true, false].include?(value[:cleared])
      # Never silently reset an unknown/partially corrupted save. That would
      # re-enable the mandatory fight after a completed encounter.
      raise "Unrecognised Route22 save state; refusing to reset encounter"
    end
    value
  end

  def self.cleared?
    !!state[:cleared]
  end

  # Essentials Game_Switches#[]= does not automatically refresh native map
  # event pages. Without this, a victorious Rattata encounter can leave the
  # three overworld sprites visible even after saving and reloading.
  def self.request_map_refresh
    map = defined?($game_map) ? $game_map : nil
    map.need_refresh = true if map && map.respond_to?(:need_refresh=)
  end

  def self.reconcile(cleared_switch)
    validate_id(cleared_switch)
    raise "Game switches unavailable" unless defined?($game_switches) && $game_switches
    # The saved quest flag is authoritative. A stale RMXP switch from an
    # interrupted install or older save must not skip the mandatory battle.
    done = cleared?
    previous = $game_switches[cleared_switch]
    $game_switches[cleared_switch] = done
    request_map_refresh if previous != done || done
    done
  end

  # Native RMXP map setup can restore event pages before the Route22 trigger
  # executes. Reconcile the saved encounter flag as soon as Map016 loads so a
  # completed fight cannot display its Rattata sprites again on Continue.
  # Leave all other maps untouched and do not initialise save data prematurely.
  def self.reconcile_on_map_setup
    return false unless defined?($PokemonGlobal) && $PokemonGlobal &&
      defined?($game_switches) && $game_switches &&
      defined?($game_map) && $game_map &&
      $game_map.respond_to?(:map_id) && $game_map.map_id == 16
    reconcile(992)
  end

  def self.validate_id(value)
    raise ArgumentError, "expected a reserved game ID" unless value.instance_of?(Integer) &&
      (1..9999).include?(value)
  end

  # Battle result 1 means victory. Escape, defeat, abort, draw and capture never
  # clear the mandatory encounter. A failed battle call leaves it retryable.
  def self.encounter(outcome_variable, cleared_switch)
    validate_id(outcome_variable)
    validate_id(cleared_switch)
    return true if reconcile(cleared_switch)
    raise "Game variables unavailable" unless defined?($game_variables) && $game_variables
    raise "Shattered HUMAN battle plugin missing" unless defined?(Shattered) &&
      Shattered.respond_to?(:human?)
    raise "WildBattle.start unavailable" unless defined?(WildBattle) && WildBattle.respond_to?(:start)
    raise "Battle rules unavailable" unless respond_to?(:setBattleRule, true) ||
      Object.private_method_defined?(:setBattleRule)
    raise "RATTATA species not compiled" unless defined?(GameData::Species) &&
      GameData::Species.respond_to?(:exists?) && GameData::Species.exists?(SPECIES)
    player = defined?($player) ? $player : nil
    raise "HUMAN party member missing" unless player && player.respond_to?(:party) &&
      player.party.any? { |member| Shattered.human?(member) }
    # Essentials v21.1 treats a wild battle with zero able party members as
    # a *skipped victory* (decision 1). Never let that skip clear a mandatory
    # encounter. This is a native engine contract, not a synthetic battle rule.
    return false unless player.respond_to?(:able_pokemon_count) &&
      player.able_pokemon_count > 0
    # Essentials chooses the first able party member as the opening battler.
    # A fainted HUMAN with a healthy companion would otherwise let this
    # mandatory *first HUMAN battle* be cleared without HUMAN fighting.
    # Pokemon#able? in the pinned v21.1 Scripts.rxdata excludes eggs/fainted.
    first_able = player.party.find { |member| member.respond_to?(:able?) && member.able? }
    return false unless first_able && Shattered.human?(first_able)
    return false if $DEBUG && defined?(Input) && Input.respond_to?(:press?) &&
      defined?(Input::CTRL) && Input.press?(Input::CTRL)
    return false if @running
    @running = true
    @last_capture_violation = false
    begin
      $game_variables[outcome_variable] = 0
      setBattleRule("disablePokeBalls")
      # A lost mandatory encounter must return to the map for a retry, not
      # trigger game over before the persistent quest flag can be checked.
      setBattleRule("canLose")
      setBattleRule("outcome", outcome_variable)
      WildBattle.start(SPECIES, LEVEL)
      decision = $game_variables[outcome_variable]
      if decision == 1
        $game_switches[cleared_switch] = true
        state[:cleared] = true
        request_map_refresh
        return true
      end
      # Essentials v21.1 heals the party after a canLose loss/draw (decisions
      # 2/5), but Shattered's stamina lives on PokemonGlobal, not the Pokemon.
      # Restore HUMAN stamina as well or repeated mandatory defeats can leave
      # a fully healed HUMAN unable to use any techniques on the next attempt.
      # Do not grant free stamina after escape, abort or capture violations.
      if [2, 5].include?(decision)
        player.party.each do |member|
          Shattered.restore_stamina(member) if Shattered.human?(member)
        end
      end
      # A result of 4 is an explicit violation of the no-capture acceptance gate.
      @last_capture_violation = (decision == 4)
      false
    rescue StandardError
      # Essentials v21.1 queues rules on Game_Temp and clears them only
      # after the battle scene has been prepared (or on a skipped battle).
      # A failed foe generator/scene initialization can otherwise leak
      # canLose/disablePokeBalls/outcome into the NEXT unrelated battle.
      temp = defined?($game_temp) ? $game_temp : nil
      temp.clear_battle_rules if temp && temp.respond_to?(:clear_battle_rules)
      raise
    ensure
      @running = false
    end
  end

  # A failed or escaped mandatory battle must not let the player walk from
  # the trigger tile straight into Viridian. Return to the safe west side if
  # still on Route22; never teleport someone after a blackout/map transfer.
  def self.return_to_entry(map_id, x, y)
    validate_id(map_id)
    raise ArgumentError, "Invalid Route22 retry position" unless
      x.instance_of?(Integer) && y.instance_of?(Integer) &&
      x.between?(0, 255) && y.between?(0, 255)
    return true if cleared?
    map = defined?($game_map) ? $game_map : nil
    return false unless map && map.respond_to?(:map_id) && map.map_id == map_id
    player = defined?($game_player) ? $game_player : nil
    raise "Game player cannot return to mandatory encounter entry" unless
      player && player.respond_to?(:moveto)
    player.moveto(x, y)
    request_map_refresh
    false
  end

  # Three real Route22 overworld events. A failed attempt resets their positions
  # before scattering again; the saved victory switch hides their second pages.
  SCATTER_EVENTS = {5 => [31, 17, :move_right],
                    6 => [31, 18, :move_left],
                    7 => [32, 18, :move_right]}.freeze

  def self.scatter!
    return false if cleared?
    map = defined?($game_map) ? $game_map : nil
    raise 'Route22 Rattata group requires native Map016' unless map &&
      map.respond_to?(:map_id) && map.map_id == 16 && map.respond_to?(:events)
    actors = SCATTER_EVENTS.map do |id, (x, y, direction)|
      actor = map.events[id]
      raise "Missing native Rattata scatter event #{id}" unless actor &&
        actor.respond_to?(:moveto) && actor.respond_to?(direction)
      [actor, x, y, direction]
    end
    actors.each { |actor, x, y, _direction| actor.moveto(x, y) }
    actors.each { |actor, _x, _y, direction| actor.public_send(direction) }
    pbWait(12) if defined?(pbWait)
    true
  end

  def self.capture_violation?
    !!@last_capture_violation
  end
end

# Use the saved quest state, not a potentially stale RMXP switch, when native
# Map016 is opened via transfer, New Game, or Continue.
if defined?(EventHandlers)
  EventHandlers.add(:on_game_map_setup, :shattered_route22_reconcile,
    proc { |*args| ShatteredRoute22.reconcile_on_map_setup })
  # Essentials v21.1 Game.load_map normally restores the saved MapFactory
  # without calling Game_Map#setup. Scene_Map#createSpritesets does invoke
  # :on_map_or_spriteset_change even on Continue. Reconcile there too, after
  # the saved map and switches are restored but before the first rendered frame.
  # Reconciliation is idempotent and never initialises state on unrelated maps.
  EventHandlers.add(:on_map_or_spriteset_change, :shattered_route22_reconcile_on_continue,
    proc { |*args| ShatteredRoute22.reconcile_on_map_setup })
end
