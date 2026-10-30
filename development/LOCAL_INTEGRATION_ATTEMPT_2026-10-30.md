# Local integration attempt — 2026-10-30

Full v0.4 project recovered from the existing authorised archive (159,578,449 bytes; 7,675 ZIP entries). Original archive preserved. No game assets uploaded to GitHub.

Actual local results:
- Integration manifest validated: 12 source PRs, 49 source files, 10 components, 7 map slots.
- 20 integration/staging Python tests passed.
- All 49 pinned files fetched successfully; combined contract tree assembled with all 10 Shattered plugins and HUMAN/SHATTEREDGATEKEY PBS sections without duplicate plugin/PBS targets.
- Six HnS converter tests passed.
- This assembly is a contract tree, NOT a compiled or playable game.

Concrete remaining inputs:
- Recovered base contains Hotfixes 1.0.3, whereas manifest pins 1.0.9. Deluxe Battle Kit and Enhanced Battle UI archives are absent from the base.
- Base contains Audio/SE/Cries/AIPOM.ogg and RATTATA.ogg. Reuse these existing private inputs after recording hashes; do not ask user to resupply cries.
- HnS metatile mapping, converted tileset and actual target map/resource allocations remain required by initial_slice; base prototype must not be called the faithful HnS map.
- Native Ruby executable absent in this executor. Standard package installation failed due to container setgroups/setuid restrictions. Run Ruby contract suites in existing GitHub CI rather than reporting local Ruby success.
- A manually assembled PR-6 test tree lacked plugin_manifest.json; this is a limitation of partial local materialisation, not proof of a production test failure. Use the official full-checkout contract runner for authoritative CI.

Next execution: resolve existing private inputs and acquire authoritative plugin distributions; use initial_slice preflight, then stage into a fresh copy. Record native engine compile and real save/reload separately. Do not mark integrated or increment runtime completion on the basis of these static results.
