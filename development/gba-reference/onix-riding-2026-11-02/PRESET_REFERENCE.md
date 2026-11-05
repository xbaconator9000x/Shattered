# Onix riding and follower preset — GBA reference, 2 November 2026

This is the exact xx1.06 GBA emulator prototype approved by Wade. It is archived for reuse case by case. It is not an Essentials implementation or a released general riding system.

## Agreed rules for the future system

- Normal-size Pokémon may follow indoors. Larger-than-normal Pokémon stay outside; configure this per species rather than guessing from battle art or canvas padding.
- Size and rideability are independent. Add rideable species individually as they are approved; no final accessible-species roster has been selected.
- An appropriate active outdoor companion automatically carries the player; input, camera and interactions continue through the normal player controller.
- Onix carries the player on its head at ordinary walking speed. Dismount before entering a door. Larger companions return outside (return/remount behaviour is still to implement).
- Per-species configuration should include display size, indoor-follow permission, rideability, directional seat anchors/occlusion, movement speed and terrain support.
- Party capacity is the player character (HUMAN) plus at most one Pokémon partner. HUMAN may occupy either party position; never infer partner identity from slot index. The sole non-HUMAN Pokémon is the active partner, regardless of its order. Recruitment while a partner is present must be refused or routed through an explicit safe swap; never silently discard the existing partner. A swap must be refused if it would strand the player on terrain the replacement cannot traverse. These restrictions are not implemented by this visual prototype.
- The active partner is out of its Poké Ball by default. A normal-size Pokémon may follow indoors. An oversized Pokémon remains hidden indoors. Outdoors, an oversized partner explicitly tagged rideable carries the player automatically, using that species' speed and seat anchors. An oversized partner without rideability follows outside on foot. Door transitions dismount before the native warp; outdoors return should restore riding when still eligible. Other Pokémon in storage are not followers.

## Party data check (6 November 2026)

In the available xx1.06 emulator states, the native party array at 0x02024284 has HUMAN in the first 100-byte record and, after the debug Give Pokémon action, a second occupied record at +100. The byte at 0x02024029 reads 1 both before and after the added Pokémon. It is therefore **not** a proven total party occupancy counter and must not be used alone to enforce the one-partner cap. These states do not test swapped order; the runtime must distinguish HUMAN by its species identity after decrypting/reading Pokémon data, then count all non-HUMAN members through the game's own accessor. This observation is diagnostic only; no ROM enforcement was installed.

## Exactly what the prototype does

The real-player revision calls the ROM’s native MixedAvatar renderer at 0x08B19215. It copies the selected avatar’s complete 16-colour palette and directional pixels, retaining rows 0–25 exactly (east mirrors west). Only rows 26–31 become simplified seated knees/boots using native garment colours. A foreground Onix horn mask supplies the overlap. The rider is not an AI-generated person.

Onix is an approved redraw, not a nearest-neighbour enlargement of the tiny original. The saved Onix-only source, conversion script, final native 4bpp data and palette are in the source archive. AI editing removed placeholder riders and restored the crown; Prompt.txt records this. Original reference: rh-hideout/pokeemerald-expansion graphics/pokemon/onix/overworld.png. Native player art: Shattered’s Coffee Cup / Poltergeist avatar system.

Rendering uses separate native 64×64 Onix and 32×32 rider sprites. Onix OBJ tiles 768–831, rider tiles 832–847; palettes 14 and 15, respectively. Rider palette follows the normal player’s actual field tint. Dedicated tiles avoid the original corruption/overlap. The normal player controller/callback remains responsible for movement and camera; its redundant visible sprite is suppressed using OBJ-window mode. No movement speed/action values are changed. Only lower Onix rocks sway.

Directional anchors in source order: seatX={24,27,30,34}, seatY={18,19,22,22}, bodySeatX={16,16,14,17}. These are Onix-specific, not universal offsets for other species.

