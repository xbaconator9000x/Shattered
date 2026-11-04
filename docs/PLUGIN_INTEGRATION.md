# Shattered Essentials integration hub

This project is **independent** from the Shattered FireRed ROM hack and from Essentials Studio Mobile. The source-game archive and Pokémon graphics are **not** committed to GitHub. Build a separate local test folder from an authorised copy of Pokémon Essentials v21.1.

## Working code and claims

- `essentials/Plugins/Shattered Core/`: **real Ruby plugin v0.2.3**, including HUMAN lifecycle, persistent stamina, battle move/PP hooks, HUMAN-specific defensive effectiveness, capture-rule guards and no-ball `Shattered.befriend`. These hooks have source tests and an actual mkxp-z Core evaluation probe, but no genuine HUMAN battle, save/reload or Android acceptance. Full menus, specialisations and equipment UI remain unfinished.
- `essentials/PBS/HUMAN.pbs`: appended to `PBS/pokemon.txt` by staging. HUMAN's PBS base type is Normal while its special defensive chart is implemented through the Core battle move hook. **PBS species compilation has not yet been executed in the actual staged game**; appending text alone does not create a playable HUMAN.
- `development/plugin_manifest.json`: catalogue pins, declared dependency/override claims and verification state. Third-party source, version, compatibility and license claims below remain **unverified**; this is not a claim of installation.
- `scripts/stage_essentials.py`: testable safe installer; its default action stages only Shattered Core/HUMAN. It accepts local third-party ZIPs (`--archive pluginid=/path/to.zip`) but does not verify their provenance, version or license; complete those checks manually first. The tool refuses unsafe/overlapping archive writes by default.
- `scripts/validate_integration.py`: checks version syntax/compatibility targets, dependency references/cycles and declared dependency-version constraints, duplicate overrides, verification metadata, runtime claims and task readiness.
- `scripts/compile_private_plugins.rb`: guarded local-only compiler of the native v21.1 `PluginScripts.rxdata` Marshal+Zlib format, based on the original v0.4 `PluginManager.compilePlugins` implementation. Preserves existing compiled Hotfixes, backs up before updates and rejects conflicting sources. This **does not compile PBS or prove gameplay**.
  The runtime source allowlist now excludes offline map installers (`002_Install.rb`), the HnS importer and World Links installer. Those files remain available for explicit private offline installation but must never be evaluated at game startup. The compiler records requested offline-only modules separately, refuses unreviewed new Ruby filenames, and rejects top-level `require` statements in compiled runtime scripts. Murkrow event scripts use reviewed Ruby Hash literals rather than `JSON`/`Base64` calls; Raid installer loads Digest only when explicitly invoked offline. The native archive compiler alone is insufficient for debug launch because Essentials can rescan filesystem plugin scripts. Run the private isolation step below after compilation.
- `scripts/finalize_private_runtime.rb`: **required after compiling Shattered plugins for a private runtime test**. Verifies compiled plugin bytes against source, then moves offline installers and offline-only plugin folders to `SHATTERED_OFFLINE_TOOLS/` outside `Plugins/`. It refuses tampered or uncompiled modules and preserves original user files. A private mkxp-z launch has now evaluated all eight runtime modules after this step.
- `scripts/prepare_linux_map_aliases.py`: Linux-only, private staged-project helper. The original v0.4 compiler requests lowercase `Data/mapNNN.rxdata`, while RPG Maker stores uppercase `Data/MapNNN.rxdata`. The tool creates verified lowercase symlinks to the 222 existing maps without renaming or changing originals. Do not run it on the user's original project.
- `.github/workflows/private-runtime-source-bundle.yml`: produces a short-lived exact-commit source-only GitHub artifact, explicitly excluding game binaries, graphics and audio. Combine it privately with the authorised original v0.4 project; never upload the game files.
- GitHub Actions runs static validation, Ruby tests and builds an isolated *synthetic* starter project. These tests **cannot replace a native Essentials plugin compilation or an Android playtest**.

## Catalogue evidence and attribution limits

The following are the URLs and version pins already recorded in the manifest. During this review the resource host could not be resolved, and no upstream archives or source files were available for inspection. Therefore the resource names, authorship/origin, pinned releases, Essentials compatibility and dependency claims are **not independently verified** here. Resource links alone do not establish licensing or permission to redistribute; confirm author credits and each license before obtaining, installing or sharing any plugin. No third-party code, graphics or archives are included in this repository.

