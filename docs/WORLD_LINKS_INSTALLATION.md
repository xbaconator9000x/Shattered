# SE-017 — Source-indexed native RMXP world transfers

This PR contains a real RMXP transfer-event installer, NOT a map importer or a playable game. It creates native RPG::Event entries with EventCommand 201 in a separate staged project. It does not include or redistribute ROMs, game graphics, scripts, source dialogue, tiles or commercial assets.

## Inputs

1. The sanitised SE-015 reference at development/demo_parity_reference.json (from PR #12).
2. A LOCAL, manually verified mapping of each source map UUID to an actual target RMXP map ID, width and height, plus each selected source link UUID to both explicit target endpoint positions.
3. A separate Essentials v21.1 project staged with scripts/stage_essentials.py, with SHATTERED_STAGING_REPORT.json and the actual MapNNN.rxdata files. The Heart & Soul gate importer and other map authoring must run before this step.

Example mapping JSON (illustrative only, not real coordinates):

    {
      "schema_version": 1,
      "maps": {
        "source-map-A": {"target_map_id": 10, "width": 20, "height": 20},
        "source-map-B": {"target_map_id": 11, "width": 12, "height": 12}
      },
      "links": {
        "source-link-id": {
          "from": {"x": 3, "y": 4, "landing_x": 3, "landing_y": 5, "direction": 2},
          "to": {"x": 2, "y": 3, "landing_x": 2, "landing_y": 4, "direction": 8}
        }
      }
    }

The x/y coordinates are the player-touch trigger tiles. The landing_x/landing_y coordinates are the safe tiles on which the player appears after entering from the other map, NOT the trigger tiles. Direction is the arrival facing: 0 preserve, 2 down, 4 left, 6 right, 8 up. Optional fade is 0 or 1. One-way vs two-way comes from the source link, never guessed. No default mapping is committed because the target map IDs, geometry and passability are not yet validated.

Generate the plan with:

    python3 scripts/build_world_links.py --reference development/demo_parity_reference.json --mapping /local/verified/world_links_mapping.json --output /local/staged/world_links_plan.json

Use --require-all to reject any of the 36 source links that still lacks a reviewed mapping. Without that flag, the plan explicitly records unmapped links and does not pretend completeness.

Copy the Shattered World Links plugin folder into the staged project's Plugins directory. Compile plugins in the real Essentials v21.1 debug runtime, then run from its debug script console:

    pbInstallShatteredWorldLinks("/local/staged/world_links_plan.json")

The installer requires the staging report, verifies every map and dimension, rejects occupied event tiles and warp loops, and preflights before writing. It uses temporary files and rollback backups for ordinary Ruby exceptions. A power loss during multi-map replacement can require manual recovery from .shattered.bak files. Running it twice is idempotent.

Tests:

    python3 -m unittest discover -s tests -v
    ruby -c 'essentials/Plugins/Shattered World Links/001_Install.rb'
    ruby tests/test_world_links.rb

## Still open

No actual target map/doorway mapping is yet approved, and this PR has not modified the user's project. Native RPG Maker XP compilation, collision/passability, correct door facing, map transitions, save/reopen and JoiPlay/NaviaXP playtesting are UNVERIFIED. Tests use synthetic map objects and cannot satisfy the full-demo acceptance gate.
