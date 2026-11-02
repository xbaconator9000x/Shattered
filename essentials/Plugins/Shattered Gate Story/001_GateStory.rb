# frozen_string_literal: true
# SE-016: persisted opening gate scene, not a substitute for a compiled map.
# Uses the actual Essentials saved $PokemonGlobal object; no temporary module flags.
module ShatteredGateStory
  KEY_ITEM = :SHATTEREDGATEKEY
  MAX_IMPACTS = 6
  # Native Essentials v21.1 Game_Screen#start_shake duration is measured in
  # 1/20-second units; native Essentials pbWait accepts SECONDS, not frames.
  # Use 0.8/1.2 second intervals to avoid a 112-second opening stall.
  IMPACT_SHAKES = [[3, 5, 5], [4, 5, 5], [6, 6, 8],
                   [4, 5, 5], [5, 6, 5], [8, 7, 8]].freeze
  KEY_AFTERSHOCK = [6, 6, 8].freeze
  KEY_AFTERSHOCK_SE = "Mining collapse"
  # Reserved for native Map223 rock event pages. The saved story state, not
  # this ordinary RMXP switch, remains authoritative after Continue.
  DEBRIS_SWITCH = 997
  DEBRIS_MAP_ID = 223
  DEBRIS_EVENT_IDS = [1, 8, 9].freeze
  class InvalidState < StandardError; end

  class << self
    def state(store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
      raise "Shattered gate requires initialized saved PokemonGlobal" unless store
      raw = store.instance_variable_get(:@shattered_gate_story)
      if raw.nil?
        raw = { :version => 1, :impacts => 0, :aipom_clue => false, :key => false,
                :johto_blocked_message => false, :final_roar => false,
                :post_key_impact => false }
        store.instance_variable_set(:@shattered_gate_story, raw)
      end
      valid = raw.is_a?(Hash) && raw[:version] == 1 &&
        raw[:impacts].instance_of?(Integer) && (0..MAX_IMPACTS).include?(raw[:impacts]) &&
        [:aipom_clue, :key].all? { |flag| [true, false].include?(raw[flag]) }
      raise InvalidState, "Unknown gate save data; refusing to replay collapse or key award" unless valid

      # Older v1 saves may lack these two optional presentation flags. Preserve
      # their impact/key progress, but never overwrite a malformed existing flag.
      [:johto_blocked_message, :final_roar].each do |flag|
        raw[flag] = false unless raw.key?(flag)
        raise InvalidState, "Invalid gate save flag: #{flag}" unless [true, false].include?(raw[flag])
      end
      # Legacy v1 saves already holding the key must not receive a surprise
      # aftershock on their next Continue. New saves start with false.
      raw[:post_key_impact] = raw[:key] unless raw.key?(:post_key_impact)
      raise InvalidState, "Invalid gate save flag: post_key_impact" unless
        [true, false].include?(raw[:post_key_impact])
      consistent = (!raw[:post_key_impact] || raw[:key]) &&
        (!raw[:aipom_clue] || raw[:impacts] == MAX_IMPACTS) &&
        (!raw[:key] || raw[:aipom_clue]) &&
        (!raw[:final_roar] || raw[:impacts] == MAX_IMPACTS) &&
        (!raw[:johto_blocked_message] || raw[:impacts] >= 3)
      raise InvalidState, "Inconsistent gate save progress; refusing to reset story" unless consistent
      raw
    end

    def collapsed?(store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
      state(store)[:impacts] == MAX_IMPACTS
    end

    def impact!(store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
      current = state(store)
      current[:impacts] += 1 if current[:impacts] < MAX_IMPACTS
      current[:impacts]
    end

    def announce_johto_blocked_once
      current = state
      return if current[:impacts] < 3 || current[:johto_blocked_message]
      pbMessage(_INTL("The way back to Johto is blocked. Better find another way.").dup)
      current[:johto_blocked_message] = true
    end

    def clue!(store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
      return false unless collapsed?(store)
      state(store)[:aipom_clue] = true
      true
    end

    # The saved flag records Aipom's award; the bag is the actual door key.
    # Never unlock a door solely from a stale flag after an interrupted save,
    # item removal, or migration. Revisit Aipom to recover a missing key.
    def key_obtained?(store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil),
                      bag = (defined?($bag) ? $bag : nil))
      !!state(store)[:key] && !!(bag && bag.respond_to?(:has?) && bag.has?(KEY_ITEM))
    end

    # Mark awarded only after bag.add succeeds. Revisit/loaded save cannot duplicate.
    def award_key!(bag = (defined?($bag) ? $bag : nil),
                   store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
      return false unless collapsed?(store) && state(store)[:aipom_clue]
      return true if key_obtained?(store, bag)
      raise "Shattered gate key not compiled in PBS/items.txt" unless
        defined?(GameData::Item) && GameData::Item.respond_to?(:exists?) && GameData::Item.exists?(KEY_ITEM)
      raise "Bag unavailable" unless bag && bag.respond_to?(:add)
      # If a save was interrupted after bag.add, reconcile rather than duplicate.
      already_has = bag.respond_to?(:has?) && bag.has?(KEY_ITEM)
      return false unless already_has || bag.add(KEY_ITEM, 1)
      state(store)[:key] = true
      true
    end

    def blocked_johto
      if collapsed?
        pbMessage(_INTL("Rocks and structural debris block the entrance.").dup)
      else
        pbMessage(_INTL("The way back to Johto is blocked. Better find another way.").dup)
      end
      true
    end

    # Run the real Essentials screen effect; do not mark an impact complete
    # if the native screen object is unavailable.
    def shake!(power, speed, duration)
      screen = defined?($game_screen) ? $game_screen : nil
      raise "Native Game_Screen unavailable for gate cinematic" unless
        screen && screen.respond_to?(:start_shake)
      screen.start_shake(power, speed, duration)
    end

    # A one-time aftershock after receiving Aipom's key. If audio/wait fails,
    # the key remains awarded but the effect is retryable on the next visit.
    def play_key_aftershock_once
      current = state
      return false unless key_obtained?
      return true if current[:post_key_impact]
      shake!(*KEY_AFTERSHOCK)
      pbSEPlay(KEY_AFTERSHOCK_SE)
      pbWait(0.8)
      current[:post_key_impact] = true
      true
    end

    # The native Johto corridor has three walkable cells at y=19. Event #1
    # previously had an empty graphic, which Game_Character#passable? treats
    # as non-blocking even with through=false. A separate offline installer
    # adds switch-controlled solid rock pages at all three cells. Reconcile
    # after the collapse and on map setup/Continue so a stale switch cannot
    # hide rocks or display them before the collapse.
    def reconcile_debris
      return false unless defined?($PokemonGlobal) && $PokemonGlobal &&
        defined?($game_map) && $game_map &&
        $game_map.respond_to?(:map_id) && $game_map.map_id == DEBRIS_MAP_ID &&
        $game_map.respond_to?(:events) && $game_map.events.is_a?(Hash) &&
        defined?($game_switches) && $game_switches
      events = $game_map.events
      # Older private candidates do not yet have the debris installer.
      return false unless DEBRIS_EVENT_IDS.all? { |id| events.key?(id) }
      unless events[8].name == "SHATTERED_HNS_DEBRIS:8" &&
             events[9].name == "SHATTERED_HNS_DEBRIS:9" &&
             events[1].name == "SHATTERED_HNS:1"
        raise InvalidState, "Native Johto debris event identity changed"
      end
      desired = collapsed?
      previous = $game_switches[DEBRIS_SWITCH]
      $game_switches[DEBRIS_SWITCH] = desired
      if (previous != desired || desired) && $game_map.respond_to?(:need_refresh=)
        $game_map.need_refresh = true
      end
      true
    end

    # Each effect is an existing, locally licensed SE basename. No audio is committed.
    # The beat is saved after each successful playback, allowing interrupted scene recovery.
    def run_collapse(sound_names, final_roar)
      raise ArgumentError, "six impact sound names required" unless
        sound_names.is_a?(Array) && sound_names.length == MAX_IMPACTS &&
        sound_names.all? { |name| valid_cry_name?(name) }
      raise ArgumentError, "invalid final roar name" unless
        valid_cry_name?(final_roar)
      announce_johto_blocked_once
      while state[:impacts] < MAX_IMPACTS
        index = state[:impacts]
        shake!(*IMPACT_SHAKES.fetch(index))
        pbSEPlay(sound_names[index])
        pbWait(index == 2 || index == 5 ? 1.2 : 0.8)
        impact!
        announce_johto_blocked_once
      end
      reconcile_debris
      if !state[:final_roar]
        pbSEPlay(final_roar)
        state[:final_roar] = true
      end
      true
    end

    # Essentials keeps the original Pokemon cries under Audio/SE/Cries/.
    # Permit that single reviewed subdirectory, never arbitrary paths.
    def valid_cry_name?(cry)
      cry.is_a?(String) && /\A(?:Cries\/)?[A-Za-z0-9_ -]+\z/.match?(cry)
    end

    def run_aipom(cry, event = nil)
      raise ArgumentError, "invalid Aipom cry name" unless valid_cry_name?(cry)
      unless collapsed?
        pbMessage(_INTL("There's something shiny up ahead.").dup)
        return false
      end
      if key_obtained?
        play_key_aftershock_once
        pbMessage(_INTL("Aipom looks pleased to see you again.").dup)
        return true
      end
      # The native RMXP event supplies get_character(0). The actual Essentials
      # v21.1 Game_Character#turn_up and pbExclaim animation run only on an
      # unclaimed key, never on subsequent visits or interrupted save recovery.
      if event
        raise ArgumentError, "Invalid native Aipom event" unless
          event.respond_to?(:turn_up) && event.respond_to?(:map_id)
        raise "Essentials exclamation animation unavailable" unless defined?(pbExclaim)
      end
      pbMessage(_INTL("There's something shiny up ahead.").dup)
      pbMessage(_INTL("It has something in its tail.").dup)
      if event
        event.turn_up
        pbExclaim(event)
      end
      pbSEPlay(cry)
      clue!
      if award_key!
        pbMessage(_INTL("You received the gate key from Aipom!").dup)
        play_key_aftershock_once
        true
      else
        pbMessage(_INTL("You need space for the gate key.").dup)
        false
      end
    end
  end
end

# Native map setup covers new transfers; spriteset recreation covers Continue
# from a saved MapFactory without calling Game_Map#setup again.
if defined?(EventHandlers)
  EventHandlers.add(:on_game_map_setup, :shattered_hns_debris_map_setup,
    proc { |*args| ShatteredGateStory.reconcile_debris })
  EventHandlers.add(:on_map_or_spriteset_change, :shattered_hns_debris_continue,
    proc { |*args| ShatteredGateStory.reconcile_debris })
end
