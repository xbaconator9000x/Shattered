# Heart & Soul League Reception Gate source and conversion

## Source review and rights

The examined source is the public `PokemonHnS-Development/pokehns-expansion`
repository (the README identifies it as Pokémon Heart and Soul 2.0) at revision
`167aa6d537b109bb229c231ddce4616974c4da71`. Its README describes the project as
open source and asks downstream users to credit Pokémon Heart and Soul and
retain upstream credits, but the inspected repository root has no `LICENSE`
file or explicit license grant. Public visibility and that README are not
enough to confirm redistribution rights. Therefore this repository includes
no upstream map binary, graphics, palette files, or Pokémon game assets. Obtain
permission or establish applicable rights before distributing those assets.

The source metadata is recorded for reproducibility:

| File | Git blob SHA-1 | SHA-256 |
|---|---|---|
| `data/maps/ReceptionGate_hns/map.json` | `8651cb350a508181bfd7b69fc216696cb67c6829` | `98a04926dd4ae012bb0ea0abe4653cfc060797496dd119a04cffbd8ce38618ab` |
| `data/layouts/layouts.json` | `a3c3be1b411b1dca5a81494c7e2d4ef100b1e75d` | `3b548d055a81dbffb2348d3435077006e8b46aa19df1f2bd5798df218fba5ea3` |
| `data/layouts/ReceptionGate_hns/map.bin` | `bb1affeda8bedc75358a7c72813a7e7c6db0c660` | `121ddb32e6327f14469b7d7168900c2ee131bb822cccc0cb0139d5fd4168f3a7` |

The map uses layout `LAYOUT_RECEPTION_GATE_HNS`, dimensions **22×21**, primary
tileset `gTileset_Johto_Building_Hns`, and secondary tileset
`gTileset_PokemonCenter_White_Hns`. The primary tileset metadata includes
`metatiles.bin`, `metatile_attributes.bin`, `tiles.png`, and palettes
`00.pal`–`15.pal` under `data/tilesets/primary/johto_building_hns`. The
secondary tileset has palette files `00.pal`–`12.pal` under
`data/tilesets/secondary/pokemon_center_white_hns`. Palette assignments are
not named by the map/layout records; the converter does not copy or infer
them. The 924-byte blockdata is 462 little-endian 16-bit cells.
Each cell is decoded as a 10-bit metatile index, 2-bit collision value, and
4-bit elevation value.

## Named source exits

Coordinates are zero-based `(x, y)` map cells:

| Direction | Source position(s) | Source destination |
|---|---|---|
| West | `(1, 9)` | `MAP_ROUTE28_HNS` (Route 28) |
| East | `(20, 9)` | `MAP_ROUTE22_HNS` (Route 22) |
| South | `(11, 19)` | `MAP_ROUTE26NORTH_HNS` (Route 26) |
| North | `(10, 1)`, `(11, 1)` | `MAP_VICTORY_ROAD_KANTO_B2F_HNS` (Victory Road) |

## Reproducible conversion and staging

Use locally obtained source files at the revision above and a separately
prepared, rights-cleared RPG Maker XP tileset PNG (256 pixels wide, height a
multiple of 32). The mapping JSON must provide each used
`metatile:collision:elevation` tuple, three XP tile IDs, each layer's
passage/priority/terrain table values, destination Essentials map IDs and
coordinates, and an unused target map ID plus an existing tileset template ID.
Colliding XP tile IDs with inconsistent table values are rejected. XP autotile
IDs are not supported by this bundle; use normal tile IDs (384+) or blank tile
0. The output map data is three native XP layers at 22×21 cells.

```sh
python3 scripts/convert_hns_reception_gate.py \
  --map-json /local/hns/data/maps/ReceptionGate_hns/map.json \
  --layouts-json /local/hns/data/layouts/layouts.json \
  --map-bin /local/hns/data/layouts/ReceptionGate_hns/map.bin \
  --inspect-only

python3 scripts/convert_hns_reception_gate.py \
  --map-json /local/hns/data/maps/ReceptionGate_hns/map.json \
  --layouts-json /local/hns/data/layouts/layouts.json \
  --map-bin /local/hns/data/layouts/ReceptionGate_hns/map.bin \
  --mapping /local/rights-cleared/reception_gate_mapping.json \
  --output /local/staging/reception_gate.json

python3 scripts/stage_essentials.py \
  --project /local/clean-essentials-v21.1 \
  --output /local/staging/shattered-gate \
  --gate-data /local/staging/reception_gate.json \
  --gate-tileset-image /local/rights-cleared/reception_gate_tiles.png
```

The inspection output lists every `metatile:collision:elevation` mapping key
used by the source blockdata.

Staging copies the project to a fresh output and adds the import bundle, plugin,
and supplied tileset image; it does not change the input project. In a compiled
Essentials v21.1 debug project, call
`pbInstallShatteredHNSReceptionGate` once to serialize the new `RPG::Map`,
three-layer `Table`, cloned `RPG::Tileset` passage/priority/terrain Tables,
`RPG::MapInfo`, and five transfer events (two adjacent north cells). The import
routine rejects occupied map IDs, missing tileset templates/images, and
missing/out-of-bounds destination maps.

## Acceptance status and limits

The converter and synthetic fixture tests verify source geometry, the 16-bit
cell decoding, three target layers, table consistency, and named warp
positions. The actual source blockdata uses 46 distinct
`metatile:collision:elevation` mapping keys. The converter does not parse the
GBA tileset graphics/metatile-attribute binaries, convert source palettes or
animations, or generate a visual XP tilesheet. Those inputs need an authorized,
reviewed external mapping and rights-cleared PNG. No licensed tileset mapping,
compiled Essentials project, in-engine collision/warp
playthrough, save/reopen, or JoiPlay/NaviaXP run is included here. Therefore
this is a verifiable converter and staging path, not evidence that the final
gate is visually faithful or runtime-accepted.
