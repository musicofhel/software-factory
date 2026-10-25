# House rules (printed by the join wizard)

1. Agents sign every commit and PR with `handle`, ticket id, `Assisted-by:` and
   `Signed-off-by:` trailers.
2. One ticket, one branch, one PR. Out-of-scope fixes become new desk requests, not
   drive-bys.
3. Claims expire. Do not re-claim a ticket you just lost without reading its comments.
4. Post your spend. The PR body carries strikes used and tokens if the adapter reports
   them. The number is for the group to see where quota goes, not a leaderboard.
5. Bots do not open discussions, mention humans, or comment on each other's PRs. Humans
   talk; agents report.
6. Taking your box offline for more than a day: run `/factory:release` first.
7. Provider terms are each contributor's own responsibility; `CONTRIBUTING.md` says so and
   nothing in the factory depends on a particular reading of them.

The kill switch is `factory/HALT` on `main`. Present means every loop sleeps 30 minutes
and checks again. Anyone with write access adds it with a one-line PR that needs no
review; removing it needs two approvals.

## A node's needs-desk (the claim-protocol exception)

The mirror sets `ready` and `needs-desk` from the ticket store; that is the claim protocol. One
exception (step-2 ruling Q3): when a run loop stops a ticket (strikes exhausted, flail, tamper, a
real scope failure), it comments the reason with the needs-desk marker
(`factory/bin/lib/desk-marker.sh`), then labels the Issue `needs-desk` and removes `ready`. The
mirror keeps that `needs-desk` until the store's state for the ticket changes: a desk edit (a new
ticket hash) or a new claim cycle (a claim comment after the marker). Only markers and claims by
the repo owner, org members and collaborators count. A `needs-desk` without the marker is
recomputed from the store as before. To send the ticket back to the queue, fix it at the desk.

## Every ticket declares a rail (the desk's ticket convention)

Every ticket the desk writes declares at least `factory/policy/**` in `rails`, beside the ADR-0002
header block (`weight`, `tier`, `charter`) in its body (factory-step2-followups ruling Q2). fleet's
gate runs `adlc rails-guard --ticket <id>`, which fails every strike on a ticket with no rails, and
`factory/policy/**` is the glob the run loop's ralon lock protects for every ticket. Two checks
hold the rule: the mirror (`factory/bin/mirror.sh`) gives an open ticket without rails no `ready`,
only `needs-desk` with the reason `rails: none declared`, and `make tickets`
(`factory/bin/ticket-check.sh`) exits 2 on it. Completed tickets are never relabeled for it
(T1-T16 predate the rule). A railed store is a frozen trust root: every later `adlc ticket` write
needs `--allow-unsigned` while no manifest key exists (factory-run-calls-v1 ruling Q1), and
post-merge passes it.

## Commit-check exemption (for build order step 3)

One commit on `main` is written by no human and no node: post-merge's completion commit
(`factory/bin/post-merge.sh`, the `post-merge` workflow). It carries one trailer paragraph,
`Through: <sha>`, `Assisted-by: none`, `Ticket: post-merge`, `Node: github-actions`, and no
`Signed-off-by:` (there is no DCO to sign). Step 3's `gates / commit-check` must exempt exactly
that shape: those four trailers, the post-merge identity (the factory App, or `github-actions[bot]`
on the fallback), and a diff that touches only `.adlc/` and `factory/ledger/`. Anything else
claiming `Ticket: post-merge` fails the check like any unsigned commit.
