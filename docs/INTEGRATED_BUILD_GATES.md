# SE-024 integrated build and compatibility gate

This is a deterministic **source/export and private staging gate**, not a
prebuilt game. Its manifest records the live heads of PRs #10–#17 and #19 and
the different ancestry of those branches. The stack is not one installed
project: #12 → #13 → #15 → #16 → #17 is stacked, while #10, #11, #14, and #19
are based on `main`. The PR head/base SHAs are pinned in
`development/shattered_integration_manifest.json`; update those pins only after
reviewing new live PR heads.

The manifest and harness do not edit the integration queue, plugin manifest,
feature plugin files, or `scripts/stage_essentials.py`. They export only the
allow-listed files in the manifest from the exact pinned Git commits. The
`scripts/stage_essentials.py` version in PR #10 is not part of this harness's
owned file set.

## Commands

Validate only the static contracts. This does **not** mean the sources are
available or that a game can be staged:

```sh
python3 scripts/shattered_integration.py validate-manifest
```

For source export, provide a local Git repository with `main`, every listed PR
branch (or `refs/pull/<number>/head`), the pinned commits, and their ancestry
available. The exporter makes no network requests:

```sh
python3 scripts/shattered_integration.py export-sources \
  --git-repo /local/full/Shattered-checkout \
  --output /local/private/Shattered-pinned-sources
```

It verifies fetched branch heads and base ancestry, reads each allow-listed
file with `git show <pinned-head>:<path>`, writes only those files to a fresh
source bundle, and records their SHA256 values in
`.shattered-integration-source.json`. Missing or changed refs fail before
export.

To stage, create a **private** plan and input directory, then provide an
authorised Essentials v21.1 project. The project directory must contain
`Game.ini`, `Data/Scripts.rxdata`, `Data/MapInfos.rxdata`, `PBS/pokemon.txt`,
`PBS/items.txt`, and reviewed target `Data/MapNNN.rxdata` files. The output
must be a new, separate directory:

```sh
python3 scripts/shattered_integration.py stage \
  --project /local/authorised/Essentials21.1 \
  --sources /local/private/Shattered-pinned-sources \
  --inputs /local/private/Shattered-build-inputs \
  --plan /local/private/Shattered-build-plan.json \
  --output /local/private/Shattered-staged
```

The plan/input files stay outside this repository. The plan must include:

- `authorization`: `"engine_version": "21.1"`, `"source_authorized": true`,
  and a SHA256-pinned local JSON rights record (`rights_record`,
  `rights_record_sha256`). The record identifies `base_project`, has type
  `essentials_project`, and records a non-empty source, license, and basis.
- `map_targets`: one distinct positive actual map ID, target map file SHA256,
  source dimensions/UUID where known, `"reviewed": true`, and
  `"map_info_reviewed": true` for each of the six manifest slots. IDs shown in
  feature-PR examples are placeholders and are rejected as source evidence.
- `switch_ids` and `variable_ids`: each exact key in the manifest, with
  distinct positive IDs within each global resource class. IDs from Viridian,
  Route 22, and the raid must be reserved against the actual project.
- `assets`: every required asset ID, its relative path under `--inputs`, SHA256,
  safe `Audio/` or `Graphics/` destination (or `null` for a non-staged mapping
  input), and a SHA256-pinned local rights JSON record. Records require an
  explicit source, license, basis, and `rights_cleared: true`.
- `archives`: verified local archives for any required third-party plugin not
  already installed at the exact required version. Each archive requires its
  hash, `"license_reviewed": true`, and a corresponding local rights record.
  Add `reviewed_hooks` as the source-reviewed list of hook claims for that
  archive. The gate also scans Ruby archives and installed plugins for known
  HUMAN battle, capture, and stat override signatures. The archive's actual
  `meta.txt` name/version and declared dependency order are checked.
  Unverified or missing archives fail closed.

The staged output contains only the copied Essentials project, the manifest's
allow-listed first-party plugin files, local rights-cleared assets, approved
plugin archive contents, the required HUMAN and Gate Key PBS fragments, and
`SHATTERED_INTEGRATION_BUILD.json`. The original project is never modified.
ZIP traversal, symlinks, oversized members, duplicate/unsupported paths,
replacement of engine archives/PBS, and destination collisions are rejected.

The output build record reports `staged-copy-only` (or
`synthetic-fixture`) and keeps PBS compile, script compile, game boot, gameplay,
save/reload, actual Essentials plugin load order, and Android JoiPlay/NaviaXP
false until separately evidenced. These commands do not execute the native
RMXP event installers or compile Essentials.

## Recorded source and compatibility contracts

- Plugin order: Hotfixes → Deluxe Battle Kit → Enhanced Battle UI, followed by
  independently reviewed Following Pokémon EX and Modern Quest System, then
  Shattered Core and the scene plugins. Feral Tank is excluded until its
  `Pokemon#calc_stats`/HUMAN compatibility audit.
- Shattered Core's pinned PR #11 claims the HUMAN battler methods, Poké Ball
  `ItemHandlers::CanUseInBattle` block, and two event-handler IDs. The raid
  claims its own distinct map-setup event key and `disablePokeBalls` battle
  rule. Duplicate claims, including capture or future gear claims, fail static
  validation. No equipment battle hook is currently claimed or implemented.
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
python3 -m unittest tests.test_shattered_integration -v
```

The fixtures deliberately use synthetic project/map bytes, fake plugin
archives, and non-game art placeholders. They exercise source preservation,
PBS conflicts, duplicate queue/plugin/event-hook/resource claims, wrong branch
ancestry, overlapping map writers, missing source/assets/archives, map
collisions, hashes, dependency order, and safe staging. Passing them proves
only the Python harness behavior. The regular repository CI also runs these
tests via unittest discovery.

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

- Review and combine the pinned draft PR sources without losing their ancestry;
  obtain missing Hotfixes, DBK, Enhanced Battle UI, Following Pokémon EX, and
  quest plugin archives with versions and licences verified.
- Resolve HnS map/tile rights, provide a rights-cleared conversion mapping and
  image, and create real target maps with reviewed collision, passability,
  exits, event positions, and MapInfos entries.
- Assign actual map IDs and unique global switch/variable IDs; review every
  source-to-target mapping, role, sprite/audio licence, and PBS species/item
  prerequisite. No sample IDs are allocations.
- Compile PBS and all plugins in an authorised native Essentials v21.1 project.
  Test HUMAN battle, Poké Ball denial, Rattata/Beedrill progression, event
  recovery, followers/quests, and save/close/reopen.
- Run the complete Johto gate → Route 22 → Viridian → raid/rescue/dojo/starter
  route on desktop and Android. Capture logs, results, and project hashes.

The repository currently has no authorised native Essentials project or
Android runtime in this task environment. No full gameplay or mobile acceptance
is claimed.
