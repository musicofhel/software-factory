# ADR-0001: Adopt Distributed Software Factory Spec v0.2 as the design

- Status: accepted
- Date: 2026-10-24
- Deciders: @musicofhel

## Context

The spec (`docs/spec/SPEC-v0.2.txt`, by @Wobbly, 2026-10-24) is the consolidated result of a
working draft that went through cold reads, a premortem, a replica test and a supersession
pass. It states only what is decided; the reasoning lives in the draft.

## Decision

The spec is the design. Its state machines (ticket, node, claim), trust rules, manifest and
claim protocol are implemented as written. Where a borrowed tool and a first-party component
overlap, the borrowed tool wins unless the spec says otherwise. The build order is the
spec's: clock/janitor + claim + kill switch first.

Deviations are ADRs, never silent. ADR-0002 is the first.

## Consequences

The factory is its own first project: every `factory/` change takes the full lifecycle
before the queue opens. Until the run loop exists (step 2) the bootstrap work is built by a
plain spec loop on the owner's box and committed with the same trailers the factory will
later enforce.
