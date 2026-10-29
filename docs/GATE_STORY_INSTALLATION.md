# SE-016: gate collapse and Aipom key (partial native-event implementation)

This is a **testable partial implementation**, not a playable scene or completed game. It adds a persisted `$PokemonGlobal` story state, six sound beats, two native RMXP events (collapse and Aipom) and replaces a *verified* existing south exit transfer with a blocked-route message. It does not import the Heart & Soul map, draw falling rocks, animate Aipom's tail/key, add a follower, or validate Android execution. The existing Heart & Soul gate import in PR #10 is a prerequisite; actual map IDs and coordinates must be inspected locally. No Pokémon art, original script or audio is included.

## Local staging (never edit original project)

1. Stage an authorised Pokémon Essentials v21.1 project with `scripts/stage_essentials.py` and retain `SHATTERED_STAGING_REPORT.json`. Compile the actual 22×21 gate into the staged project using the HnS converter/importer only after source rights and tile/collision mapping are resolved.
2. Run `python3 scripts/install_gate_key_pbs.py --project /absolute/path/to/staged`. It appends the original Shattered key item to `PBS/items.txt` exactly once and refuses a conflicting definition. Recompile PBS in actual Essentials. It is a **KeyItem**, not a TM.
3. Copy `essentials/Plugins/Shattered Gate Story/` into the staged project's `Plugins/` directory. Compile plugin scripts. Locally supply licensed six SE files, an Aipom cry SE, and a correctly formatted Aipom character sprite. The installer refuses missing files.
4. Create a **private** JSON configuration. All map ID, trigger tiles, sprite/audio basenames and the exact original south transfer command must come from the actual staged map. The example below uses synthetic IDs and coordinates and **must not** be applied as-is:

```json
{
  "schema_version": 1,
  "map_id": 10,
  "positions": {
    "collapse": {"x": 9, "y": 11},
    "aipom": {"x": 11, "y": 2},
    "johto_block": {"x": 11, "y": 19}
  },
  "collapse_sounds": ["rum1", "rum2", "rum3", "rum4", "rum5", "rum6"],
  "aipom_cry": "cry",
  "aipom_character": "Aipom",
  "expected_south_transfer": [0, 20, 10, 1, 2, 0]
}
```

5. In the staged project's **actual** RPG Maker XP/Essentials debug runtime, invoke `pbInstallShatteredGateStory("/absolute/path/to/private-config.json")` once, after the HnS gate importer and after local art/audio installation. It preflights the 22×21 map, map info, south transfer command, event coordinates, key PBS and local assets before writing, and uses a temporary file plus rollback backup. Running twice with identical config is idempotent. Do not run on an original project.
6. Start a **new game** and test south blocked exit, six timed sounds, Aipom key award, repeated interactions, save/close/reopen, interrupted scene recovery, native map/event render, no duplicate item and Android JoiPlay/NaviaXP. Verify actual collision and all other directions separately. The synthetic tests below **do not** count as these gates.

## Tests

```sh
ruby -c 'essentials/Plugins/Shattered Gate Story/001_GateStory.rb'
ruby -c 'essentials/Plugins/Shattered Gate Story/002_Install.rb'
ruby tests/test_gate_story.rb
python3 -m unittest discover -s tests -p 'test_gate_key_pbs.py' -v
```

## Explicitly open

- Licensed source art and audio (not provided), true HnS tileset/collision and imported map ID/door positions.
- Actual Essentials v21.1 Ruby API execution and PBS compilation; `pbSEPlay`, `pbWait`, `pbMessage`, `$bag.add`, `GameData::Item` and RMXP `RPG::Event` behavior must be checked in-engine.
- Collapse rock sprites/movement, flashes, Aipom tail key and north-facing animation, one-tile follower, exact original pacing and additional Johto story triggers.
- Full route linkage, battle, quest progression, save/reload and Android runner evidence.

This implementation is intentionally independent of Copilot PR #10 (gate map import), PR #11 (HUMAN battle), PR #6 (manifest) and PR #13 (world links). Do not merge until integration testing on an actual staged project and relevant human approvals.
