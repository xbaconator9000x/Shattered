# Shattered Essentials integration hub

This project is **independent** from the Shattered FireRed ROM hack and from Essentials Studio Mobile. The source-game archive and Pokémon graphics are **not** committed to GitHub. Build a separate local test folder from an authorised copy of Pokémon Essentials v21.1.

## Working code and claims

- `essentials/Plugins/Shattered Core/`: **real Ruby plugin**, event-facing `Shattered.ensure_human`, `Shattered.befriend`, optional stamina backing store, planned type/technique/equipment data. Does **not** yet hook the battle PP system, modify party menus, disable Poké Balls, apply non-standard typing, or implement the specialisations.
- `essentials/PBS/HUMAN.pbs`: appended to `PBS/pokemon.txt` by staging tool. HUMAN is currently *Normal type* until a safe battle-level effectiveness hook is implemented.
- `development/plugin_manifest.json`: source links, exact versions, upstream compatibility/dependencies and conflict risks. **Not a claim of installation.**
- `scripts/stage_essentials.py`: testable safe installer; its default action stages only Shattered Core/HUMAN. Additional third-party packages require verified local ZIPs (`--archive pluginid=/path/to.zip`). The tool refuses unsafe/overlapping archive writes by default.
- `scripts/validate_integration.py`: checks dependency cycles, task readiness and structure.
- GitHub Actions runs static validation, Ruby tests and builds an isolated *synthetic* starter project. These tests **cannot replace a native Essentials plugin compilation or an Android playtest**.

## Third-party installation order

1. Update **Hotfixes from bundled 1.0.3 to v1.0.9**. Existing 1.0.3 is genuinely present in the v0.4 base archive, and updating must be verified rather than blindly adding a second copy.
2. Install **Deluxe Battle Kit v1.3.1** after Hotfixes; stage **Enhanced Battle UI v2.1.1** only after DBK.
3. Install **Following Pokemon EX v2.5.1** and test map transfers, follower spacing and trainer-as-party-member exclusion.
4. Install **Modern Quest System + UI v1.1.0** and port rescue events/sidequests.
5. Audit **Feral Tank v1.1.9** against HUMAN and other stat hooks: it overrides `Pokemon.calcHP`, `Pokemon.calcStat` and `Pokemon.calc_stats`; do not introduce a competing override. Its move-learning options need explicit test cases.

Upstream distribution and credits: [Hotfixes](https://eeveeexpo.com/resources/1376/), [DBK](https://eeveeexpo.com/resources/1470/), [Enhanced UI](https://eeveeexpo.com/resources/1472/), [Followers](https://eeveeexpo.com/resources/516/), [Quest System](https://eeveeexpo.com/resources/709/), [Feral Tank](https://eeveeexpo.com/resources/2011/).

## Test locally

```
python3 scripts/validate_integration.py
python3 -m unittest discover -s tests -v
ruby tests/test_shattered_core.rb
python3 scripts/stage_essentials.py --project '/path/to/Essentials FRLG' --output '/path/to/Shattered-Essentials-staged'
```

Run RPG Maker XP debug compilation / Ctrl-force recompile for installed plugins, **start a NEW game**, and independently test on JoiPlay or NaviaXP. Don't promise Android gameplay without device evidence.

## Safe upstream archive staging

Only supply ZIPs obtained from their official author resource pages, do not redistribute them here until license and credits are checked. For example:

```
python3 scripts/stage_essentials.py --project /path/to/base --output /path/to/newgame \
  --archive following_pokemon_ex=/path/to/followers.zip
```

Staging copies the project instead of modifying the source. Unknown paths, ZIP symlinks, traversal attempts, oversized untrusted packages and collisions cause errors. Some plugins require explicit controlled overwrites of shared Data/Graphics, so inspect the staged diff first.

## GitHub automation

A CI workflow validates every push/PR with Python and Ruby, including a miniature staged-project test. A separate 15-minute GitHub Actions watchdog reads the durable queue, identifies up to 3 dependency-ready tasks and creates deduplicated GitHub issues. **It coordinates work but does not autonomously write implementation code.** When source packages are provided, staging and consistency checks can run unattended in CI; gameplay still needs a valid engine/Android runner.
