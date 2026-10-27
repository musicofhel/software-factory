# TB6 — The claim across an open PR, and the `blocked` label (ticket T25)

Sessions 12 and 13, 2026-10-26/27. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2. Base:
`9f11ef6` (TB5 + ledger). Nothing was pushed and nothing was written to GitHub, the repo's own store
or `~/.factory` (I1, I19). Every world is a temp dir. No prep exists for this spec.

**State: done.** Fixes node:G3, node:G12, node:G13, node:G14, merge:G8a, merge:G8b, merge:G8c,
merge:G9, intake:I2 and intake:I12. The ruling is in ADR-0005 (amendment T25, item 6).

## 1. Measured this row

- **adlc's `budget`.** In adlc 1.12.0 the ticket's `budget` is a number: a token ceiling that the store
  does not validate (`@adlc/tickets/schemas/ticket.schema.json:33-35` in the npx cache of
  `@adlc/cli@1.12.0`). SPEC-v0.2 L431's per-ticket override of the node's strike and wall-clock budget
  therefore cannot reuse that number. run.sh reads an **object** `budget` {maxStrikes, wallClockMinutes}
  and leaves a number to adlc.
- **Real adlc's forecast and `in-review`.** The first real-adlc sim of this row (session 13) went red
  on S.held-24h: `#7 labels needs-desk`. Real adlc's merge-forecast reports co-change `gateFailures`
  across every open sim ticket (`10 high-risk pair(s) would run concurrently`, janitor.log of
  `.spec-loop/simreal`). The draft's rule "needs-desk wins over in-review" therefore labeled a ticket
  under review `needs-desk`. The fake adlc models no such pairs, so the fake sim had passed. The rule
  is now: an open same-repo PR → `in-review`, whatever the store reasons. The reasons stay in the
  body. Those reasons concern claiming the ticket, and a ticket in review cannot be claimed. That
  matches TB1's scenario intent ("not `ready`, and not `needs-desk` either: the PR holds it"). The
  rerun is in §3.

## 2. What was built

- **run.sh.**
  - **The hand-off.** After the success push, the PR is found or opened. Then the Issue is edited
    (`--add-label in-review --remove-label ready,in-progress`) and the lock is released. Ledger
    actions: `pr-open, comment, label-in-review, release-lock`.
  - **`lock_check`.** It runs `heartbeat.sh --dry-run` before every push: success, desk and pause.
    Exit 2 means `lock-lost`: nothing is pushed, labeled or commented. Exit 1 on success means
    `lock-check-failed`, which releases.
  - **`pr_pending`.**
    - A failed `gh pr create` saves {sha, tip, tamperguard, fleet_run, strikes, tries} in the slot
      state, heartbeats the lock and records `pr-pending`. The worktree is gone by then: the pushed
      sha is all the PR needs, and fleet's tip stays under `refs/factory/fleet/<run id>` (TB4).
    - The next iteration, after the governor, runs `pr-retry`: the lock check, then the PR again.
    - A second failure is `pr-open-failed`: a desk comment with the marker, `needs-desk`, and the lock
      is released.
  - **`ticket_budget`.** It runs after ralon-lock, as `adlc ticket show` in the worktree. An object
    budget with positive integer values (1 to 9999, JSON numbers) overrides the weight's values, all
    or nothing. The ledger's `.budget.source` is ticket, weights, weights-store-unreadable or
    weights-ticket-budget-invalid. The usage range is fixed to cover the longer header.
