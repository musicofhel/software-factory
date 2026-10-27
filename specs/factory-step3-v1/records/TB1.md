# TB1 — `make sim`: the end-to-end pipeline simulation, today's stop points recorded (ticket T20)

Sessions 2–4, 2026-10-26. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2. Base: `819b8f8` (TB0 +
ledger). Nothing was pushed, and nothing touched GitHub, the repo's own store, `~/.factory` or the
network (I1, I19). Every world is a temp dir.

**State: done.** `make sim` runs the T-sim walk and 15 failure scenarios in a scratch world. It
matches `tests/sim/EXPECTED.md` in fake-adlc mode (`make test` runs it through `tests/test_sim.sh`)
and in real `@adlc/cli` 1.12.0 mode. The result is 86 stages: 21 `pass` and 65 `red: <gap id>`.

## 1. What was built

| file | what |
|---|---|
| `tests/sim/sim.sh` | Entry point (`make sim`). Builds the world, runs the walk, sources the scenarios, then compares. `--adlc auto\|real\|fake`, `--expected`, `--results`, `--keep`. Exit 0 = equal, 2 = a stage differs, 1 = harness error. |
| `tests/sim/lib/world.sh` | The scratch world. A bare origin seeded from the working tree with the store emptied (`tests/fixtures/make-repo.sh`). A desk clone. Nodes `dev-box` and `node-b` (the `tests/test_run.sh` harness). Runner shims. Every remote is `https://github.com/sim-owner/factory` with a local `insteadOf`, so `resolve_repo` parses the repo exactly as it does on GitHub. |
| `tests/sim/lib/driver.sh` + `expr.jq` | The workflow driver. Reads `.github/workflows/*.yml` with yq and matches `on:` (types, branches, paths). Runs jobs in `needs` order. Evaluates `if:`/`env:`/`with:`/`run:` expressions, including `success()`/`failure()`. Emulates the `uses:` the workflows name and is a loud error on any other. Records each job as a check run named by the **bare job id** (TB0 (b)). |
| `tests/sim/lib/scenarios.sh` | The 15 failure scenarios, each one `S.*` stage. |
| `tests/sim/lib/compare.sh` | Results vs EXPECTED.md, in both directions. A red row must cite a gap id or `kit:`. |
| `tests/sim/EXPECTED.md` | One row per stage. Every red row names its gap id and the row that fixes it. |
| `tests/test_sim.sh` | 7 cases, 23 checks (§5). |
| `tests/fakes/{adlc,gh,fleet,tamperguard}` | `adlc`: `FAKE_ADLC_GITSTORE=1`, the real store layout. `gh`: stateful PRs, `pr create/view`, `__forms`, `FAKE_GH_UNKNOWN`. `fleet`: `FAKE_FLEET_CHECK_CONFIG=1` (preflight.mjs:63-64). `tamperguard`: `FAKE_TAMPERGUARD_VERDICT=diff`. Every existing suite still passes. |
| `Makefile` | A `sim` target. |

## 2. Decisions

1. **Stages judge the desired behavior** and never today's. A red stage is followed by a labeled
   stand-in (`stand-in:` in `sim.log`) so the later stages stay observable. The stand-ins are: the
   TB7 records, fleet without its config preflight, a passing node scope check, GitHub's queue
   building `gh-readonly-queue/main/pr-<n>-<base>`, and main fast-forwarding to the group.
2. **The driver plays GitHub, not "run from base".** For `pull_request`, workflows and scripts come
   from `refs/pull/<n>/merge`, which is built with `git merge-tree` as GitHub builds it. So the I16
   scenario (`S.head-edits-gate`) is red today for the true reason (ci:G5: the head's `exit 0`
   scope-check runs and passes). TB2 flips it by changing gates.yml, not the driver.
