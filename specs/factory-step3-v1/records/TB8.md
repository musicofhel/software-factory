# TB8 — The `Depends-on:` hold and tier order (ticket T27)

Sessions 17–19, 2026-10-27. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2. Base: `f276744`
(TB7 + ledger). Nothing was pushed and nothing was written to GitHub, the repo's own store or
`~/.factory` (I1, I19). No prep exists for this spec. Session 17 wrote the three scripts, the
gate-context store helpers and the fake gh forms and stopped at a soft gate; session 18 reviewed every
hunk, wired the workflows and the sim, had the tests drafted, fixed what they found, and ran the gates;
session 19 fixed the last test_sim case, ran the red sim and committed.

**State: done, with one recorded deviation** (`S.tier-jump` stays red until TB11, §4). Fixes merge:G3,
merge:G5, ci:G9, ci:G10, intake:I3, intake:I4 and node:G8. No new question for Aaron.

## 1. Measured this row

- **A re-run replays the original event.** GitHub docs, "Re-running workflows and jobs"
  (docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs): "Re-runs use
  the privileges of the actor who initially triggered the workflow ... the same `GITHUB_SHA` (commit
  SHA) and `GITHUB_REF` (git ref) of the original event". So a re-run of a held `depends-on` job
  sees the PR's original `base.sha`, from before the parent merged. Both scripts therefore read the
  store at `gc_store_sha`: `refs/remotes/origin/<base branch>` when it descends from the event's base,
  else the base. A gate job's checkout has fetch-depth 0 (every branch of the base repo as a remote
  ref); a PR head plants no remote ref there; main only moves forward. So that tip is as trusted as
  the base (I16).
- **adlc 1.12.0 refuses every edge cycle** (carry 15 of TB7, measured in session 17 by a subagent in
  temp worlds):
  - `ticket create`, `update` and `edit`, also dry runs and with `--force`/`--authorize`, exit 2 with
    `INVALID_TICKET_STORE` "cycle in ticket DAG: A -> B -> A" (tickets/lib/schema.mjs:52-66,
    service.mjs:49). An edge to an unknown ticket is refused too (schema.mjs:49).
  - A hand-edited cycle makes `ticket doctor` exit 2 (tickets-load), makes `list` and `show` refuse
    the store, and makes `merge-forecast` exit 2 with gateFailures "dependency cycle in ticket DAG …
    cannot schedule" (merge-forecast/bin/merge-forecast.mjs:104-116).
  - So the `desk` job (doctor, TB7) stops a cycle before main; depends-check's own cycle hold is
    defense in depth.
  - Side findings: `ticket doctor` hides store drift from hand edits (ticket-sync/lib/doctor.mjs:32
    drops the detail of passing checks); `--allow-unsigned` warns even on writes it refuses.
- **The labeler's evaluation must check the PR's identity.** The first full sim had the labeler
  re-run `depends-on` and `tier-order` on S.foreign-body's PR. It asked the scripts in node mode
  (`--ticket --base`), which passed. The re-run replayed the PR's event, where gate-context refuses
  the body's foreign `Ticket:` line, and failed again. On GitHub that is one futile re-run every 15
  minutes for as long as the PR is open. Fix (§2): the labeler asks the scripts on a pull_request event
  built from the PR object with base = main, so its answer is the re-run's.
- **Driver ordering on a push to main.** `labeler.yml` sorts before `post-merge.yml`, so the
  push-triggered labeler run sees the parent still open, and the `workflow_run` run after post-merge
  sees it completed. That is GitHub's case too: the two push workflows run concurrently, and only
  the run after post-merge's completion can see the completion.
- **Not measured (kit, TB12):** whether a job re-run requested with GITHUB_TOKEN (`actions: write`)
  starts the job. A re-run is not an event, so the "GITHUB_TOKEN events start no workflow" rule
  (records/TB0.md (d)) does not obviously apply. The workflow uses the App token when configured.
  Watch the first live re-run.

## 2. What was built

