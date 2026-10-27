#!/usr/bin/env python3
"""Generates the T20-T31 input documents (records/tickets/T<n>.json) for `adlc ticket create`.
Run from anywhere; writes next to itself. Edges run in row order, T<n> -> T<n+1>."""
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = "specs/factory-step3-v1/SPEC.md"
COMMON_OUT = ("any write to GitHub (no push, PR, label, ruleset or secret; I1); editing anything under "
              "factory/policy/ (I15: a change there is a desk note in the spec's HANDOFF); editing other tickets.")
COMMON_AC = [
    ("Every new or changed script is shellcheck -S warning clean and every workflow passes actionlint.", "`make lint`"),
    ("The whole offline suite passes, including the simulation.", "`make test` and `make sim`"),
]

def body(h, intro, fixes, deliver, acs, new, out):
    lines = [f"weight: {h[0]}", f"tier: {h[1]}", f"charter: {h[2]}", "", intro, ""]
    if fixes:
        lines += [f"Closes the pre-spec simulation gaps {fixes} (ids are `<segment>:<id>` rows of "
                  "specs/factory-step3-v1/records/sim/<segment>.md, re-checked in specs/factory-step3-v1/records/TB0.md).", ""]
    lines += ["Deliverables:"] + [f"- {d}" for d in deliver] + [""]
    lines += ["Acceptance criteria:"]
    for i, (a, v) in enumerate(acs + COMMON_AC, 1):
        lines.append(f"{i}. {a} Verify: {v}.")
    lines += [""]
    if new:
        lines += ["New paths (created by this ticket, so they match nothing yet): " + ", ".join(f"`{p}`" for p in new) + ".", ""]
    lines += ["Out of scope: " + (out + " " if out else "") + COMMON_OUT]
    return "\n".join(lines)

T = []
def ticket(n, title, h, cat, dur, scope, intro, fixes, deliver, acs, new=(), out=""):
    T.append({"id": f"T{n}", "title": title,
              "body": body(h, intro, fixes, deliver, acs, list(new), out),
              "category": cat, "duration": dur, "scope": scope,
              "rails": ["factory/policy/**"],
              "edges": [{"to": f"T{n+1}"}] if n < 31 else []})

ticket(20, "Add make sim: an offline end-to-end pipeline simulation with a stateful fake gh, recording today's stop points",
  ("light", 0, "C6"), "test", 2,
  ["tests/sim/**", "tests/test_sim.sh", "tests/fakes/**", "Makefile", "factory/test.sh"],
  f"{SPEC} row TB1. Build the harness every later step-3 row proves itself in: one ticket walks from a desk write to `completed` on main without GitHub (I19).",
  "",
  ["`tests/sim/` holds an offline harness run by `make sim` and by `make test` (through `tests/test_sim.sh`).",
   "It builds a scratch world: a local bare origin seeded from the working tree, a desk clone, two node homes (`dev-box`, `node-b`), the real repo scripts, and a stateful fake `gh` whose state is one JSON file (Issues, labels, PRs with head/base/body/labels/reviews/state, check runs, the queue, merged commits).",
   "The fake answers every `gh` form the repo's scripts and workflows already use (listed from `grep -rn 'gh '` across factory/ and .github/), and a test fails when a script calls a form the fake does not know.",
   "A fake fleet builds deterministic commits shaped exactly as fleet 1.12.0 shapes them (`feat(<id>): fleet worker build` with `:!.adlc :!.claude` excluded, then a `--no-ff` merge). adlc is the real 1.12.0 when present, the existing fake otherwise (I4).",
   "A workflow driver runs, for each `.github/workflows/*.yml` event it simulates (pull_request, merge_group, push to main, schedule), that job's `run:` steps from the base checkout with the event JSON and env a real runner gives (`GITHUB_EVENT_PATH`, `GITHUB_BASE_REF`, `GITHUB_HEAD_REF`, `GITHUB_SHA`), and records each job's exit as a check run. It reads the jobs from the YAML with a pinned parser, never a hard-coded copy.",
   "The T-sim scenario: T-sim-parent (tier 0) and T-sim-child (tier 1, depends on the parent), both railed and scoped; mirror; claim on dev-box; build; node gates; push; PR; every gate on pull_request; the hold; tier order; queue; merge_group gates; merge; post-merge complete; mirror closes the Issue; the child becomes ready and repeats the path.",
   "The failure scenarios: out-of-scope file; tamper (a new `.skip`); rail-path edit; commit without trailers; a head that edits `scope-check.sh` to `exit 0` (I16); a foreign `Ticket:` trailer; child merged before parent; a lower-tier PR jumping a tier-0 one; queue ejection on conflict; a PR held past 24 h; a HALT add with zero approvals and a HALT removal with one; a desk PR to `.adlc/**`; a ticket PR touching `.adlc/**`.",
   "`tests/sim/EXPECTED.md`: one line per stage, `pass` or `red: <gap id>`; `make sim` fails when any stage differs from it in either direction."],
  [("`make sim` runs offline and its stage results equal tests/sim/EXPECTED.md exactly.", "`make sim`"),
   ("A stage that turns green before EXPECTED.md says so fails `make sim` (proved by flipping one EXPECTED line in a scratch copy).", "`bash tests/test_sim.sh`"),
   ("The fake gh refuses a `gh` form it does not model, and every form used in factory/ and .github/ is modeled.", "`bash tests/test_sim.sh`"),
   ("The driver's job list equals the job ids parsed from .github/workflows/*.yml.", "`bash tests/test_sim.sh`")],
  new=["tests/sim/", "tests/test_sim.sh"],
  out="Fixing any gap the simulation records (later rows flip EXPECTED.md lines).")

