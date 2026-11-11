# frozen_string_literal: true
#
# Single-partner selection contract for Shattered. Rendering/movement adapters
# consume this module; the source of truth is always the current party order,
# never a cached event ID or a hard-coded party slot.
module ShatteredCompanion
  RIDEABLE_OVERSIZED = [:ONIX, :CRYSTALONIX, :CRYSTALIX, :BULLGRUM].freeze

  class << self
    # The first eligible non-HUMAN party member is the one and only field
    # companion. This deliberately works whether HUMAN occupies slot 0, slot
    # 1, or another slot after a party re-order. The Core recruitment gate
    # prevents a second partner; this selector remains deterministic when
    # inspecting an old/imported save that has not been repaired yet.
    def partner(player = (defined?($player) ? $player : nil))
      return nil unless player && player.respond_to?(:party) && player.party.is_a?(Array)
      player.party.find { |pokemon| eligible?(pokemon) }
    end

    def eligible?(pokemon)
      return false unless pokemon
      return false if defined?(Shattered) && Shattered.respond_to?(:human?) && Shattered.human?(pokemon)
      return false if pokemon.respond_to?(:egg?) && pokemon.egg?
      pokemon.respond_to?(:species)
    end

    def partners(player = (defined?($player) ? $player : nil))
      return [] unless player && player.respond_to?(:party) && player.party.is_a?(Array)
      player.party.select { |pokemon| eligible?(pokemon) }
    end

    def valid_party?(player = (defined?($player) ? $player : nil))
      partners(player).length <= 1
    end

    def oversized?(pokemon = partner)
      pokemon && RIDEABLE_OVERSIZED.include?(pokemon.species)
    end

    def rideable?(pokemon = partner)
      oversized?(pokemon)
    end

    def outdoors?(map = (defined?($game_map) ? $game_map : nil))
      return false unless map && map.respond_to?(:map_id) && defined?(GameData::MapMetadata)
      metadata = GameData::MapMetadata.try_get(map.map_id) if GameData::MapMetadata.respond_to?(:try_get)
      !!(metadata && metadata.respond_to?(:outdoor_map) && metadata.outdoor_map)
    end

    # Oversized companions never render in indoor maps. Outdoors, a rideable
    # oversized partner mounts automatically; ordinary partners follow both
    # indoors and outdoors.
    def mode(map = (defined?($game_map) ? $game_map : nil), player = (defined?($player) ? $player : nil))
      current = partner(player)
      return :none unless current
      return outdoors?(map) ? :mounted : :hidden if oversized?(current)
      :following
    end

    def following?(map = (defined?($game_map) ? $game_map : nil), player = (defined?($player) ? $player : nil))
      mode(map, player) == :following
    end

    def mounted?(map = (defined?($game_map) ? $game_map : nil), player = (defined?($player) ? $player : nil))
      mode(map, player) == :mounted
    end

    def hidden?(map = (defined?($game_map) ? $game_map : nil), player = (defined?($player) ? $player : nil))
      mode(map, player) == :hidden
    end

    def status(map = (defined?($game_map) ? $game_map : nil), player = (defined?($player) ? $player : nil))
      current = partner(player)
      {
        :mode => mode(map, player),
        :species => current && current.species,
        :party_index => current && player.party.index(current),
        :outdoors => outdoors?(map)
      }
    end
  end
end
