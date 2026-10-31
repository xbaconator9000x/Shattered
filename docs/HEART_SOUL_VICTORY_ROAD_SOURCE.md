# Heart & Soul 2.0 Kanto Victory Road — source-to-RMXP conversion

This is the **HGSS-style Victory Road** adjacent to the League Reception Gate, not
the original v0.4 Crystal-style gate. The three-floor source is pinned to
`PokemonHnS-Development/pokehns-expansion@167aa6d537b109bb229c231ddce4616974c4da71`.

| Source floor | GBA layout | Source warps | Connection |
| --- | --- | --- | --- |
| `VictoryRoadKanto_1F_hns` | 50×30 | 10 | Route 23 / B1F |
| `VictoryRoadKanto_B1F_hns` | 60×30 | 10 | 1F / B2F |
| `VictoryRoadKanto_B2F_hns` | 40×50 | 2 | B1F / Reception Gate |

The pinned source has **22 source warps**. The B2F reception gate exit is
`(30,47)` and the 1F Route 23 exit is `(28,2)`. Source `dest_warp_id`
values are zero-based **source** warp indices, not RPG Maker XP map IDs.

## Actual conversion source

`scripts/audit_hns_victory_road.py` validates source map identifiers,
floor dimensions, out-of-bounds and duplicate warps, destination indices,
return-link topology and external entrances.

`scripts/convert_hns_victory_road.py` consumes the locally held pinned
`data/maps`, `data/layouts/layouts.json` and three binary blockdata files.
It verifies exact source Git blob identities, decodes each 16-bit GBA cell
(10-bit metatile, 2-bit collision, 4-bit elevation), resolves three explicit
RPG Maker XP tile layers, preserves source collision/elevation arrays and
generates a bundle with per-tile passage/priority/terrain tables and all
source warps. It **requires a separately reviewed mapping** for every used
GBA tuple and explicit native landing coordinates for every warp, including
the external Reception Gate and Route 23. It rejects missing or conflicting
tile mappings, wrong floor map IDs, wrong internal landing coordinates,
unrecognized source data and missing warp targets.

Example, using private local files:

```sh
python3 scripts/audit_hns_victory_road.py \
  --maps-dir /private/pokehns-expansion/data/maps \
  --layouts-json /private/pokehns-expansion/data/layouts/layouts.json \
  --output /private/victory_road_warp_audit.json

python3 scripts/convert_hns_victory_road.py \
  --source-root /private/pokehns-expansion \
  --mapping /private/rights-reviewed/victory_road_xp_mapping.json \
  --output /private/victory_road_xp_bundle.json
```

Mapping schema: `floors` maps each source `MAP_VICTORY_ROAD_KANTO_*_HNS`
ID to a unique native `map_id`, `tileset_template_id`, simple
`tileset_name`, matching `tileset_image`, and the 64-character lowercase
SHA-256 `tileset_sha256` of the independently reviewed local PNG. The
converter requires the pin; the native installer hashes the actual private
PNG and refuses substitutions. `entries` follows the
Reception Gate converter's `metatile:collision:elevation` format:
`layers` is exactly three XP tile IDs, and `tables` has exactly three
`{passage, priority, terrain}` records. `warp_targets` maps every
`SOURCE_MAP_ID:zero_based_source_warp_index` to a reviewed
`{map_id, x, y, direction, fade}` native landing.

## Guarded private native import

After converting with a rights-reviewed tile mapping, stage the canonical v0.4
Essentials project in a **new** private folder and install each matching,
rights-cleared 256px-wide XP tileset PNG into its
`Graphics/Tilesets/` directory. Keep `SHATTERED_STAGING_REPORT.json`.
Use the project's actual Essentials v21.1 **debug runtime**, where `RPG::Map`,
`RPG::Event`, `Table`, `load_data` and `save_data` are defined:

```ruby
load "/local/source/scripts/install_hns_victory_road.rb"
ShatteredHNSVictoryRoadInstall.install("/local/private/victory_road_xp_bundle.json")
```

The offline-only importer checks all three pinned source warp records (10+10+2),
unique unoccupied map IDs, existing external destination maps, bounds,
tileset PNG dimensions/capacity, layer/table completeness, source metadata,
and a staging marker before modifying native files. It writes three
`Data/MapNNN.rxdata` files and updates `Tilesets.rxdata` and
`MapInfos.rxdata` in one rollback-protected transaction. It must **not**
be installed as a runtime plugin. The converter additionally requires each
internal landing to be exactly one cardinal tile adjacent to its source
destination warp (not on the transfer event itself), to prevent wrong-floor
teleports and immediate bounce-back. The importer independently rechecks
adjacency and native XP passage flags even if the JSON bundle is edited after
conversion. These are static guards, not a substitute for in-engine playtesting.

Local synthetic RMXP/Marshal regression: `ruby tests/test_hns_victory_road_install.rb`
— 11 tests / 198 assertions passed on 2026-10-31, including simulated
rename failures both before and after mutation. This is **not** an Essentials
launch, a real map import or collision/playability evidence. The user-supplied
game and HnS assets were not committed.

**Unresolved acceptance gates:** no licensed graphics/metatile-to-XP mapping
has been approved, no native three-floor installer has executed, no
Essentials in-engine tileset passability/warp/rock collapse tests have
run, and no Android JoiPlay/NaviaXP playthrough has been performed.
The generated JSON is **not** an executable map. The original source repo
is public but lacks a clear redistribution licence; no source assets,
GBA binaries, map files or Pokémon graphics belong in GitHub.

The next task is to source/verify the rights-cleared XP tileset mapping,
execute this installer against a privately staged native project, and verify
actual warp collision and the north/south/west/east gate playthrough. Do not substitute a
generic cave, invent missing tiles or mark gameplay complete from the
converter's tests.
