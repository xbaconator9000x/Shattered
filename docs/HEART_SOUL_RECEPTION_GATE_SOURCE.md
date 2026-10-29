# Heart & Soul Reception Gate as next Shattered Essentials test map

The user's screenshot shows a **failed ChatGPT upload** of a Pokémon Heart & Soul file (attachment still spinning with error toast), not an in-game JoiPlay crash. No ROM upload is required to locate the source map: the publicly accessible open-source Heart & Soul 2.0 decomp contains it directly.

## Exact source found

Repository: `PokemonHnS-Development/pokehns-expansion` (master).

- `data/maps/ReceptionGate_hns/map.json`: map metadata, NPCs, 5 warps, coordinate event.
- `data/maps/ReceptionGate_hns/scripts.inc`: existing officer/guards/Janine scripted events.
- `data/layouts/ReceptionGate_hns/map.bin`: 924-byte layout (22×21 GBA metatiles).
- `data/layouts/ReceptionGate_hns/border.bin`
- `data/layouts/layouts.json`: **LAYOUT_RECEPTION_GATE_HNS**, 22×21, primary tileset `gTileset_Johto_Building_Hns`, secondary `gTileset_PokemonCenter_White_Hns`.
- `data/tilesets/primary/johto_building_hns/tiles.png`, `metatiles.bin`, `metatile_attributes.bin`, and `palettes/`.
- `data/tilesets/secondary/pokemon_center_white_hns/tiles.png`, `metatiles.bin`, `metatile_attributes.bin`, and `palettes/`.

## Source warps

- **South / Route 26:** (11,19), destination `MAP_ROUTE26NORTH_HNS`.
- **North / Victory Road:** (10,1) and (11,1), destination `MAP_VICTORY_ROAD_KANTO_B2F_HNS`.
- **West / Route 28:** (1,9), destination `MAP_ROUTE28_HNS`.
- **East / Kanto Route 22:** (20,9), destination `MAP_ROUTE22_HNS`.

Source NPCs: officer (9,14), Mt Silver guard (7,7), Kanto guard (14,7), Janine (11,6), plus a coordinate trigger (11,14).

This is a better matching **GBA-generation Johto interior** than the Crystal-style v0.4 map. **The HnS map has been located and audited, not yet converted into RPG Maker XP**. Next implement a source-grounded metatile renderer, two-layer RGSS tile/transparency conversion, passages, then overlay Shattered's event pages and test on Android. The graphics retain the upstream source's attribution/license obligations.

## What is already scripted in the v0.4 Essentials project

- Map 222: autorun intro messages; temporary MACHOP level 5 named HUMAN; blocked Route 26 boulders; interact with temporary Aipom (currently Meowth sprite) to set switch 990; east key-gated transfer; north/west demo text; inscription/desk dialogue.
- Map 16: autorun Rattata level 5 battle via `setBattleRule("cannotRun"); setBattleRule("canLose"); WildBattle.start(:RATTATA, 5)`, with a separate transfer to Viridian.
- Map 10: autorun end-of-demo arrival text.
- **Not implemented:** animated tremors and Tyranitar cries, Aipom movement/actual sprite, custom human species/equipment/PP, fortified Viridian exterior, full story.
- **Not verified:** actual game launch or event execution on Android.

## Android overlay workaround (already built and verified)

The full v0.4 game archive is 78 MB (Lite) / 160 MB (Full). A new 294,496-byte ZIP overlay contains **17 changed/new game files** plus install instructions. Applying it over the exact previously supplied `Essentials FRLG V1.1.rar` project reproduces **all 7,674 target game files byte-for-byte**, except the original FRLG update-guide PDF intentionally left unchanged. The overlay's CRC check passes. `SHA256 eee0060fa812747d7cdafe8b0c72e2c9808150400f9216cec9bf0a3780ee0061`.

The actual overlay ZIP is a private ChatGPT conversation attachment, **not checked into GitHub**, because it contains tiles and modified derivative map files. Do not claim this is an Android runtime test.
