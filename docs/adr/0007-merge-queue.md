# ADR-0007: The merge queue — GitHub's when the repo has one, else a first-party serial queue

- Status: accepted 2026-10-27 (specs/factory-step3-v1 row TB9; ticket T28); amended 2026-10-27 by row TB11 (ticket T30): decision 9, the attest note
- Date: 2026-10-27
- Deciders: @musicofhel. The loop `specs/factory-step3-v1` drafted it under ticket T28.

## Context

SPEC-v0.2's Merge section lands ticket PRs one at a time through a merge queue, so every PR is gated
on the exact commit main becomes. GitHub's merge queue is available only to organization-owned
repositories, and this repo is owned by a user account: `native-queue: no`
(`specs/factory-step3-v1/records/TB0.md` (a), the docs quoted there; ADR-0004 had flagged it). Before
this ADR nothing enqueued a green PR (merge:G4), nothing merged one (merge:G1), and a PR that conflicted
with main or failed on the queue was never handled (merge:G7, ci:G21). Moving the repo to an
organization is Aaron's decision and out of the spec's scope.

## Decision

1. **One script, two modes, read never guessed.** `factory/bin/enqueue.sh pick` asks GitHub
   (GraphQL `repository.mergeQueue(branch: "main")`): an object means the native queue is on, null
   means it is not, an error stops the run. The code carries both paths, so moving the repo to an
   organization and turning the queue on switches the mode without a code change.
   - **native-queue: yes** → `enqueuePullRequest(pullRequestId, expectedHeadOid)` for the head of the
     merge order, only while GitHub's queue is empty (build and merge group size 1). GitHub builds the
     merge group, runs `gates.yml` on `merge_group`, and merges. When it removes a PR, the
     `pull_request_target: dequeued` job runs `eject.sh --dequeued`.
   - **native-queue: no** → the first-party serial queue (SPEC-v0.2's MergeGuard pattern, first
     party): `pick` builds the merge commit S of the head PR onto current main (parents [main, PR
     head], `git merge-tree --write-tree`, subject `Merge pull request #<n> from <owner>/<ref>`,
     committed by github-actions[bot]) on `factory-queue/pr-<n>`; enqueue.yml's `gates` job calls
     `gates.yml` (workflow_call) on S with inputs pr, base and head; `land` pushes S to main
     with the App token when every gate passed. One PR at a time: sequential like GitHub's queue
     with size 1.
2. **The merge order** is `tier-order.sh --order` at main's tip: approved, green, open ticket PRs by
   tier, then first green, then number. A row is taken only when its own `tier-order` job is green,
   it targets main, it is no draft, it carries no `autorebase`, and its head is still the one that was
   gated. Only the first such row is acted on. A serial run first deletes every `factory-queue/*`
   branch: one is left only by a run that never landed, since the `enqueue` concurrency group runs one
   at a time.
3. **The queue path is gated like `merge_group` (I16, I18).** The called `gates.yml` is main's (the
   caller's workflow file), not the PR's. `lib/gate-context.sh` resolves the event `queue` from
   `GATE_QUEUE_PR`, `GATE_BASE` and `GATE_HEAD`, and refuses a head that is not exactly [base, PR
   head], or a PR that does not target main. `commit-check.sh` skips only S in that exact shape (the parents, the identity and the
   subject), as it skips GitHub's own queue commit on merge_group.
4. **Landing is a fast-forward that never forces.** `land` re-checks HALT, the queue branch, S's
   shape, that the PR is still open at the gated head, and that main is still the base. A main that
   moved means `main-moved`: nothing lands, and the next run rebuilds onto the new main (merge:G13).
   The push is `git push origin S:main` with no force, so a race loses safely. The App is the
   ruleset's only bypass actor (TB10).
5. **The PR is not closed by the queue.** The spec says "closes the PR as merged". GitHub marks a PR
   merged when "its head branch commits become reachable from the base branch outside that pull
   request" (docs, "About pull request merges"), and post-merge.sh completes a ticket only when the PR
   reads `merged == true` with `merge_commit_sha` equal to the first-parent commit. Closing the PR
   before that mark could leave it closed and unmerged, so `land` reads the PR back and reports
   `merged_mark` instead. The REST docs define `merge_commit_sha` only for GitHub's own merge methods,
   so its value after an indirect merge is unmeasured: a kit line for the first live merge (TB12).
6. **Ejection** (`factory/bin/eject.sh`): a conflict (serial pick, or the native `MERGE_CONFLICT`)
   or a red queue run (serial `land` on a failed gates result, or native `CI_FAILURE`/`CI_TIMEOUT`)
   does three things. It appends `{at, pr, ticket, handle, issue, head, base, queue, reason, strike}`
   to `factory/ledger/ejections.jsonl` on main through a plumbing commit by github-actions[bot] that
   carries no `Ticket:` trailer. It labels the PR `autorebase` and closes it, because claim.sh skips a
   ticket with any open PR. It returns the Issue to `ready` with `rebase-strike`. GitHub types the
   dequeue `reason` as a bare String and documents no values (schema `RemovedFromMergeQueueEvent.reason:
   String`), so the three reasons above are an assumption: any other reason is reported `ignored`.
   That list is a kit line for the first live native dequeue. A `land` failure while HALT is on main
   ejects nothing, and neither does a failure whose queue commit cannot be read (the failing PR head
   is unknown). If eject.sh fails after closing the PR but before relabeling the Issue, the job fails
   red and the desk relabels the Issue: a re-run sees a closed PR and does nothing.
