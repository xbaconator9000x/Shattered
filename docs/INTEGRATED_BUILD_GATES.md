# SE-024 integrated build and compatibility gate

This is a deterministic **source/export and private staging gate**, not a
prebuilt game. It records current main and live heads for PRs #6, #10–#17, #19,
#24, and #25, including their exact bases and ancestry. PRs #6 and #10 are
merged into the pinned main. The stack is #12 → #13 → #15 → #16 → #17;
#10, #11, #14, #19, #24, and #25 are main-based. The manifest is updated only
after inspecting live PR heads, changed files, and base ancestry.

The manifest and harness do not edit the integration queue, plugin manifest,
feature plugin files, or `scripts/stage_essentials.py`. They export only the
allow-listed files in the manifest from the exact pinned Git commits. Merged
components are resolved from the pinned `main` tree; their original PR heads are
still recorded and checked as ancestors of `main`, without requiring closed PR
branches to remain fetchable. The
`scripts/stage_essentials.py` version in PR #10 is not part of this harness's
owned file set.

## Commands

Validate only the static contracts. This does **not** mean the sources are
available or that a game can be staged:

```sh
python3 scripts/shattered_integration.py validate-manifest
```

The CI contract fetches the pinned initial-slice PR refs, exports allow-listed
files, assembles the slice plugins and PBS fragments into a temporary synthetic
tree, checks compatibility declarations, and runs each applicable Python/Ruby
suite in a separate process. It prints exact source SHAs and does not include
game data or copyrighted assets. The default local contract profile can test the
full manifest when every later stacked PR ref is available:

```sh
python3 scripts/shattered_integration_contract.py \
 --git-repo /local/full/Shattered-checkout
```

To export the initial slice only, provide a full local checkout with pinned
history and PR refs. This does not fetch files or make network requests:

```sh
python3 scripts/shattered_integration.py export-sources \
 --profile initial_slice \
 --git-repo /local/full/Shattered-checkout \
 --output /local/private/Shattered-initial-slice-sources
```

### First private initial-slice staging attempt

The profile is limited to the requested thin slice:
**new game → genuine HUMAN → gate collapse → Aipom key → mandatory Lv5 Route22
Rattata → save/close/reload**. It does not require Viridian, dojo, raid,
Murkrow/quest, Following Pokémon EX, Modern Quest System, or optional Feral Tank.
It still stages only; it cannot verify that route in the game engine.

Preflight reports all known blockers and exact expected local paths:

```sh
python3 scripts/shattered_integration.py preflight \
 --profile initial_slice \
 --project /local/authorised/Essentials21.1 \
 --sources /local/private/Shattered-initial-slice-sources \
 --inputs /local/private/Shattered-build-inputs \
 --plan /local/private/Shattered-build-plan.json
```

The single private staging-and-handoff command is `stage --native-plan` with the
same staging arguments, plus a separate reviewed native plan:

```sh
python3 scripts/shattered_integration.py stage \
 --profile initial_slice \
 --project /local/authorised/Essentials21.1 \
 --sources /local/private/Shattered-initial-slice-sources \
 --inputs /local/private/Shattered-build-inputs \
 --plan /local/private/Shattered-build-plan.json \
 --native-plan /local/private/Shattered-native-install-plan.json \
 --output /local/private/Shattered-staged
```

The minimum authorized project files are `Game.ini`, `Data/Scripts.rxdata`,
`Data/MapInfos.rxdata`, `Data/Tilesets.rxdata`, `PBS/pokemon.txt`,
`PBS/items.txt`, and reviewed existing HnS warp-destination maps with their
MapInfos entries. Reception Gate is a new map created by the native importer;
its reviewed map ID must be unoccupied. Route 22 is an existing 48×24 map with
a reviewed SHA256. The original project is copied and not edited.

The initial-slice plan must include:

- `authorization`: `"engine_version": "21.1"`, `"source_authorized": true`,
  and a SHA256-pinned local JSON rights record (`rights_record`,
  `rights_record_sha256`). The record identifies `base_project`, has type
  `essentials_project`, and records a non-empty source, license, and basis.
- `map_targets`: distinct positive actual IDs with `"reviewed": true` and
  `"map_info_reviewed": true`. Reception Gate has the HnS source UUID and no
  existing map file; Route 22 has the actual staged map SHA256 and 48×24
  dimensions. `required_existing_maps` must cover all five HnS exit destinations
  (including Route 22) with dimensions, hashes, and reviewed MapInfos.
- `switch_ids`: `route22_scatter` and `route22_cleared`; `variable_ids`:
  `route22_outcome`. Each needs a unique positive ID of its resource class,
  allocated against the actual project.