- **`factory/bin/lib/gate-context.sh`**:
  - `GC_BASE_BRANCH` comes from `pull_request.base.ref` or `merge_group.base_ref` (main on the node).
  - `gc_store_sha <base> [branch]`: the base branch's remote tip when it descends from `<base>`, else
    `<base>`.
  - `gc_store <sha>`: every ticket JSON at `<sha>` as one array (`ls-tree --full-tree`, so a
    subdirectory cwd reads the same store). An unreadable file dies, never an empty store.
  - `GC_STORE_JQ`: `gc_tier` (the body header `tier: <n>`) and `gc_parents($id)` (`edges[].to == $id`,
    mirror.sh's rule).
- **`factory/bin/depends-check.sh`** (new), the `depends-on` job:
  - pass for a desk, halt or human PR;
  - a ticket PR passes only when every parent in the store is completed;
  - held (exit 2): an open parent, each one named, or an edge cycle through the ticket, named;
  - refused (exit 2): the ticket is unknown or already completed in the store;
  - exit 1 when the store cannot be read;
  - never reads the body.

  `--ticket <id> [--base <sha>]` gives the same answer outside a PR. stdout is one JSON verdict line.
- **`factory/bin/tier-order.sh`** (new), the `tier-order` job. A tier-n ticket PR waits (exit 2,
  naming the PRs sorted by number) while an open, same-repo ticket PR of a lower tier is approved and
  green.
  - approved: each reviewer's latest decisive review; at least one APPROVED, no CHANGES_REQUESTED.
  - green: the latest `gates.yml` pull_request run on the head has every job of the store commit's
    `gates.yml` except tier-order completed with success, skipped or neutral. Tiers and the job list
    come from that one commit. The job list is awk-parsed; quoted keys are accepted, and a test holds
    the awk text equal to `yq '.jobs | keys'`.
  - first_green: the max completed_at of those jobs.
  - `--order` prints the merge order (tier, first green, PR number) for TB9's queue.
  - A lower-tier PR whose state cannot be read exits 1, never a pass.
- **`factory/bin/labeler.sh`** (new), dry run by default, `--apply`. For each open same-repo ticket
  PR whose ticket is open in main's store (`gc_store_sha` of the checkout, the store the scripts
  read):
  - the label `tier:<n>`, removing other `tier:` labels and creating a missing repo label first;
    case-insensitive, as GitHub is.
  - the body's display block (`Tier:`, `Depends-on: <id> (open|completed on main)` per parent,
    `Prosecuting adapter: not recorded …`, `Assisted-by:` from the head commit in a code span or
    `unrecognized`). It goes below the node's own lines, which are kept, and is rewritten only when it
    differs. CR is ignored. A start line with no end line is the node's text and is kept.
  - the re-evaluation: the latest gates run's `depends-on`/`tier-order` job is re-run
    (`POST actions/jobs/<id>/rerun`) when its conclusion differs from what the script answers now on
    the PR's event with base = main. A refusal (no JSON verdict) re-runs nothing.
  - A PR whose runs cannot be read is reported (`error` in its JSON line), still labeled, and nothing
    of it is re-run. The rest are handled and the run exits 1.
- **`.github/workflows/gates.yml`**: jobs `depends-on` and `tier-order`, shaped like rails-proof (head
  with fetch-depth 0, the base in `./.base`, the base's script, no `if:`, so they report on
  pull_request and merge_group, I18). `actions: read` added for tier-order's run reads.
- **`.github/workflows/labeler.yml`** (new):
  - triggers: `push` to main, `workflow_run` of post-merge `completed`, schedule `*/15 * * * *`, and
    workflow_dispatch with a `dry_run` input; never pull_request_target;
  - a checkout of main with fetch-depth 0, so PR heads are remote refs for the identity check;
  - the App token minted as in post-merge.yml (pull-requests, issues and actions write) when
    configured, else GITHUB_TOKEN with `pull-requests/issues/actions: write`;
  - concurrency group `labeler`.
- **`tests/fakes/gh`**:
  - `pr edit` (`--add-label`, `--remove-label`, `--body-file`; unknown labels fail; names match
    case-insensitively);
  - GET `actions/runs` (head_sha, event and branch filters), GET `actions/runs/<id>/jobs`, and POST
    `actions/jobs/<id>/rerun` (404 for an unknown job, 403 for one not completed; the id goes to
    `.reruns`);
  - `forms()` updated.