3. **yq is mikefarah v4.** `sim.sh` refuses any other yq. Here it is v4.44.1 at
   `/usr/local/bin/yq`, and ubuntu-latest ships mikefarah yq v4. The spec allows "yq or a pinned
   parser" (TB1). The driver never holds a copy of the job list, and a test proves it (§5).
4. **`make test`/`make lint` inside a simulated job are stubbed** (`runner-bin/make`). The suite runs
   the sim, so a real call would recurse. The real gate command list is TB5's (build-test from the
   base config).
5. **Fake mode and real mode must reach the same EXPECTED.md.** CI's npx cache is empty, so CI runs
   fake mode. `--adlc auto` uses the real CLI only when the npx cache already holds 1.12.0
   (`npm_config_offline=true`); it never downloads.
6. **The scratch store starts empty.** Tickets are created child first, because an edge target must
   exist (the real CLI and the fake agree).
7. **Scenarios are one stage each**, judged on the gate that should stop them and on its log naming
   the reason (a path, `"verdict": "tamper"`, `Signed-off-by`, the parent id, the blocking PR
   number). Lines starting with `##` (step names) are excluded from the match, so a step titled
   "Signed-off-by + Assisted-by…" cannot satisfy its own judge.

## 3. Measured this row

- **Real adlc shapes**, measured in a scratch store and copied by the fake's git-store mode:
  - Files are `<toplevel>/.adlc/tickets/<lowercased id>--<sha256>.json`, and `complete` keeps the
    file name.
  - `ticket list --json` returns `[{id, title, ticketHash}]`.
  - `merge-forecast` waves for parent → child are `[[parent],[child]]`.
  - `gate-manifest record` prints `recorded: seq=N gate=… (unsigned)` and appends
    `{seq, gate, ts, ticket, data, files, prev}`.
  - A frozen store needs `--allow-unsigned` on create.
- **New: real forecast "unscoped".** Real 1.12.0's `merge-forecast` gives a ticket whose scope globs
  match no existing path the pair signal `unscoped`, with verdict `SEQUENCE` against every other
  ticket. The mirror then labels it `needs-desk` with "merge-forecast: sequenced behind T-sim-b1 in
  wave 1". The fake does not model this. The first real-mode run caught it: `S.held-24h` came out
  "green early" for the wrong reason (`needs-desk` instead of `ready`).
  - Fix 1: the scenario desk seeds `sim/<dir>/.keep` for each scenario ticket.
  - Fix 2: the held-24h judge also refuses `needs-desk`.
  - This confirms intake:I7 (scope globs unchecked). TB7 owns it, and a desk that writes a ticket for
    a new directory hits it today.
