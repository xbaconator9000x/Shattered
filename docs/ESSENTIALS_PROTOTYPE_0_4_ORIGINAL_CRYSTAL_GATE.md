# Shattered Essentials v0.4 — original Pokémon Crystal reception gate

This supersedes v0.1's cave, v0.2's FRLG one-room hall, and v0.3's oversized new four-way reconstruction.

## Source-grounded map

The gate interior is now reconstructed from the actual Gen II **Pokémon League Reception Gate** source files in `pret/pokecrystal`, not guessed from screenshots:

- `maps/VictoryRoadGate.blk`: 10 × 9 map blocks, 90 bytes.
- `gfx/tilesets/gate.png`: original grayscale graphics.
- `data/tilesets/gate_metatiles.bin`: 64 metatile definitions, 16 original 8-px tiles per block.
- `data/tilesets/gate_collision.asm`: source collision flags per quarter-block.

Original blocks are rendered and adapted into a **20 × 18 RPG Maker XP tilemap**, each native RPG tile being 32 pixels. A new XP `Tilesets.rxdata` entry and `Graphics/Tilesets/JohtoLeagueGate_Crystal.png` preserve graphics and passability. Only the source palette is recoloured. The original reception desk, four corridor entrances, north entrance, and counter geometry are retained.

**This is the original *Pokémon Crystal* reception gate, not an exact extraction of the user's customized Shattered FireRed ROM layout or of the HeartGold/SoulSilver 3D version.**

## Mini-story

- Player spawns inside the southern hall at **(10,14)**. Intro: Twenty Years Later; Tyranitar roar, tremors, Johto route collapses.
- Southern Route 26 entrance blocked by four boulder events at `(8..11,16)`.
- Aipom stand-in `(11,7)`, sets key switch 990; graphic currently Meowth.
- Eastern hall `(18,5)` transfers to **Kanto Route 22 map 16**, gated by switch 990.
- Western hall `(1,5)` leads toward Route 28/Mt. Silver (demo dialogue).
- Northern hall `(9,1)` leads to Victory Road (demo dialogue).
- Original badge officer counter has extra Shattered dialogue.
- Kanto Route 22 and Viridian City existing FRLG map 10 are unchanged relative to the preceding demo.

## Test builds provided to user

- `Shattered_Essentials_v0.4_Original_Johto_Gate_ANDROID_LITE.zip` — **78,118,136 bytes**, 7,597 files; SHA-256 `aefa7642179a77e48722f818f096d1ba2a4407247b30594809fadc17d87c5c71`.
- `Shattered_Essentials_v0.4_Original_Johto_Gate_FULL.zip` — **159,578,449 bytes**, 7,675 files; SHA-256 `c6fa8d1fca79718419cf6fcfaba523e055305cc3f03b2a0c2937e2cf1fc8870e`.
- `Shattered_Essentials_v0.4_Original_Johto_Gate_Source_Kit.zip` — 13,911 bytes; includes source files and rebuild scripts for local private reuse.

## Verified

- Python source tile regeneration; real source block and collision structure loaded.
- Ruby Marshal/RGSS Table map and extra tileset reads.
- 11 events, no coordinate overlaps, walkable new-game spawn.
- Independent passability BFS verifies player access to north, west, east and the key area with south exit blocked.
- Both ZIP archives passed per-member CRC check; checked Game.exe, Game.ini, Map222.rxdata, Tilesets.rxdata and generated tileset image.
- **Not verified:** launch, story logic, battle, saves, or Johto sprite appearance on actual Android JoiPlay/NaviaXP.

All third-party game assets remain outside GitHub source control. Private local testing only.
