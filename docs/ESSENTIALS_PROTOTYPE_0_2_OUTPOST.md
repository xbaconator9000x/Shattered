# Shattered Essentials prototype v0.2: Johto reception outpost

Updated test build assembled privately and linked in the project conversation. This is a separate Essentials v21.1/RPG Maker XP prototype, not an update to the FireRed Shattered ROM.

## Outpost correction
The v0.1 prototype's South Rock Cave was an unsuitable generic cave stand-in. The user clarified the intended start is Shattered's **ruined Johto-Kanto League Reception Gate / Victory Road outpost**.
v0.2 therefore recreates the test opening using the stock **FRLG Indigo Plateau Gate, map 017**, as the visual base for prototype map 222. This hall contains six Pokémon statues, tiled floors, entrances and an indoor checkpoint feeling. Original tile layers are copied unchanged. The test adds a damaged statue inscription, two rubble obstacles and scripted Johto-entry collapse. It is a **condensed approximation**, not a pixel-exact copy of Shattered's custom gate layout with branching corridors/desks.

## Story event layout
- Start (7,9): Twenty Years Later, Tyranitar roar and triple structural impact, damaged entrance, placeholder HUMAN battler.
- South entrance (7,11): Johto blocked; boulders at (6,10) and (8,10).
- Aipom key (9,6), with temporary Meowth character graphic.
- Eastern security door (14,7): key-gated action transfers to **Kanto Route 22 map 16**, at (30,17).
- Route 22: mandatory Rattata battle, then Kanto Viridian City map 10.

## Verification
- The imported starting map's tile Table bytes and tileset ID match the stock FRLG map 017 exactly.
- 7 new outpost events present with unique IDs and valid 20×15 coordinates.
- System starting map and coordinates verified; original Kanto maps remain intact.
- Complete ZIP assembled and passed CRC/integrity check: 7,746 ZIP entries, 160,017,242 bytes compressed; SHA256 `ad64634ae22553c73babdf4648f4e84e19d72bb144f39c3ff4b20f6d9666eb23`.
- Android JoiPlay/NaviaXP execution and event functionality have **not** yet been validated.

## Reproducibility
The source patch kit includes `rebuild_outpost.rb`, a second-stage idempotence-safe copy-and-modify script that takes a v0.1 project as input and produces a separate v0.2 directory. Both the private-test ZIP and patch kit are supplied to the user directly, not committed to GitHub because the full game includes third-party assets.

## Follow-up
Run on Android and record gameplay errors. If an exact recreation of the original Shattered gate is required, inspect an actual outpost screenshot, ROM map export or native Shattered map rather than assuming stock FRLG is identical.
