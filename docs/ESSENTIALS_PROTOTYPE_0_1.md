# Shattered: Essentials prototype 0.1

Status: full project assembled from uploaded files, static tests passed; Android gameplay not yet tested.

## Actual map provenance
- Johto-style test chamber: new map 222, adapted from South Rock Cave map 146 of Remastered Kanto Johto Map Pack. IMPORTANT: the supplied pack contains NO Johto Victory Road map. This is only a temporary Johto-style cave, not the actual Shattered opening map.
- Kanto Route 22: FRLG template map 16.
- Kanto Viridian City: FRLG template map 10.

## Event sequence
Start map 222 at 23,18: Twenty Years Later, tremors, collapsing entrance, level 5 Machop nicknamed HUMAN.
Aipom key action event at 24,18 (temporary Meowth overworld sprite). After retrieving key, step east onto 25,18.
Transfer to Kanto Route 22 at 30,17: mandatory Rattata level-5 battle. Step east to 32,17 to enter Viridian at 25,20 and read the end-of-test dialogue.
Existing original rival events on Route 22 were removed from the copied test only.
Barricades are narrative only; custom battler, regional forms and accurate Johto Victory Road layout are deferred.

## Tests
- Five Ruby tests passed, 28 assertions, zero failures.
- Six scripted event tiles checked as passable using the actual RPG Maker XP Table and Tilesets passage values.
- Full project contains Game.exe, Game.ini and complete source engine. 7,674 files retained/assembled.
- 7,664 original FRLG files kept, with six deliberately modified. Nine imported map/graphics files plus START_HERE.txt added.
- ZIP integrity test passed, compressed size 159,491,818 bytes.
- SHA256: fb60675678ff38a2feef9ef34a5d728bb402ab82ad502e5d9396f85dd1f1abb4.

## Android
Extract the full game ZIP and use JoiPlay with its RPG Maker plugin, adding Game.exe; or select Game.ini folder using NaviaXP. Begin a NEW game. APK runtime, save/load and battle are not verified yet.

## Distribution and sources
Actual ZIP and Ruby source patch kit are supplied in the source-archives ChatGPT conversation. Third-party assets are NOT committed to GitHub; keep the repo private. This project is separate from Essentials Studio Mobile and the original Shattered ROM hack.
