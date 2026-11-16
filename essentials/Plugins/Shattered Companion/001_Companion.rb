# frozen_string_literal: true
#
# Single-partner selection contract for Shattered. Rendering/movement adapters
# consume this module; the source of truth is always the current party order,
# never a cached event ID or a hard-coded party slot.
module ShatteredCompanion
  RIDEABLE_OVERSIZED = [:ONIX, :CRYSTALONIX, :CRYSTALIX, :BULLGRUM].freeze
  FOLLOWER_NAME = "SHATTERED_COMPANION".freeze
  # This ID belongs only to the transient event handed to Essentials' native
  # follower factory. It is deliberately well outside ordinary RMXP event IDs,
  # and is never inserted into $game_map.events.
  FOLLOWER_EVENT_ID = 9_001

  class << self
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

    # Use only genuine character sheets already installed in the project.
    # A missing sheet means "do not render", never "borrow a random sprite".
    def character_name(pokemon = partner)
      return nil unless pokemon && pokemon.respond_to?(:species)
      species = pokemon.species.to_s.split("_").map { |part| part.capitalize }.join
      candidate = "POKEMON_#{species}"
      character_sheet_exists?(candidate) ? candidate : nil
    end

    def character_sheet_exists?(name)
      return false unless name && !name.empty?
      File.file?(File.join("Graphics", "Characters", "#{name}.png"))
    end

    # Essentials already provides pathfinding, map transfer and save recovery
    # for Game_Follower. This adapter only supplies/removes its source event.
    # It is idempotent so both transfer and Continue callbacks are safe.
    def reconcile_runtime(map = (defined?($game_map) ? $game_map : nil),
                          player = (defined?($player) ? $player : nil))
      return false unless follower_runtime_ready?(map)
      desired_mode = mode(map, player)
      sheet = desired_mode == :following ? character_name(partner(player)) : nil
      current = runtime_follower
      if !sheet
        remove_runtime_follower if current
        return desired_mode
      end
      if current && current.respond_to?(:character_name) && current.character_name != sheet
        remove_runtime_follower
        current = nil
      end
      create_runtime_follower(sheet, map) unless current
      :following
    rescue StandardError
      # A missing imported sheet or bad saved follower must not crash map load.
      false
    end

    def runtime_follower
      return nil unless defined?($game_temp) && $game_temp && $game_temp.respond_to?(:followers)
      followers = $game_temp.followers
      return nil unless followers && followers.respond_to?(:get_follower_by_name)
      followers.get_follower_by_name(FOLLOWER_NAME)
    end

    def remove_runtime_follower
      return false unless defined?($game_temp) && $game_temp && $game_temp.respond_to?(:followers)
      followers = $game_temp.followers
      return false unless followers && followers.respond_to?(:remove_follower_by_name)
      followers.remove_follower_by_name(FOLLOWER_NAME)
      true
    end

    private

    def follower_runtime_ready?(map)
      map && map.respond_to?(:map_id) && defined?($game_player) && $game_player &&
        defined?($game_temp) && $game_temp && $game_temp.respond_to?(:followers) &&
        defined?(RPG::Event) && defined?(Game_Event)
    end

    def create_runtime_follower(sheet, map)
      return false if map.respond_to?(:events) && map.events && map.events.key?(FOLLOWER_EVENT_ID)
      source = RPG::Event.new($game_player.x, $game_player.y)
      source.id = FOLLOWER_EVENT_ID
      source.name = FOLLOWER_NAME
      page = source.pages[0]
      page.through = true
      page.graphic.character_name = sheet
      event = Game_Event.new(map.map_id, source, map)
      $game_temp.followers.add_follower(event, FOLLOWER_NAME)
      true
    end
  end
end

# Native map setup covers transfers and spriteset recreation covers Continue.
# Both routes are no-ops until a genuine character sheet is installed.
if defined?(EventHandlers)
  EventHandlers.add(:on_game_map_setup, :shattered_companion_map_setup,
    proc { |*args| ShatteredCompanion.reconcile_runtime })
  EventHandlers.add(:on_map_or_spriteset_change, :shattered_companion_continue,
    proc { |*args| ShatteredCompanion.reconcile_runtime })
  # Party changes can occur away from a transfer (captures, storage and scripts).
  # Reconcile on the next native step so an old field follower never lingers.
  EventHandlers.add(:on_player_step_taken, :shattered_companion_party_refresh,
    proc { |*args| ShatteredCompanion.reconcile_runtime })
end