ticket(21, "Resolve gate context and ticket identity for every CI gate, and run gate scripts from the base checkout",
  ("light", 0, "C6"), "feature", 1,
  ["factory/bin/lib/gate-context.sh", "factory/bin/lib/common.sh", "factory/bin/rails-proof.sh", "factory/bin/scope-check.sh",
   "factory/bin/commit-check.sh", "factory/bin/attest-verify.sh", ".github/workflows/gates.yml",
   "tests/test_gate_context.sh", "tests/fixtures/events/**", "tests/fakes/**", "tests/sim/**"],
  f"{SPEC} row TB2. Every gate needs the same facts (base, head, PR, ticket, PR class) and must read its scripts and data from the base commit, never the PR head (I16).",
  "ci:G4, ci:G5, ci:G7, merge:G10, node:G4 (identity half)",
  ["`factory/bin/lib/gate-context.sh` resolves BASE and HEAD (from `pull_request.base.sha/head.sha`, or `merge_group.base_sha/head_sha`, or on the node the merge-base with origin/main and the tip), the PR number (on merge_group from `gh-readonly-queue/main/pr-<N>-<sha>`), the ticket id (from the head ref `ticket/<id>/<handle>`; on merge_group from PR N's head ref read with the read-only token) and the PR class: `ticket`, `desk` (touches only `.adlc/**` and desk docs), `halt` (adds or removes `factory/HALT` only) or `human`.",
   "`common.sh`'s id validator refuses `/` in an id.",
   "gates.yml checks out the base into `./.base` and runs every gate script from there, with the PR head as the working tree it inspects.",
   "Ticket gates refuse a `ticket` PR whose body `Ticket:` line or commit trailers name another id."],
  [("Each event shape resolves correctly, from fixtures of real event JSON copied from GitHub's webhook docs (the source cited in the fixture).", "`bash tests/test_gate_context.sh`"),
   ("Each PR class is classified correctly, and the merge_group ref parse gives the PR number.", "`bash tests/test_gate_context.sh`"),
   ("A head that edits `scope-check.sh` to `exit 0` still fails, because the base copy runs.", "`make sim` (the I16 scenario)"),
   ("An id containing `/` is refused.", "`bash tests/test_gate_context.sh`")],
  new=["factory/bin/lib/gate-context.sh", "tests/test_gate_context.sh", "tests/fixtures/events/"])

