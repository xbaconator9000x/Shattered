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

The change preserves the prior 380/555 BST targets. It replaces Fighting and Ground/Fighting typing. Intimidate and Rock Head remain its regular abilities. **Huge Power is the inherited hidden ability**: a hidden-ability Snubbull remains hidden-ability Bullgrum.

## Ground/Fairy level-up set

The physical Ground/Fairy core remains clear: Mud-Slap, Bulldoze, Play Rough, Stomping Tantrum, Dig, High Horsepower and Bullgrum’s Earthquake. The line also keeps its broader bulldog toolkit:

- **Snubbull:** Swagger 17, Bulk Up 34, Cosmic Power 48, Double-Edge 58 and Superpower 63.
- **Bullgrum:** Swagger 17, Bulk Up 34, Cosmic Power 49, Superpower 58, Double-Edge 61, Crunch 64 and Head Smash 67.

Bite and Crunch provide Dark coverage, while Charm, Scary Face, Tail Whip, Roar and Lick retain the intended bulldog utility. Low Kick, Revenge, Brick Break and Cross Chop are removed from level-up progression because they were only present to carry the former Fighting identity. Rock Head gives the late Head Smash its intended payoff; Huge Power is deliberately restricted to the hidden ability.

Implementation source: the DPE9 Shattered regional-form patch and its regional manifest. The exact source-patch archive is retained in the project Library. This remains **source-level implementation**, not a playable-ROM confirmation: the v0.39 checkpoint’s compiled object artifacts predate the change. Rebuild DPE data objects, then run table and emulator checks before release.