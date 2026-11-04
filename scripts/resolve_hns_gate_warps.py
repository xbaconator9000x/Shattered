"""Resolve source-indexed Reception Gate transfers without collapsing twin north exits.

Source warp order is the pinned HnS map.json warp_events order. A destination-
only lookup is ambiguous for the two distinct Victory Road north doors.
"""
from collections import Counter


MAP_ID = "MAP_RECEPTION_GATE_HNS"


def resolve_warp_targets(warps, mapping):
    if not isinstance(warps, list) or not warps:
        raise ValueError("source Reception Gate warps must be a nonempty list")
    if not isinstance(mapping, dict):
        raise ValueError("gate mapping must be an object")
    defaults = mapping.get("destinations", {})
    overrides = mapping.get("warp_targets", {})
    if not isinstance(defaults, dict) or not isinstance(overrides, dict):
        raise ValueError("destinations and warp_targets must be objects")
    keys = {f"{MAP_ID}:{i}" for i in range(len(warps))}
    unknown = set(overrides) - keys
    if unknown:
        raise ValueError(f"unknown Reception Gate warp_targets keys: {sorted(unknown)}")
    counts = Counter(warp["source_destination"] for warp in warps)
    if set(defaults) - set(counts):
        raise ValueError("destinations contains an unknown Reception Gate destination")

    resolved = []
    duplicate_landings = {}
    for index, warp in enumerate(warps):
        source = warp["source_destination"]
        key = f"{MAP_ID}:{index}"
        if counts[source] > 1 and key not in overrides:
            raise ValueError(f"{key}: repeated source destination requires explicit per-warp landing")
        target = overrides.get(key, defaults.get(source))
        if not isinstance(target, dict):
            raise ValueError(f"{key}: missing reviewed target destination")
        for field in ("map_id", "x", "y"):
            value = target.get(field)
            minimum = 1 if field == "map_id" else 0
            if type(value) is not int or not minimum <= value <= 999_999:
                raise ValueError(f"{key}: invalid target {field}")
        direction = target.get("direction", 0)
        fade = target.get("fade", 0)
        if type(direction) is not int or direction not in (0, 2, 4, 6, 8):
            raise ValueError(f"{key}: invalid target direction")
        if type(fade) is not int or fade not in (0, 1):
            raise ValueError(f"{key}: invalid target fade")
        normalized = {"map_id": target["map_id"], "x": target["x"],
                      "y": target["y"], "direction": direction, "fade": fade}
        if counts[source] > 1:
            previous = duplicate_landings.setdefault(source, [])
            if previous and any(p["map_id"] != normalized["map_id"] for p in previous):
                raise ValueError(f"{key}: repeated source exits disagree on destination map")
            if any((p["x"], p["y"]) == (normalized["x"], normalized["y"]) for p in previous):
                raise ValueError(f"{key}: distinct source exits collapse onto one landing")
            previous.append(normalized)
        resolved.append(normalized)
    return resolved