| Catalogue entry | Pinned version | Recorded source | Verification |
| --- | --- | --- | --- |
| v21.1 Hotfixes | 1.0.9 | [resource 1376](https://eeveeexpo.com/resources/1376/) | Source and version unverified; license unknown |
| Deluxe Battle Kit | 1.3.1 | [resource 1470](https://eeveeexpo.com/resources/1470/) | Source and version unverified; license unknown |
| Enhanced Battle UI | 2.1.1 | [resource 1472](https://eeveeexpo.com/resources/1472/) | Source and version unverified; license unknown |
| Following Pokemon EX | 2.5.1 | [resource 516](https://eeveeexpo.com/resources/516/) | Source and version unverified; license unknown |
| Modern Quest System + UI | 1.1.0 | [resource 709](https://eeveeexpo.com/resources/709/) | Source and version unverified; license unknown |
| Feral Tank | 1.1.9 | [resource 2011](https://eeveeexpo.com/resources/2011/) | Source and version unverified; license unknown |

The manifest records the desired Essentials target (21.1), not proven upstream compatibility. No dependency-version bounds have been independently confirmed; the validator enforces any bounds added to `dependency_version_constraints` without inventing pins. SE-002 remains in progress until source, version, dependency, compatibility and permission evidence can be checked.

## Staged integration order

1. **Verify before install:** obtain the authoritative release/source and license information for each plugin; inspect its metadata/version and Essentials compatibility. Keep source archives local and preserve the original project.
2. **Hotfixes:** the v0.4 base-project inventory records bundled Hotfixes 1.0.3; verify its metadata and compare with the pinned 1.0.9 release before updating. Do not install a second copy blindly.
3. **Battle plugins:** install Hotfixes before Deluxe Battle Kit (DBK), then stage Enhanced Battle UI only after DBK. The dependency links are manifest claims and remain pending archive/source verification.
4. **Independent candidates:** evaluate Following Pokemon EX and Modern Quest System separately against a clean copy. Test follower map transfers, spacing and trainer exclusion; compile quest UI and ported events.
5. **Feral Tank last:** do not install until its pinned source is inspected and stat calculations are regression-tested against Essentials and Shattered HUMAN behavior.
6. **After each stage:** inspect changed files and override order, recompile in Essentials, start a new game and run focused functional checks. Record compilation/runtime evidence separately; no step here implies Android validation.

### Feral Tank / HUMAN conflict audit

The existing catalogue describes Feral Tank as overriding `Pokemon#calcHP`, `Pokemon#calcStat` and `Pokemon#calc_stats`. These are **unverified override claims**, not a source audit. Such replacements could conflict with another plugin's stat hook or change a Pokémon object's stat calculations when called by custom HUMAN battle logic. Shattered Core now implements HUMAN battle move/stamina and defensive type hooks but does not require Feral Tank; Feral Tank remains optional and **not a prerequisite for the first HUMAN battle**. No compatibility with its stat overrides has been verified. Before modifying or installing either side, inspect the exact upstream methods and hook/alias behavior, then test Pokémon stat recalculation and HUMAN stats independently; avoid competing method replacements until their call order and data model are understood.

## Test locally

```
python3 scripts/validate_integration.py
python3 -m unittest discover -s tests -v
ruby tests/test_shattered_core.rb
python3 scripts/stage_essentials.py --project '/path/to/Essentials FRLG' --output '/path/to/Shattered-Essentials-staged'
ruby scripts/compile_private_plugins.rb --project '/path/to/Shattered-Essentials-staged' --plugin 'Shattered Core'
# For the eight integrated gameplay modules, repeat --plugin NAME for each module.
ruby scripts/finalize_private_runtime.rb --project '/path/to/Shattered-Essentials-staged'
python3 scripts/prepare_linux_map_aliases.py --project '/path/to/Shattered-Essentials-staged'  # Linux only
```

The private native-format compiler above handles only plugin script archives. Run actual Essentials debug PBS/map compilation, **start a NEW game**, and independently test on JoiPlay or NaviaXP. The 2026-10-31 Linux mkxp-z private probe loaded all eight Shattered gameplay modules, compiled HUMAN PBS, entered New Game with a genuine HUMAN party member, and preserved HUMAN through a diagnostic Game.save/Continue across process restart; see `development/native_linux_full_plugin_runtime_2026-10-31.json`. A separate 2026-11-03 gate-only candidate used the normal Save menu and continued after process restart on Map223 with the collapse, Aipom key flag, debris switch and HUMAN party preserved; see `development/native_gate_collapse_runtime_2026-11-03.json`. That candidate did not reach Route 22: the direct step at (12,9)→(13,9) is blocked, and the reviewed northern walkway was not traversed. Neither receipt verifies the mandatory Route 22 map event, Rattata battle, later Viridian progress/save or Android.

## Safe upstream archive staging

Only supply ZIPs obtained from their official author resource pages, do not redistribute them here until license and credits are checked. For example:

```
python3 scripts/stage_essentials.py --project /path/to/base --output /path/to/newgame \
  --archive following_pokemon_ex=/path/to/followers.zip
```

Staging copies the project instead of modifying the source. Unknown paths, ZIP symlinks, traversal attempts, oversized untrusted packages and collisions cause errors. Some plugins require explicit controlled overwrites of shared Data/Graphics, so inspect the staged diff first.

## Private HnS overworld conversion (Aipom and Rattata)

The HnS source repository contains indexed `graphics/pokemon/{aipom,rattata}/overworld.png` sprite strips. Its repository does **not** declare redistribution rights for those Pokémon assets. Do not commit converted sheets, source PNGs, the game ZIP or licensed graphics to GitHub. After independently checking permissions, use the following SHA-pinned conversion **only in a private, separately staged project**. The pins come from `development/hns_overworld_sprite_provenance.json` and prevent silent upstream sprite drift:

```sh
python3 scripts/convert_hns_overworld.py \\
  --source /private/hns/graphics/pokemon/aipom/overworld.png \\
  --output /private/Shattered-staged/Graphics/Characters/Aipom.png \\
  --expected-source-sha256 cf313fdb7c650da510f0dcd75082d7170d642d79c2d2698b7761cd9c9fb2f38e \\
  --expected-output-sha256 d1933daa849c2d4fa5b1e7b991cb2941fbc8324e24cc960b5f117c465198dfd1
python3 scripts/convert_hns_overworld.py \\
  --source /private/hns/graphics/pokemon/rattata/overworld.png \\
  --output /private/Shattered-staged/Graphics/Characters/Rattata.png \\
  --expected-source-sha256 05e3e63cfbea4809604e09476320eebad923c93484ddd211ff12790013cdcf53 \\
  --expected-output-sha256 3b7119e99a4bba28ceeab6250792ca9d3aad6f3aa6ca2ead37fdbeb448efef03
```

The converter refuses mismatched hashes and writes atomically. The native installer separately checks the resulting 128×128 RGBA PNG structure and CRCs. These checks do **not** verify appearance, animation, event timing, or native Essentials/JoiPlay execution.

## Private HUMAN battle-back visual fallback

The original v0.4 project contains `Graphics/Trainers/POKEMONTRAINER_Red_back.png` (800×160 RGBA, five frames), but no `Graphics/Pokemon/Back/HUMAN.png`. Without a HUMAN battle-back sprite, an **actual native HUMAN-vs-Rattata battle** renders a question-mark placeholder. Use the rights-safe source-only converter below on a **private staged copy** to extract the first 160×160 frame, while final Shattered Survivalist battle art is being developed:

```sh
python3 scripts/stage_human_battle_sprite.py --project /private/Shattered-staged \
  --expected-source-sha256 9f5e0fa8b6c02b059085b1d75af994cf8f875c9c4f25c33b57f322dd28e7499c
```

The conversion output has SHA-256 `1cf99ece3c3dd3e456179984f2299cc19e78eb5ef74b84abf262312c95d88447` and is pixel-identical to the privately cropped frame that rendered successfully in mkxp-z. No trainer graphics or generated Pokémon sprites are committed to GitHub. This is **temporary fallback art**, not the planned modular outfit or final HUMAN battle presentation.

The actual private native diagnostic also reached HUMAN Lv5 vs Rattata Lv5, accepted battle commands, exchanged HP damage and returned numeric victory outcome 1. The battle was invoked after map spriteset initialization; it **does not** verify the mandatory Route 22 map event, stamina/type/capture behavior or Android.

## GitHub automation

A CI workflow validates every push/PR with Python and Ruby, including a miniature staged-project test. A separate 15-minute GitHub Actions watchdog reads the durable queue, identifies up to 3 dependency-ready tasks and creates deduplicated GitHub issues. **It coordinates work but does not autonomously write implementation code.** When source packages are provided, staging and consistency checks can run unattended in CI; gameplay still needs a valid engine/Android runner.
