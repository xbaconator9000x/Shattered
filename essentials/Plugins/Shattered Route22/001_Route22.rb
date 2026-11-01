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

  def self.capture_violation?
    !!@last_capture_violation
  end
end
