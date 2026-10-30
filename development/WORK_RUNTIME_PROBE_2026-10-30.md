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
