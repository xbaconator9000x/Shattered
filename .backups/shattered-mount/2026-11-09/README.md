# Shattered Crystal mounts source snapshot — 9 November 2026

Private archival checkpoint. This folder preserves the source-level work for the partner-ride integration and the v0.39/DPE9 Crystal/regional-species overlay. It is separate from active game development and does not replace the existing hard backups.

## Preserved implementation

- Crystal Onix selector: species ID 272 (shown in-game as Onix)
- Crystalix selector: species ID 273
- Existing selectors retained: Onix 95 and Bullgrum 262
- The selector patch relocates the four-entry profile table to unused injected-ROM space, then dispatches each distinct species ID to its own frame and palette bank.

`enable_crystal_profiles.py` is the reproducible source patch for the experimental xx1.06 ROM. `dpe9-overlay/` preserves the v0.39/DPE9 registration definitions. `riding-prototype/` preserves the native mount renderer source from which the hook was adapted.

The binary release and its full asset archive are retained in ChatGPT Library as `Shattered_All_Three_Mounts_Experimental_Release.zip` and `Shattered_v039_DPE9_Crystal_Regional_Integration.zip`; SHA-256 values are recorded in `integrity-manifest.txt`. Binary ROMs are intentionally not committed directly to avoid confusing this source backup with a production build.

Validation at capture: the patched 32 MiB test ROM booted through 900 mGBA frames; table inspection confirmed profile IDs 95, 262, 272 and 273. Crystal species still need registration merged and compiled from the v0.39/DPE9 overlay before they can be obtained normally in gameplay.