# frozen_string_literal: true
# SE-018: saved Viridian escort and weather state, separate from map rendering.
# The installer places native RMXP events; this module does not replace Essentials weather.
module ShatteredViridian
  VERSION = 1

  def self.valid_switch!(id)
    raise ArgumentError, "reserved switch ID required" unless id.instance_of?(Integer) && (1..9999).include?(id)
    raise "Game switches unavailable" unless defined?($game_switches) && $game_switches
    id
  end

  def self.state(store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
    raise "PokemonGlobal save metadata unavailable" unless store
    value = store.instance_variable_get(:@shattered_viridian_entry)
    if value.nil?
      value = { :version => VERSION, :started => false, :arrived => false, :center => false }
      store.instance_variable_set(:@shattered_viridian_entry, value)
    end
    raise "Unknown Viridian save state; refusing to reset story" unless value.is_a?(Hash) &&
      value[:version] == VERSION && [:started, :arrived, :center].all? { |k| [true, false].include?(value[k]) }
    value
  end

  def self.start!(started_switch, rain_switch)
    valid_switch!(started_switch)
    valid_switch!(rain_switch)
    raise ArgumentError, "duplicate Viridian switch IDs" if started_switch == rain_switch
    value = state
    first = !value[:started]
    value[:started] = true
    $game_switches[started_switch] = true
    $game_switches[rain_switch] = !value[:center]
    first
  end

  def self.arrive!(arrived_switch)
    valid_switch!(arrived_switch)
    value = state
    return false unless value[:started]
    first = !value[:arrived]
    value[:arrived] = true
    $game_switches[arrived_switch] = true
    first
  end

  def self.center!(center_switch, rain_switch)
    valid_switch!(center_switch)
    valid_switch!(rain_switch)
    raise ArgumentError, "duplicate Viridian switch IDs" if center_switch == rain_switch
    value = state
    return false unless value[:started]
    first = !value[:center]
    value[:center] = true
    $game_switches[center_switch] = true
    $game_switches[rain_switch] = false
    first
  end

  def self.sync!(switches)
    raise ArgumentError, "invalid Viridian switch map" unless switches.is_a?(Hash) &&
      [:started, :arrived, :center, :rain].all? { |k| switches.key?(k) }
    ids = switches.values
    ids.each { |id| valid_switch!(id) }
    raise ArgumentError, "switch IDs must be distinct" unless ids.uniq.length == 4
    value = state
    $game_switches[switches[:started]] = value[:started]
    $game_switches[switches[:arrived]] = value[:arrived]
    $game_switches[switches[:center]] = value[:center]
    $game_switches[switches[:rain]] = value[:started] && !value[:center]
    value
  end
  # Both New Game map transfers and normal Continue can restore native RMXP
  # event pages from saved switches without running the original event setup.
  # PokemonGlobal is the authoritative persistent story state. Reconcile only
  # on the reviewed Viridian city/Center maps; never create quest state on
  # unrelated maps or while the save object is not ready.
  def self.reconcile_on_map_restore
    return false unless defined?($PokemonGlobal) && $PokemonGlobal &&
      defined?($game_switches) && $game_switches &&
      defined?($game_map) && $game_map &&
      $game_map.respond_to?(:map_id) && [10, 11].include?($game_map.map_id)
    ids = { :started => 993, :arrived => 994, :center => 995, :rain => 996 }
    before = ids.values.map { |id| $game_switches[id] }
    sync!(ids)
    after = ids.values.map { |id| $game_switches[id] }
    if before != after && $game_map.respond_to?(:need_refresh=)
      $game_map.need_refresh = true
    end
    true
  end

  # Called after both nonblocking move routes finish. If either NPC was
  # obstructed, the escort remains retryable rather than marking success.
  def self.complete_route!(guard_id, nidoran_id, guard_start, nidoran_start,
                           guard_end, nidoran_end, started_switch, rain_switch)
    valid_switch!(started_switch)
    valid_switch!(rain_switch)
    return false unless defined?($game_map) && $game_map &&
      $game_map.respond_to?(:events)
    guard = $game_map.events[guard_id]
    nidoran = $game_map.events[nidoran_id]
    return false unless guard && nidoran
    complete = [guard.x, guard.y] == guard_end && [nidoran.x, nidoran.y] == nidoran_end
    unless complete
      guard.moveto(*guard_start) if guard.respond_to?(:moveto)
      nidoran.moveto(*nidoran_start) if nidoran.respond_to?(:moveto)
      return false
    end
    start!(started_switch, rain_switch)
    true
  end

end

# Essentials v21.1 normal Continue restores the saved MapFactory without
# necessarily invoking Game_Map#setup. The spriteset-change hook covers that
# path, while the map-setup hook covers New Game and map transfers.
if defined?(EventHandlers)
  EventHandlers.add(:on_game_map_setup, :shattered_viridian_restore,
    proc { |*args| ShatteredViridian.reconcile_on_map_restore })
  EventHandlers.add(:on_map_or_spriteset_change, :shattered_viridian_continue,
    proc { |*args| ShatteredViridian.reconcile_on_map_restore })
end