Door detection reads the actual map-group table at 0x0836FC9C, checks current/next tiles against warp entries and identifies destination map type 8 (indoors). Dismount restores native player rendering and frees the temporary sprite/task/heap resources before the native warp. A hook at ROM offset 0x1094E18 wraps the existing follower callback, preserving its displaced prologue and PC-relative literal through object_trampoline.s. Indoors it hides follower local ID 250 with both the invisible flag and OBJ-window mode. The invisible flag alone failed because later native follower logic unhides it. The global normal-player callback hook was tested and discarded; it is not in this final patch.

**Important limitation:** the prototype indoor guard currently hides every companion. The agreed normal-size indoor exception is future work, as are automatic return/remount, party restrictions, water travel and per-species configuration. Appearance is captured at mount time; live wardrobe changes and dedicated seated poses for every long coat are not implemented. Do not copy hardcoded addresses into another ROM revision without resolving symbols and verifying original bytes.

## Reproduce the saved build

1. Extract Onix_Riding_Prototype_Source.zip into a working folder named real-rider at the workspace root. It includes source, compiled ELF/bin, allocations, graphics, BPS patch, native emulator adapter, capture scripts, screenshots and validation JSON.
2. Supply the exact xx1.06 base ROM, SHA256 63e55e9907b02ef11ceec880fcb3a1305bbde29be4aac6047fad3c0d20b22685. The archive’s BPS is the shortest route to the exact test ROM. It contains no full ROM or user save.
3. To compile instead: provide ARM GCC 13.2.1 / binutils under native-toolchain/usr/bin, run sh real-rider/build.sh from the workspace root, and set SHATTERED_BASE if the base differs from the default recovered/xx1.06_Pokemon_Shattered_Character_UI.gba path. build.sh/link.ld compile Thumb ARM7TDMI freestanding code at 0x08B9BEE0. install.py checks the original callback bytes, uses fixed owned allocations and updates alloc.json.
4. Final native code size: 2,136 bytes within the reserved 4,096-byte region. Exact patched ROM SHA256: 4f5ce5fbd6f937b28189b6bf04904774dd5e83b7f8cdb46a257a2cf6d6836b95.
5. Riding is activated by an emulator native call to StartMount (alloc.json entry), not by normal gameplay automatically. The capture adapter requires the separately supplied mGBA emulator_bridge runtime. Existing capture scripts also expect local field savestates; these are test prerequisites, not included user saves. Regenerate mounted states after a rebuild because task/entry addresses can move.
6. For the door recording, start outdoors at map 3.1, x25,y14, enable the follower (var 0x40DC=1), call StartMount and save door-start.state. record_door.py uses normal UP input for 180 frames, then releases and walks inside. Clover entrance is x25,y11 → map 5.0; indoor native movement is (4,7) → (4,5). The initial two idle frames refresh the rendered state before recording.

## Evidence and caveats

Door_Validation.json confirms actual mGBA capture, native direction input only, dismount while still outdoors, native map transition, visible on-foot player, hidden indoor follower and successful indoor movement. Onix_Door_Transition_Test.gif is the exact delivered recording. Rider_Pixel_Validation.json verifies 3,328 unchanged native upper-body pixels and the native palette. Other archived walking checks verify sprite tile/palette integrity; they record transient hardware-frame timing differences rather than claiming frame-perfect speed equivalence. Pixel validation and original walking checks precede the door-hook revision; door validation is the final revision’s targeted check.

The archive is a frozen reference. Future work should implement identity-based partner selection and one-partner enforcement across recruitment, deposit/withdrawal and swaps; a per-species size/rideability table; normal-size indoor followers; safe large-companion recall/return; persistent activation; and full transition testing before release.

Acceptance cases: [HUMAN, Vulpix] and [Vulpix, HUMAN] both select Vulpix; a second non-HUMAN cannot join the party; a small partner remains visible indoors; a large non-rideable partner follows outdoors and hides indoors; a large rideable partner mounts outdoors, dismounts before entering, hides indoors, and remounts upon returning outside when safe. No test should infer HUMAN by name or fixed index. Do not confuse this GBA reference with the parallel Essentials remake.
