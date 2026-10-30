# Latest follow-up — 2026-10-30

## Native Linux follow-up: launch blocker bypassed

The Wine restriction remains, but is no longer the only execution path. Downloaded official mkxp-z push-build dev-37a04d1 (run 37110075912, Linux Ubuntu Xenial x86_64 artifact) via nightly.link. Xvfb TCP display with supplied xkbcomp works in Work. OpenAL null backend (ALSOFT_DRIVERS=null) avoids absent physical audio hardware; actual audible playback remains unverified.

Actual hands-on execution of the preserved v0.4 base: title screen rendered; XTest keyboard Return opened New Game menu; New Game loaded reception-gate prototype; advanced through Twenty Years Later and tremor/collapse/Johto-blocked messages. Captured real framebuffer screenshots for title, menu, opening and final map state. Interpreter input visibly advances dialogue. Runtime remained alive until operator termination.

Not verified: save/reload, player movement/collision, HUMAN battles/equipment, Aipom, Route22, Viridian, audio playback. No player sprite visible in final opening screenshot; menu/save access was not established. These require diagnosis before playable acceptance. This is existing v0.4 prototype execution, NOT execution of the newly integrated main source and NOT faithful HnS conversion or full remake completion.

Use this native route for subsequent real candidate tests rather than retrying Wine. Persistent recipe: official runtime + Ruby stdlib/preload files beside game; Xvfb -nolisten unix -listen tcp -ac; DISPLAY=127.0.0.1:<port>; software Mesa; ALSOFT_DRIVERS=null; xkbcomp and dependencies accessible to Xvfb. No user game assets or screenshots uploaded to GitHub.

---

# Work runtime execution probe — 2026-10-30

User requested hands-on game execution in Work, with CI supporting only.

## Actual execution
- Recovered full authorised v0.4 project, SHA256 c6fa8d1fca79718419cf6fcfaba523e055305cc3f03b2a0c2937e2cf1fc8870e.
- Inspected executable: Game.exe is PE32+ x86-64. This is the existing prototype, not a newly integrated Victory Road-to-Viridian candidate.
- Downloaded Wine 9.0 and dependencies plus Xvfb into private workspace. Wine reports version successfully.
- Started Xvfb with TCP display fallback after local socket listeners failed.
- Attempted actual Game.exe launch under Wine. Corrected Wine's extracted wineserver launcher path.
- Final launch fails before gameplay: `wineserver: socket: Operation not permitted`.

## Status
Game launch: BLOCKED by Work sandbox socket restriction for Wine server. Opening/events/battles/equipment/transitions/save/reload: NOT RUNTIME VERIFIED. No gameplay screenshot exists because no game window was reached. No public game assets uploaded. Native Linux mkxp is not provisioned or tested; do not infer that all possible execution environments are impossible.

## Continuation
Preserve tested source integration and independent development. Runtime acceptance requires an executable supported Work environment or an authorised connected test environment; CI cannot replace this gate. Read actual current map/assets/plugin blockers before assembling a new candidate. Do not label recovered v0.4 as the finished remake.
