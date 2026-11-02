# Shattered regional starter coverage and setup revision

Approved 3 November 2026. This extends the Ground/Fairy Bullgrum line revision in the DPE9 Shattered source patch.

| Line | Setup | Natural coverage |
| --- | --- | --- |
| Ghost Vulpix → Ghost/Fire Noctales | Nasty Plot 33 | Dark Pulse, Fire Spin, Flamethrower, Energy Ball; Noctales also gets Heat Wave |
| Ice/Psychic Staryu → Starus | Nasty Plot 42 | Psybeam, Signal Beam, Power Gem and Energy Ball |
| Grass/Dark Exeggcute → Exeggutive | Amnesia 57 and Swords Dance 60 on Exeggutive | Ancient Power; Exeggutive gains Fire Punch 50, Ice Punch 52 and Thunder Punch 54 |

Staryu and Starus no longer learn Water Gun, Bubble Beam or Hydro Pump: those were inherited base-species leftovers with no relation to their Ice/Psychic identity.

The Exeggutive physical suite is intentional. Its Fire, Ice and Thunder Punches pair with Swords Dance and 85 base Attack, while its 125 Special Attack still supports Grass/Dark special play. Nasty Plot strengthens Noctales’ Fire/Dark special attacks and Staryu/Starus’ Ice/Psychic/coverage attacks under the engine’s type-based Gen III physical/special split.

The changes are present in both `regional_manifest.json` and `donor-patches/dpe9.patch`. The source checkpoint still needs a full DPE rebuild plus table/emulator checks before a playable ROM can be claimed.