# Viridian entry / rain / Center native event staging (SE-018)

**Status: implementation under test, NOT yet compiled in Pokémon Essentials v21.1 or played on Android.**

This plugin uses native RMXP event commands and a saved story-state API. It is a deliberately bounded first part of Viridian: an entry guard and Nidoran movement route, entry/arrival triggers, rain on entry and until the first Center entry, and a Center autorun that stops the weather. It does **not** import the walled Viridian tilemap, interiors, doors, NPC art, raids or final escort dialogue.

The **ROM parity reference** Viridian city map is 48×40 with source UUID `5e2cbf0c-2a22-47ac-9205-ccca87172d2e`; entry markers are at (0,17), (0,18) and (0,19). NPC coordinate candidates are validated against `development/demo_parity_reference.json`, but the source-only manifest **does not identify which NPC is the guard or Nidoran**. The operator must inspect the original authorised project and confirm roles, sprite licences, path and map passability before setting `roles_reviewed` and `path_passability_reviewed` to true. The privately inspected original Essentials v0.4 `Data/Map010.rxdata` is **50×40**, SHA-256 `0fc83d0c1d55d9286727fc948759730d23d792b9e34524dbe6669f0076879b25`, with 23 existing events; the Center door is (26,26), and the arrival event is (25,20). The original Route 22 Map016 event ID 4 transfers to **Map010 (25,20)** with facing down (RMXP transfer parameters `[0,10,25,20,2,0]`); the arrival event at that same tile is ID 23. The actual native entry plan must account for that existing event and use an **adjacent, collision-safe player-touch trigger**, never assume a player-touch event fires automatically on the warp landing. **Source ROM NPC coordinates must not be assumed to match native RMXP coordinates.** Do not use the synthetic test fixture coordinates as actual route instructions.

In a separate copy of a legally held Essentials v21.1 project, run `scripts/stage_essentials.py` and then add the Shattered Viridian plugin directory to that **staged** project's `Plugins` directory. Provide locally licensed Guard and Nidoran character sprites in `Graphics/Characters`. The staging tool currently installs Shattered Core only; adding this plugin is an explicit separate step until the unified staging manifest is verified.

Example config **schema illustration only, not a reviewed or installable map plan**:

```json
{
  "schema_version": 1,
  "source_map_uuid": "5e2cbf0c-2a22-47ac-9205-ccca87172d2e",
  "roles_reviewed": false,
  "path_passability_reviewed": false,
  "native_entrance_reviewed": false,
  "native_city_dimensions": [50, 40],
  "city_map_id": 41,
  "center_map_id": 42,
  "center_dimensions": [15, 10],
  "expected_city_sha256": "REPLACE_WITH_64_LOWERCASE_HEX",
  "expected_center_sha256": "REPLACE_WITH_64_LOWERCASE_HEX",
  "guard": {"source_event_id":"3.1:npc:1","source_position":[9,16],"x":9,"y":16,"character":"Guard"},
  "nidoran": {"source_event_id":"3.1:npc:8","source_position":[18,9],"x":18,"y":9,"character":"Nidoran"},
  "guard_path": [[9,16],[10,16]],
  "nidoran_path": [[18,9],[17,9]],
  "entry_source_marker": [0,17],
  "entry_trigger": [2,17],
  "native_warp_landing": [1,17],
  "finish_trigger": [12,16],
  "rain_controller": [3,3],
  "center_trigger": [7,5],
  "switches": {"started":101,"arrived":102,"center":103,"rain":104}
}
```

Replace every illustrative target map ID, event position, route, switch ID, sprite name, SHA and role mapping with values verified against the **actual** imported RMXP project. Trigger positions must be unoccupied, routes must be walkable and must not collide with existing transfer events; the installer now checks native `Data/Tilesets.rxdata` passages for every event and escort-path tile and refuses paths through existing events. These are **static** checks; engine movement and the actual walled map are still unverified. The sample intentionally has false review flags and must not be installed.

Inside the **staged project**, after opening the native engine and compiling plugins, call `pbInstallShatteredViridian("path/to/reviewed-plan.json")` once from the Essentials debug console. It modifies `Data/MapNNN.rxdata` for both maps transactionally and leaves backups on crash for manual recovery. Do not run it on the original. After installation, force script/PBS compilation and verify: rain begins on city entry, guard/Nidoran movement finishes, finish trigger sets arrived, Center entry clears rain, save/reload does not restart the escort, returning to Viridian does not restart rain, and transfer/collision remain correct. **Those real-engine and Android acceptance gates remain open.**

Static test: `ruby tests/test_viridian.rb`. A Ruby fixture passing is not a gameplay pass. No original game assets are committed.
