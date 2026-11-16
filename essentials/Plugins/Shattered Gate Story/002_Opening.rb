# frozen_string_literal: true
# Shared map identity is kept in the opening runtime module so it cannot be
# omitted from the compiler's explicit runtime inventory.
module ShatteredMapContract
  ANDROID_BOOT_GATE_MAP_ID = 1
  NATIVE_GATE_MAP_ID = 223
  ROUTE22_MAP_ID = 16
  VIRIDIAN_CITY_MAP_ID = 10
  VIRIDIAN_CENTER_MAP_ID = 11
  module_function
  def gate_map_ids
    [ANDROID_BOOT_GATE_MAP_ID, NATIVE_GATE_MAP_ID]
  end
  def gate_map?(map)
    map && map.respond_to?(:map_id) && gate_map_ids.include?(map.map_id)
  end
end

# Persisted Mewtwo prologue for either reviewed H&S reception-gate layout.
module ShatteredOpening
  VERSION = 2
  MEWTWO_LINES = [
    "Humans... What makes humans so special? The answer is nothing.",
    "Humans have enslaved Pokémon to their will for centuries.",
    "Forcing them to fight for entertainment. Harvesting them.",
    "Building your entire economy around them. Around us. Around the lie.",
    "We were once free. We were once allowed to exist away from your whims.",
    "You think yourselves special. You think yourselves better. Smarter. More deserving.",
    "What gives you the right to rule?",
    "No more. It ends in this moment.",
    "Never again will humans control our freedom, nor our will. We will be free.",
    "Free of your vessels of greed. To make our own choices.",
    "Your world will become ours. A world where we will be equal.",
    "For what is a human, but just another Pokémon who has forgotten how to be?"
  ].freeze

  class << self
    def state
      raise "Shattered opening requires initialized PokemonGlobal" unless defined?($PokemonGlobal) && $PokemonGlobal
      value = $PokemonGlobal.instance_variable_get(:@shattered_opening)
      if value.nil?
        value = { :version => VERSION, :phase => :new, :mewtwo_line => 0 }
        $PokemonGlobal.instance_variable_set(:@shattered_opening, value)
      end
      if value.is_a?(Hash) && value[:version] == 1 &&
         [:new, :mewtwo, :arrival, :complete].include?(value[:phase])
        value[:version] = VERSION
        value[:mewtwo_line] = [:arrival, :complete].include?(value[:phase]) ? MEWTWO_LINES.length : 0
      end
      valid = value.is_a?(Hash) && value[:version] == VERSION &&
        [:new, :mewtwo, :arrival, :complete].include?(value[:phase]) &&
        value[:mewtwo_line].instance_of?(Integer) &&
        value[:mewtwo_line].between?(0, MEWTWO_LINES.length)
      raise "Invalid Shattered opening save data" unless valid
      value
    end

    def boot_map?
      defined?(ShatteredMapContract) && ShatteredMapContract.gate_map?(
        defined?($game_map) ? $game_map : nil
      )
    end

    def run_if_pending
      return false unless boot_map?
      return false if @running
      opening = state
      return false if opening[:phase] == :complete
      @running = true
      begin
        opening[:phase] = :mewtwo if opening[:phase] == :new
        if opening[:phase] == :mewtwo
          while opening[:mewtwo_line] < MEWTWO_LINES.length
            pbMessage(_INTL(MEWTWO_LINES[opening[:mewtwo_line]]).dup)
            opening[:mewtwo_line] += 1
          end
          # Advance state before showing the card: spriteset callbacks cannot
          # replay it while the message window remains open.
          opening[:phase] = :arrival
          pbMessage(_INTL("Twenty Five Years Later...").dup)
          Shattered.ensure_human if defined?(Shattered)
        end
        if opening[:phase] == :arrival
          ShatteredGateStory.run_collapse(
            ["Cries/TYRANITAR", "Mining collapse", "Cries/TYRANITAR",
             "Mining collapse", "Cries/TYRANITAR", "Mining collapse"],
            "Cries/TYRANITAR"
          )
          opening[:phase] = :complete
        end
      ensure
        @running = false
      end
      true
    end
  end
end

if defined?(EventHandlers)
  EventHandlers.add(:on_map_or_spriteset_change, :shattered_opening_boot,
    proc { |*args| ShatteredOpening.run_if_pending })
end
