# frozen_string_literal: true
# Shattered Core v0.2 — Pokémon Essentials 21.1.
# Does not override Pokemon#calc_stats. Battle hooks use Essentials v21.1 APIs.
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
      defined?(Pokemon) && pkmn.is_a?(Pokemon) && pkmn.species == HUMAN_SPECIES
    end

    # Uses Essentials' genuine HUMAN species rather than a battle engine replacement.
    def ensure_human(player = $player, level = 5)
      raise ArgumentError, "player party unavailable" unless player && player.respond_to?(:party)
      party = player.party
      raise ArgumentError, "player party unavailable" unless party.respond_to?(:delete_if) && party.respond_to?(:length)
      found = nil
      party.delete_if do |pkmn|
        next false unless human?(pkmn)
        if found
          true
        else
          found = pkmn
          false
        end
      end
      raise ArgumentError, "party exceeds six members" if party.length > 6
      return found if found
      raise ArgumentError, "party full; unable to add HUMAN" if party.length >= 6
      raise ArgumentError, "Pokemon class unavailable" unless defined?(Pokemon)
      battler = Pokemon.new(HUMAN_SPECIES, level)
      battler.name = "HUMAN" if battler.respond_to?(:name=)
      party.unshift(battler)
      battler
    end

    def install_lifecycle_hooks
      return false unless defined?(SaveData) &&
                          SaveData.respond_to?(:load_new_game_values) &&
                          SaveData.respond_to?(:load_all_values)
      save_data_singleton = class << SaveData; self; end
      return true if save_data_singleton.method_defined?(:shattered_core_load_new_game_values)
      save_data_singleton.class_eval do
        alias_method :shattered_core_load_new_game_values, :load_new_game_values
        alias_method :shattered_core_load_all_values, :load_all_values

        def load_new_game_values(*args)
          result = shattered_core_load_new_game_values(*args)
          Shattered.ensure_human
          result
        end

        def load_all_values(*args)
          result = shattered_core_load_all_values(*args)
          Shattered.ensure_human
          result
        end
      end
      true
    end

    def max_stamina(level)
      [[BASE_STAMINA + ([level.to_i, 1].max / 10) * STAMINA_PER_10_LEVELS,
        STAMINA_CAP].min, 0].max
    end

    # Persisted in Essentials' saved PokemonGlobal metadata object.
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

    def stamina_cost(move)
      return nil unless move.respond_to?(:to_sym)
      TECHNIQUE_COSTS[move.to_sym]
    end

    def can_spend_stamina?(human, move, store = stamina_store)
      cost = stamina_cost(move)
      human?(human) && cost && stamina(human, store) >= cost
    end

    def spend_stamina(human, move, store = stamina_store)
      cost = stamina_cost(move)
      return false unless store && cost && can_spend_stamina?(human, move, store)
      store.instance_variable_set(:@shattered_stamina, stamina(human, store) - cost)
      true
    end

    def install_capture_protection
      return false unless defined?(GameData::Item) && defined?(ItemHandlers::CanUseInBattle)
      GameData::Item.each do |item_data|
        next unless item_data.respond_to?(:is_poke_ball?) && item_data.is_poke_ball?
        ItemHandlers::CanUseInBattle.add(item_data.id,
          proc { |item, pokemon, battler, move, firstAction, battle, scene, showMessages|
            scene.pbDisplay(_INTL("Poké Balls cannot be used in Shattered.")) if showMessages
            false
          })
      end
      true
    end

    def install_battle_hooks
      install_capture_protection
      return false unless defined?(Battle::Battler)
      battler_class = Battle::Battler
      return true if battler_class.method_defined?(:shattered_core_original_pb_try_use_move)
      battler_class.class_eval do
        alias_method :shattered_core_original_pb_can_choose_move, :pbCanChooseMove?
        alias_method :shattered_core_original_pb_try_use_move, :pbTryUseMove
        alias_method :shattered_core_original_pb_reduce_pp, :pbReducePP
        alias_method :shattered_core_original_pb_reduce_pp_other, :pbReducePPOther

        def pbCanChooseMove?(move, commandPhase, showMessages = true, specialUsage = false)
          allowed = shattered_core_original_pb_can_choose_move(
            move, commandPhase, showMessages, specialUsage
          )
          return false unless allowed
          human = instance_variable_get(:@pokemon)
          return true unless Shattered.human?(human)
          return true if Shattered.can_spend_stamina?(human, move.id)
          if showMessages
            message = _INTL("HUMAN doesn't have enough stamina to use {1}!", move.name)
            if commandPhase
              @battle.pbDisplayPaused(message)
            else
              @battle.pbDisplay(message)
            end
          end
          false
        end

        def pbReducePP(move)
          return true if Shattered.human?(instance_variable_get(:@pokemon))
          shattered_core_original_pb_reduce_pp(move)
        end

        def pbReducePPOther(move)
          return true if Shattered.human?(instance_variable_get(:@pokemon))
          shattered_core_original_pb_reduce_pp_other(move)
        end

        def pbTryUseMove(choice, move, specialUsage, skipAccuracyCheck)
          human = instance_variable_get(:@pokemon)
          result = shattered_core_original_pb_try_use_move(
            choice, move, specialUsage, skipAccuracyCheck
          )
          return result unless result && Shattered.human?(human)
          used_move = choice[2] || move
          return result if Shattered.spend_stamina(human, used_move.id)
          @lastMoveFailed = true
          @battle.pbDisplay(_INTL("HUMAN doesn't have enough stamina to use {1}!", used_move.name))
          false
        end
      end
      true
    end

    def befriend(species, level = 5, player = $player)
      raise ArgumentError, "player party unavailable" unless player && player.respond_to?(:party)
      party = player.party
      raise ArgumentError, "player party unavailable" unless party.respond_to?(:find) && party.respond_to?(:length)
      raise ArgumentError, "species must be a Symbol or String" unless species.respond_to?(:to_sym)
      species = species.to_sym
      raise ArgumentError, "cannot recruit a HUMAN" if species == HUMAN_SPECIES
      existing = party.find { |pkmn| pkmn.respond_to?(:species) && pkmn.species == species }
      return existing if existing
      raise ArgumentError, "party exceeds six members" if party.length > 6
      raise ArgumentError, "party full; unable to add companion" if party.length >= 6
      raise ArgumentError, "Pokemon class unavailable" unless defined?(Pokemon)
      friend = Pokemon.new(species, level)
      party << friend
      friend
    end

  end
end

Shattered.install_lifecycle_hooks
if defined?(EventHandlers)
  EventHandlers.add(:on_start_battle, :shattered_core_battle_hooks,
    proc { |*args| Shattered.install_battle_hooks })
end
