# SPEC — factory-step3-v1: CI gates and the merge queue with the `Depends-on:` hold (build order step 3)

**Status: ACTIVE v0.1, 2026-10-26 (launched without ratification per Aaron's 2026-09-30 rule). Project:
`~/software-factory`, `origin/main` = `4ea237c` (post-merge completed T17–T19). Steps 1 and 2 are
built (`specs/factory-step1-v1`, `factory-step2-v1`, `factory-step2-followups-v1`,
`factory-run-calls-v1`). SPEC-v0.2 build order L1272–1276: "3. CI gates and merge queue with the
Depends-on: hold."**

Goal: one ticket goes from a desk write, through the Issue mirror, a node claim, a fleet build, a PR,
every CI gate on both `pull_request` and the queue, the `Depends-on:` hold and tier order, a merge, to
`completed` on main. That walk passes as an offline end-to-end simulation (`make sim`), and every gap the
2026-10-26 pre-spec simulation found is either closed by a row below or named as Aaron's kit or a ruling.

**Where this spec came from.** On 2026-10-26, before any code was written, the launching session ran a
read-only simulation of the whole pipeline in four segments (intake, node, CI, merge and after). It ran
against scratch copies with the test fakes and the real `@adlc/cli` 1.12.0, and nothing was written to
the repo, the store, `~/.factory` or GitHub. The four reports, each with a file:line citation per gap,
are committed in `records/sim/` (`intake.md`, `node.md`, `ci.md`, `merge.md`), with the scripts that drove
them (`records/sim/*.sh`, re-runnable from a scratch copy). Gap ids below are `<segment>:<id>` from those
reports, for example `ci:G2` is `records/sim/ci.md` row G2. TB0 re-measures every gap before it is fixed.

**Invariants.** I1–I15 of `specs/factory-run-calls-v1/SPEC.md` apply verbatim. In short: never write to
GitHub; user-space pinned installs, no sudo; bash + jq + git + gh; `make test` offline and tool-free,
with real tools only in `make live`; no false green; one trailer paragraph with `Ticket:`; the real CLI is
the truth; transcripts never leave the node; never touch `rb-spec-*`; no wall-clock waits in a DoD;
never `git commit --amend`; I12–I13 the bwrap shim; I14 rendered policy only adds read roots; I15
`factory/policy/**` is never edited by a ticket. Plus:

- **I16 The base is trusted, the head is data.** Every CI gate reads rails, scope, edges, tier, gate
  commands and its own scripts from the **base** commit (`pull_request.base.sha` or
  `merge_group.base_sha`), never from the PR head. A PR that edits a gate script, `gates.yml`,
  `factory/policy/**`, `CODEOWNERS` or `.adlc/config.json` is gated by the base's copy of that file.
  A test proves that a PR which edits `scope-check.sh` to `exit 0` still fails scope.
- **I17 One matcher, one argv.** The node (run.sh) and CI call the same helper for rails-proof, scope
  and tamperguard, with the same arguments, the same tool pin and the same diff range rule (three-dot
  from the merge-base with the base). A test diffs the two call sites' argv.
- **I18 Every required check reports on every path to main.** A check is required only if it runs and
  reports on `pull_request` **and** on the queue path (`merge_group`, or the first-party serial queue
  of TB9). A test compares the required-check set in the branch-protection policy with the job ids in
  `gates.yml` and with the `on:` triggers.
- **I19 The simulation is the proof, GitHub is the kit.** Under I1 no row pushes a branch, opens a PR or
  applies a ruleset. Every DoD that needs "GitHub did X" is proven in `make sim` against a local bare
  origin and the stateful fake `gh` (TB1). The first live GitHub run is a line in Aaron's kit and a
  close-out item, never a row's DoD (no wall-clock waits).
- **I20 Completed means merged to main.** SPEC-v0.2 contradicts itself (the transitions table completes a
  ticket at release, L185–193; the Merge section and post-merge complete it at merge, L689–690). This
  spec rules for merge (merge:G20), and ADR-0002 gains the line.

---

## 0. The register (2026-10-26, measured by the pre-spec simulation; TB0 re-measures)

| key | value | source |
|---|---|---|
| repo | public, **owned by a user account** (not an org); no rulesets, no protection, no secrets, no variables, 0 runners; auto-merge off; `gates.yml` has never run | ci.md §1, merge.md |
| merge queue | believed **org-owned repos only**; the docs pages fetched on 2026-10-26 did not state availability; ADR-0004 L91–95 already flags it | ci:G3, merge:G1 |
| check-run names | a check run is named by the **job id** alone (`janitor`, `mirror` on main); the policy requires `gates / <job>` and `tests/test_halt_rules.sh:94` asserts the wrong form | ci:G1, merge:G2, node:G9 |
| tamper job | `gates.yml:50` passes `--base`, which tamperguard 0.2.0 rejects (rc 2 = "tamper"), so the job is always red; the node uses `--range BASE..tip --json` (`policy-render.sh:107`) | ci:G2, node:G1 |
| stubs | `rails-proof.sh`, `scope-check.sh`, `commit-check.sh`, `attest-verify.sh`, `skills-scan.sh`, `digest.sh` each exit 2 | ci §1 |
| node commits | fleet's two commits (`feat(T20): fleet worker build` and the `--no-ff` merge) carry no `Signed-off-by` / `Assisted-by` / `Ticket:` | node:G2, ci:G8 |
| PR body | `Ticket:`, `Issue:`, `Node:` only; no tier label, no `Depends-on:`, no reviewer adapter | node:G8, intake:I3 |
| claim across a PR | the kept lock is never heartbeated, the Issue stays `ready`; after 24 h the janitor releases it and a second node rebuilds; the kept lock also counts toward slots, so the janitor kills the node's next in-flight claim (`over-slots`) | node:G3, merge:G8a/G8b (sim_merge_held) |
| `ready` records | nothing writes the `spec-lint`, `coldstart` or per-ticket `merge-forecast` records mirror.sh requires (L187–202), so no Issue has ever been `ready` | intake:I1, merge:G14 |
| Depends-on | no hold anywhere; adlc lets a child complete while its parent is open | merge:G3, ci:G9 |
| fleet block | main's `.adlc/config.json` has none, so fleet refuses at preflight on any real ticket (ruled into step 3, step-2-followups RULINGS Q3) | node:G10, merge:G19 |
| post-merge | completes **every** `Ticket:` trailer it finds (a T20 PR could complete T21); its push to a protected main needs the App (absent) | merge:G11, merge:G12 |
| janitor | red hourly: `couldn't find remote ref refs/heads/nodes` | ci:G22, merge:G15 |

---

## 1. Rows (tracer bullets, in order; cap = 8 × 13 = 104 iterations)

Each row from TB2 on is one adlc ticket (T20–T31, created in TB0), with commit trailer `Ticket: T<n>`.
Each row's DoD includes: `make test` + `make lint` green, every new script covered by an offline test,
red proofs (the new test fails on the old code, recorded), and the `make sim` stages it owns turned from
the recorded "expected red" to green. `records/TB<n>.md` per row.

### TB0 — Register, tickets T20–T31, and the measurements the rows depend on
DoD: `records/TB0.md` re-measures every register line with its command (GitHub by read-only `gh api` /
GraphQL only) and re-checks every gap id cited below as still open, closed, or wrong (a wrong gap is
dropped from its row with the evidence). Measure, never guess:
(a) merge-queue availability for a user-owned public repo: GitHub docs (fetch the rulesets
"available rules" page and the merge-queue page, quote the availability line), plus a read-only GraphQL
`repository { mergeQueue(branch:"main") { id } }`. Record the result as `native-queue: yes | no | unknown`.
(b) the exact check-run name a job gets in a `pull_request` run and in a `merge_group` run, from GitHub's
docs (`required status checks` context naming) and from this repo's existing runs.
(c) whether `ubs`, `aislop`, an `attest` CLI, `flaky-test-detective` and `bomdrift` exist as pinned,
installable releases (registry API reads), with version and license.
(d) whether GitHub Actions' `GITHUB_TOKEN` events trigger other workflows (docs quote), for the labeler
and the re-evaluation design in TB8.
Then create T20–T31 through `adlc ticket create … --write --allow-unsigned` (ruling Q1 of
factory-run-calls-v1) with the ADR-0002 header, verification-method acceptance criteria, scope globs,
`rails: ["factory/policy/**"]`, tier, and edges in row order. doctor ok, coldstart gaps empty,
merge-forecast exit 0. Commit `Ticket: scaffold`.

### TB1 — `make sim`: the end-to-end pipeline simulation, today's stop points recorded (ticket T20)
DoD: `tests/sim/` holds an offline harness, run by `make sim` and by `make test`, which:
- builds a scratch world: a local bare origin seeded from the working tree, a desk clone, two node
  homes (`dev-box`, `node-b`), the real repo scripts, and a **stateful fake `gh`** whose state is a
  JSON file holding Issues, labels, PRs (head/base/body/labels/reviews/state), check runs, the queue and
  merged commits. The fake answers the `gh` calls the repo already makes (list them from `grep -rn 'gh '`
  across `factory/` and `.github/`), and a test fails if a script calls a `gh` form the fake does not
  know. A fake fleet builds deterministic commits exactly as fleet 1.12.0 shapes them (records/sim
  node.md §walk). adlc is the real 1.12.0 when present, the existing fake otherwise (I4).
- runs a **workflow driver**: for each `.github/workflows/*.yml` event it simulates (pull_request,
  merge_group, push to main, schedule), it runs that job's `run:` steps from the **base** checkout in the
  scratch world with the GitHub event JSON and env a real runner would give (`GITHUB_EVENT_PATH`,
  `GITHUB_BASE_REF`, `GITHUB_HEAD_REF`, `GITHUB_SHA`), and records each job's exit as a check run. The
  driver reads the jobs from the YAML (yq or a pinned parser; never a hard-coded copy), so a job added in a
  later row is simulated without editing the driver.
- walks the **T-sim scenario**: the desk writes T-sim-parent (tier 0) and T-sim-child (tier 1, depends on
  the parent), both railed and scoped; mirror; claim on dev-box; build; gates on the node; push; PR;
  every gate on `pull_request`; the hold; tier order; queue; `merge_group` gates; merge; post-merge
  complete; mirror closes the Issue; the child becomes ready; the child repeats the path.
- writes `tests/sim/EXPECTED.md`: one line per stage with `pass` or `red: <gap id>`. In this row every
  stage up to the first gap is `pass` and every later stage is `red` with its gap id (for example
  `tamper: red ci:G2`). `make sim` fails when a stage's result differs from EXPECTED.md, in either
  direction (a stage going green early is a fail until EXPECTED.md says so). Later rows flip lines.
- also holds the **failure scenarios**, each recorded red-with-gap-id until its row: a PR touching a file
  outside scope; a tamper (a new `.skip`); a rail-path edit; a commit without trailers; a PR whose head
  edits `scope-check.sh` to `exit 0` (I16); a foreign `Ticket:` trailer (merge:G11); a child merged
  before its parent; a lower-tier PR jumping a tier-0 one; a queue ejection on conflict; a PR held past
  24 h (sim_merge_held); a HALT add with zero approvals and a HALT removal with one; a desk PR to
  `.adlc/**`; a ticket PR touching `.adlc/**`.
Commit `Ticket: T20`.

### TB2 — Gate context and ticket identity (ticket T21)
Fixes ci:G4, ci:G5, ci:G7, merge:G10, node:G4 (identity half).
DoD: `factory/bin/lib/gate-context.sh` resolves, for any gate run, `BASE` and `HEAD` (from
`pull_request.base.sha/head.sha`, or `merge_group.base_sha/head_sha`, or the node's merge-base and tip),
the PR number (on `merge_group` from `gh-readonly-queue/main/pr-<N>-<sha>`), the ticket id (from the head
ref `ticket/<id>/<handle>`; on `merge_group` from PR N's head ref, read with the read-only token) and the
PR class: `ticket`, `desk` (touches only `.adlc/**` and desk docs), `halt` (adds or removes
`factory/HALT` only), or `human` (a non-ticket PR by a collaborator). `common.sh`'s id validator refuses
`/` in an id. `gates.yml` checks out the **base** into `./.base` and runs every gate script from there
(I16), with the PR head as the working tree it inspects. Ticket gates refuse a PR whose class is
`ticket` but whose body `Ticket:` line or trailers name another id. Tests: each event shape (fixtures of
real event JSON from GitHub's docs, cited), each class, the queue-ref parse, the base-script rule (the
`exit 0` scenario stays red for the right reason). `make sim`: the identity stages go green. Commit
`Ticket: T21`.

### TB3 — The three diff gates: rails-proof, scope, tamper, one helper for node and CI (ticket T22)
Fixes ci:G2, ci:G6 (three of four stubs), node:G1, node:G4, node:G5, ci §1 (`:(glob)` pathspecs).
DoD: `factory/bin/lib/diff-gates.sh` (sourced by run.sh and by the three CI scripts, I17):
- **rails-proof.sh**: rails from the base store; `git diff --quiet BASE...HEAD -- ':(glob)<rail>'…`
  (plain pathspecs let `*` cross `/`, records/sim ci.md); non-empty fails, exit 1, with the paths.
- **scope-check.sh**: scope from the base store; every path in `BASE...HEAD` must match a scope glob,
  same glob semantics as fleet's own scope check (measure fleet's matcher in `@adlc/cli`, cite file:line;
  if they differ, use fleet's and record it); a ticket PR that touches `.adlc/**` fails (merge §fleet
  block); interface `--ticket <id> --base <sha> --head <sha>` for both callers.
- **tamper**: tamperguard 0.2.0 with `--range BASE...HEAD --json`, verdict parsed from the JSON (rc 2
  with a parsed `tamper` verdict fails; any other non-zero is `tamper-error`, also a fail, never a pass).
  Node and CI use the same Python minor (measure what the node's uv tool resolves and pin CI to it, node:G16); run.sh refuses to start when `adversarial-review` is not on PATH (SPEC-v0.2 L644, node:G16).
- On the node, the gate range starts at the merge-base with origin/main, not at a lapsed tip (node:G5).
run.sh replaces its `scope-check-not-built` hold with the real call; ADR-0005 gains an amendment.
Tests per gate (pass, fail, error, glob crossing `/`, the lapsed-resume range). `make sim`: the diff-gate
stages and their failure scenarios go green. Commit `Ticket: T22`.

### TB4 — One trailered commit per ticket and the commit check (ticket T23)
Fixes node:G2, ci:G8, merge:G11, ci:G6 (commit-check stub).
DoD: after every node gate passes, run.sh writes **one** commit whose tree is fleet's final tree and
whose parent is the merge-base with origin/main, carrying the one trailer paragraph (`Assisted-by:`,
`Ticket: <id>`, `Node: <handle>`, `Signed-off-by:` via `-s`). That commit is what gets pushed (fleet's
own commits stay in the local log for the transcript record, never pushed). Rationale for squash over
"tip trailers cover the range": SPEC-v0.2 says every commit carries the trailers, and the builder already
"cherry-picks onto a fresh branch, never rebases" on ejection (L689), so a one-commit branch is the shape
the queue path also wants. `commit-check.sh`: every commit in `BASE...HEAD` (skipping GitHub's own queue
merge commit, identified by its author and parent shape, measured) has `Signed-off-by` + `Assisted-by`;
on a `ticket` PR every `Ticket:` trailer equals the branch's id; `desk`, `halt`, `human` classes have
their own rule (DCO only). post-merge.sh completes **only** the ticket named by the merged PR's head
branch, and refuses (records, does not complete) a trailer naming another id. Tests for each. `make sim`
stages green. Commit `Ticket: T23`.

### TB5 — main's `fleet` block and the build-test gate from the base config (ticket T24)
Fixes node:G10, merge:G19 (ruling Q3 of factory-step2-followups-v1).
DoD: main's `.adlc/config.json` gains the one repo-wide block, starting from the shape in records/sim
merge.md §"main's fleet block" (`gate.test`, `gate.build`, desk-written `allowedCommands`,
`prosecuteFailOn`, `timeoutMinutes`; adapter, model and key stay CLI-only). Every key is checked against
fleet 1.12.0's config reader (cite file:line); unknown keys are errors. `make lint`'s shellcheck download
fallback is replaced or pinned so `gate.build` runs under the build profile's no-network rule (measure;
if a node needs shellcheck installed, join.sh's probe requires it and the join test covers it). CI's
`build-test` job reads the gate commands from the **base** config and runs exactly those (I16, I17), not
a hard-coded `make test`. Test: the config parses for fleet (real fleet in `make live`, a schema check in
`make test`), CI and node run the same command list. `make live` smoke: the toy ticket now passes fleet's
preflight on a scratch copy of **main's** config, not only the fixture's. Commit `Ticket: T24`.

### TB6 — The claim across an open PR, and the `blocked` label (ticket T25)
Fixes node:G3, merge:G8a, merge:G8b, merge:G8c, intake:I2, merge:G9, intake:I12.
DoD: when run.sh opens the PR it **releases the claim lock** (the PR is now the claim) and labels the
Issue `in-review`; mirror.sh never labels `ready` while an open PR exists for the ticket's branch prefix
`ticket/<id>/`; claim.sh skips such a ticket; the janitor leaves out locks whose PR is open from both
the TTL and the slot count, and releases any lock whose Issue is closed. A new owned label `blocked`
replaces `needs-desk` when the only reasons are dependency order (wave > 1 or an open parent); the
digest and summoner ignore `blocked`. `Depends-on:` lines in the Issue body carry the link,
`Depends-on: T21 (#2)`. Also: run.sh checks it still owns the lock (`heartbeat.sh` dry run) before it pushes, else `lock-lost` (node:G13); a `pr-open-failed` is retried on the next iteration from a state file, then released to the desk (node:G12); the per-ticket `budget` from `adlc ticket show` overrides the weights (node:G14). Ruling taken here (no page; SPEC-v0.2 L213 already defines `blocked`): the
forecast's serial order stands, and the merge-queue hold of TB8 is defense in depth, because adlc lets a
child complete before its parent (merge:G3). Tests: sim_merge_held's two scenarios now pass (no second
build, no `over-slots` kill); `blocked` vs `needs-desk`; the link. `make sim` stages green. Commit
`Ticket: T25`.

### TB7 — The desk gates: records `ready` needs, contract lint, the manifest chain (ticket T26)
Fixes intake:I1, intake:I5, intake:I6, intake:I7, intake:I10, intake:I14, merge:G14.
DoD: `factory/bin/desk-gates.sh` writes the `spec-lint` and `coldstart` records for every open ticket
whose record is missing or stale (adlc's own record commands; measure which exist in 1.12.0 and cite
them). The per-ticket `merge-forecast` record requirement in mirror.sh is dropped in favor of the live
forecast mirror.sh already runs, unless TB0 finds a record command (cite either way). ticket-check.sh
gains: the ADR-0002 header present, every scope glob resolves to at least one path or a declared new
path, every edge target exists, no tier inversion (a tier-n ticket whose parent is tier > n), and any
forecast warning that names the ticket is a failure. A `desk` job in `gates.yml` runs on PRs touching
`.adlc/**`: `make tickets`, `adlc ticket doctor`, and the manifest chain check with 0 skipped (two desk
PRs, or a desk PR racing a post-merge commit, that break the hash chain fail here, never on main); a
desk runbook in `factory/RULES.md` says to write a child and its parent's edge in one PR and re-run the
parent's coldstart (intake:I10). ADR-0002 is amended: ids are `T<n>`, not ULIDs (intake:I11); completed
means merged (I20). Tests for each check; `make sim`: the desk writes a ticket and it reaches `ready`
with no record injected by hand. Commit `Ticket: T26`.

### TB8 — The `Depends-on:` hold and tier order (ticket T27)
Fixes merge:G3, ci:G9, ci:G10, merge:G5, intake:I3, intake:I4, node:G8.
DoD: `factory/bin/depends-check.sh` and a required `depends-on` job on `pull_request` and the queue
path: the parents are the tickets in the **base** store with an edge to this ticket; pass only if every
parent is completed in the base store; never read the PR body. A `tier-order` job: a tier-n ticket PR
waits (pending, exit 1 with the blocking PR numbers) while any approved, green, open ticket PR of a lower
tier exists; first-done-first within a tier (the PR's first green `gates` time, kept by the queue, TB9).
A trusted labeler (a workflow on `push` to main and on schedule, never `pull_request_target` running head
code) applies `tier:<n>` to open ticket PRs from the base store and writes the PR body's display lines
(`Depends-on:`, tier, prosecuting adapter, `Assisted-by`). Because `GITHUB_TOKEN` events do not trigger
other workflows (measured in TB0 (d)), the labeler and the re-evaluation of held PRs run on `push` to main
after post-merge and on a schedule, and use the App token when it exists. Tests: child before parent held;
released after the parent completes; tier-1 waits for tier-0; ties by first-green. `make sim` stages and
the "child merged before parent" and "tier jump" scenarios green. Commit `Ticket: T27`.

### TB9 — The queue: native merge queue or the first-party serial queue, and ejection (ticket T28)
Fixes merge:G1 (as far as code can), merge:G4, merge:G7, ci:G21, ci:G19.
DoD: `factory/bin/enqueue.sh` (run by a workflow on `push` to main, on check completion and on
schedule, with the App token) takes the ordered list of mergeable ticket PRs (every required check green,
the hold and tier jobs green, approvals per TB10) and, by `native-queue` from TB0:
- **yes**: enqueues the head of the list through GraphQL `enqueuePullRequest`;
- **no or unknown**: runs the **first-party serial queue** (SPEC-v0.2's MergeGuard pattern, first party):
  for the head of the list only, it builds the merge of the PR onto current main in a temporary branch
  `factory-queue/pr-<N>`, runs the same gates there (the driver treats it as the queue path, I18), and if
  green fast-forwards main to it with the App (the App is the only bypass actor), then closes the PR as
  merged. One PR at a time, so it is sequential like GitHub's queue with build and merge size 1.
Ejection: a conflict or a red queue run labels the PR `autorebase`, writes an ejection record
(`factory/ledger/ejections.jsonl`, read later by the digest), and returns the ticket to `ready` with a
`rebase-strike` flag; on the next claim run.sh cuts a fresh branch from main and cherry-picks the one
ticket commit (TB4), and the rebase strike does not count toward `--max-strikes`. ADR-0007 records the
queue design and the `native-queue` fallback. Tests: both modes in `make sim` (the fake gh models the
native queue too); ejection; the strike counter. Commit `Ticket: T28`.

### TB10 — Branch protection as code, approvals, the halt-guard, the App's reach (ticket T29)
Fixes ci:G1, merge:G2, node:G9, ci:G11, ci:G12, merge:G6, ci:G13, merge:G17, ci:G22, merge:G15
(code half), node:G7, ci:G17, ci:G18, ci:G20.
DoD:
- `branch-protection.json` requires the **bare job ids** with `integration_id` 15368 (GitHub Actions;
  cite), and a test asserts the required set equals the `gates.yml` job ids that report on both paths
  (I18); `tests/test_halt_rules.sh:94` is fixed. Merge-queue settings are written only when
  `native-queue: yes`; otherwise the policy requires the first-party queue's check and disallows direct
  merges by everyone but the App.
- Approvals: 0 required approvals globally; code-owner review required; a first-party `owners` job
  requires **two distinct** CODEOWNERS approvals on PRs touching `factory/**`, `.adlc/**`, `.github/**`,
  `.claude/**` (SPEC-v0.2 trust section; GitHub can count only one owner), with
  `require_last_push_approval`. Until a second owner exists, such PRs cannot merge; that is the spec's
  rule, and HANDOFF says so in Aaron's kit.
- `halt-guard` job and `halt.yml` per ADR-0004 option C: a collaborator adds `factory/HALT` with zero
  approvals through a dispatch or label that the App commits directly (a halt must never wait in the
  queue, merge §19), and the workflow sets `factory:halt`; removing HALT needs two approvals; HALT PRs
  are the `halt` class of TB2 and skip ticket gates.
- The App's private key lives in a GitHub **environment** restricted to `main` (post-merge, mirror,
  janitor, enqueue, revoke, halt), never as a repo secret a PR run could read (ci:G13); the workflows say
  `environment:`.
- janitor.sh treats a missing `nodes` branch as empty (ci:G22); `apply-branch-protection.sh` gains a
  `--bootstrap` that creates `nodes` and `flaky-history` (run by Aaron, merge:G15).
- join.sh asks for Contents, Issues and Pull requests write plus Metadata, and the node env file exports
  `GH_TOKEN` from the stored token so gh and git run as the node, not the owner (node:G7).
- Actions pinned by commit sha with the tag in a comment; CI installs a pinned actionlint so `make lint`
  never silently skips it; `factory/policy/tamperguard.toml` either exists or its mention is removed
  (desk note if it is under `factory/policy/**`, I15).
Tests for each. `make sim`: HALT scenarios and required-check naming green. Commit `Ticket: T29`.

### TB11 — The remaining CI gates: attest, bug scan, flaky, skills (ticket T30)
Fixes ci:G6 (attest-verify stub), ci:G15, ci:G16, node:G6, merge:G18, ci:G14.
DoD, by what TB0 (c) measured:
- **Gate manifest**: the node writes the gate manifest (tests run, result hashes, adapter, verdicts) as a
  git note under `refs/notes/factory-attest` on the ticket commit and pushes it with the branch, unsigned
  under the store's `unsigned-fallback` (ruling Q1 of factory-run-calls-v1; a key can replace it later);
  `attest-verify.sh` in CI recomputes what it can (rails, scope, tamper verdicts, gate command list) and
  fails on any mismatch or a missing note. If an `attest` CLI exists as a pinned release, use it and cite
  it; otherwise the first-party format is documented in ADR-0007.
- **Bug scan**: `ubs` and `aislop` as a `bugscan` job with SARIF upload and a score gate, if both are
  pinned, installable and license-compatible; if not, the job is not added and a `### Q` names what is
  missing (never a stub that exits 0).
- **Flaky**: the quarantine list `factory/policy/quarantine.json` is a desk file (I15: created by the desk,
  not this ticket; the row writes the reader and a desk note) with an expiry per entry; a `flaky` job fails
  on an expired entry; the JUnit-history classifier (`flaky-test-detective` on `flaky-history`) is
  added only if TB0 found a pinned release, otherwise it is recorded as step 4.
- **skills-scan**: either a real body with `merge_group` and required, or left unrequired with the reason
  (merge:G18); never a required stub.
- **Heavy work** (ci:G14): no `w:heavy` job is required until a self-hosted `factory-node` runner exists;
  the gates.yml header comment says so.
Tests for each added gate; `make sim` stages green. Commit `Ticket: T30`.

### TB12 — The full walk green, live smoke to `pr-ready`, close-out (ticket T31)
DoD part A: `tests/sim/EXPECTED.md` is `pass` on every stage of the T-sim scenario and every failure
scenario fails for its own reason (each red line names the gate that stopped it). `make sim` output is
kept in `records/TB12.md`. Any stage that cannot go green without GitHub itself (for example the native
queue's real behavior) is `kit: <line>` in EXPECTED.md with the reason, never `pass`.
DoD part B: `FACTORY_SMOKE_KEEP=$HOME/.cache/factory-smoke-evidence make live`: the toy ticket on the
dev box runs through fleet, tamperguard under the rendered policy, the real scope-check and rails-proof,
the one trailered commit and the attest note, and ends at **`pr-ready`**: pushed to a **local bare
origin** (never GitHub, I1) with the PR body written to the evidence dir. Record each verdict.
DoD part C: `make test` + `make lint` + `make live` + `make sim` green; coldstart gaps empty T20–T31;
README build-order row 3 updated; desk notes for `factory/policy/**` in HANDOFF (I15); HANDOFF ends with
"Aaron's kit", one line each, re-checked read-only: the App (now also Pull requests write for enqueue),
its key into the `main` environment, the variables and webhooks, `apply-branch-protection.sh
--bootstrap` then `--apply` last, the runner, the second CODEOWNERS owner, and the first live run (one
toy ticket PR through GitHub, which closes the `kit:` lines of EXPECTED.md). Then `### Q` blocks,
including at least **Q: the merge queue** if `native-queue` is not `yes` (move the repo to an organization
for GitHub's queue, or keep the first-party serial queue; the code supports both). Commit `Ticket: T31`.

---

## 2. Out of scope

Build order 4+: the rail author charter, the withholding check, prosecution CLI depth, the verifier,
summoner and digest bodies beyond reading the ejection records, hollow-test mutation, the 1-in-5
re-prosecution and calibration (step 4); preview, behavior-diff, release (step 5). Re-pinning fleet past
1.12.0 or retiring the bwrap shim (its own spec). Filing anything upstream (drafts only). Any write to
GitHub (I1). Editing `factory/policy/**` (I15). Moving the repo to an organization, adding a second
owner, or making the repo private (Aaron).

---

## 3. Gap → row map (every gap in records/sim/*.md has a home)

| row | gaps |
|---|---|
| TB2 | ci:G4 G5 G7, merge:G10, node:G4 |
| TB3 | ci:G2 G6, node:G1 G4 G5 G16 |
| TB4 | node:G2 G15, ci:G8, merge:G11 |
| TB5 | node:G10, merge:G19 |
| TB6 | node:G3 G12 G13 G14, merge:G8a G8b G8c G9, intake:I2 I12 |
| TB7 | intake:I1 I5 I6 I7 I10 I11 I14, merge:G14 G20 |
| TB8 | merge:G3 G5, ci:G9 G10, intake:I3 I4, node:G8 |
| TB9 | merge:G1 G4 G7 G13, ci:G19 G21 |
| TB10 | ci:G1 G11 G12 G13 G17 G18 G20 G22, merge:G2 G6 G15 G17, node:G7 G9 |
| TB11 | ci:G6 G14 G15 G16, node:G6, merge:G16 G18 |
| step 4 (named, not built) | intake:I8 (labels on `github.token`, approval marker), intake:I13 (`touches_factory`), merge:G16 digest body |
| Aaron's kit | merge:G12 (App + key), merge:G15 (`nodes` branch, via `--bootstrap`), intake:I9, merge:G1 if no native queue |
| covered by a row's ruling or folded | node:G11 (TB6 ruling: serial order stands), node:G17 (TB10 approvals + TB11 heavy), ci:G19 (TB9 queue; `strict` revisited there), ci:G21 (TB9 ejection); TB0 re-checks each |