ticket(22, "Build the three diff gates (rails-proof, scope, tamper) as one helper shared by the node and CI",
  ("light", 0, "C6"), "feature", 2,
  ["factory/bin/lib/diff-gates.sh", "factory/bin/rails-proof.sh", "factory/bin/scope-check.sh", "factory/bin/tamper-check.sh",
   "factory/bin/run.sh", "factory/bin/lib/run.sh", "factory/bin/lib/policy-render.sh", ".github/workflows/gates.yml",
   "docs/adr/0005-run-loop-cli-reality.md", "tests/test_diff_gates.sh", "tests/test_run.sh", "tests/fakes/**", "tests/sim/**"],
  f"{SPEC} row TB3. The node and CI must call the same matcher with the same argv, the same tool pin and the same diff range rule, three-dot from the merge-base with the base (I17).",
  "ci:G2, ci:G6 (three of four stubs), node:G1, node:G4, node:G5, node:G16",
  ["`factory/bin/lib/diff-gates.sh`, sourced by run.sh and by the three CI scripts.",
   "rails-proof.sh: rails from the base store; `git diff --quiet BASE...HEAD -- ':(glob)<rail>'`; a non-empty diff exits 2 with the paths.",
   "scope-check.sh: scope from the base store; every path in BASE...HEAD matches a scope glob with fleet's own glob semantics (fleet's matcher measured in @adlc/cli 1.12.0 and cited file:line); a ticket PR touching `.adlc/**` fails; interface `--ticket <id> --base <sha> --head <sha>` for both callers.",
   "tamper-check.sh: tamperguard 0.2.0 with `--range BASE...HEAD --json`; the verdict is parsed from the JSON; rc 2 with a parsed `tamper` verdict fails; any other non-zero is `tamper-error`, also a fail. Node and CI use the same Python minor (measured from the node's uv tool).",
   "run.sh refuses to start when `adversarial-review` is not on PATH, starts the gate range at the merge-base with origin/main (not a lapsed tip), and replaces its `scope-check-not-built` hold with the real call; ADR-0005 gains an amendment."],
  [("Each gate passes, fails and errors on fixture repos, including a glob that would cross `/` without `:(glob)`.", "`bash tests/test_diff_gates.sh`"),
   ("A lapsed-branch resume gates the range from the merge-base with origin/main.", "`bash tests/test_run.sh`"),
   ("The node and CI call sites pass the same argv to the helper.", "`bash tests/test_diff_gates.sh`"),
   ("The diff-gate stages and their failure scenarios are green.", "`make sim`")],
  new=["factory/bin/lib/diff-gates.sh", "factory/bin/tamper-check.sh", "tests/test_diff_gates.sh"])

ticket(23, "Push one trailered commit per ticket and build the commit check; post-merge completes only the branch's ticket",
  ("light", 0, "C6"), "feature", 1,
  ["factory/bin/run.sh", "factory/bin/lib/run.sh", "factory/bin/commit-check.sh", "factory/bin/post-merge.sh",
   ".github/workflows/gates.yml", "tests/test_run.sh", "tests/test_commit_check.sh", "tests/test_post_merge.sh",
   "tests/fakes/**", "tests/sim/**"],
  f"{SPEC} row TB4. fleet's worker and merge commits carry no trailers, so the node pushes one commit that does, and CI checks every commit.",
  "node:G2, node:G15, ci:G8, merge:G11, ci:G6 (commit-check stub)",
  ["After every node gate passes, run.sh writes one commit whose tree is fleet's final tree and whose parent is the merge-base with origin/main, carrying one trailer paragraph (`Assisted-by:`, `Ticket: <id>`, `Node: <handle>`, `Signed-off-by:` via `-s`); that commit is pushed, fleet's own commits stay local.",
   "commit-check.sh: every commit in BASE...HEAD (skipping GitHub's own queue merge commit, identified by its author and parent shape) has `Signed-off-by` and `Assisted-by`; on a `ticket` PR every `Ticket:` trailer equals the branch's id; `desk`, `halt` and `human` classes need the DCO only; the post-merge exemption in factory/RULES.md is honored exactly.",
   "post-merge.sh completes only the ticket named by the merged PR's head branch and records, without completing, a trailer naming another id."],
  [("A built ticket's pushed branch holds exactly one commit over the merge-base, with all four trailers.", "`bash tests/test_run.sh`"),
   ("commit-check passes the node's commit and fails an untrailered commit, a foreign `Ticket:`, and a fake post-merge shape.", "`bash tests/test_commit_check.sh`"),
   ("post-merge refuses a foreign trailer and completes the branch's ticket.", "`bash tests/test_post_merge.sh`"),
   ("The commit-check stages are green.", "`make sim`")],
  new=["tests/test_commit_check.sh"])