- **`tests/sim/lib/driver.sh`**:
  - every run is recorded as the Actions API lists it (`.runs`: ids and times from a `.seq` counter
    on the pinned clock);
  - `workflow_run`: after an event's workflows ran, each completed run fires `workflow_run` for main's
    workflows that name it, one level deep, and MATCH_JQ matches `workflows:` and `branches:`;
  - the outermost `drive` plays the requested re-runs. The job runs again with its run's original
    event, sha, ref and workflow file; a new job id replaces the old; run_attempt goes up by 1; a new
    check run and a `rerun: true` jobs.jsonl line are recorded;
  - the workflow list is cached per sha.
- **`tests/sim/sim.sh`**: the walk drives the labeler's schedule after the PR opens, before
  `$X.tier-label`. **`tests/sim/lib/scenarios.sh`**: new `S.child-released`. T-sim-p2's PR merges
  (the queue stand-in), post-merge completes p2, the labeler on workflow_run re-runs c2's held
  `depends-on`, and the re-run passes.

## 3. Tests and gates

### New and changed tests (drafted by three parallel subagents, reviewed and re-run here)

- `tests/test_depends_check.sh` (new): 13 cases, 69 checks. They cover:
  - no parents; an open parent; a completed parent;
  - the body ignored both ways;
  - merge_group equal to pull_request;
  - unknown and completed tickets refused;
  - a parent completed only on a side branch, or in the head's store, still held;
  - base moved (origin/main a descendant: the re-run case) passes; a diverged origin/main is ignored;
  - a human PR passes;
  - cycles of 2 and 3 held, while an ancestor cycle that does not reach the ticket passes;
  - corrupt store files exit 1;
  - node mode equals CI mode.
- `tests/test_tier_order.sh` (new): 11 cases, 115 checks. They cover:
  - the wait; each "not approved/green" variant, forks, completed and no-tier tickets;
  - same tier, and tier 0 never waits;
  - `--order` sorting and ties by first green;
  - the base job list; the awk list equal to yq (quoted keys too);
  - tiers and jobs from one commit (`one-commit`);
  - node mode; refusals and classes; `--help`;
  - unreadable state exits 1 in every mode.
- `tests/test_labeler.sh` (new): 17 cases, 123 checks. They cover:
  - labels and dry run; label creation; the body block written once; the store from main, never the
    head; the skipped PRs;
  - the depends-on and tier-order re-runs, and no re-run when nothing changed; Assisted-by
    sanitizing;
  - unreadable runs; origin/main ahead; a refusal; an identity refusal; a head missing locally;
  - CRLF; an unterminated start line; case-insensitive labels.
- `tests/test_gate_context.sh`: `depends-on` and `tier-order` run a base script, check out head then
  base, and have no `if:`. **Scope deviation** (§4).

The subagents found these in the session-17 draft, all fixed and covered:
- a read failure on one PR killed the whole labeler run, against its header;
- the labeler and the scripts could read different stores;
- an unterminated `<!-- factory:display` line dropped the node's text (and the first fix still did on
  the second run);
- a CRLF body cost one extra edit;
- `Assisted-by` could carry a link or a mention;
- label case;
- tier-order took its job list from the event base while the tiers came from main's tip;
- `blocking` was unsorted;
- quoted job keys were dropped (fail open);
- `--help` printed code;
- gc_store read nothing from a subdirectory;
- the fake gh crashed on a run without `jobs`.

The sim found the identity-refusal re-run loop (§1).

Not fixed, carried:
- any APPROVED review counts in tier-order, including a stranger's. That fails safe: it only makes
  PRs wait. Who may approve is TB10's.
- the 200 PR / 100 run caps;
- jobs matched by display name (no gates.yml job sets `name:`);
- awk misses `'x' :` (a space before the colon);
- the fake's `issue edit` still matches labels case-sensitively.

### The sim

New stages: `P/C.pr.depends-on`, `P/C.pr.tier-order`, `P/C.mg.depends-on`, `P/C.mg.tier-order` (pass)
and `S.child-released` (pass). Flipped to pass: `P/C.tier-label`, `P/C.hold`, `P/C.tier-order` and
`S.child-before-parent`. `S.tier-jump` stays red with a new reason (§4). EXPECTED.md: 126 = 107 pass +
19 red.

- `S.child-before-parent`: `depends-check: HELD: T-sim-c2 waits on parent T-sim-p2 (open in the store
  at …)`.
