# SE-004 implementation report

## Implemented

- Essentials save-data lifecycle methods create a genuine `Pokemon(:HUMAN, ...)` on new game and deduplicate existing HUMAN entries after save data is loaded. A missing player or full party produces a clear `ArgumentError`.
- Current stamina is stored on the saved `$PokemonGlobal` object. The maximum is level-scaled and capped; `Shattered.restore_stamina` resets the value for healing events.
- Essentials v21.1 move eligibility refuses unaffordable or unmapped HUMAN techniques. Successful move-attempt checks debit the mapped cost once. HUMAN moves do not consume PP; non-HUMAN PP handling is unchanged.
- Poké Ball items are denied through the battle-only `ItemHandlers::CanUseInBattle` registry. Other battle items retain their own handlers. `Shattered.befriend` creates a real party Pokémon without a capture operation and is idempotent by species.
- No `Pokemon#calc_stats` override or external plugin source/assets were added. The existing single `[HUMAN]` PBS definition is unchanged.

## Upstream integration references

The implementation targets Pokémon Essentials v21.1:

- [`SaveData.load_new_game_values` and `load_all_values`](https://github.com/Maruno17/pokemon-essentials/blob/v21.1/Data/Scripts/002_Save%20data/002_SaveData_Value.rb)
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

Final results are recorded in the PR summary.

## Native and device gates — OPEN

The sandbox does not contain a licensed, native Essentials v21.1 project or a JoiPlay/NaviaXP device. These checks have **not** been run.

1. In a legally held, unmodified Essentials v21.1 project, stage to a fresh output (preserving the input) with `python3 scripts/stage_essentials.py --project /path/to/Essentials21.1 --output /path/to/fresh/output`. Compile PBS with the native compiler and confirm `[HUMAN]` appears exactly once in `PBS/pokemon.txt`.
2. Start a new game and verify one HUMAN in the party; save, close, reopen and continue. Confirm there is still exactly one HUMAN and current stamina survives save data.
3. In a battle, verify an affordable HUMAN move spends its configured cost once, an unaffordable/unknown move is refused, failed/fled actions do not spend, HUMAN PP is not consumed, Pokémon PP behaves normally, Poké Balls are refused, and a Potion remains usable.
4. Call `Shattered.restore_stamina` from the project's authorized healing event and confirm stamina resets to the level cap.
5. Repeat new-game, battle, healing, and save/reopen checks on JoiPlay/NaviaXP. Record device/runtime, results, and logs before closing either gate.
