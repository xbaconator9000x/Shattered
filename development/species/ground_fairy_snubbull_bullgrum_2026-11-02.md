# Shattered regional Snubbull → Bullgrum: Ground/Fairy revision

Approved 2 November 2026.

Both regional forms are now **Ground/Fairy**. Ordinary Snubbull and Granbull remain separate vanilla Fairy species.

| Form | HP | Atk | Def | SpA | SpD | Spe | BST |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Shattered Snubbull | 70 | 100 | 55 | 15 | 60 | 80 | 380 |
| Shattered Bullgrum | 100 | 145 | 90 | 30 | 90 | 100 | 555 |

The underlying expanded-engine table stores the six values as `HP, Attack, Defence, Speed, Sp. Atk, Sp. Def`, so the source rows are:

- Snubbull: `70, 100, 55, 80, 15, 60`
- Bullgrum: `100, 145, 90, 100, 30, 90`

The change preserves the prior 380/555 BST targets. It replaces Fighting and Ground/Fighting typing. Intimidate, Rock Head, the level-30 evolution and ordinary species remain unchanged.

## Ground/Fairy learnset compliance

The old level-up lists were Fighting-focused and supplied no damaging Fairy move. They have been replaced with a physical Ground/Fairy progression:

- **Snubbull:** Mud-Slap 11, Bulldoze 22, Play Rough 30, Stomping Tantrum 34, Dig 38, High Horsepower 53 and Double-Edge 58.
- **Bullgrum:** Mud-Slap 1, Bulldoze 22, Play Rough 30, Stomping Tantrum 34, Dig 42, Earthquake 46, Double-Edge 49, High Horsepower 54 and Head Smash 58.

Bite and Crunch remain Dark coverage; Charm, Scary Face, Tail Whip, Roar, Lick and Take Down keep the intended bulldog utility. Low Kick, Revenge, Brick Break, Cross Chop and Superpower were removed from level-up progression. Rock Head now gives Bullgrum a deliberate late-game Head Smash payoff.

Implementation source: the DPE9 Shattered regional-form patch and its regional manifest. The exact source-patch archive is retained in the project Library. This remains **source-level implementation**, not a playable-ROM confirmation: the v0.39 checkpoint’s compiled object artifacts predate the change. Rebuild DPE data objects, then run table and emulator checks before release.