- **actions/checkout on branch events.** With no `ref:`, a `push`/`schedule`/`merge_group` checkout
  is on the named branch (`checkout -B <branch>`); only `refs/pull/*` stays detached. The driver first
  detached every checkout, and the janitor's ready-recompute failed (`mirror: --apply runs only in a
  checkout of main (HEAD is detached)`). The driver now names the branch.
- **gh forms the repo calls** (static grep over `factory/` and `.github/`, 22 forms): `issue
  list/create/edit/comment/close/reopen`, `label list/create`, `pr list/create`; and `api` GET
  `git/matching-refs/*`, `git/ref/*`, `git/commits/*`, `rulesets`, `rulesets/*`, `branches/*/protection`,
  POST `git/commits`, `git/refs`, PATCH `git/refs/*`, DELETE `git/refs/*`, `collaborators/*`. Every
  one is in `gh __forms`, and no form was refused during a sim run.

## 4. Stage table (tests/sim/EXPECTED.md)

86 stages: 21 pass, 65 red. Red rows by gap:

| gap | rows | fixed by |
|---|---|---|
| ci:G6 (stubs) | 22: P/C × pr/mg rails-proof, scope, commit-check, attest-verify; P/C.node-scope; S.out-of-scope, S.rail-edit, S.no-trailer, S.ticket-adlc | TB3, TB4, TB11 |
| ci:G1 (context names; dependencies skipped on the queue) | 6: P/C × pr/mg.required-checks, P/C.mg.dependencies | TB10 |
| ci:G2 (tamper `--base`) | 5: P/C × pr/mg.tamper, S.tamper-skip | TB3 |
| merge:G3 / merge:G5 | 3 + 3: P/C.hold, S.child-before-parent / P/C.tier-order, S.tier-jump | TB8 |
| node:G2, node:G3, node:G10, merge:G8c, intake:I3 | 2 each (P and C) | TB4, TB6, TB5, TB6, TB8 |
| merge:G1, merge:G4 | 2 each: P/C.merge, P/C.enqueue | TB9 |
| one each | ci:G5 S.head-edits-gate (TB2); ci:G11 S.halt-remove, merge:G17 S.halt-add (TB10); ci:G22 janitor.no-nodes (TB10); intake:I1 P.mirror-ready, intake:I6 S.desk-pr (TB7); intake:I2 C.mirror-blocked, intake:I12 C.depends-link, merge:G8a S.held-24h, merge:G8b S.built-plus-claim (TB6); merge:G7 S.queue-conflict (TB9); merge:G11 S.foreign-trailer (TB4) | |

Pass today: world.seed, desk.write, push.mirror, P/C.claim, P/C.node-tamper, P/C.pr-open,
P/C.pr.build-test (stubbed make), P/C.pr.dependencies, P/C.mg.build-test, P/C.complete,
P/C.issue-closed, C.mirror-ready, gh.forms.

The first red stage of the walk is `janitor.no-nodes` (ci:G22). The first red stage on the ticket path is
`P.fleet-preflight` (node:G10).

## 5. Tests and red proofs

`tests/test_sim.sh` has 7 cases and 23 checks, all green:
- `sim-equals-expected`: the sim in fake mode exits 0, its stage set equals EXPECTED.md's, and both
  completions pass.
- `compare-both-directions` is the **red proof** of the both-directions rule. In a scratch
  EXPECTED.md, `world.seed` is flipped to red and `janitor.no-nodes` to pass. compare exits 2 with
  exactly two lines:
  `green early: world.seed passed (…); EXPECTED says red: ci:G1 flipped` and
  `regressed: janitor.no-nodes is red (janitor: failure); EXPECTED says pass`.
- `compare-missing-and-malformed`: a stage missing from EXPECTED (exit 2), a stage missing from the
  results (exit 2), a red row with no gap id (malformed, exit 2), a usage error (exit 1).
- `gh-forms-static` (22 forms) and `gh-unknown-refused`: `gh repo view` and `api …/actions/runs` are
  refused and logged to `FAKE_GH_UNKNOWN`.
- `driver-jobs-from-yaml`: the driver's job ids (yq + `JOB_ORDER_JQ`) equal an awk parse of every
  workflow's `jobs:` keys, and the gates jobs the walk ran equal gates.yml's.
- `driver-runs-a-new-job`: a commit adds a `sim-extra` job to gates.yml, and the driver runs it
  (success, `${{ github.event_name }}` templated) without any edit to the driver.

A **live red proof** came out of this session too: the first real-adlc run exited 2 with
`green early: S.held-24h passed (#8 labels needs-desk,…)`. The compare rule caught a stage that
went green for the wrong reason (§3).

## 6. Timings (this box)

| run | wall |
|---|---|
| `sim.sh --adlc fake` | 48–55 s |
| `sim.sh --adlc real` (npx per call) | about 3 min 10 s |
| `tests/test_sim.sh` | about 53 s |
| `make test` (17 suites) | 2 min 37 s (it was 1 min 55 s before test_sim.sh) |
| `make lint` (shellcheck + actionlint) | about 11 s |

## 7. Gates

`make lint` exit 0. `make test` exit 0: 17 suites PASS, including `tests/test_sim.sh` (2 min 37 s).
`sim.sh --adlc real` (what `make sim` resolves to on this box) exit 0, and `--adlc fake` exit 0.
