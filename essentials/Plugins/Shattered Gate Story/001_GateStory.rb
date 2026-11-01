# frozen_string_literal: true
# SE-016: persisted opening gate scene, not a substitute for a compiled map.
# Uses the actual Essentials saved $PokemonGlobal object; no temporary module flags.
module ShatteredGateStory
  KEY_ITEM = :SHATTEREDGATEKEY
  MAX_IMPACTS = 6
  class InvalidState < StandardError; end

  class << self
    def state(store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
      raise "Shattered gate requires initialized saved PokemonGlobal" unless store
      raw = store.instance_variable_get(:@shattered_gate_story)
      if raw.nil?
        raw = { :version => 1, :impacts => 0, :aipom_clue => false, :key => false,
                :johto_blocked_message => false, :final_roar => false }
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
      consistent = (!raw[:aipom_clue] || raw[:impacts] == MAX_IMPACTS) &&
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
      pbMessage(_INTL("The way back to Johto is blocked. Better find another way."))
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
        pbMessage(_INTL("Rocks and structural debris block the entrance."))
      else
        pbMessage(_INTL("The way back to Johto is blocked. Better find another way."))
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
        pbSEPlay(sound_names[index])
        pbWait(index == 2 || index == 5 ? 24 : 16)
        impact!
        announce_johto_blocked_once
      end
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

    def run_aipom(cry)
      raise ArgumentError, "invalid Aipom cry name" unless valid_cry_name?(cry)
      unless collapsed?
        pbMessage(_INTL("There's something shiny up ahead."))
        return false
      end
      if key_obtained?
        pbMessage(_INTL("Aipom looks pleased to see you again."))
        return true
      end
      pbMessage(_INTL("There's something shiny up ahead."))
      pbMessage(_INTL("It has something in its tail."))
      pbSEPlay(cry)
      clue!
      if award_key!
        pbMessage(_INTL("You received the gate key from Aipom!"))
        true
      else
        pbMessage(_INTL("You need space for the gate key."))
        false
      end
    end
  end
end