- `source_projects.hns_reception_gate`: a SHA256-pinned local rights record
  (`type: "source_project"`, `rights_cleared: true`) and local files matching the
  pinned HnS source hashes: `sources/hns/data/maps/ReceptionGate_hns/map.json`,
  `sources/hns/data/layouts/layouts.json`, and
  `sources/hns/data/layouts/ReceptionGate_hns/map.bin`. Also provide the
  operator-authored `sources/hns/reception_gate_mapping.json` and document its
  rights basis. The upstream repository had no explicit license grant; without
  an actual permission/rights basis this is a hard blocker.
- `assets`: exactly the initial profile IDs. Required inputs include
  `assets/tilesets/ReceptionGate.png`, `assets/characters/Aipom.png`,
  `assets/characters/Rattata.png`, the Aipom cry, six gate-collapse SE files,
  the final gate roar, and the reviewed metatile/collision mapping. Each needs its source, SHA256,
  staged destination where applicable, and a SHA256-pinned rights record.
  The input filename conventions are in the manifest; the event installer must
  use the matching local asset basenames.
- `archives`: verified local archives for Hotfixes 1.0.9, Deluxe Battle Kit
  1.3.1, and Enhanced Battle UI 2.1.1 if the exact versions are not already
  installed. The manifest lists expected local ZIP paths. No archive is
  downloaded automatically; each requires license review, SHA256 and a rights
  record. Following Pokémon EX and Modern Quest System are not initial-slice
  dependencies and remain independently unreviewed.
- `assets`: each input has a safe `Audio/` or `Graphics/` destination (or
  `null` for a non-staged mapping input), SHA256, and a SHA256-pinned local
  rights JSON record. Records require an explicit source, license, basis, and
  `rights_cleared: true`.

The staged output contains only the copied Essentials project, the manifest's
allow-listed first-party plugin files, local rights-cleared assets, approved
plugin archive contents, the required HUMAN and Gate Key PBS fragments, and
`SHATTERED_INTEGRATION_BUILD.json` plus the Essentials staging marker. With
`--native-plan`, it also contains the private generated installer, configs, and
exact plan SHA256. The command removes its new output if the handoff preflight
fails. The original project is never modified.
ZIP traversal, symlinks, oversized members, duplicate/unsupported paths,
replacement of engine archives/PBS, and destination collisions are rejected.

The output build record reports `staged-copy-only` (or
`synthetic-fixture`) and keeps PBS compile, script compile, game boot, gameplay,
save/reload, actual Essentials plugin load order, and Android JoiPlay/NaviaXP
false until separately evidenced. Staging alone does not execute the native
RMXP event installers or compile Essentials.

The native plan contains four reviewed installer configs, exact PR/base/source
SHAs, hashes for staged scripts/PBS/assets, target map IDs, switch/variable IDs,
the original south transfer, and all event positions. The installer dependency
order is HnS map import → World Links → Gate Story → Route22. The HnS importer
creates five exits, so all four destination maps must exist and be reviewed;
the build is not ready if one is missing. In the native Essentials debug
console, run this only after PBS/plugin compilation and game boot:

```ruby
pbInstallShatteredInitialSlice
```

The Ruby installer verifies the source/config hashes and reserved IDs, snapshots
all modified RXData, restores on ordinary errors, and writes a receipt only
after strict component return/event checks. An interrupted install leaves a
recovery marker and must not be rerun blindly. Route22's expected map hash is
computed after World Links changes its map. The Gate Story installer currently
expects a Hash for `Tilesets.rxdata` while the HnS importer writes an Array; the
handoff supplies a temporary Hash view and restores the original Array bytes
before continuing. This adapter does not prove that the plugins compile or that
the Route22 event trigger semantics work in native RMXP. The handoff remains
`native_install_pending` until the command runs in the authorized engine.
Gameplay and save/reload remain unverified afterward.

The private native plan JSON is separate from the staging plan and must contain
`schema_version: 1`, `profile: "initial_slice"`, reviewed `map_targets`,
`required_existing_maps`, `switch_ids`, `variable_ids`, and
`installer_configs` keyed exactly as `hns_import`, `world_links`, `gate_story`,
and `route22`. Config values must follow the schemas validated by the pinned
installer APIs; they are serialized into the staged project only after all
cross-map IDs, coordinates, source hashes, and asset basenames pass preflight.
If source permissions, licensed art/audio, exact plugin archives, any one of the
four HnS destination maps, or a unique map/resource ID is missing, staging
returns a specific blocker and does not produce a staged output.

## Recorded source and compatibility contracts

