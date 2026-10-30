# SE-019: native dojo questionnaire and no-ball starter (draft)

This is **executable Essentials v21.1 Ruby and a native RMXP event installer**, not an installed or playable demo claim. No game graphics or commercial scripts are included.

The original Shattered parity manifest identifies two NPC anchors in interior source map \`VIRIDIAN CITY · 5.2\` (10×9), source UUID \`b1d081d6-6600-4c9e-a280-a38a162831b1\`, at (6,4) and (3,5). **The source-only manifest does not establish which NPC is the dojo instructor or the exact original questionnaire dialogue.** The included three-question prompts and deterministic scoring are original provisional text. They must be reconciled with the user's authorised source before claiming parity.

The \`Shattered Dojo\` plugin uses \`$PokemonGlobal\` for append-only answers, deterministic Vulpix/Staryu/Exeggcute choice and one-time recruitment. It requires \`Shattered Core\` (including \`Shattered.befriend\` and genuine HUMAN party membership). It marks the awarded Pokémon in the save object so a save interrupted between recruitment and flag commit cannot create another reward. A full party preserves the choice and permits retry. It does not use Poké Balls. This is not yet a quest-system or follower integration.

In a **separately staged and authorised** Essentials v21.1 game with the Shattered Core plugin installed, add this plugin and a locally licensed NPC sprite. Create a reviewed JSON plan with these fields:

\`\`\`json
{
  "schema_version": 1,
  "source_map_uuid": "b1d081d6-6600-4c9e-a280-a38a162831b1",
  "role_reviewed": false,
  "passability_reviewed": false,
  "dojo_map_id": 45,
  "source_event_id": "5.2:npc:1",
  "source_position": [6, 4],
  "native_map_reviewed": false,
  "native_map_dimensions": [10, 9],
  "event_position": [6, 4],
  "character": "REPLACE_WITH_LICENSED_SPRITE_BASENAME",
  "expected_map_sha256": "REPLACE_WITH_REVIEWED_64_CHARACTER_LOWERCASE_SHA256"
}
\`\`\`

**The above is deliberately non-installable**: map ID and NPC role are illustrative, and review flags must remain false until checked against the original project. The ROM-source 10×9 layout is **not** assumed to be the native Essentials interior. The installer separately verifies the source NPC anchor and a reviewed native map size/position, then checks the actual staged tileset's static passage flags, map hash, staging marker, local sprite, existing events and idempotence. It refuses blocked/unknown or occupied native event tiles. These static checks are not proof that the player can reach or activate the instructor. Inside the staged project, call \`pbInstallShatteredDojo("path/to/reviewed-dojo.json")\` once from an Essentials debug script, then force native script compilation and run the scene.

Validation still required: real dojo map and collision, instructor identity, original dialogue/questionnaire logic, native Essentials event execution, HUMAN party and starter ownership, follower appearance, save/close/reopen, quest progression and JoiPlay/NaviaXP gameplay. Passing \`ruby tests/test_dojo.rb\` proves only isolated Ruby behaviour.