ticket(24, "Make CI's build-test run main's fleet gate commands from the base config, with a lint that runs offline",
  ("heavy", 0, "C5"), "feature", 2,
  ["factory/bin/build-test.sh", ".github/workflows/gates.yml", "Makefile", "factory/bin/join.sh", "factory/bin/lib/probe.sh",
   "docs/adr/0005-run-loop-cli-reality.md", "tests/test_build_test.sh", "tests/test_policy.sh", "tests/test_join.sh",
   "tests/live/**", "tests/fakes/**", "tests/sim/**"],
  f"{SPEC} row TB5 (ruling Q3 of specs/factory-step2-followups-v1/RULINGS.md). main's `.adlc/config.json` has no `fleet` block, so fleet refuses every real ticket at preflight. The block itself is desk-written (`.adlc/**` is outside every ticket's scope, row TB3): the step-3 loop writes it as a desk commit, and this ticket makes CI and the node run exactly its commands.",
  "node:G10, merge:G19",
  ["main's `.adlc/config.json` carries one repo-wide `fleet` block (gate.test, gate.build, desk-written allowedCommands, prosecuteFailOn, timeoutMinutes; adapter, model and key stay CLI-only), every key checked against fleet 1.12.0's config reader (cited file:line).",
   "`factory/bin/build-test.sh` reads the gate commands from the base config and runs exactly those; gates.yml's build-test job calls it instead of a hard-coded `make test`.",
   "`make lint`'s shellcheck download fallback is replaced or pinned so `gate.build` runs under the build profile's no-network rule; if a node needs shellcheck installed, join.sh's probe requires it."],
  [("main's config parses for fleet: a schema check of every key against fleet 1.12.0's reader.", "`bash tests/test_policy.sh`"),
   ("CI and the node run the same command list, read from the base config.", "`bash tests/test_build_test.sh`"),
   ("The join probe requires shellcheck when gate.build needs it.", "`bash tests/test_join.sh`"),
   ("The toy ticket passes fleet's preflight on a scratch copy of main's config.", "`make live` (tests/live/test_smoke_live.sh)")],
  new=["factory/bin/build-test.sh", "tests/test_build_test.sh"])

ticket(25, "Release the claim when the PR opens, keep held PRs from being rebuilt, and add the blocked label",
  ("light", 1, "C2"), "feature", 2,
  ["factory/bin/run.sh", "factory/bin/lib/run.sh", "factory/bin/mirror.sh", "factory/bin/claim.sh", "factory/bin/janitor.sh",
   "factory/bin/heartbeat.sh", "factory/bin/summon.sh", "factory/bin/lib/lock.sh", "docs/adr/0005-run-loop-cli-reality.md",
   "tests/test_run.sh", "tests/test_mirror.sh", "tests/test_claim.sh", "tests/test_janitor.sh", "tests/test_summon.sh",
   "tests/fakes/**", "tests/sim/**"],
  f"{SPEC} row TB6. A kept lock is never heartbeated, so a PR held more than 24 h is rebuilt by a second node, and the kept lock eats a slot so the janitor kills the node's next claim.",
  "node:G3, node:G12, node:G13, node:G14, merge:G8a, merge:G8b, merge:G8c, merge:G9, intake:I2, intake:I12",
  ["When run.sh opens the PR it releases the claim lock (the PR is now the claim) and labels the Issue `in-review`.",
   "mirror.sh never labels `ready` while an open PR exists for the branch prefix `ticket/<id>/`; claim.sh skips such a ticket; the janitor leaves locks whose PR is open out of both the TTL and the slot count, and releases any lock whose Issue is closed.",
   "A new owned label `blocked` replaces `needs-desk` when the only reasons are dependency order (wave > 1 or an open parent); the digest and summoner ignore `blocked`. `Depends-on:` lines in the Issue body carry the link, `Depends-on: T21 (#2)`.",
   "run.sh checks it still owns the lock (heartbeat.sh dry run) before it pushes, else `lock-lost`; a `pr-open-failed` is retried on the next iteration from a state file, then released to the desk; the per-ticket `budget` from `adlc ticket show` overrides the weights.",
   "Ruling recorded: the forecast's serial order stands; the merge-queue hold is defense in depth, because adlc lets a child complete before its parent."],
  [("A PR held past 24 h is not rebuilt, and a held PR does not cause an over-slots release.", "`bash tests/test_janitor.sh` and `make sim`"),
   ("A dependency-only wait is `blocked`, any other reason is `needs-desk`, and the Issue body links the parent.", "`bash tests/test_mirror.sh`"),
   ("claim.sh skips a ticket with an open PR.", "`bash tests/test_claim.sh`"),
   ("lock-lost, pr-open retry and the budget override behave as described.", "`bash tests/test_run.sh`")])

