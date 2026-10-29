# Shattered Essentials v0.3 — full Johto-style reception gate

**Replaces the shortened FireRed gate used in v0.2.** The requested setting is the **full four-way Pokémon League Reception Gate** found in Pokémon Gold/Silver/Crystal and HeartGold/SoulSilver. The supplied Remastered Kanto Johto pack does not include the actual reception-gate map, so the prototype instead constructs a full 38 × 32 RPG Maker XP map using the existing FRLG tileset and League statues. **This is structurally faithful to the four-way junction, but NOT a pixel-for-pixel import of the original Johto or Shattered ROM map.**

## Directions retained
- **North**: Victory Road (demonstration dialogue, not an active transfer).
- **South**: Johto via Route 26 (rock collapse in the opening).
- **West**: Route 28/Mt. Silver (visible passage, demonstration dialogue).
- **East**: Kanto Route 22 (key-gated transfer to existing FRLG map 16), then Viridian City (existing FRLG map 10).

## Test build
Source folder assembled from uploaded FRLG project and earlier private prototype v0.2. Data/Map222.rxdata is now a 38 × 32 × 3 RPG Maker XP Table with 10 new events; original FRLG Tilesets.rxdata and source Kanto destination maps are retained. The HUMAN and Aipom graphics remain provisional.

Files delivered in conversation:
- **Android Lite** `Shattered_Essentials_v0.3_Full_Johto_Gate_Android_Lite.zip`: 78,116,909 bytes, 7,596 files, SHA-256 `444d02bd21a294c21321526bab1415bdacf363a015ce2e5c096dc8d25e0f3a28`
- **Full** `Shattered_Essentials_v0.3_Full_Johto_Gate_Full.zip`: 159,577,222 bytes, 7,674 files, SHA-256 `3005b9e933974a87840095cdd090de7e4bf910b69cf5ae2ed394dd2bab15c1c3`

## Validation
- The original FRLG reception tileset ID remains assigned; the new map data has correct Ruby Marshal/RGSS Table binary dimensions.
- 10 event IDs and event coordinates checked, no overlaps.
- Player starts at (18,26). Tile-passability BFS verifies access to north, west, east, and the key location.
- Four source orientations are present, and game archive ZIP CRC/integrity checks pass.
- **Unverified:** actual on-device JoiPlay or NaviaXP boot, scripted events, and fight/save behavior.

## Important source limitation
The public source map of Pokémon League Reception Gate is a four-way junction with Victory Road north, Route 22 east, Route 28 west, Route 26 south. The supplied user map pack omitted this building. The 38 × 32 representation is a new reconstruction, **not the exact normal Johto original**, and should be swapped for the original if an editable asset becomes available. Do not describe it as an exact import.

Third-party game content is excluded from the private GitHub source repository and is only supplied for private local testing.
