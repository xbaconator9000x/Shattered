# frozen_string_literal: true
# Shattered Core v0.2.4 — Pokémon Essentials 21.1.
# Does not override Pokemon#calc_stats. Battle hooks use Essentials v21.1 APIs.
module Shattered
  HUMAN_SPECIES = :HUMAN
  STRUGGLE = :STRUGGLE
  class HumanPartyFullError < ArgumentError; end
  class PartnerCapacityError < ArgumentError; end
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
      raise HumanPartyFullError, "party full; unable to add HUMAN" if party.length >= 6
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
          Shattered.ensure_human_if_player_available
          result
        end

        def load_all_values(*args)
          result = shattered_core_load_all_values(*args)
          Shattered.ensure_human_if_player_available
          result
        end
      end
      true
    end

    def ensure_human_if_player_available
      return false unless defined?($player) && $player && $player.respond_to?(:party)
      ensure_human($player)
      @human_setup_diagnostic = nil
      true
    rescue HumanPartyFullError => error
      @human_setup_diagnostic = error.message
      false
    end

    def human_setup_diagnostic
      @human_setup_diagnostic
    end

    def recover_human(player = $player, level = 5)
      human = ensure_human(player, level)
      @human_setup_diagnostic = nil
      human
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
      return 0 if move.to_sym == STRUGGLE
      TECHNIQUE_COSTS[move.to_sym]
    end

    def can_spend_stamina?(human, move, store = stamina_store)
      cost = stamina_cost(move)
      human?(human) && cost && stamina(human, store) >= cost
    end

    def spend_stamina(human, move, store = stamina_store)
      cost = stamina_cost(move)
      return true if human?(human) && cost == 0
      return false unless store && cost && can_spend_stamina?(human, move, store)
      store.instance_variable_set(:@shattered_stamina, stamina(human, store) - cost)
      true
    end

    # Essentials v21.1 has two native full-heal entry points. Trainer#heal_party
    # is used by scripted healing, while Interpreter#command_314 calls
    # pbEachPokemon directly when MECHANICS_GENERATION=8 (the pinned project).
    # Neither normally touches the HUMAN stamina stored on PokemonGlobal.
    def restore_player_stamina_after_healing(player)
      return false unless player && player.respond_to?(:party) &&
        defined?($PokemonGlobal) && $PokemonGlobal
      human = player.party.find { |pkmn| human?(pkmn) }
      return false unless human
      restore_stamina(human)
      true
    end

    def install_healing_hooks
      if defined?(Trainer) && Trainer.method_defined?(:heal_party) &&
         !Trainer.method_defined?(:shattered_core_original_heal_party)
        Trainer.class_eval do
          alias_method :shattered_core_original_heal_party, :heal_party
          def heal_party(*args)
            result = shattered_core_original_heal_party(*args)
            if defined?($player) && equal?($player)
              Shattered.restore_player_stamina_after_healing(self)
            end
            result
          end
        end
      end
      if defined?(Interpreter) && Interpreter.method_defined?(:command_314) &&
         !Interpreter.method_defined?(:shattered_core_original_command_314)
        Interpreter.class_eval do
          alias_method :shattered_core_original_command_314, :command_314
          def command_314(*args)
            result = shattered_core_original_command_314(*args)
            # Parameter 0 denotes Recover All for the player's party. This
            # includes the Gen 8 pbEachPokemon path which bypasses Trainer.
            if @parameters && @parameters[0] == 0 && defined?($player)
              Shattered.restore_player_stamina_after_healing($player)
            end
            result
          end
        end
      end
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

    # The native Essentials v21.1 Battle::Move#pbCalcTypeMod(moveType,user,target)
    # is the standard defensive type calculation used by battle damage and AI.
    # HUMAN is stored as a genuine species with Normal PBS typing for data
    # compatibility, but its defensive chart is intentionally non-standard.
    def human_type_multiplier(move_type)
      neutral = Effectiveness::NORMAL_EFFECTIVE_MULTIPLIER
      return neutral if move_type.nil?
      return 0 if HUMAN_MATCHUPS[:immune].include?(move_type)
      return neutral / 2 if HUMAN_MATCHUPS[:resist].include?(move_type)
      return neutral * 2 if HUMAN_MATCHUPS[:weak].include?(move_type)
      neutral
    end

    def install_type_hooks
      return false unless defined?(Battle::Move) &&
                          Battle::Move.method_defined?(:pbCalcTypeMod)
      move_class = Battle::Move
      return true if move_class.method_defined?(:shattered_core_original_pb_calc_type_mod)
      move_class.class_eval do
        alias_method :shattered_core_original_pb_calc_type_mod, :pbCalcTypeMod
        def pbCalcTypeMod(move_type, user, target)
          # Shadow moves retain the engine's special effectiveness rule.
          if move_type != :SHADOW && target && target.respond_to?(:pokemon) &&
             Shattered.human?(target.pokemon)
            return Shattered.human_type_multiplier(move_type)
          end
          shattered_core_original_pb_calc_type_mod(move_type, user, target)
        end
      end
      true
    end

    def install_battle_hooks
      install_capture_protection
      install_type_hooks
      return false unless defined?(Battle::Battler)
      battler_class = Battle::Battler
      return true if battler_class.method_defined?(:shattered_core_original_pb_try_use_move)
      battler_class.class_eval do
        alias_method :shattered_core_original_pb_can_choose_move, :pbCanChooseMove?
        alias_method :shattered_core_original_pb_try_use_move, :pbTryUseMove
        alias_method :shattered_core_original_pb_reduce_pp, :pbReducePP
        alias_method :shattered_core_original_pb_reduce_pp_other, :pbReducePPOther

        def pbCanChooseMove?(move, commandPhase, showMessages = true, specialUsage = false)
          human = instance_variable_get(:@pokemon)
          # Essentials checks native move PP before any Shattered stamina check.
          # A HUMAN technique with zero native PP must still be selectable if
          # shared stamina can pay for it. Borrow one PP ONLY while running the
          # original legality checks (Disable, Encore, etc.), then restore it.
          # Never borrow PP for a companion, an unmapped technique or Struggle.
          borrow_pp = Shattered.human?(human) && move.respond_to?(:pp) &&
            move.respond_to?(:pp=) && move.pp == 0 &&
            move.id != Shattered::STRUGGLE &&
            Shattered.can_spend_stamina?(human, move.id)
          original_pp = move.pp if borrow_pp
          begin
            move.pp = 1 if borrow_pp
            allowed = shattered_core_original_pb_can_choose_move(
              move, commandPhase, showMessages, specialUsage
            )
          ensure
            move.pp = original_pp if borrow_pp
          end
          return false unless allowed
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
      # Shattered's early-game party is the player-character HUMAN plus one
      # active Pokémon partner. Do not silently turn that into a normal six
      # Pokémon party: the field follower, indoor hiding and automatic mount
      # rules all rely on an unambiguous partner identity. Future story swaps
      # must explicitly remove/replace the current partner at a safe location.
      if party.any? { |pkmn| pkmn.respond_to?(:species) && !human?(pkmn) }
        raise PartnerCapacityError, "HUMAN can travel with only one Pokémon partner"
      end
      raise ArgumentError, "Pokemon class unavailable" unless defined?(Pokemon)
      friend = Pokemon.new(species, level)
      party << friend
      friend
    end

  end
end

Shattered.install_lifecycle_hooks
Shattered.install_healing_hooks
if defined?(EventHandlers)
  EventHandlers.add(:on_game_map_setup, :shattered_core_ensure_human,
    proc { |*args| Shattered.ensure_human_if_player_available })
  EventHandlers.add(:on_start_battle, :shattered_core_battle_hooks,
    proc { |*args| Shattered.install_battle_hooks })
end