ticket(26, "Build the desk gates: write the ready records, lint ticket contracts, and check the manifest chain on desk PRs",
  ("light", 1, "C6"), "feature", 2,
  ["factory/bin/desk-gates.sh", "factory/bin/ticket-check.sh", "factory/bin/mirror.sh", ".github/workflows/gates.yml",
   "factory/RULES.md", "docs/adr/0002-adlc-sharded-ticket-store.md", "Makefile",
   "tests/test_desk_gates.sh", "tests/test_ticket_check.sh", "tests/test_mirror.sh", "tests/fakes/**", "tests/sim/**"],
  f"{SPEC} row TB7. Nothing writes the `spec-lint`, `coldstart` or per-ticket `merge-forecast` records mirror.sh requires, so no Issue has ever been `ready`.",
  "intake:I1, intake:I5, intake:I6, intake:I7, intake:I10, intake:I11, intake:I14, merge:G14, merge:G20",
  ["`factory/bin/desk-gates.sh` writes the spec-lint and coldstart records for every open ticket whose record is missing or stale, with adlc 1.12.0's own record commands (measured and cited).",
   "mirror.sh drops the per-ticket merge-forecast record requirement in favor of the live forecast it already runs, unless adlc 1.12.0 has a forecast record command (cited either way).",
   "ticket-check.sh gains: the ADR-0002 header present; every scope glob resolves to at least one path or a declared new path; every edge target exists; no tier inversion (a tier-n ticket whose parent is tier > n); any forecast warning naming the ticket fails.",
   "A `desk` job in gates.yml runs on PRs touching `.adlc/**`: `make tickets`, `adlc ticket doctor`, and the manifest chain check with 0 skipped.",
   "A desk runbook in factory/RULES.md: write a child and its parent's edge in one PR and re-run the parent's coldstart. ADR-0002 is amended: ids are `T<n>`, not ULIDs; completed means merged to main (I20)."],
  [("desk-gates.sh writes the records and the mirror then labels the ticket `ready` with no record injected by hand.", "`bash tests/test_desk_gates.sh` and `make sim`"),
   ("Each new ticket-check rule fails its bad case and passes main's store.", "`bash tests/test_ticket_check.sh` and `make tickets`"),
   ("Two desk PRs that break the manifest hash chain fail the desk job.", "`make sim`"),
   ("The ADR and runbook amendments are written.", "`grep -n 'T<n>' docs/adr/0002-adlc-sharded-ticket-store.md` and `grep -n coldstart factory/RULES.md`")],
  new=["factory/bin/desk-gates.sh", "tests/test_desk_gates.sh"])

