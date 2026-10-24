# ADR-0003: Chassis (the one open decision)

- Status: proposed
- Date: 2026-10-24

## Context

The spec assumes ADLC `fleet` composed by `ru` as the chassis (ticket → sandboxed run → PR).
The supersession pass surfaced two single-machine chassis with wider adapter support:
Untrivial-ai/agent-orchestrator (mature, 20+ harnesses, Go daemon) and Bernstein
(deterministic gating, 31 adapters, one month old). Neither does multi-machine over a
public repo; both would sit under this spec's claim protocol and gates exactly as fleet
does. Earlier candidates: norma, Fabro, Symphony's `SPEC.md`.

## Decision

Open. The bootstrap's first factory ticket reads Symphony `SPEC.md`, norma
`docs/pdca-agent.md`, Fabro's example graphs and agent-orchestrator's adapter list, then
amends this ADR with a decision. Whatever is chosen, the state machines, trust rules,
manifest and claim protocol stay as written; only the run loop's inner command changes.

Default until decided: `fleet` (it is on the pinned toolchain and its `--json` reason set
is what the run loop's `case reason:` keys on).
