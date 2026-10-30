# SE-017 — Route 22 Rattata encounter (native RMXP event staging)

This implementation is **not a playable map or a validated battle**. It adds six native RMXP events to an authorised, separately staged Pokémon Essentials v21.1 project. No Pokémon assets, original ROM scripts, or private project files are included.

## Provenance and scope

The sanitised SE-015 source reference identifies Route 22 3.41 as UUID c4c03051-b9be-4d3c-a06c-bcde09a0e3a2, 48×24 tiles. Its three Rattata triggers are (36,16), (36,17), (36,18) and its three NPC anchors are (38,17), (39,16), (39,18). These are **source** positions, not independently verified Essentials coordinates. This installer refuses maps of other dimensions, occupied event tiles, or changed source-map bytes. It does not convert map tiles or create a new map.

The first player-touch trigger plays an original text prompt, schedules three native RPG Maker XP move routes, turns on a locally reserved scatter switch, and starts a real WildBattle.start(:RATTATA, 5) through the Shattered HUMAN plugin. Subsequent encounters skip the scatter. Battle rules disable Poké Balls and record the outcome in a configured variable. Only result 1 (victory) marks the persistent story flag and switches all six events to their blank pages. Flee, loss, abort and draw leave the encounter retryable. A captured outcome (4) is flagged as a release-blocking capture-protection violation, not accepted as success.

**The scatter directions (right, up, down) require in-engine passability and sprite checks.** The trigger strip also requires collision validation so the player cannot bypass the intended mandatory encounter. Native compilation, battle, visuals, and save/reload on a real device are not yet proven.

## Local installation

Use a separately staged project from scripts/stage_essentials.py, containing SHATTERED_STAGING_REPORT.json, an existing Route 22 MapNNN.rxdata, valid Data/MapInfos.rxdata, a locally licensed Graphics/Characters/Rattata.png (or another locally verified basename), and the real Shattered Core/HUMAN battle implementation. Do not commit the project or sprite.

First determine the actual Route 22 map ID, map-file SHA256, and unused global switch/variable IDs from the target project. Example **placeholders, not approved map IDs or resource reservations**:

    {
      "schema_version": 1,
      "source_map_uuid": "c4c03051-b9be-4d3c-a06c-bcde09a0e3a2",
      "map_id": 42,
      "expected_map_sha256": "REPLACE_WITH_64_LOWERCASE_HEX_SHA256",
      "outcome_variable": 91,
      "scatter_switch": 92,
      "cleared_switch": 93,
      "rattata_character": "Rattata"
    }

Save the reviewed JSON outside GitHub and install this plugin folder in Plugins/Shattered Route22. After compiling plugins with actual Essentials v21.1, run from the debug script console:

    pbInstallShatteredRoute22("/path/to/reviewed_route22_config.json")

The installer preflights all six locations, checks the SHA256 on first install, refuses partial/foreign prior installations, and uses a temporary map file plus rollback backup on ordinary exceptions. It does **not** rewrite original files or automatically overwrite existing events. Re-running the exact installation is byte-identical. If a process is killed between file renames, recover the .shattered_route22.bak manually rather than blindly rerunning.

## Evidence and remaining acceptance gates

Static Ruby syntax checks and the isolated tests in tests/test_route22.rb validate source positions, generated native RMXP event commands, page conditions, one-time scatter, battle outcome handling, save-state serialization, duplicate installation and preflight failures. These are synthetic tests, not an Essentials execution.

Still required: verify local reserved switch/variable IDs; install HnS gate and Route 22 maps; inspect all collision, event passability and transfers; install/compile the actual HUMAN battler, Hotfixes and battle dependencies; run a real Rattata fight with win/flee/loss and no Poké Ball capture; save/reopen; run the full demo and JoiPlay/NaviaXP playthrough. No release claim is justified yet.

API reference: https://essentialsdocs.fandom.com/wiki/Event_encounters documents WildBattle.start, setBattleRule("outcome", id) and outcome values; these are independently checked at runtime before claiming compatibility.