ticket(27, "Add the Depends-on hold and tier order as required CI jobs, with a trusted labeler",
  ("light", 1, "C8"), "feature", 2,
  ["factory/bin/depends-check.sh", "factory/bin/tier-order.sh", "factory/bin/labeler.sh", "factory/bin/lib/gate-context.sh",
   ".github/workflows/gates.yml", ".github/workflows/labeler.yml", "tests/test_depends_check.sh", "tests/test_tier_order.sh",
   "tests/test_labeler.sh", "tests/fakes/**", "tests/sim/**"],
  f"{SPEC} row TB8. adlc lets a child complete while its parent is open, and GitHub orders nothing by label, so the hold and the tier order live in CI.",
  "merge:G3, merge:G5, ci:G9, ci:G10, intake:I3, intake:I4, node:G8",
  ["`factory/bin/depends-check.sh` and a required `depends-on` job on pull_request and the queue path: the parents are the tickets in the base store with an edge to this ticket; pass only if every parent is completed in the base store; never read the PR body.",
   "A `tier-order` job: a tier-n ticket PR waits (exit 1 with the blocking PR numbers) while any approved, green, open ticket PR of a lower tier exists; first-done-first within a tier by the PR's first green `gates` time.",
   "A trusted labeler (a workflow on push to main and on schedule, never pull_request_target running head code) applies `tier:<n>` to open ticket PRs from the base store and writes the PR body's display lines (`Depends-on:`, tier, prosecuting adapter, `Assisted-by`). GITHUB_TOKEN events start no other workflow (GitHub docs, quoted in specs/factory-step3-v1/records/TB0.md), so re-evaluation of held PRs runs on push to main and on a schedule, with the App token when it exists."],
  [("A child before its parent is held, and released after the parent completes.", "`bash tests/test_depends_check.sh`"),
   ("A tier-1 PR waits for a tier-0 one; ties break by first green.", "`bash tests/test_tier_order.sh`"),
   ("The labeler applies tier labels and display lines from the base store only.", "`bash tests/test_labeler.sh`"),
   ("The child-before-parent and tier-jump scenarios are green.", "`make sim`")],
  new=["factory/bin/depends-check.sh", "factory/bin/tier-order.sh", "factory/bin/labeler.sh", ".github/workflows/labeler.yml",
       "tests/test_depends_check.sh", "tests/test_tier_order.sh", "tests/test_labeler.sh"])

ticket(28, "Build the queue: native merge queue when available, else a first-party serial queue, with ejection and rebase strikes",
  ("light", 1, "C8"), "feature", 2,
  ["factory/bin/enqueue.sh", "factory/bin/eject.sh", ".github/workflows/enqueue.yml", ".github/workflows/gates.yml",
   "factory/bin/run.sh", "factory/bin/lib/run.sh", "factory/bin/mirror.sh", "factory/ledger/README.md",
   "docs/adr/0007-merge-queue.md", "tests/test_enqueue.sh", "tests/test_eject.sh", "tests/test_run.sh", "tests/test_mirror.sh",
   "tests/fakes/**", "tests/sim/**"],
  f"{SPEC} row TB9. GitHub's merge queue is available only to organization-owned repos (docs quoted in specs/factory-step3-v1/records/TB0.md, `native-queue: no`), and nothing enqueues or handles an ejection.",
  "merge:G1 (as far as code can), merge:G4, merge:G7, merge:G13, ci:G19, ci:G21",
  ["`factory/bin/enqueue.sh` (run by a workflow on push to main, on check completion and on schedule, with the App token) takes the ordered list of mergeable ticket PRs (every required check green, the hold and tier jobs green, approvals per row TB10) and, by `native-queue`: yes → enqueues the head of the list through GraphQL `enqueuePullRequest`; no or unknown → runs the first-party serial queue: for the head of the list only, builds the merge onto current main in `factory-queue/pr-<N>`, runs the same gates there as the queue path, and if green fast-forwards main to it with the App (the only bypass actor), then closes the PR as merged.",
   "Ejection: a conflict or a red queue run labels the PR `autorebase`, appends an ejection record to `factory/ledger/ejections.jsonl`, and returns the ticket to `ready` with a `rebase-strike` flag; on the next claim run.sh cuts a fresh branch from main and cherry-picks the one ticket commit, and the rebase strike does not count toward `--max-strikes`.",
   "ADR-0007 records the queue design and the `native-queue` fallback."],
  [("Both queue modes merge the head of the ordered list and only it.", "`bash tests/test_enqueue.sh` and `make sim`"),
   ("A conflict ejects with the label, the record and the flag.", "`bash tests/test_eject.sh`"),
   ("The rebase strike cherry-picks the ticket commit and leaves the strike budget untouched.", "`bash tests/test_run.sh`"),
   ("ADR-0007 exists and names both modes.", "`grep -n native-queue docs/adr/0007-merge-queue.md`")],
  new=["factory/bin/enqueue.sh", "factory/bin/eject.sh", ".github/workflows/enqueue.yml", "docs/adr/0007-merge-queue.md",
       "tests/test_enqueue.sh", "tests/test_eject.sh"])

