# Shattered RPG Maker XP / Pokémon Essentials v21.1 — full demo remake

**Status:** development specification, NOT a statement that features are already implemented.  
**Product:** one coherently integrated, playable and saveable remake of the Shattered demo in RPG Maker XP / Pokémon Essentials **v21.1**. Android playback through JoiPlay/NaviaXP is a release acceptance target. The original FireRed ROM hack and Essentials Studio Mobile remain distinct projects.

## Non-negotiable definition of "fully integrated"
The result must be **one reproducible game project**, not disconnected test plugins or an editor mockup:
- A pinned, owned base Essentials v21.1 project + a deterministic installer/patch pipeline + a bill of installed, versioned plugins + generated build manifest.
- Maps, events, NPCs, battles, artwork, audio, quest flags, player graphics, followers, PBS, UI and save data function together, with no prototype placeholders pretending to be finished features.
- Validate installation and script/PBS compilation in native Essentials, **then** run the complete scene on Android; Android APK compilation of an editor is not proof the RPG works.
- Publish only distributable outputs with rights verified. Keep third-party archives, Pokémon game assets and the user's supplied game/ROM projects out of public source control. Preserve the original files. Provide a build recipe that consumes legally held assets locally.

## Ground truth and reference
1. The currently playable **v0.4 Essentials proof of concept** establishes baseline mobile boot, but does **not** implement the full Shattered demo, battle system or final map. Its initial map used an older Crystal-style reception-gate layout.
2. Opening world layout should use the correct **Heart & Soul 2.0 Johto League Reception Gate** rather than a generic cave. The previously identified source in `PokemonHnS-Development/pokehns-expansion` is `data/maps/ReceptionGate_hns/map.json` and `data/layouts/ReceptionGate_hns/map.bin`, 22×21 tiles. The reception gate has Route 28 (west), Route 22 (east), Route 26/Johto (south), Victory Road (north). Source art/maps must be reviewed for permission/credits before redistribution.
3. The original user's FireRed Shattered demo, its design history and their project files are the **content reference**. First create a traceable scene/quest manifest comparing original content to the Essentials remake; mark any unexamined feature as unverified. Do not assume v0.4 already contains it.

## End-to-end demo acceptance: exact gameplay path

**A. Johto / reception gate**
- Correct layered tiles, collision, directional entrances and warps, map connections and appropriate player sprites; gate visually matches the authorised HnS reference once licensed.
- Opening establishes Poké Ball failure / Shattered premise as designed. At the gate, 3 initial tremors/roars and impacts followed by rock collapse block the route to Johto; later 3 additional rumbles/impacts and final roar. Timing, sound, flashes, rocks, blocker permanence and event flags survive save/reload.
- Aipom with the shiny gate key: clue, visible held key, north-facing animation/cry, exclamation, approach/bonding/key acquisition and unique event state. The key works as an item, not a wrongly labelled TM. Distinct messages for blocked Johto exit and debris.
- West Route 28, north Victory Road and east Route 22 transitions are mapped accurately or intentionally gated in the demo. Hidden Poké Ball, Rare Candy and bandage follow intended location/behaviour.

**B. Route 22 / Viridian entry**
- Route 22 triggers a mandatory level-5 Rattata encounter: group scatters, one attacks. The human participates correctly from the first real battle.
- Route-to-Viridian mapping is connected and saves warp positions. Walled Viridian, guard/Nidoran escort, controlled weather and rain audio until the Pokémon Center entry; appropriate house doors, stairs, collision and no frozen NPCs.
- Test that scripted scenes cannot recur incorrectly or become softlocks on interruption/save/reload.

**C. Viridian quest/demo content**
- Beedrill chase/raid with non-stacking enemies, distinct doors/windows/threats, an NPC fleeing into the Center after rescue and sensible dialog timing.
- Murkrow west rescue, Order of Beedrill spawns, dojo/battle tutorial, friendship bond introduction; choose Vulpix/Staryu/Exeggcute based on the intended questionnaire and actual companion recruitment (not a Poké Ball).
- Include demo-accessible side activities/locations from the reference: bunks/guard/kitchen/farm, crops, healing, relevant interactions and quest states. Record any scene beyond the reference demo as future scope rather than falsely marking it remade.

