# Shattered Murkrow Rescue — Essentials v21.1

This plugin adds a save-backed rescue event and an isolated RPG Maker XP map
installer. It does not import a map, guess an Essentials map ID, or install
itself into a staged game.

## Source reference and open location review

The source-only parity index proposed in [PR #12](https://github.com/xbaconator9000x/Shattered/pull/12),
`development/demo_parity_reference.json`, identifies **ROUTE 22 · 28.5**
(`491b8085-ec13-440e-9800-335edda8b08d`, 67×36) as the Murkrow-rescue
reference. Its recorded anchors are `28.5:npc:1` at (51,16),
`28.5:npc:2` at (50,16), `28.5:npc:3` at (52,15), `28.5:npc:4` at
(52,17), and triggers at (53,15), (53,17), and (54,16).

Those are source-map coordinates, **not** an approved Essentials placement.
The index labels the scene `source_reference_only`; it does not identify which
NPC is Murkrow, the other actors' roles, walkability, a converted target map,
or the destination warp. No reviewed location plan was supplied with this
task. Installation therefore fails closed until a local reviewer confirms
the source role, target map/position, sprite, passability, event ID, and
destination warp. Do not treat the synthetic test fixture as an approved plan.

This plugin contains only new Shattered code. It does not copy source-game
scripts/dialogue, ROM data, music, graphics, or third-party assets. Provide a
locally held, distributable Murkrow character graphic and verify its rights
before staging it.

## Private Murkrow overworld artwork found (not distributed)

The HnS source tree includes `graphics/pokemon/murkrow/overworld.png`
(Git blob `1b72d9093076ba6e750d7773d8ec0aa9eb5a80dc`, source SHA-256
`d518d65f407c960086a1bae9120361e653cd7912a41632ffc84ad64f618f43fd`).
A 128×128 four-direction RMXP sheet was converted into a **private local**
asset workspace, output SHA-256
`8c0edf25aa451dd9bf8e91c37d7a0044ec075866c63645a97ab7c1de61e2d5d8`.
It is **not** included in this PR or repository. The upstream repository has
no confirmed redistribution license, and the converted sheet has not been
played or animated in Essentials. Keep the asset local pending rights review.

## Quest behavior

`ShatteredMurkrowRescue` stores discovery, battle, recruitment, reward, and
completion flags on the existing saved `$PokemonGlobal` object. Loss, flee,
or a raised battle/cutscene error returns the event to a retryable state. A
won battle leaves befriending available without replaying the encounter.
Recruitment checks the party before calling `Shattered.befriend`, so retries
do not add a second Murkrow. A full party or unavailable reward delivery
leaves the remaining step retryable.

Shattered Core v0.2.3 provides the `befriend` API and lifecycle/battle hooks.
The rescue still checks for an existing Murkrow before recruitment and
refuses duplicate quest-specific additions.
The event plan selects only the Essentials `WildBattle.start_core` or
`TrainerBattle.start_core` entry point; the selected helper and arguments must be verified
against the staged v21.1 project. The original v0.4 Essentials v21.1 `Overworld_BattleStarting` script defines these numeric-returning core entry points; the legacy `pbWildBattle` and `pbTrainerBattle` helpers are not defined. Only outcome `1` counts as victory: loss (`2`), escape (`3`), capture (`4`), draw (`5`) and abort (`0`) must remain retryable. Wild rescue requires `:MURKROW` and a reviewed level. For `WildBattle.start_core`, the rescue explicitly
requires and applies Essentials' `setBattleRule("disablePokeBalls")` before
battle; missing rules abort the encounter without marking it complete.
No native battle integration is claimed merely because the Ruby tests pass.

The rescue reward is an explicitly reviewed item and quantity. This plugin
uses no RMXP global switches or variables; `switch_ids` and `variable_ids`
must both be empty. Persistent quest flags are kept in the save object instead.

## Reviewed plan and staged installation

1. Prepare a fresh staged game using the repository's safe staging procedure.
   Preserve the supplied source project. Copy `essentials/Plugins/Shattered
   Murkrow Rescue/` into the staged project's `Plugins` directory after
   Shattered Core.
2. In the staged project's `Data/MapInfos.rxdata`, identify the actual target
   map and the existing, reviewed transfer event that leads to the intended
   destination. Review the map in RPG Maker XP and confirm the anchor role,
   event tile passability, local sprite, target event ID, warp destination,
   encounter helper/arguments, and reward. Do not use the test coordinates as
   approval.
3. Create a local JSON plan (do not commit a plan containing private project
   details) with these fields:

   | Field | Required review/validation |
   |---|---|
   | `schema_version` | `1` |
   | `source_map_uuid`, `source_map_size` | Exact index values above |
   | `source_event_id`, `source_position` | One listed source anchor and its exact indexed coordinate |
   | `reviewed_source_role` | Human-confirmed role; the index does not supply it |
   | `role_reviewed`, `location_reviewed`, `passability_reviewed`, `sprite_reviewed`, `battle_reviewed`, `reward_reviewed` | All `true` after review |
   | `target_map_id`, `target_map_size`, `target_position` | Actual Essentials map ID, dimensions, and reviewed event tile |
   | `event_id` | Reviewed, unused event ID on that map |
   | `expected_map_sha256` | SHA-256 of the untouched target `Data/MapNNN.rxdata` |
   | `expected_tilesets_sha256` | SHA-256 of the reviewed `Data/Tilesets.rxdata`; any change fails closed |
   | `character` | Safe local character filename without `.png`; graphic must be licensed |
   | `switch_ids`, `variable_ids` | Both `[]`; this plugin uses saved quest flags |
   | `destination_warp` | Reviewed `event_id`, destination `map_id`, `x`, `y`, and `reviewed: true` |
   | `battle` | `hook` is `WildBattle.start_core` or `pbTrainerBattle`; `arguments` use JSON primitives and `{"symbol":"SPECIES_OR_TYPE"}` for symbols |
   | `reward` | Existing item ID and quantity from 1 through 99 |

   The installer verifies the source anchor, plan review markers, IDs and
   dimensions, map and tileset hashes, native passage flags for the event tile
   and at least one unoccupied traversable adjacent approach, sprite file,
   route transfer command and destination bounds, plus empty reservations before
   it writes a temporary map. It rejects symlinked target files, stale
   temporary/backup files, occupied IDs/tiles, and partial or drifted installs.
4. From the staged project root, run:

   ```ruby
   pbInstallShatteredMurkrowRescue("path/to/local-reviewed-plan.json")
   ```

   The installer stages one updated map, then replaces it using a backup and
   restores the original on write/replace failure. Re-running the same plan
   verifies the managed event and returns unchanged rather than adding a
   duplicate. If review inputs or the map change, create a newly reviewed plan;
   do not bypass the SHA check.

## Verification status

`ruby tests/test_murkrow_rescue.rb` exercises the state machine, retries,
save-object serialization, duplicate prevention, installer validation,
rollback, and idempotence with synthetic RPG Maker fixtures. It does not
compile the plugin in native Essentials, prove that the local map/warp or
sprite is correct, or execute the cutscene in-game. Native v21.1 compilation,
actual map installation, save/close/reopen playthrough, battle/helper
compatibility, reward delivery, and JoiPlay/NaviaXP testing remain open.

This focused plugin does not change the shared integration queue, global
staging scripts, Shattered Core, or the Viridian/dojo/raid plugins.