- **mirror.sh.**
  - **Inputs and gate labels.** It reads the open PRs (`isCrossRepository`; a fork PR counts for
    nothing). The gate labels are ready | needs-desk | blocked | in-review.
  - **`blocked`.** A new reason, `blocked: waits on <open parents>`. `blocked` replaces needs-desk when
    every reason is dependency order: that reason, or the forecast's `in wave k, not wave 1`.
  - **`in-review`.** It wins over everything (§1), with the reason `in-review: PR #n is open`.
  - **`Depends-on: <id> (#<issue>)`.**
    - A parent whose Issue is created in the same run is created first (a jq `until` ordering), and
      the child links the new number.
    - When an existing child's only change is that link, its plan is turned from `unchanged` into a
      body edit.
    - A parent with no Issue leaves the line bare.
  - **Close.** Closing removes ready, blocked and in-review.
  - **Labels.** `in-review` is created when the repo lacks it, because run.sh adds it at the
    hand-off.
- **claim.sh.** It skips an Issue labeled `in-review` or with an open same-repo PR from
  `ticket/<Ticket:>/`. The plan's `in_review: [{number, pr}]` is shown as an `in review` line.
- **janitor.sh.**
  - **Lock rules.** Issue closed → release `issue-closed`. An open same-repo PR → hold (fresh) or keep
    `pr-open` (`kept_for: "PR #n"`), outside both the TTL and the slot count.
  - **ready duty.** It recomputes when the open set **or** the in-review set changed. state.json saves
    `in_review`, so a PR opening or closing moves the Issue on the next sweep.
- **tests/fakes/gh.** PRs carry `isCrossRepository` (`headRepository` other than the repo).
- **ADR-0005.** Amendment "T25, the claim across an open PR", with the ruling: the forecast's serial
  order stands, and TB8's hold is defense in depth (merge:G3).
- **EXPECTED.md.** 8 lines flip to pass: C.mirror-blocked, C.depends-link, P/C.claim-released,
  P/C.lock-released, S.held-24h, S.built-plus-claim. 110 = 82 pass + 28 red.

## 3. Tests and gates

### New and changed tests (drafted by four parallel subagents, reviewed and re-run here)

- **test_mirror (20 cases).**
  - Changed:
    - creates: label-create 5→6, `in-review`.
    - ready-only-when-gated: T10 is blocked, wave 2.
    - depends-on-lines: `(#n)`, parents-first numbering.
    - dry-run-inert: an extra label-create.
    - forecast-file: T1 is blocked.
  - New:
    - depends-on-blocked: blocked with two parents, then ready once both complete.
    - forecast-wave-blocked: wave-only → blocked, wave plus rails or a record → needs-desk.
    - in-review: fork, closed and merged PRs and the `ticket/T44/` prefix are ignored; in-review wins
      over blocked and over needs-desk.
    - links: an existing parent, a same-run parent, a completed parent without an Issue (bare). A
      failed parent create leaves the child bare, and the next run links it **in the same run** as
      the parent's create.
    - close-removes-gate-labels.
- **test_claim (11 cases).** New: open-pr-skipped, fork-pr-not-skipped, in-review-label-skipped,
  closed-pr-not-skipped, ticket-prefix-boundary.
- **test_janitor (23 cases).**
  - Changed:
    - fresh-branch-kept: lock 20 is now kept for `PR #100` (pr-open), and locks 21/22/24 still test
      the fresh-branch keep (reason stale-lock).
    - node-lifecycle: 8 files, because an old state without `in_review` recomputes once.
    - ready-open-only: its state gains `in_review: []`, so it still tests the open set alone.
  - New: held-pr-stale, fork-pr-no-hold, built-plus-new-claim, issue-closed, in-review-change-recomputes.
- **test_run (33 cases).**
  - Changed:
    - success: the lock is released and the Issue is in-review.
    - argv: `ticket show` is called twice, by ralon-lock and by the budget.
    - The `pr create` shim gained an injected-failure counter.
    - run_setup adds the `in-review` label to the fake repo.
  - New:
    - success-handoff.
    - lock-lost-before-push: the lock gone, or another node's, after fleet.
    - pr-open-once-fails, then the retry succeeds.
    - pr-open-twice-fails.
    - budget-override: object, partial, none, number, and 6 invalid forms including a string "3" and
      2.5.
