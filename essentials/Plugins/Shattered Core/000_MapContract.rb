# frozen_string_literal: true
# Shared native/Android map identity contract for the H&S reception gate.
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