ticket(29, "Make branch protection code-checked: bare job-id contexts, owner approvals, the halt-guard, and the App's reach",
  ("light", 1, "C6"), "feature", 2,
  ["factory/bin/apply-branch-protection.sh", "factory/bin/halt-guard.sh", "factory/bin/owners-check.sh", "factory/bin/janitor.sh",
   "factory/bin/join.sh", ".github/workflows/**", "Makefile", "docs/adr/0004-halt-two-person-rule.md",
   "tests/test_halt_rules.sh", "tests/test_halt_guard.sh", "tests/test_owners_check.sh", "tests/test_janitor.sh", "tests/test_join.sh",
   "tests/fakes/**", "tests/sim/**"],
  f"{SPEC} row TB10. The required contexts `gates / <job>` never match a check run, which is named by its job id, and the kill switch cannot land through the queue. `factory/policy/branch-protection.json` is a desk file (I15): its new contents are written as a desk note in the spec's HANDOFF, and this ticket's code and tests read whatever main holds.",
  "ci:G1, ci:G11, ci:G12, ci:G13, ci:G17, ci:G18, ci:G20, ci:G22, merge:G2, merge:G6, merge:G15 (code half), merge:G17, node:G7, node:G9",
  ["The required checks are the bare job ids with `integration_id` 15368 (GitHub Actions); a test asserts the required set equals the gates.yml job ids that report on both paths (I18); tests/test_halt_rules.sh:94 is fixed. Merge-queue settings only when `native-queue: yes`; otherwise the first-party queue's check is required and only the App may merge directly.",
   "0 required approvals globally, code-owner review required, and a first-party `owners` job requiring two distinct CODEOWNERS approvals on PRs touching `factory/**`, `.adlc/**`, `.github/**`, `.claude/**`, with `require_last_push_approval`.",
   "A `halt-guard` job and `halt.yml` per ADR-0004 option C: adding `factory/HALT` needs zero approvals (a dispatch or label the App commits directly, never through the queue) and sets `factory:halt`; removing it needs two approvals; HALT PRs are the `halt` class and skip ticket gates.",
   "The App's private key lives in a GitHub environment restricted to `main`; the post-merge, mirror, janitor, enqueue, revoke and halt workflows say `environment:`.",
   "janitor.sh treats a missing `nodes` branch as empty; apply-branch-protection.sh gains `--bootstrap` (creates `nodes` and `flaky-history`).",
   "join.sh asks for Contents, Issues and Pull requests write plus Metadata, and the node env exports `GH_TOKEN` from the stored token.",
   "Actions pinned by commit sha with the tag in a comment; CI installs a pinned actionlint so `make lint` never silently skips it."],
  [("The required-check set equals the job ids that run on both paths.", "`bash tests/test_halt_rules.sh`"),
   ("A HALT add passes with zero approvals and a HALT removal fails with one.", "`bash tests/test_halt_guard.sh` and `make sim`"),
   ("owners-check counts distinct CODEOWNERS approvals after the last push.", "`bash tests/test_owners_check.sh`"),
   ("janitor exits 0 with a missing nodes branch; join exports GH_TOKEN.", "`bash tests/test_janitor.sh` and `bash tests/test_join.sh`")],
  new=["factory/bin/halt-guard.sh", "factory/bin/owners-check.sh", ".github/workflows/halt.yml", "tests/test_halt_guard.sh",
       "tests/test_owners_check.sh"])