**D. Core playable mechanics, not event-only facades**
- HUMAN is an actual supported in-battle party entity; tested name, sprite, HP, damage, speed, attacks, equipment and save persistence. No substitute Machop named HUMAN.
- Human matchups: immune Fairy/Ghost/Dragon; resist Dark/Psychic/Bug; weak Fire/Ice/Electric/Poison/Steel/Rock/Fighting; exactly one battle-level effectiveness implementation, validated against engine and DBK hooks. Human has high HP/Speed and low SpA, per balance spec.
- Shared HUMAN technique/stamina pool starts around 60, techniques cost 1–5; pool is debited **once per successful use**, disallows unaffordable moves, persists in save, restores at healing, scales with level. Pokémon companions retain their normal per-move PP.
- Poké Ball captures cannot work. Befriending recruits Pokémon with the correct follower/party semantics and stable ownership. Throw/flee/menu behaviour must not leave the state invalid.
- Equip head, torso, left hand, right hand, legs, feet; example gear grants Slash/Ember/Rock Throw/Bubble/Defense Curl with native move information and usable UI, not just stored item tags. Specialisations at levels 30/55 and eventual regional forms need explicit rollout/testing; do not claim full implementation solely from the demo milestone.
- Party/follower, trainer sprites and menu render without colour/palette corruption, freezes, follower gaps, gender mismatch or offscreen event bugs.

**E. Real integration and release evidence**
- Unmodified input project preserved, verified asset source/rights and plugin dependency/override ledger (Hotfixes → DBK → Enhanced UI; followers and quests independently; **Feral Tank optional until compatibility proven**).
- Unit and integration tests: battle stamina/no capture, HUMAN species/type, quest/event save flags, map layers/collision/warps, recruitment/follower, plugin load order, serialization and failure injection.
- Playthrough: clean new game → gate collapse/Aipom key → Route 22 Rattata → Viridian escort/center → rescue/dojo/starter → save → close → reopen → continue. Repeat on supported Android runner with screenshot/log/crash evidence. A synthetic CI test is *not* a user-device acceptance.
- Verify graphics, timing, BGM/cry/weather audio and save integrity before release. No public download marked "fully working" until all mandatory gates pass.

## Implementation waves and dependencies

| Wave | Scope | Main queue | Acceptance evidence |
|---|---|---|---|
| 0 | Baseline project, rights/source manifest, plugin API/version audits, reproducible safe staging | SE-002/003/004/005 | Clean compilation and versioned patch on authorised assets |
| 1 | Exact HnS reception map and scripted gate/Aipom demo; Route 22 and Viridian connection | SE-013 + new demo scene tasks | Map/event/warp fixtures plus actual in-engine scene |
| 2 | HUMAN battle/stamina/type/equipment basics, no capture and befriending; battle UI + followers | SE-006/007/009/011/012 | Executed battle and save/restore tests |
| 3 | Viridian rescue, tutorial, starters, quest system, weather and visuals | SE-008 + demo quest tasks | Full scripted playthrough with flags and follower |
| 4 | Combined engine/plugin regression, editor export integration, Android release gate | SE-014 + final acceptance | Real full project, desktop reopen and Android playthrough |

**Parallelism rule:** source-rights audit, map conversion and editor interoperability can run independently; **do not** gate HUMAN combat on optional Feral Tank. Never create concurrent Copilot tasks editing the same queue/plugin Ruby files. After a Copilot PR exists, review/merge or close it before assigning overlapping work.

## Copilot usage policy
- Use Copilot on bounded implementation blockers with concrete code/tests and a reviewable PR, rather than generic "continue until done" prompts.
- **Current Shattered Copilot ownership:** SE-002 plugin manifest PR #6; avoid parallel assignments to that code while active.
- Primary objective is a functional RPG; allocate cloud agent time to Essentials Studio Mobile when the safe project import/edit/export pipeline blocks actual game authoring. Keep routine queue updates, deterministic checks and documentation in GitHub scripts, not premium agent sessions.
- Enforce billing safeguards; assigning Copilot is explicitly permissioned work, not permission to enable paid overages, external paid APIs or unattended unlimited sessions.
- Completion claims require actual evidence, not confident prose.
