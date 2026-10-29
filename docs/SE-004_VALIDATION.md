# SE-004 implementation report

## Implemented

- Essentials save-data lifecycle methods create a genuine `Pokemon(:HUMAN, ...)` on new game and deduplicate existing HUMAN entries after save data is loaded. If `$player` is not available at that point, setup is deferred to Essentials' documented `:on_game_map_setup` event instead of raising during startup. If a loaded party is full and has no HUMAN, map setup preserves all six members, records `Shattered.human_setup_diagnostic`, and returns without raising. After the player makes room, `Shattered.recover_human` explicitly retries creation.
- Current stamina is stored on the saved `$PokemonGlobal` object. The maximum is level-scaled and capped; `Shattered.restore_stamina` resets the value for healing events.
- Essentials v21.1 move eligibility refuses unaffordable or unmapped HUMAN techniques. `STRUGGLE` is the only free, zero-stamina fallback, so no configured moves being selectable cannot softlock battle. A successful move-usability check debits the mapped cost once. HUMAN PP reduction is bypassed; non-HUMAN PP handling is unchanged.
- Poké Ball items are denied through the battle-only `ItemHandlers::CanUseInBattle` registry. Other battle items retain their own handlers. `Shattered.befriend` creates a real party Pokémon without a capture operation and is idempotent by species.
- Shattered Core is version `0.2.2`. No `Pokemon#calc_stats` override or external plugin source/assets were added. The existing single `[HUMAN]` PBS definition is unchanged.

## Upstream integration references

The implementation targets Pokémon Essentials v21.1:

- [`SaveData.load_new_game_values` and `load_all_values`](https://github.com/Maruno17/pokemon-essentials/blob/v21.1/Data/Scripts/002_Save%20data/002_SaveData_Value.rb)
- [`$player` new-game/save-load value registration](https://github.com/Maruno17/pokemon-essentials/blob/v21.1/Data/Scripts/002_Save%20data/004_Game_SaveValues.rb)
- [Documented `:on_game_map_setup` event](https://github.com/Maruno17/pokemon-essentials/blob/v21.1/Data/Scripts/003_Game%20processing/006_Event_HandlerCollections.rb)
- [`Game.start_new`/`Game.load` call order](https://github.com/Maruno17/pokemon-essentials/blob/v21.1/Data/Scripts/003_Game%20processing/001_StartGame.rb)
- [`Battle::Battler#pbCanChooseMove?` and `#pbTryUseMove`](https://github.com/Maruno17/pokemon-essentials/blob/v21.1/Data/Scripts/011_Battle/002_Battler/009_Battler_UseMoveSuccessChecks.rb)
- [`Battle::Battler#pbReducePP`](https://github.com/Maruno17/pokemon-essentials/blob/v21.1/Data/Scripts/011_Battle/002_Battler/003_Battler_ChangeSelf.rb)
- [`ItemHandlers::CanUseInBattle` Poké Ball handler](https://github.com/Maruno17/pokemon-essentials/blob/v21.1/Data/Scripts/013_Items/003_Item_BattleEffects.rb)
- [`GameData::Item#is_poke_ball?`](https://github.com/Maruno17/pokemon-essentials/blob/v21.1/Data/Scripts/010_Data/002_PBS%20data/006_Item.rb)

These are API integration references, not copied third-party code.

## Automated evidence

Commands run after the implementation:

```sh
ruby -c 'essentials/Plugins/Shattered Core/001_Core.rb'
ruby tests/test_shattered_core.rb
python3 scripts/validate_integration.py
python3 -m unittest discover -s tests -v
```

Review follow-up results: Ruby syntax OK; Ruby tests **24 runs, 173 assertions, 0 failures**; integration manifest/queue validation passed (**7 plugins, 23 tasks**); Python tests **9 passed**. Coverage includes Struggle fallback, delayed player setup, full-party preservation/no exception, diagnostic reporting, and explicit retry after a party slot is freed.

## Compatibility and remaining blockers

- The hooks target the cited Essentials v21.1 methods and item registry. A game project or plugin that replaces these methods/handlers needs a compatibility review and native battle test.
- Essentials v21.1 registers `$player` as the first save value and constructs/loads it before `load_new_game_values`/`load_all_values` return. If a custom project still has no player after that callback, HUMAN setup is deferred until the documented map-setup event; that event is a recovery path, not runtime test evidence.
- The diagnostic is an in-session recovery aid, not a save-file migration. A loaded full party remains unchanged until the user explicitly frees a slot and calls `Shattered.recover_human`; no companion is automatically deleted or replaced.
- `Shattered.restore_stamina` is an API for healing events; an authorized project healing event must call it. The repo does not supply or verify an automatic Pokémon Center healing hook.
- Native PBS compilation, actual Essentials save/reload and battle execution, follower/storage behavior, and JoiPlay/NaviaXP remain unverified. The integration recipe below is the outstanding validation gate.
- The integration validator currently lists `SE-002`, `SE-013`, and `SE-015` as ready queue items; no queue/manifest files were changed here.

## Native and device gates — OPEN

The sandbox does not contain a licensed, native Essentials v21.1 project or a JoiPlay/NaviaXP device. These checks have **not** been run.

1. In a legally held, unmodified Essentials v21.1 project, stage to a fresh output (preserving the input) with `python3 scripts/stage_essentials.py --project /path/to/Essentials21.1 --output /path/to/fresh/output`. Compile PBS with the native compiler and confirm `[HUMAN]` appears exactly once in `PBS/pokemon.txt`.
2. Start a new game and verify one HUMAN in the party; save, close, reopen and continue. Confirm there is still exactly one HUMAN and current stamina survives save data.
3. In a battle, verify an affordable HUMAN move spends its configured cost once, an unaffordable/unknown move is refused, failed/fled actions do not spend, HUMAN PP is not consumed, Pokémon PP behaves normally, Poké Balls are refused, and a Potion remains usable.
4. Call `Shattered.restore_stamina` from the project's authorized healing event and confirm stamina resets to the level cap.
5. Repeat new-game, battle, healing, and save/reopen checks on JoiPlay/NaviaXP. Record device/runtime, results, and logs before closing either gate.