- `S.child-released`: `T-sim-p2 completed: true; … depends-check: pass: T-sim-c2 waits on nothing:
  every parent is completed (T-sim-p2) in the store at <main's tip>; re-run: success`.
- Fake: rc 0 inside `make test` (test_sim `sim-equals-expected`: every one of the 126 stages equal
  to EXPECTED.md, the T-sim walk reaches both completions).
- Real (adlc 1.12.0): `sim.sh --adlc real` rc 0 in 7m43s, all 126 stages equal (session 18, on the
  final tests/sim, factory/ and tests/fakes; session 19 changed only tests/test_sim.sh).

### Gates

- `make test`: **25 PASS, 0 FAIL**, rc 0, 411 s (session 19). Session 18's one failure,
  test_sim `gh-unknown-refused`, used `api repos/a/b/actions/runs` as its unknown path, which the fake
  now models. It now uses `api repos/a/b/deployments` (still unmodeled), same intent. **Scope
  deviation** (§4).
- `make lint`: rc 0 (shellcheck 0.11.0 at ~/.local/bin).

### Red proofs (`f276744`, worktree `/tmp/tb8red`, the new tests, tests/fakes and tests/sim copied in)

| suite | on f276744 | failing cases |
|---|---|---|
| test_depends_check | rc 1, 13 of 13 fail | all (no depends-check.sh) |
| test_tier_order | rc 1, 11 of 11 fail | all (no tier-order.sh) |
| test_labeler | rc 1, 17 of 17 fail | all (no labeler.sh) |
| test_gate_context | rc 1, 1 of 11 fails | gates-yml-base-scripts (no depends-on/tier-order jobs) |
| sim (fake) | rc 2, 157 s, 16 stages differ | the 7 flipped stages and S.child-released regressed (red, EXPECTED pass); the 8 new `P/C.pr/mg.depends-on/tier-order` stages missing in results; S.tier-jump equal (red both sides) |

## 4. Deviations and decisions

- **`S.tier-jump` stays red (deviation from the spec's "tier jump scenario green").** The spec defines
  the blocker as an approved, **green**, open lower-tier PR. Green includes `attest-verify`, still the
  stub (ci:G6, TB11), so no PR is ever green and tier-order has nothing to wait for. A weaker "green"
  (dropping attest-verify, or any job) would be a false green. The behavior is proven offline instead
  (test_tier_order `waits`, `order`, `one-commit`). The stage's reason is now `red: ci:G6 …`. TB11
  flips it, and the scenario's hand-made PR_A then needs whatever attest-verify checks.
- **Exit 2 = held/wait**, not the spec's "exit 1". 2 is every gate's fail code (the rails-proof
  precedent), 1 an operational error. Both fail the job; the labeler tells them apart by the JSON
  verdict.
- **Re-evaluation re-runs the held job.** workflow_dispatch was rejected: a dispatched gates run that
  skips jobs would overwrite failed required checks with `skipped`, which passes.
- **Within a tier, nothing waits in CI.** First-done-first is the queue's order (`--order`, TB9).
- **The labeler runs on push to main too.** The spec names push to main and a schedule. A post-merge
  push on GITHUB_TOKEN starts no workflow, so `workflow_run` on post-merge's completion is added, and
  that is what releases the child in the sim. The App token is used when configured.
- **Scope deviations:** `tests/test_gate_context.sh` (the list of base-script jobs, as in TB3–TB7),
  `tests/test_sim.sh` (the unknown api path of `gh-unknown-refused`, §3 Gates) and
  this file. Dogfood on the T27 commit (`--ticket T27 --base <c>~1 --head <c>`): commit-check pass (1
  commit carries the trailers), rails-proof pass, scope-check exit 2 naming exactly
  `specs/factory-step3-v1/records/TB8.md`, `tests/test_gate_context.sh` and `tests/test_sim.sh`.
- **Desk note (I15, factory/policy/**):** branch-protection.json's required set needs `depends-on`
  and `tier-order`. TB10 renames the contexts to bare job ids (ci:G1) and adds these two.
- **Merge queue note for TB9:** in a native queue with more than one entry, a later group's
  `merge_group.base_sha` can be an earlier group's queue commit. The store would then be read at a
  commit holding another queued PR's head. Ticket PRs cannot touch `.adlc/**` (scope, TB3), and the
  group size must be 1 (gotcha 12), so this is safe today. TB9 should keep both.
