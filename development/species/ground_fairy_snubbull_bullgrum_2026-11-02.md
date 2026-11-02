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

The change preserves the prior 380/555 BST targets. It replaces Fighting and Ground/Fighting typing. Abilities, learnsets, evolution at level 30 and the ordinary species are unchanged.

Implementation source: the DPE9 Shattered regional-form patch and its regional manifest. A source archive with the exact edited patch/manifest is retained in the project Library. The v0.39 checkpoint's compiled object artifacts predate this edit; rebuild the DPE data objects and rerun table/emulator checks when the full engine checkout is next assembled.