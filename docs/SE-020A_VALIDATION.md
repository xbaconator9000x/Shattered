# SE-020A — Shattered Equipment adapter

This plugin is an adapter for Pokémon Essentials v21.1 and the Shattered Core battle/stamina hooks in PR #11 (Core 0.2.2). It does not change Core, global scripts, item PBS, or the plugin manifest. The bundled Core in this checkout predates those hooks; with it, equipment moves are deliberately unavailable until PR #11's API is present.

## Contracts

- Equipment is stored on the HUMAN Pokémon as a versioned hash keyed by the six canonical slot symbols: `:head`, `:torso`, `:left_hand`, `:right_hand`, `:legs`, and `:feet`. Essentials serializes the Pokémon with save data; the adapter does not put gear on companions or add granted moves to the saved Pokémon move list.
- Default item IDs map as follows: `:KNIFE` → `:SLASH`, `:BRAZIER` → `:EMBER`, `:SLING` → `:ROCKTHROW`, `:SPRAYGUN` → `:BUBBLE`, and `:BUCKLER` → `:DEFENSECURL`. IDs and move definitions are checked against the project's `GameData`; unknown item or move IDs fail closed. The IDs are adapter expectations, not new PBS item definitions.
- The Sling is two-handed and occupies both hand slots. Conflicting gear is rejected without changing the existing equipment. Replacing an item in the same canonical slot is allowed.
- The adapter adds temporary `Battle::Move` objects after Essentials v21.1 `Battle::Battler#pbInitPokemon`. It uses `Pokemon::Move.new` and `Battle::Move.from_pokemon_move`; duplicate move IDs are not appended. The default v21.1 fight menu exposes `Pokemon::MAX_MOVES` buttons, so grants replace trailing moves only in the HUMAN battler's temporary move list. The saved HUMAN moves and companions remain unchanged. Configurations exceeding that menu capacity are rejected.
- It does not debit stamina or change PP. Before adding moves it asks Shattered Core to install its idempotent battle hooks; Core remains responsible for move eligibility, the single successful-use stamina debit, and HUMAN PP behavior. If the Core hooks or Essentials constructors are unavailable, no equipment moves are added.

## Source references

- Pokémon Essentials v21.1 `PBS/moves.txt` defines the canonical move IDs/names used here, including `[SLASH]` / `Slash`, `[EMBER]` / `Ember`, `[ROCKTHROW]` / `Rock Throw`, `[BUBBLE]` / `Bubble`, and `[DEFENSECURL]` / `Defense Curl`: <https://github.com/Maruno17/pokemon-essentials/blob/v21.1/PBS/moves.txt>
- Pokémon Essentials v21.1 `Battle::Battler#pbInitPokemon` loads `pkmn.moves` into battle-only `Battle::Move` objects: <https://github.com/Maruno17/pokemon-essentials/blob/v21.1/Data/Scripts/011_Battle/002_Battler/002_Battler_Initialize.rb>
- Pokémon Essentials v21.1's move-selection scene reads the battler's move list: <https://github.com/Maruno17/pokemon-essentials/blob/v21.1/Data/Scripts/011_Battle/004_Scene/003_Scene_ChooseCommands.rb>
- Pokémon Essentials v21.1's `Battle::Scene::FightMenu` creates exactly `Pokemon::MAX_MOVES` move buttons: <https://github.com/Maruno17/pokemon-essentials/blob/v21.1/Data/Scripts/011_Battle/004_Scene/005_Battle_Scene_Menus.rb>
- The adapter does not copy upstream code or assets. Shattered Core's shared-stamina battle contract is from PR #11, not duplicated here.

## Validation

Run `ruby -c 'essentials/Plugins/Shattered Equipment/001_Equipment.rb'` and `ruby tests/test_equipment.rb`. These tests use Ruby doubles for Essentials data, move construction, serialization, and Core's shared-stamina API. They validate the adapter contract, not a compiled game.

This checkout has no licensed Essentials project, native item PBS definitions for the default gear IDs, DBK archive, or runtime. Therefore PBS compilation, item/UI integration, real battle/save-load execution, and JoiPlay/NaviaXP playback remain open. Define the expected items in the authorized game project and validate a freshly staged copy before claiming runtime support.
