# Shattered / Pokémon Essentials coding instructions

This is the PRIVATE source-control hub for the **Pokémon Shattered Essentials v21.1 prototype**, not the original FireRed ROM patch project or the separate Essentials Studio Mobile editor.

**Primary product specification:** Read `docs/SHATTERED_ESSENTIALS_FULL_REMAKE_ACCEPTANCE.md` before taking new implementation tasks. The goal is one fully integrated, playable and saveable Shattered demo, not a collection of separate successful plugin tests.

## Project truth
- GitHub `main` is authoritative for `development/integration_queue.json` and `development/plugin_manifest.json`.
- Keep independent source changes in focused PRs. Do not silently edit or merge an unrelated existing branch/PR.
- The current playable v0.4 test was a *minimal Crystal reception-gate prototype*, not the desired Heart & Soul 2.0 reception gate. The correct HnS source is `PokemonHnS-Development/pokehns-expansion/data/maps/ReceptionGate_hns` (see `docs/HEART_SOUL_RECEPTION_GATE_SOURCE.md` in the earlier prototype branch). Never present a generic cave as the final Johto outpost.
- Source files under `essentials/Plugins/Shattered Core` implement only event-facing HUMAN APIs for now; no battle-turn stamina hook, complete equipment system, full friendship recruitment, real HUMAN renderer, or Android runtime validation has been established.

## Implementation requirements
1. Use Pokémon Essentials **v21.1** conventions and genuine source references. Cite upstream plugin version, origin, and licence before copying or distributing third-party code or graphics. Do not upload ROMs, commercial Pokémon assets, or vendor ZIP archives to GitHub without rights.
2. Follow plugin dependency order: Hotfixes → Deluxe Battle Kit → Enhanced Battle UI. Independently evaluate Following Pokémon EX and Modern Quest System. Audit **Feral Tank** against `Pokemon#calc_stats` and custom HUMAN battle logic before touching those overrides.
3. Preserve a copy of the original user-supplied project; generate changes through `scripts/stage_essentials.py` to a fresh output. Reject unsafe ZIP extraction, collisions, and missing dependencies.
4. In Shattered, humans fight without Poké Balls; Poké Ball capture is disabled; Pokémon companions join through befriending; the human has a common stamina budget while Pokémon retain individual PP. HUMAN has its own defensive matchups, and equipment/specialisations are later features. Do not claim a feature works in battles merely because an API is defined.
5. Prefer small independently testable components. Update or add Python/Ruby tests alongside production changes. Run `python3 scripts/validate_integration.py`, `python3 -m unittest discover -s tests -v`, `ruby -c 'essentials/Plugins/Shattered Core/001_Core.rb'`, and `ruby tests/test_shattered_core.rb` as applicable.
6. Mark tasks `done` only with actual test evidence. Keep stated completion percentages conservative and distinguish static validation, compiled Essentials execution and Android JoiPlay/NaviaXP playtesting.
7. Do not automatically enable paid services, increase billing limits, purchase AI credits, run long Android emulator builds without need, or resume paused PKHeX-Mobile/CUBE-Mobile workflows. Minimise duplicated Actions runs and expensive CI.
8. For each PR provide: change summary, source attribution, tests and results, compatibility concerns, unresolved blockers, and next eligible queue items.

## Current priority
Start with queued or in-progress `SE-002` (plugin source/version verification, manifests, version/dependency/conflict checks), then HUMAN validation `SE-004`. Do not automatically install unverified third-party binaries or touch the original FireRed ROM project.

## Integration-first execution priority
Supersedes the older Current priority paragraph. First reconcile existing draft work into one reviewable integration candidate: SE-002 catalogue, SE-004 HUMAN, SE-015 source anchors, SE-013 gate, SE-016 gate story and SE-017 transfers in dependency order. Inspect current PR heads and tests; reuse existing implementations rather than opening duplicate feature PRs.
Use one preserved, authorised Essentials v21.1 source project and one reproducible fresh staging output. Record source hashes, plugin versions and missing inputs. First playable milestone: new game → HUMAN → gate collapse → Aipom key → Route 22 battle → save/close/reload.
Run combined Python/Ruby checks on the integrated candidate; synthetic tests do not close native runtime gates. Produce a single candidate artifact and commit-specific test route when staging succeeds. Explicitly identify missing archives/assets instead of repeatedly auditing them.
After each completed task select the next eligible integration task in the same execution while capacity remains. Hourly watchdog is recovery, not a reason to stop between eligible tasks. Keep checks incremental and avoid redundant APK/CI runs. Preserve review requirements; do not claim engine or device execution without evidence.


## Work runtime acceptance (user directive, 2026-10-30)
ChatGPT Work coordinates actual runtime testing. GitHub Actions supplies builds and supporting regression checks only; a green workflow never proves Android or gameplay acceptance. Continue develop → integrate → build → install → launch → test → repair → retest → commit while an executable path exists. Record features separately as implemented, integrated, runtime verified, or blocked, with exact candidate SHA/artifact hash and observed evidence. Assess Work runtime provisioning before assigning device work to the user. Preserve successful prototype implementations; integrate instead of rewriting. Runtime claims require actual execution, screenshots/logs and persisted-state checks; synthetic fixtures remain supporting evidence. On a genuine environment restriction, preserve the reproduction and continue independent eligible work rather than repeatedly re-auditing the same blocker.