- Plugin order: Hotfixes → Deluxe Battle Kit → Enhanced Battle UI → Shattered
  Core → slice plugins. Following Pokémon EX and Modern Quest System remain
  independently evaluated and are not initial-slice dependencies. Feral Tank is
  excluded until its `Pokemon#calc_stats`/HUMAN compatibility audit.
- Shattered Core's pinned PR #11 claims the HUMAN battler methods, Poké Ball
  `ItemHandlers::CanUseInBattle` block, and two event-handler IDs. The raid
  claims its own distinct map-setup event key and `disablePokeBalls` battle
  rule. The Equipment PR's `pbInitPokemon` and battle-start hook are inventoried;
  duplicate claims, including capture or gear hooks, fail static validation.
- Event/installer APIs, event prefixes, map source UUIDs and dimensions, PBS
  fragments, party/save-state fields, per-component map writes, and required
  dependencies are recorded per component in the JSON manifest.
- The gate source is Heart & Soul 2.0 at
  `167aa6d537b109bb229c231ddce4616974c4da71`. The reviewed source root had no
  explicit license grant; source map binaries, converted tiles, and art must
  remain local until rights are established. The Shattered parity source is a
  sanitized anchor index, not original game content.
- Actual target map IDs, event IDs, switch IDs, and variable IDs remain
  unassigned. The Route 22 map is 48×24, Viridian city 48×40, and dojo interior
  10×9 in their source index. Viridian NPC roles/passability, Center source
  identity, raid map/anchors, destination maps, and native map dimensions still
  require local review.

## Tests and evidence tiers

Run the harness fixtures:

```sh
python3 -m unittest tests/test_shattered_integration.py -v
python3 -m unittest discover -s tests -p 'test_shattered_native_handoff.py' -v
ruby tests/test_shattered_native_handoff.rb
python3 scripts/shattered_integration_contract.py --git-repo /local/full/Shattered-checkout
```

The fixtures deliberately use synthetic project/map bytes, fake plugin
archives, and non-game art placeholders. They exercise source preservation,
PBS conflicts, duplicate queue/plugin/event-hook/resource claims, wrong branch
ancestry, overlapping map writers, missing source/assets/archives, map
collisions, hashes, dependency order, and safe staging. Passing them proves
only harness/source-contract behavior. The contract command separately reports
all pinned source SHAs and runs 15 Python/Ruby component test commands. It does
not compile PBS, launch Essentials, or establish gameplay/save/reload acceptance.

Evidence must be reported at the tier actually run:

1. **Static** — manifest, lock, graph, queue, and resource preflight.
2. **Synthetic fixture** — deterministic harness behavior with generated test
   inputs; not source game or Essentials runtime evidence.
3. **Staged copy** — source-owned project files and approved local inputs copied
   to a clean output; not proof of PBS or plugin compilation.
4. **Native Essentials v21.1** — compile PBS and plugin scripts, boot a clean
   game, execute map/battle events, and verify save/reopen.
5. **Android** — repeat the full route and save/reopen test on JoiPlay/NaviaXP
   with device/runtime logs.

## Open gates before a playable release

- Resolve missing source permission for the HnS map files, mapping, and
  converted tileset; provide rights-cleared Aipom/Rattata art and cry/SE files.
- Obtain local Hotfixes, DBK, and Enhanced Battle UI archives at pinned versions
  with verified licences, unless those exact versions are already in the
  authorized project. Following Pokémon EX and Modern Quest System are
  independent later evaluations, not initial-slice blockers.
- Resolve HnS map/tile rights, provide a rights-cleared conversion mapping and
  image, and create real target maps with reviewed collision, passability,
  exits, event positions, and MapInfos entries.
- Assign actual Reception Gate/Route 22 map IDs and Route 22 switches/variable;
  review source-to-target mapping, event passability, and existing RATTATA PBS.
- Compile PBS and all plugins in an authorised native Essentials v21.1 project.
  Test HUMAN battle, Poké Ball denial, Rattata/Beedrill progression, event
  recovery, followers/quests, and save/close/reopen.
-   Verify Route22 event trigger behavior in native RMXP, then run new game → HUMAN
  → gate collapse → Aipom key → mandatory Lv5 Route22 Rattata → save/close/reload.
  The separate Viridian/raid/rescue/dojo/starter route and Android acceptance are
  later gates. Capture logs, results, and project hashes.

The repository currently has no authorised native Essentials project, licensed
HnS/art inputs, verified plugin archives, or Android runtime in this task
environment. Runtime status remains **BLOCKED**. No full gameplay or mobile
acceptance is claimed.
