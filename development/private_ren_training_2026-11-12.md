Ren lesson and curriculum integration
====================================

The private ROM upgrade now installs Ren on native dojo Map015 event 1.
After Mara's supply reward, Ren grants a nonconsumable Training Manual and
offers Quick Attack to the party's HUMAN through Essentials' pbLearnMove.
The lesson completes only when the HUMAN actually knows the move. Full Bag,
declining the lesson and cancelling move replacement leave progress retryable;
the granted book is not duplicated after save/reload.

The hash-gated extractor recovers 171 class definitions (starting HUMAN,
17 primary paths, 153 combinations) and 5,850 level-up entries, with original
names, stats, types and passive names. The private candidate stores these in
Data/shattered_training.dat. The Bag manual explicitly identifies them as a
ROM curriculum reference; reading it does not implement class mechanics.
Neither source text nor extracted curriculum data is committed here.

Reproduction uses the same v14 input as the previous chapter build:

    python3 scripts/upgrade_private_hns_from_rom.py --candidate PRIVATE_V14 --rom PRIVATE_ROM --output FRESH_OUTPUT

Checks performed locally:

- Ren regression: 5 tests, 37 assertions; rest/tour/supplies: 5 tests, 50 assertions.
- Plugin compiler: 17 tests, 107 assertions; candidate upgrade: 1 test, 8 assertions.
- Python extraction tests: 4 tests pass (dialogue and training).
- Actual private candidate rebuild: 402 native scripts and 14 plugin scripts pass Ruby syntax audit; compiled/editable plugin coherence passes.
- Two fresh builds produce identical bytes for the five changed maps, compiled plugins, items, switch registry, curriculum and item PBS (10 files).

Not runtime acceptance: the native engine was not launched. Battle UI,
move-replacement UI, real save/reload and field interaction need engine testing.
The night raid/rescue sequence remains unported: source scripts select encounters
through custom specials 454/455, whose battle parameter mapping has not yet been
recovered. Full HUMAN specialisation mechanics and mounted movement are also
unfinished. No claim of full quest completion is made by this batch.