ticket(30, "Add the remaining CI gates: the attest note and its verifier, the quarantine expiry, and skills-scan's status",
  ("light", 1, "C6"), "feature", 2,
  ["factory/bin/attest-verify.sh", "factory/bin/lib/attest.sh", "factory/bin/flaky-check.sh", "factory/bin/skills-scan.sh",
   "factory/bin/run.sh", "factory/bin/lib/run.sh", "factory/bin/join.sh", ".github/workflows/gates.yml",
   ".github/workflows/skills-janitor.yml", "docs/adr/0007-merge-queue.md", "tests/test_attest.sh", "tests/test_flaky_check.sh",
   "tests/test_run.sh", "tests/test_join.sh", "tests/fakes/**", "tests/sim/**"],
  f"{SPEC} row TB11, by what specs/factory-step3-v1/records/TB0.md §(c) measured: corvidlabs/attest 1.0.0 ships a linux binary (MIT); ubs's license rider excludes Anthropic and anyone acting for it, so no bugscan job is added; flaky-test-detective has no pinned release, so its classifier is step 4.",
  "ci:G6 (attest-verify stub), ci:G14, ci:G15, ci:G16, node:G6, merge:G18",
  ["The node writes the gate manifest (tests run, result hashes, adapter, verdicts) as a git note under `refs/notes/factory-attest` on the ticket commit and pushes it with the branch, unsigned under the store's `unsigned-fallback`; `attest-verify.sh` recomputes what it can (rails, scope, tamper verdicts, gate command list) and fails on a mismatch or a missing note. Use the pinned attest CLI if it fits the note format, citing it; otherwise ADR-0007 documents the first-party format.",
   "No `bugscan` job (ubs is not license-compatible; the spec's HANDOFF carries the question).",
   "A `flaky` job fails on an expired entry in `factory/policy/quarantine.json` (a desk file; this ticket writes the reader and a desk note).",
   "skills-scan: a real body with merge_group and required, or left unrequired with the reason; never a required stub.",
   "No w:heavy job is required until a self-hosted factory-node runner exists; the gates.yml header comment says so."],
  [("A missing or mismatched attest note fails attest-verify and a matching one passes.", "`bash tests/test_attest.sh`"),
   ("An expired quarantine entry fails the flaky job.", "`bash tests/test_flaky_check.sh`"),
   ("The node writes and pushes the note with the branch.", "`bash tests/test_run.sh` and `make sim`")],
  new=["factory/bin/lib/attest.sh", "factory/bin/flaky-check.sh", "tests/test_attest.sh", "tests/test_flaky_check.sh"])

ticket(31, "Turn the whole simulated walk green, run the live smoke to pr-ready, and close out factory-step3-v1",
  ("heavy", 2, "C8"), "test", 1,
  ["tests/sim/**", "tests/live/**", "tests/fixtures/make-repo.sh", "README.md"],
  f"{SPEC} row TB12. The close-out: every stage of the simulated walk passes, and the real tools carry the toy ticket on the dev box to a pushed branch on a local bare origin.",
  "",
  ["tests/sim/EXPECTED.md is `pass` on every stage of the T-sim scenario, and every failure scenario fails for its own reason (each red line names the gate that stopped it); a stage that needs GitHub itself is `kit: <line>` with the reason, never `pass`.",
   "`FACTORY_SMOKE_KEEP=$HOME/.cache/factory-smoke-evidence make live`: the toy ticket runs through fleet, tamperguard under the rendered policy, the real scope-check and rails-proof, the one trailered commit and the attest note, and ends at `pr-ready`, pushed to a local bare origin with the PR body written to the evidence dir.",
   "README build-order row 3 updated."],
  [("Every T-sim stage passes and every failure scenario names its gate.", "`make sim`"),
   ("The live smoke ends at pr-ready with each verdict recorded.", "`FACTORY_SMOKE_KEEP=$HOME/.cache/factory-smoke-evidence make live`"),
   ("README's build-order row 3 is marked built.", "`grep -n '^| 3' README.md`")],
  out="Pushing to GitHub or opening a real PR (the first live run is Aaron's kit).")

for t in T:
    with open(os.path.join(HERE, t["id"] + ".json"), "w") as f:
        json.dump(t, f, indent=2); f.write("\n")
print(" ".join(t["id"] for t in T))
