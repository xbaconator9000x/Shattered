# Shattered ROM hard backup — 1 November 2026

Private archival checkpoint only. Separate from the Pokémon Essentials remake and its runtime assets. Do not modify these files during development or content removal.

- **xx0.95**: current compacted build, matching PokéBacon JSON, repair scripts, compaction ledger, and validation evidence.
- **xx0.92**: earlier pre-consolidation checkpoint, matching PokéBacon JSON, native patch details, validation evidence, and xx0.91 reconstruction ROM.

Both original backup ZIPs are preserved byte for byte in numbered parts. Each ZIP includes its ROM and matching JSON. The manifest records sizes and SHA-256 hashes for every part, archive, and archived member.

To restore, download or clone this complete folder and run `python3 restore.py`. It reconstructs both original ZIPs in `restored/`, verifies their checksums and ZIP integrity, and checks every member. Extract the desired ZIP and use its ROM with its matching JSON.

The dot-prefixed folder is a project-only archive. Its privacy comes from the private repository, not the folder name. No purge is part of this backup commit.
