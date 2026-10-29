# SE-019B Beedrill raid slice

This adds only three sequential native Beedrill encounters. It is not the Murkrow
rescue, dojo, full Viridian quest, map art, or a door/window chase. It does not
establish compiled Essentials gameplay or Android JoiPlay/NaviaXP playtesting.
Those acceptance gates remain open.

## Staging and reviewed map config

Work on a fresh output made with `scripts/stage_essentials.py`; never install
into the source project. Copy `essentials/Plugins/Shattered Raid/` into that
staged project's `Plugins/` directory after Shattered Core. Compile the project
in Essentials before testing. The raid will refuse to start unless compiled
HUMAN and BEEDRILL and a real HUMAN party member are present.

There is deliberately no default map ID, NPC identity, coordinate, dialogue,
or sprite. The manifest's source anchors do not establish which NPC is a
Beedrill or where a chase occurs. An installer config must be assembled from
reviewed native source data and include:

- `reviewed: true`, exact positive `map_id`, source `expected_sha256`, and
  `width: 48`, `height: 40`.
- `switches_reviewed: true` and `outcome_variable_reviewed: true`, after
  reserving four unused game IDs (three switches and one outcome variable).
- Exactly three `events`, in index order `0..2`. Each needs the exact role
  `beedrill_threat_1`, `_2`, or `_3`, `role_reviewed: true`, an existing
  distinct `source_anchor_event_id`, and `source_anchor_reviewed: true`.
- Explicit in-bounds `x`, `y`, `level`, unique positive `switch_id`, available
  local `sprite_name` (without extension), and `sprite_hue`.

The installer checks the staging marker, target map digest/dimensions, source
anchor IDs, sprite files, occupied and duplicate tiles, and passability in all
four directions before writing. It creates native `RPG::Event` pages with a
switch-controlled hidden page after victory. A valid SHA256 backup is retained
for recovery; stale backups/temporary files and modified target maps are
refused. Re-running an exact install is a no-op.

Run installation from the staged game while its reviewed target map is loaded.
Pass a passability callback backed by that live map; restart the game after
installation so the newly written native map is loaded:

```ruby
passability = proc do |_map, x, y, direction|
  $game_map.map_id == reviewed_config["map_id"] &&
    $game_map.passable?(x, y, direction)
end
ShatteredRaid.install_staged(Dir.pwd, reviewed_config, passability)
```

`reviewed_config` must be the full config described above, not guessed values.
No scene dialogue or source graphics are supplied by this plugin.

## Runtime and evidence

Each event calls `WildBattle.start(:BEEDRILL, level)` with Poké Balls disabled
and an outcome variable. Only outcome `1` advances one encounter. Flee, loss/
blackout, undecided outcome, exception, or interruption leaves progression
retryable. Progress and completion are versioned on `$PokemonGlobal`; map
switches are reconciled on map setup and after battle. The slice grants no
rewards, so retries cannot duplicate rewards.

The isolated CI and Minitest suite exercise Ruby stubs only. They are not a
substitute for compiling the plugin in Essentials v21.1 or testing a complete
game on desktop or Android.
