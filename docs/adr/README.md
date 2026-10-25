# Decision records

One file per decision, numbered. Desk disagreements become ADRs. Format: Status, Date,
Deciders, Context, Decision, Consequences. `adrs` (joshrotenberg/adrs) manages this
directory once the desk adopts it; until then, copy `0003-chassis.md` as the template.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-adopt-spec-v0.2.md) | Adopt SPEC v0.2 as the design | accepted |
| [0002](0002-adlc-sharded-ticket-store.md) | ADLC 1.12's sharded store is the ticket source of truth | accepted |
| [0003](0003-chassis.md) | The chassis | accepted |
| [0004](0004-halt-two-person-rule.md) | The HALT two-person rule GitHub cannot express | accepted |
| [0005](0005-run-loop-cli-reality.md) | The run-loop sketch against the real CLIs | proposed |
| [0006](0006-bwrap-shim-for-fleet-1-12-0.md) | A temporary bwrap shim for fleet 1.12.0's canary (#1266); retires with the re-pin | accepted |