7. **The rebase strike** (run.sh): on a claim of an Issue labeled `rebase-strike`, the ticket's last
   ejection record names the PR. Its head, which must be the one trailered ticket commit (T23), is
   cherry-picked onto origin/main with `git merge-tree --merge-base E^` (git 2.40 or later). E's
   parent must already be on main, so a two-commit head is never half-applied. A clean pick gets the
   same gates, push, PR and hand-off as a fleet build, and fleet does not run. A conflict, a
   merge-tree error, or a record that cannot be used runs fleet from origin/main, never from the
   ejected branch. A rebase strike never counts toward fleet's `--max-strikes`, and nothing caps how
   many a ticket can take (each one is a line in the ledger for the digest). The claim's rebase
   result is kept in the slot state across a pause or a PR retry. The hand-off removes
   `rebase-strike`, and so does a desk label: a ticket the desk returns builds anew.
8. **The merge method is `merge`** (carry 3 of the spec's HANDOFF). The serial queue always makes a
   two-parent merge commit. The native queue's merge method is set by the branch-protection policy
   (TB10); `squash` would break commit-check's queue rule and post-merge's range.
9. **The attest note: what the queue checks about the node** (specs/factory-step3-v1 TB11, ticket
   T30; ci:G6, ci:G16, node:G6). The node writes its gate manifest as one JSON git note on the ticket
   commit it pushes, under `refs/notes/factory-attest`, and pushes it in the same atomic push as the
   branch (`lib/run.sh` `run_push_attested`: the notes ref grows from origin's tip under a lease, so
   two nodes never drop each other's notes; each slot builds it on its own scratch ref). Format
   `factory-attest/1` (`factory/bin/lib/attest.sh`):
   `{format, signing, ticket, node, adapter, outcome: built | rebased, base, head, tree, fleet: {run,
   strikes, doc_sha256}, gate_commands, tests_run, verdicts: {tamperguard: {verdict, score, findings},
   rails-proof, scope}, hashes: {tamperguard_json}}`. It holds ids, shas, codes, counts, the base's
   gate commands and hashes, never a finding's text (I8). It is unsigned, which the store's
   `securityMode: unsigned-fallback` allows (ruling Q1 of factory-run-calls-v1); a key can sign it
   later.
   The required check `attest-verify` reads the note on the PR head. On `merge_group` and the
   first-party queue, that is the queue commit's second parent, which must be the PR's own head
   (`gh api pulls/N`). The check recomputes everything it
   can from the base, through the same helpers the node calls (I17): the ticket, node and adapter
   against the gate context and the commit's own trailers; the merge-base, head and tree; the gate
   command list (`build-test.sh --list` of `fleet.gate` at the merge-base) and the tests fleet ran;
   and the rails-proof, scope and tamperguard verdicts. A missing note, a note lacking a key, a ticket not open in
   the store at the merge-base, or any mismatch fails it. So does a store that no longer accepts
   unsigned notes. What CI cannot recompute (fleet's run id,
   strikes and the two hashes) stays as a record. A desk, halt or human PR has no node and no note,
   and passes; approvals gate those (TB10).
   CorvidLabs/attest 1.0.0 (MIT, a linux binary; `records/TB0.md` (c)) also keeps records in git
   notes, under `refs/notes/attest`. Its record is `{reviewer, confidence, verdict, tests-passed,
   human-approved}`, and `attest verify` checks it against a confidence policy. That record has no
   field for a recomputable gate verdict, so the factory uses its own format beside it. An attest
   record can be added on the same commit later without touching this one. The node's token asks
   for write access to `refs/notes/factory-attest` along with its branches (join.sh).

## Consequences

- Without the App configured, every enqueue job runs `--dry-run` and says so in the summary: only the
  App may push to a protected main, and a push on GITHUB_TOKEN would start no post-merge.
- The serial queue holds main for one gates run per PR (minutes). Throughput is one PR per gates run,
  the same as GitHub's queue at size 1.
- A PR whose head moves while its queue run is in flight is not landed (`pr-changed`). Its new head
  is gated anew on pull_request.
- `ejections.jsonl` grows on main. The digest reads it (step 4).
- Unmeasured until the first live run (Aaron's kit, TB12): whether GitHub marks the PR merged after
  `land`'s push and what `merge_commit_sha` it reports, and the native dequeue reason values. That
  `mergeQueue` reads null on this user-owned repo is measured (`records/TB0.md` (a):
  `{"data":{"repository":{"mergeQueue":null}}}`).
- A PR built before the attest note existed (or pushed by hand on a ticket ref) fails
  `attest-verify` until a node rebuilds it. Notes accumulate on one ref; nothing prunes them.
