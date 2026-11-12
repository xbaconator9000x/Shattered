Viridian night raid recovery and native installation
===================================================

Recovered the authenticated registered-mounts ROM's special-function table at
0x163D2C and special 454 encounter builder at 0xEB2960. The extractor evaluates
the builder's bounded Thumb selection code rather than substituting assumed
levels. It stops before game-function calls. This is static ROM recovery, not
emulated gameplay evidence.

The five source victim scripts select three Beedrill (levels 6, 6 and 8) and
two Raider species opponents (both level 8). Their four moves, fixed IVs and
personality come from the ROM. Species 253 is RAIDER, not the player's HUMAN.
The private build installs its source base stats, Insomnia, original front art
and the source Beedrill front/stat line. Raider uses native slot-9 QMARKS to
avoid adding Normal STAB; Core supplies the HUMAN defensive chart. It remains
a separate enemy species, not a party HUMAN or recruitable quest reward.

After Mara's supply reward, resting with Hana starts the native night raid.
Five new native victim interactions appear in Viridian. Each invokes a real
Essentials WildBattle with the recovered opponent, capture/run disabled and
retryable defeat. Rescues can be completed in any order and only decision 1
records victory. Completion hides the actors and permits morning rest, then
Ren's dojo lesson. Saved progression restores their self switches on Continue.
Ren's lesson is now gated on the completed night, correcting its earlier
availability immediately after the supply run.

Victim positions and NPC sheets are adapted to the existing Essentials city;
original ROM map geometry, chase movement and cinematic routes are not ported
by this installer. Dialogue, recovered curriculum, sprites and native assets
remain in the private candidate only. The source repository contains recovery
and installation logic, not those assets.

Enemy HUMANs previously shared the player's global stamina through the Core
battle hooks. Those hooks now check native battler ownership; enemy HUMANs
retain native PP and cannot drain the player's stamina. Raider has native PP
as an independent species and receives the HUMAN defensive matchups.

Validation: local recovery from the exact ROM; bounded evaluator unit tests;
native quest API tests for five wins, loss/draw/escape/skipped outcomes, battle
exceptions, reentrancy, prerequisites, Marshal save-state restoration and
duplicate-trigger rejection; Core enemy PP/stamina/type regressions; Ren and
existing Viridian/healing tests. Actual private rebuild and source/archive
coherence checks are separate from engine gameplay acceptance.

Native engine launch, battle UI, actual save/reload and field playthrough remain
unverified. The forest confrontation and remaining full-ROM story integrations,
complete HUMAN class mechanics, chase choreography and real mounted movement
are not declared complete by this batch.
