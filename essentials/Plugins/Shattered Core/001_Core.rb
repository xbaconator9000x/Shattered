# frozen_string_literal: true
# Shattered Core v0.1 — Pokémon Essentials 21.1.
# Deliberately does not override Pokemon#calc_stats, battle PP, or plugins.
# These functions are event-facing until runtime hooks have been playtested.
module Shattered
  HUMAN_SPECIES = :HUMAN
  BASE_STAMINA = 60
  STAMINA_PER_10_LEVELS = 5
  STAMINA_CAP = 100
  TECHNIQUE_COSTS = {
    :POUND => 1, :DEFENSECURL => 1, :QUICKATTACK => 2,
    :ROCKTHROW => 3, :SLASH => 3, :EMBER => 3, :BUBBLE => 3
  }.freeze
  HUMAN_MATCHUPS = {
    :immune => [:FAIRY, :GHOST, :DRAGON].freeze,
    :resist => [:DARK, :PSYCHIC, :BUG].freeze,
    :weak => [:FIRE, :ICE, :ELECTRIC, :POISON, :STEEL, :ROCK, :FIGHTING].freeze
  }.freeze
  EQUIPMENT_SLOTS = [:head, :torso, :left_hand, :right_hand, :legs, :feet].freeze
  SPECIALISATION_LEVELS = [30, 55].freeze

  class << self
    def human?(pkmn)
      !!pkmn && pkmn.respond_to?(:species) && pkmn.species == HUMAN_SPECIES
    end

    # Uses Essentials' existing party species rather than a battle engine replacement.
    # Call during a NEW GAME event, not at every map load.
    def ensure_human(player = $player, level = 5)
      raise ArgumentError, "player party unavailable" unless player && player.respond_to?(:party)
      found = player.party.find { |p| human?(p) }
      return found if found
      raise ArgumentError, "party full" if player.party.length >= 6
      raise ArgumentError, "Pokemon class unavailable" unless defined?(Pokemon)
      battler = Pokemon.new(HUMAN_SPECIES, level)
      battler.name = "HUMAN" if battler.respond_to?(:name=)
      player.party.unshift(battler)
      battler
    end

    def max_stamina(level)
      [[BASE_STAMINA + ([level.to_i, 1].max / 10) * STAMINA_PER_10_LEVELS,
        STAMINA_CAP].min, 0].max
    end

    # Persisted in Essentials' saved PokemonGlobal metadata object; battle integration
    # must call spend_stamina once per successful human move (NOT done automatically).
    def stamina_store
      defined?($PokemonGlobal) ? $PokemonGlobal : nil
    end

    def stamina(human, store = stamina_store)
      return 0 unless human?(human)
      return max_stamina(human.level) if store.nil?
      value = store.instance_variable_get(:@shattered_stamina)
      return max_stamina(human.level) if value.nil?
      [[value.to_i, 0].max, max_stamina(human.level)].min
    end

    def restore_stamina(human, store = stamina_store)
      raise ArgumentError, "HUMAN required" unless human?(human)
      value = max_stamina(human.level)
      store.instance_variable_set(:@shattered_stamina, value) if store
      value
    end

    def can_spend_stamina?(human, move, store = stamina_store)
      human?(human) && stamina(human, store) >= TECHNIQUE_COSTS.fetch(move.to_sym, 1)
    end

    def spend_stamina(human, move, store = stamina_store)
      return false unless store && can_spend_stamina?(human, move, store)
      cost = TECHNIQUE_COSTS.fetch(move.to_sym, 1)
      store.instance_variable_set(:@shattered_stamina, stamina(human, store) - cost)
      true
    end

    # Developer-facing recruitment API: no Poke Ball or catch operation.
    # Does not suppress the default capture menu in the Essentials battle UI.
    def befriend(species, level = 5, player = $player)
      raise ArgumentError, "player party unavailable" unless player && player.respond_to?(:party)
      raise ArgumentError, "cannot recruit a HUMAN" if species.to_sym == HUMAN_SPECIES
      raise ArgumentError, "party full" if player.party.length >= 6
      friend = Pokemon.new(species.to_sym, level)
      player.party << friend
      friend
    end
  end
end