- **test_summon.** `blocked` and `in-review` are refused as kinds, and summoner.yml names neither
  label. digest.sh is still a stub, so nothing reads `blocked` there yet.

The subagents' review found 2 bugs in the draft, both fixed in run.sh/mirror.sh before the gates:
- **The budget always read unreadable.** `jq -e` on `.ticket.budget // null` exits 1 when there is no
  budget, so every ticket without one read as `weights-store-unreadable`.
- **A link landed one run late.** The link to a parent created in the same run reached an existing
  child only on the next run.

Also fixed:
- The pr-pending save now heartbeats the lock, so `lock_beat_at` is no longer a guess.
- String budgets are invalid.
- The usage ranges of mirror, claim, janitor and run are fixed.
- Dead `$review_ids` is removed.

### The sim

- Fake: `sim.sh --adlc fake` exits 0, 82 pass + 28 red, equal to EXPECTED. S.held-24h: `#7 labels
  in-review,tier:0,w:light; lock kept`. The janitor's sweep ran the mirror because the in_review set
  changed, and the lock is kept `pr-open`. S.built-plus-claim: `#6 lock kept; #5 lock kept`.
  C.mirror-ready still passes.
- Real (adlc 1.12.0), rerun after the §1 fix: `sim.sh --adlc real` exits 0, 82 pass + 28 red, equal
  to EXPECTED. S.held-24h: `#7 labels in-review,tier:0,w:light; lock kept`. C.mirror-blocked:
  `#2 labels blocked`. C.depends-link: `Depends-on: T-sim-parent (#1)`.

### Gates (the T25 tree)

- `make test`: 21 suites PASS (it includes the fake sim through test_sim.sh).
- `make lint`: exit 0.
- `shellcheck -x -S warning` on the four scripts: clean.

### Red proofs (the new tests on `9f11ef6`, worktree `/tmp/tb6red`, the new tests, fakes/gh and tests/sim copied in)

| suite | on 9f11ef6 | failing cases |
|---|---|---|
| test_mirror | rc 1, 10 of 20 fail | creates, ready-only-when-gated, depends-on-lines, dry-run-inert, forecast-file, depends-on-blocked, forecast-wave-blocked, in-review, links, close-removes-gate-labels |
| test_claim | rc 5, 5 of 11 fail | the five new cases |
| test_janitor | rc 1, 7 of 23 fail | fresh-branch-kept, node-lifecycle, held-pr-stale, fork-pr-no-hold, built-plus-new-claim, issue-closed, in-review-change-recomputes |
| test_run | rc 1, 7 of 33 fail | success, argv, success-handoff, lock-lost-before-push, pr-open-once-fails, pr-open-twice-fails, budget-override |
| test_summon | rc 0 | none: it guards summoner.yml, which this row does not change (a regression guard, not a behavior change) |
| sim (fake) | rc 2, 74 pass + 36 red | exactly the 8 flipped stages, each `regressed: … EXPECTED says pass` |

## 4. Deviations and carries

- **`factory/skills/run/SKILL.md:64`** still says "The lock stays until merge". The file is outside
  T25's scope. Carry to TB12, together with carry 5 on the same file.
- **The pr-retry with an unknown lock check** (heartbeat.sh exit 1) stays `pr-pending` without
  counting a try. It is bounded by the janitor: a lock with no PR goes stale, is released
  `no-pr-48h`, and the next lock check returns 2 (`lock-lost`).
- **A failed hand-off label edit** still releases the lock. claim.sh skips the ticket because of its
  open PR, and the mirror's next run sets `in-review`.
- **janitor `plan_branches`** still counts a fork PR's head name as protecting a same-named branch
  from deletion. That is conservative (it keeps a branch) and is left as it is.
- **Deployed `janitor/state.json`** lacks `in_review`, so the first sweep after T25 recomputes once.
  That is intended.
