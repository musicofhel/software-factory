# TB9 — The queue: native merge queue or the first-party serial queue, and ejection (ticket T28)

Sessions 20–23, 2026-10-27. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2, git 2.43.0. Base:
`681408b` (TB8 + ledger). Nothing was pushed and nothing was written to GitHub, the repo's own store or
`~/.factory` (I1, I19). No prep exists for this spec. Session 20 researched and designed the row;
session 21 wrote the production code and stopped at a soft gate; session 22 reviewed every hunk, had
the tests drafted by parallel subagents and fixed what they found; session 23 wired and finished the
sim, ran the gates and committed.

**State: done.** Fixes merge:G1 (as far as code can: the serial queue merges; GitHub's queue needs an
organization), merge:G4, merge:G7, merge:G13, ci:G19, ci:G21. No new question for Aaron; the spec's
end-of-spec **Q: the merge queue** (TB12) stands, and the code supports both answers.

## 1. Measured this row

- **native-queue: no** stands (records/TB0.md (a)): the repo is user-owned, and the read-only
  `repository.mergeQueue(branch: "main")` answered `null`. enqueue.sh reads that answer every run, so
  the mode is never guessed: null → serial, an object → native, an error → exit 1.
- **GitHub marks a PR merged by reachability.** Docs, "About pull request merges"
  (docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/about-pull-request-merges):
  "A pull request can be marked as merged if its head branch commits become reachable from the base
  branch outside that pull request." The REST docs (pulls#get-a-pull-request) define
  `merge_commit_sha` only for GitHub's merge, squash and rebase merges, so its value after an
  indirect merge (the serial queue's `land`) is **not documented**: kit for TB12. post-merge.sh
  `pr_ticket` requires `.merged == true and .merge_commit_sha == <first-parent commit>`
  (post-merge.sh:121-123), which is why `land` reports `merged_mark` rather than closing the PR (§4).
- **The dequeue reason is a bare String.** GitHub's public schema
  (docs.github.com/public/fpt/schema.docs.graphql): `RemovedFromMergeQueueEvent.reason: String` ("The
  reason this pull request was removed from the queue."); octokit/webhooks
  `pull_request/dequeued.schema.json` types `reason` as `{type: string}` with no enum. So eject.sh's
  mapping (MERGE_CONFLICT → conflict, CI_FAILURE / CI_TIMEOUT → red-queue-run, anything else
  `ignored`) is an assumption, a kit line for the first live native dequeue.
- **The mutation.** `enqueuePullRequest(input: EnqueuePullRequestInput!)` takes `pullRequestId`,
  `expectedHeadOid` and `jump`; `Repository.mergeQueue(branch: String): MergeQueue` is nullable
  (same schema). enqueue.sh passes `expectedHeadOid`, so GitHub refuses a head that moved.
- **Facts from the code the design rests on:**
  - claim.sh:77-89 skips a ticket with ANY open same-repo `ticket/<id>/*` PR, so an ejection must
    CLOSE the PR.
  - mirror.sh:175 owns only `ready|needs-desk|blocked|in-review|w:*|tier:*`, so `rebase-strike`
    survives the mirror; an open PR makes the Issue `in-review` (mirror.sh:278).
  - run.sh's worktree started fleet from the newest `origin/ticket/<id>/*` branch, which after an
    ejection is the stale ejected one: a rebase strike now always cuts from origin/main.
  - run_push is `--force-with-lease` on the node's own branch (lib/run.sh:79-83), so the rebased push
    overwrites the ejected branch.
  - In a called workflow (`workflow_call`) `github.event_name` is the CALLER's, so gates.yml's
    `dependencies` job (`if: github.event_name == 'pull_request'`) is skipped on the serial queue as
    on merge_group (ci:G1, TB10).
  - `git merge-tree --write-tree` needs git 2.38, `--merge-base` 2.40 (this box: 2.43.0).

## 2. What was built

- **`factory/bin/enqueue.sh`** (`pick`, `land`; `--dry-run` default, `--apply`):
  - pick: nothing while factory/HALT is on origin/main; the mode from GraphQL; candidates =
    `tier-order.sh --order --base <main>` rows whose run's own `tier-order` job is green too, the PR
    open, targeting main, no draft, no `autorebase`, head unchanged; the FIRST such row only.
  - native: an empty queue → `enqueuePullRequest(id, expectedHeadOid)`; else `queue-busy`.
  - serial: every stale `factory-queue/*` branch deleted first; `refs/pull/N/head` must equal the
    row's head (`head-moved`); `git merge-tree --write-tree main head`: rc 1 → `eject.sh --reason
    conflict`; else the merge commit S (parents [main, PR head], subject `Merge pull request #N from
    <owner>/<ref>`, author and committer github-actions[bot]) pushed to `factory-queue/pr-N`, and
    GITHUB_OUTPUT queue/pr/base/head.
  - land: failure → (HALT: nothing) `eject.sh --reason red-queue-run --head S^2` (an unreadable S
    ejects nothing, exit 1), the queue branch deleted; cancelled/skipped → nothing; success → HALT,
    the queue branch still S, S's shape, the PR open at S^2 without `autorebase` (`pr-changed`),
    main still the base (`main-moved`, merge:G13), then `git push origin S:main` never forced (a
    refused push re-reads main: moved → `main-moved`, else exit 1), the queue branch deleted, PR N
    read back and `merged_mark` reported. The PR is NOT closed (§4).
- **`factory/bin/eject.sh`** (`--pr N --reason conflict|red-queue-run`, or `--dequeued` from a
  pull_request_target event): reads PR N (open, same repo, `ticket/<id>/<handle>`, head a full sha;
  `stale` when the PR moved past `--head`), the Issue with `Ticket: <id>`, and the ledger on main.
  Writes, each only after the one before succeeded: (1) one line `{at, pr, ticket, handle, issue,
  head, base, queue, reason, strike}` (+ `dequeued_reason`, upper case) appended to
  `factory/ledger/ejections.jsonl` by a plumbing commit on origin/main (github-actions[bot],
  trailers `Ejected: #N`, `Assisted-by: none`, `Node: github-actions`, no `Ticket:`; never forced,
  3 tries on a moved main; a line for the same pr+head is never written twice; malformed lines are
  skipped); (2) labels `autorebase`/`rebase-strike` created if missing, the PR labeled `autorebase`
  and closed with an ids-only comment; (3) the Issue `ready` + `rebase-strike`, `in-review` removed.
- **`.github/workflows/enqueue.yml`**: jobs `pick` → `gates` (`uses: ./.github/workflows/gates.yml`,
  inputs pr/base/head) → `land` (`if: always() && queue != ''`), and `dequeued` (pull_request_target
  `dequeued`, checks out main only). Triggers: push to main, workflow_run of gates/post-merge
  completed, `*/15` schedule, pull_request_target dequeued, workflow_dispatch (dry_run). Concurrency
  `enqueue`, never cancelled. Without the App (vars.FACTORY_APP_ID + secrets.FACTORY_APP_KEY) every
  job runs `--dry-run` and says so in the step summary.
- **`.github/workflows/gates.yml`**: `on.workflow_call` inputs pr/base/head; `GATE_BASE`/`GATE_HEAD`
  read the inputs first; `GATE_QUEUE_PR: ${{ inputs.pr }}`; concurrency `queue-<pr>` on the queue.
- **`factory/bin/lib/gate-context.sh`** (scope deviation, §4): event `queue` when `GATE_QUEUE_PR` is
  set (it wins over the caller's event): PR N through `gh api`, which must target main
  (GC_BASE_BRANCH main); the head must be exactly [GATE_BASE, PR N's head]; else refused.
- **`factory/bin/commit-check.sh`** (scope deviation): on `queue`, S is skipped only in its exact
  shape (parents [base, PR head], identity github-actions[bot] as author and committer, subject
  `Merge pull request #<GC_PR> from `). The merge_group skip is unchanged.
- **`factory/bin/run.sh`** the rebase strike: an Issue labeled `rebase-strike` → the ticket's last
  ledger line names the PR; its head E, fetched from `refs/pull/<pr>/head`, must be the record's head,
  ONE commit whose parent is on main, carrying `Ticket: <id>`. E is cherry-picked onto origin/main
  (`git merge-tree --write-tree --merge-base E^ main E`). Clean → one commit (Factory-Outcome:
  rebased, Rebased-From: E) through `gate_push` (the same tamperguard, rails-proof, scope-check, lock
  check, push, PR, hand-off as a fleet success), no fleet. A conflict, a merge-tree error, or an
  ineligible record → fleet from origin/main (never the ejected branch) with the budget's
  `--max-strikes` unchanged. `.rebase = {pr, from, strike, result}` in the run record and the slot
  state (so a PR retry or a pause keeps it); the hand-off and the desk label remove `rebase-strike`.
  `on_success` split into `gate_push`. lib/run.sh: the PR body's outcome row says "rebased".
- **`tests/fakes/gh`**: `api POST graphql` (mergeQueue from state `.merge_queue`, enqueuePullRequest
  appending to `.merge_queue.entries` and `.enqueued`, GraphQL errors exit 1), `pr close --comment`
  (→ `.pr_comments`), GET pulls/N `node_id` and `draft`.
- **`docs/adr/0007-merge-queue.md`** (accepted) and its README row; `factory/ledger/README.md`
  describes `ejections.jsonl`.

## 3. Tests and gates

### New and changed tests (drafted by four parallel subagents, reviewed and re-run here)

- `tests/test_enqueue.sh` (new): 22 cases. HALT; the mode (unknown repo / HTTP error exit 1 before
  tier-order; null → serial; object → native); empty; every skip reason (draft, autorebase any case,
  head moved, tier-order red/missing/in progress, closed, another base branch), only the first
  eligible row read; serial build (stale branches deleted, kept on dry run; parents, tree, identity,
  subject, GITHUB_OUTPUT); head-moved; conflict → eject (dry and apply); native enqueue / dry /
  failure / queue-busy; the real tier-order.sh once; land success / merged_mark true, false, null /
  main-moved / a race (the push not forced) / pr-changed / refusals (7 wrong shapes) / failure →
  eject / failure guards (HALT, unreadable S) / cancelled, skipped / 10 bad-argument forms / HALT /
  dry run.
- `tests/test_eject.sh` (new): 19 cases. Dry run; apply (the line, the identity, the 3 trailers and
  no Ticket, only the ledger touched); base and queue; labels present vs created; strike count;
  idempotence (seeded, re-run, a new head → strike 2); not-open; stale; refused (fork, non-ticket
  ref); bad args; no Issue; write order (a failed `pr edit` or `pr close` stops later writes);
  a main moved under the push (a real pre-receive hook moves main, then declines: retried on top;
  the same line written by the winner → ledger-present); refused 3 times → exit 1; `--dequeued`
  mapping (any case), ignored reasons, bad events.
- `tests/test_run.sh`: 7 new cases, 40 in all: rebase-clean, rebase-conflict, rebase-ineligible
  (no record, ledger gone, PR head unreadable, moved, a merge, a root commit, a two-commit head,
  another ticket's commit, no trailers), rebase-none, rebase-gated (tamper and scope judge the
  rebased commit; the desk takes `rebase-strike`), rebase-survives (a PR retry and a pause keep the
  rebase), rebase-malformed-line.
- `tests/test_gate_context.sh` (scope deviation): queue (4 caller events, GC_BASE_BRANCH main, a PR
  targeting another branch refused, the queue env wins over pull_request, an empty GATE_QUEUE_PR
  leaves pull_request), queue-refusals (7 parent shapes, 7 bad PR numbers, 404 and missing commits
  exit 1), queue-identity-classes; gates-yml-base-scripts updated for workflow_call.
- `tests/test_commit_check.sh` (scope deviation): queue-skip, queue-not-skipped (identity, subject,
  GitHub's merge_group shape, parents refused by gate-context first), queue-merge-group-apart.

The subagents found these in the session-21 code, fixed here and covered:
- **run.sh lost the rebase across iterations** (real bug): REBASE was not in the slot state, so a
  retried PR said "built (fleet …)" and the hand-off after a retry or a pause left `rebase-strike`
  on the Issue, making the next claim rebase again (rebase-survives failed 3 checks).
- run.sh cherry-picked only the top commit of a two-commit head and called it clean (now
  ineligible: E's parent must be on main); any merge-tree failure counted as a conflict (now
  `error` unless rc 1); a malformed ledger line ended the read (run.sh and eject.sh now skip it);
  a desk on the rebase path kept `rebase-strike` (the desk label now removes it).
- eject.sh: a duplicate check through `jq | grep -q` that SIGPIPE could defeat under pipefail; an
  empty PR head sha recorded; a dry run that listed `ledger-append` and no strike when the line was
  already on main; `dequeued_reason` casing; a non-number PR in a dequeued event answered `ignored`.
- enqueue.sh: stale queue branches were deleted only when a row was eligible (now every serial run
  first); a land failure ejected during HALT, and without S (a PR pushed since could be ejected for
  an old head's red run); `-F owner/name` would turn a numeric repo name into a number (now `-f`);
  the dry run logged "deleted"; a branch delete failure was silent; a PR targeting another branch
  was a candidate (now skipped, and refused by gate-context on `queue`).

Not fixed, carried (§4 for the reasoning): eject.sh failing after `pr close` and before the Issue
edit strands the Issue (the job fails red; the desk relabels); a clean rebase's PR body says
"strikes 0 of 0" and its title and Issue comment read like a fleet build; nothing caps rebase
strikes; land's subject check is a prefix (S must equal pick's pushed head anyway); the fake answers
every GraphQL error with exit 1, so the "exit 0 with errors" branches are unreachable offline.

### The sim

Session 23 finished the sim (design items 6–7 of the handoff), on the driver draft session 22's
subagent left unwired.

**The driver (`tests/sim/lib/driver.sh`)** now plays:
- a job's `outputs:`, evaluated on its steps (`needs.<job>.outputs`);
- a job-level `uses: ./.github/workflows/<f>` (workflow_call). The called workflow is read at the
  caller's workflow commit, with the `inputs` context (the caller's `with:`, then the defaults,
  typed) and only GITHUB_TOKEN of the secrets unless `secrets: inherit`. Its jobs are recorded in the
  caller's run and as check runs named `<caller job> / <job>`, the way GitHub names them. Their
  jobs.jsonl lines carry `call: {caller, workflow, inputs}`. The caller's result is failure when a
  called job failed;
- `pull_request_target` (types, branches; GITHUB_SHA/REF = the base branch tip);
- GitHub's push events for the App's pushes. A job that minted the App token and created or moved a
  `refs/heads/*` ref queues one push event per ref; deletions start none, and a GITHUB_TOKEN push
  starts none (records/TB0.md (d)). The outermost drive plays the queued events with the re-runs.
  When a job moves main, every open PR on main whose head is now reachable is marked merged: GitHub's
  indirect merge, `.merged += {pr, sha: <new main>}`;
- `SIM_STANDIN_GREEN`: GitHub's view of a failed job of that id is success (.runs, .checks, needs),
  while jobs.jsonl keeps the real conclusion plus `standin: true`. It is set only for the walk and
  the queue scenarios, to `attest-verify` (the ci:G6 stub). S.tier-jump keeps its TB8 result;
- **a found bug, fixed:** with the App's pushes now starting workflows, the labeler asked for a
  re-run of the same held job twice before the driver played the first. The second request named a
  job id the first re-run had replaced, and the driver died ("no run holds it"). A second request
  for a job already re-run is now skipped and logged: GitHub refuses a re-run of a queued run.

**The sim (`tests/sim/sim.sh`, `lib/scenarios.sh`, `lib/world.sh`):**
- The App is configured (SIM_VARS FACTORY_APP_ID, SIM_SECRETS FACTORY_APP_KEY). post-merge's push
  therefore now starts post-merge again (a no-op), plus the labeler, the mirror and enqueue.
- **The walk:** the owner approves the PR before its pull_request event. The gates run's
  workflow_run starts enqueue.yml: `pick` builds `factory-queue/pr-<n>`, `gates` runs gates.yml there
  (stages `P.q.<job>`, `P.q.identity`: event `queue`, the PR, ticket, class, base = main, head = the
  queue commit), and `land` pushes it to main on the App. Then post-merge completes the ticket.
  `P.enqueue` and `P.merge` pass. `P.merged-mark` is `red: kit:` by fiat: the sim models
  merge_commit_sha as the queue commit, which GitHub does not document. land's own read saw
  `merged_mark: false`, because GitHub's mark (here: the driver's) comes after the push. The
  `queue_standin`/`merge_standin` walk stand-ins and the `.mg.*` stages are gone.
- **Scenarios:** new desk tickets T-sim-r, T-sim-n1 and T-sim-n2. With the stand-in on, the earlier
  T-sim-s PRs are closed first.
  - `S.queue-conflict` (X unapproved, then Y approved and landed; X approved, then a schedule tick):
    pick reports `conflict`, X is closed and labeled `autorebase`, the record is `{reason: conflict,
    strike: 1}`, and the Issue is `ready` + `rebase-strike`.
  - `S.rebase-strike` (dev-box claims T-sim-s): `.rebase = {pr: X, result: conflict}`, the worktree
    is cut from origin-main, fleet runs, `budget.max_strikes` is still 2, a new PR opens, and the
    Issue goes from `in-review` to no `rebase-strike`. claim.sh takes the oldest ready Issue, and
    the mirror numbers the scenario Issues by ticket id, so the other ready Issues are held back for
    this one claim (a labeled stand-in) and then restored.
  - `S.queue-red`: the runner's `make test` stub fails only when both sim/r/main-side and
    sim/r/pr-side are in the tree. R is green on its PR, the desk pushes main-side, and land reports
    `red` and ejects R with `red-queue-run`.
  - Native mode (`.merge_queue` set in the fake): `S.native-enqueue` (`.enqueued` is exactly [N1 at
    its head]); `S.native-merge` is `red: ci:G1` (GitHub's group is a stand-in; the policy's `gates
    / <job>` contexts are absent on merge_group); `S.native-dequeue` (pull_request_target `dequeued`,
    CI_FAILURE: N2 is closed with `autorebase`, and the record says `red-queue-run`,
    `dequeued_reason: CI_FAILURE`).
  - S.foreign-trailer and S.child-released now merge by `admin_merge`, a labeled stand-in: a merge
    commit "Merge pull request #N from owner/ref" with no merge_group run.
- `ci_tg_argv` (I17) keeps only the CI tamperguard calls on `...<PR head>`: the queue's own call on
  `base...S` follows in the same pr_event.

**EXPECTED.md: 126 → 131 stages, 107 → 116 pass, 19 → 15 red.**
- Removed (28): P/C.mg.* (13 each) and the old red P/C.merge.
- Added (33): P/C.q.* (10 pass; `dependencies` is red ci:G1, skipped on the queue path as on
  merge_group, TB10; `attest-verify` is red ci:G6, TB11), P/C.merge pass, P/C.merged-mark red kit,
  S.rebase-strike / S.queue-red / S.native-enqueue / S.native-dequeue pass, and S.native-merge red
  ci:G1.
- Flipped red → pass (3): P.enqueue, C.enqueue (merge:G4), S.queue-conflict (merge:G7).

**Runs:** fake rc 0, `--adlc real` (@adlc/cli 1.12.0) rc 0, both 131 = 116 pass + 15 red, equal to EXPECTED.md. Runtimes, measured under parallel load: the fake sim took 8 min
41 s wall (with a real sim running beside it), and the real sim took 16 min 22 s (beside `make test`
and lint). Neither is about 2.5 / 6.5 min any more. Every PR event now also runs the queue,
and every App push runs the push workflows. The App's pushes start 18 push events in a run, and 3 PRs
are marked merged by the queue.

**Found, not fixed (for TB10):** the serial queue's check runs are named `gates / <job>`, because
the caller job is `gates`. By coincidence that is the policy's current context form, but land acts
on `needs.gates.result` and never on required checks.

### Gates

Run in parallel on the final tree: `make test` rc 0, 27 PASS (13 min 29 s wall, beside the real
sim), including test_sim (which runs the fake sim against EXPECTED.md), test_enqueue, test_eject,
test_run, test_gate_context and test_commit_check. `make lint` rc 0 (shellcheck 0.11.0 + actionlint).
The fake and real sims are as above. `grep -n native-queue docs/adr/0007-merge-queue.md` hits
(T28's acceptance).

### Red proofs (`681408b`, worktree `/tmp/tb9red`, the new tests and tests/fakes copied in)

| suite | on 681408b | failing cases |
|---|---|---|
| test_enqueue | rc 1, 22 of 22 fail | all (no enqueue.sh) |
| test_eject | rc 1, 19 of 19 fail | all (no eject.sh) |
| test_run | rc 1, 6 of 40 fail | rebase-clean, -conflict, -ineligible, -gated, -survives, -malformed-line (rebase-none passes: the old behavior, unchanged) |
| test_gate_context | rc 1, 4 of 14 fail | queue, queue-refusals, queue-identity-classes, gates-yml-base-scripts |
| test_commit_check | rc 1, 2 of 12 fail | queue-skip, queue-not-skipped (queue-merge-group-apart passes: no skip before either) |
| the sim (tests/sim + tests/fakes copied in) | rc 1, 40 stages | P.enqueue (`pick: {}`), P.q.identity, P.merge, P.complete, P.issue-closed red. Then it dies at C.mirror-ready: nothing merged the parent, so the child stays `blocked` ("no record of T-sim-child was missing or stale, and it is not ready") |

On the session-21 code (before this session's fixes): test_run rebase-survives failed 3 checks;
test_eject idempotent-seeded failed its dry-run check; test_enqueue serial-build and real-tier-order
failed their stale-branch checks (all observed in this session, then fixed).

## 4. Deviations and decisions

- **The queue does not close the PR** (the spec says "closes the PR as merged"). Closing it before
  GitHub marks it merged could leave it closed and unmerged, and post-merge completes a ticket only
  on `merged == true` with `merge_commit_sha` = the first-parent commit. `land` reads the PR back
  and reports `merged_mark`; the sim models GitHub's indirect merge and its stage is `red: kit:`
  (ADR-0007 §5). If the first live merge shows the mark missing, the fix is a land step that closes
  the PR and a post-merge rule for the queue commit (TB12).
- **Dequeue reasons assumed** (§1): MERGE_CONFLICT, CI_FAILURE, CI_TIMEOUT eject; any other is
  `ignored`. Kit line.
- **An ejection closes the PR and returns the Issue to `ready`** (claim.sh skips open-PR tickets).
  If eject.sh dies between closing the PR and relabeling the Issue, nothing re-runs it (the PR is
  closed and `autorebase`, so enqueue never picks it again): the job is red and the desk relabels.
  Reordering would not help, since enqueue skips `autorebase` PRs either way.
- **A rebase strike is not a fleet strike and is not capped.** The spec says it "does not count
  toward `--max-strikes`"; each ejection is a ledger line with its strike number for the digest
  (step 4) to read. A clean rebase records `outcome: built` with `.rebase.result: clean`, and its PR
  body reads "strikes 0 of 0" (no budget is read on that path): cosmetic, carried.
- **A queue PR must target main** (gate-context refuses, enqueue skips). The serial queue builds on
  main only.
- **merge method `merge`** (carry 3): the serial queue makes a two-parent merge commit; the native
  path's method is TB10's policy (ADR-0007 §8).
- **Scope deviations** (T28's scope does not list them): `factory/bin/lib/gate-context.sh`,
  `factory/bin/commit-check.sh` (the `queue` event: the serial queue's run is a third gate path,
  I18), `docs/adr/README.md` (the 0007 row), `tests/test_gate_context.sh`,
  `tests/test_commit_check.sh` and this file. Dogfood (`--ticket T28 --base <c>~1 --head <c>`):
  commit-check pass (1 commit carries the ticket trailers); rails-proof pass (no rail of T28);
  scope-check rc 2 and names exactly these six: docs/adr/README.md, factory/bin/commit-check.sh,
  factory/bin/lib/gate-context.sh, specs/factory-step3-v1/records/TB9.md, tests/test_commit_check.sh,
  tests/test_gate_context.sh. tests/sim/** and tests/fakes/** are in scope, so test_sim.sh was not
  touched.
- **Carried:** post-merge.yml:2's stale header (carry 1, TB12); the merge_commit_sha after an
  indirect merge, the dequeue reasons (kit, TB12); the native queue's group size must stay 1
  (gotcha 12, TB10's policy).
