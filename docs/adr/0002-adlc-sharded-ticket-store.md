# ADR-0002: The ticket source of truth is ADLC 1.12's sharded store, not `.adlc/tickets.json`

- Status: accepted
- Date: 2026-10-24
- Deciders: @musicofhel

## Context

The spec names `.adlc/tickets.json` as the ticket source of truth. `@adlc/cli` 1.12.0 (the
pinned version; `adlc init` run 2026-10-24) creates `.adlc/tickets/.store.json` with
`"format": "adlc-ticket-directory"`: one JSON file per ticket under `.adlc/tickets/`, an
archive beside it, and `adlc ticket` as the only writer (dry-run by default, `--write` to
commit, audited once any ticket declares a rail). `tickets.json` remains readable through
1.x for legacy stores only.

The spec's ticket contract also carries `weight`, `tier`, `touches_factory` and `issue`,
which the ADLC schema does not have (it has `category`, `duration`, `budget`, `scope`,
`rails`, `edges`).

## Decision

1. The store is the directory `adlc init` made. "`.adlc/tickets.json`" in the spec reads as
   "the ADLC ticket store". The rule stands: written only from `main`, by `adlc ticket`,
   in the post-merge job or a desk PR.
2. The four extra fields live in a fixed header block at the top of each ticket `body`:

       weight: light|heavy
       tier: 0|1|2
       charter: <PROJECT.md line id, e.g. C3>

   `touches_factory` is derived (scope ∩ `factory/`, `.adlc/`, `.github/`, `.claude/`), and
   `issue` is written by the mirror job into the Issue, never into the store. The mirror
   job parses the header to set `w:<weight>` and `tier:<n>` labels; `tk` stays the trial
   replacement if this becomes painful.
3. Ticket ids are ADLC ULIDs (`T-01K…`); lock refs use the Issue number
   (`refs/locks/issue-N`) as the spec says, and the mirror job keeps the mapping in the
   Issue body.

## Consequences

`coldstart`, `spec-lint`, `merge-forecast` and `fleet` all read the store natively, which
is the point of borrowing ADLC. The mirror job owns the schema bridge and is tested against
the header format.
