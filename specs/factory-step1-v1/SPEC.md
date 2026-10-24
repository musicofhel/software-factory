# SPEC — factory-step1-v1: build order step 1 of the Distributed Software Factory (clock + janitor, claim protocol, kill switch) plus the mirror bridge and the chassis ADR

**Status: ACTIVE v0.1, 2026-10-24 (launched without ratification per Aaron's 2026-09-30 rule). Project:
`~/software-factory`, a fresh mono repo scaffolded this day from `docs/spec/SPEC-v0.2.txt` (Aaron's PDF, v0.2
final, 2026-10-24). This loop is the bootstrap builder: the factory cannot yet build itself (no run loop, no
nodes, no remote), so the first foundation tickets are built here, on Aaron's box, under the same trailers the
factory will later enforce.**

Aaron's words (chat, 2026-10-24): *"Looking at starting this project to get it built as a mono repo I can pass
to all my friends."* The deliverable is the repo. Step 1 is the spec's own build order: *"Clock and janitor,
claim protocol, kill switch. Nothing else is safe without TTLs and a stop."*

**What this spec is not.** It is not the join wizard, the run loop, vetto/Ralon/dcg/cux integration (step 2),
nor the CI gate bodies beyond build-test (step 3). It never creates the GitHub remote, never pushes, never
registers a runner: those are Aaron's, prepped to one click in the close-out row.

---

## 0. The register at the scaffold commit (2026-10-24; TB0 re-measures every line)

| key | value | reading |
|---|---|---|
| ADLC | `@adlc/cli` **1.12.0** via `npx -y @adlc/cli@1.12.0` (never a floating version) | sharded store `.adlc/tickets/` (ADR-0002); `fleet`, `coldstart`, `merge-forecast`, `spec-lint`, `gate-manifest` all present |
| tickets | **T1–T5** in the store, `adlc ticket doctor` all ok; edges T1→T3, T1→T4, T2→T4 | each body carries the ADR-0002 header (`weight:`, `tier:`, `charter:`) |
| tests | `make test` PASS (tests/test_layout.sh only); `make lint` = shellcheck via `uvx --from shellcheck-py` (not installed system-wide), actionlint absent | every `factory/bin/*.sh` is a stub that **exits 2** ("not built"); a stub never reads green |
| workflows | gates, janitor (hourly, concurrency `janitor`, DRY_RUN default true), mirror, digest, summoner, post-merge, skills-janitor | bodies call the stubs; they are red by construction until the rows below land |
| policy | `prosecution.json` (fail-on medium, quorum 2, loop 3), `budget.json` (TTLs: heartbeat 60 min, stale 24 h, no-PR release 48 h, branch delete 7 d; node stale 24 h, retire 7 d; cap 0.4), `quarantine.json` (empty), `branch-protection.json` (rules as code) | vetto/ralon/dcg configs deliberately absent (step 2, written against the pinned versions' docs) |
| tool shelf verified 2026-10-24 | adlc, adversarial-review, ACFS, action-lock (archived; pattern only), attest, dcg, cux, agent-permissions, agent-role-contracts, flaky-test-detective, ubs, aislop, bomdrift, Sauron, edgeverdict, autorebase, adrs, slb, ru, skills-janitor, cass; crates vetto 0.6.5 / ralon 0.1.7 / vallum 0.8.16 / momus-diff 0.9.3; PyPI tamperguard 0.2.0 / tampercheck 0.1.1 / qikly / unasked / cauterule / stalebrain / agentslint / perla / notari; **dsr = `Dicklesworthstone/doodlestein_self_releaser`** (the spec's short name does not resolve) | `bwrap` is MISSING on this box, `unshare` present; fleet's Linux backend needs one of them, so TB0 proves which |
| box | 28 CPU, 47 GB RAM, WSL2, Node 22.22.0 via nvm, `gh` 2.45 authenticated as musicofhel, no remote on the repo | `codex`/`gemini`/`opencode` absent: claude-code is the only adapter here |

---

## 1. Invariants (hard; a row that breaks one is red)

- **I1 No remote, ever, from this loop.** No `git remote add`, no `git push`, no `gh repo create`, no runner
  registration, no secret creation. Read-only `gh api` calls against public repos are allowed for
  documentation lookups. The first push is Aaron's (TB5 preps it).
- **I2 Factory code is bash 4+ with `jq`, `git`, `gh`, and Node 18+ only through `npx -y @adlc/cli@1.12.0`.**
  No Python on the node path (tests may use `python3` only when present, guarded). Every script:
  `set -euo pipefail`, `--dry-run` default on writers, `--json` on readers, exit 0/1/2, shellcheck `-S warning`
  clean (`make lint`).
- **I3 Tests run offline with no keys.** `make test` is the gate for every row. Network-dependent proofs are
  close-out proofs with a due date (TB5), never unit tests. A fake `gh` under `tests/fakes/` that records
  every call and emulates the GitHub API semantics the scripts rely on (422 on existing ref, force-update,
  delete) is the instrument; its behaviour is itself tested.
- **I4 No false green.** A stub exits 2. A row is checked only when its test cases pass inside `make test`
  and the stub is gone. A test that cannot prove its claim offline says so in the records and in the test
  name (`_closeout`).
- **I5 Commit trailers on every commit:** `git commit -s` (DCO, `Signed-off-by: musicofhel
  <wobblyagent@gmail.com>`), `Assisted-by: claude-code@<claude --version>`, `Ticket: <id>` (T1–T5 or
  `scaffold`), `Node: dev-box`. These are the trailers the factory's own commit-check will enforce; building
  the enforcer with commits that would fail it is a false start.
- **I6 One row = at least one commit; the tree is clean at the end of every session.** Never check a row with
  uncommitted work.
- **I7 The spec PDF/text and ADR-0001/0002 are the design.** A deviation is a new ADR in `docs/adr/`, never a
  silent change. Fields, labels, ref names and TTLs come from the spec and `factory/policy/budget.json`.
- **I8 Never touch another window's loops** (`rb-spec-*` units are running on this box for reserve-ledger;
  do not stop, inspect or wait on them).
- **I9 No wall-clock waits in any DoD.** Live proofs are "if it happened by then, else due at <event>".

---

## 2. Rows (tracer bullets, in order; cap = 8 × 6 = 48 iterations)

### TB0 — Register: measure the scaffold, prove the toolchain, fix what the scaffold got wrong
DoD: `records/TB0.md` holds the outputs of `make test`, `make lint`, `adlc ticket doctor`, `adlc ticket list
--json`, `adlc coldstart --all --offline --json` (gap list per ticket, verbatim; a gap list that is not empty
is fixed by editing the ticket body through `adlc ticket update --expect <hash> --write`, never by hand),
`adlc merge-forecast --json`, `adlc fleet run --dry-run --json` (exit code and whether the sandbox precondition
is met on this box: `bwrap` missing, `unshare` present; record the verdict), and `claude --version`. Every
scaffold defect found (a wrong path, a workflow that cannot parse, a test that cannot run) is fixed and
committed with `Ticket: scaffold`. Commit.

### TB1 — Claim protocol (ticket T1)
DoD: `factory/bin/claim.sh`, `heartbeat.sh`, `release.sh`, `factory/bin/lib/` helpers, `tests/fakes/gh`
(records calls to `$FAKE_GH_LOG`, emulates `api -X POST repos/{r}/git/refs` → 422 when the ref exists in the
fake's ref table, `PATCH` with `force`, `DELETE`, `issue list --label --json`, `issue edit`, `issue comment`),
`tests/test_claim.sh` with the five named cases of T1's acceptance criteria plus `fake-gh-semantics` (the fake
itself: 422 on duplicate, force-update changes sha, delete removes). `make test` and `make lint` green. The
T1 stubs are gone. Commit with `Ticket: T1`. `records/TB1.md` = the test run output.

### TB2 — Kill switch (ticket T2)
DoD: `halt-check.sh` (reads `origin/main` via `git ls-tree` after `git fetch origin main`, exit 0 absent / 3
present, prints the sleep minutes from budget.json), `apply-branch-protection.sh` (dry-run default; prints
every `gh api` call from `factory/policy/branch-protection.json` including the rulesets; `--apply` executes;
idempotent), `summon.sh` (three kinds, one webhook POST, exit 2 otherwise; fake `curl` captures the payload),
`tests/test_halt.sh` + `tests/test_summon.sh` with T2's named cases against a local bare origin built in the
test. `make test`/`make lint` green, stubs gone. Commit `Ticket: T2`. `records/TB2.md`.

### TB3 — Clock and janitor (ticket T3)
DoD: `tests/fixtures/make-repo.sh` builds a local bare origin with `main`, `nodes` (manifests of chosen
`last_seen`), `flaky-history`, lock refs of chosen commit ages (`GIT_COMMITTER_DATE`), `ticket/**` branches of
chosen ages; `factory/bin/janitor.sh` implements the six duties with `--dry-run` default printing one JSON line
per would-be action; `version-check.sh`; `tests/test_janitor.sh` with the ten named cases of T3 including
`dry-run-inert` (fixture byte-identical: compare `git for-each-ref` + `git ls-tree -r` before and after);
`tests/test_version_check.sh`. `.github/workflows/janitor.yml` reviewed against the script's flags. `make
test`/`make lint` green, stubs gone. Commit `Ticket: T3`. `records/TB3.md`.

### TB4 — Mirror and post-merge (ticket T4)
DoD: `mirror.sh` (store → Issues via the fake gh; header parse; labels `w:`, `tier:`, `ready`/`needs-desk`
from the gate record; `Depends-on:` lines from edges), `post-merge.sh` (`Ticket:` trailers since the last run
marker → `adlc ticket complete --write --authorize`; ledger append; refuses off `main` with exit 2),
`tests/test_mirror.sh` and `tests/test_post_merge.sh` with T4's named cases. `make test`/`make lint` green,
stubs gone. Commit `Ticket: T4`. `records/TB4.md`.

### TB5 — Chassis ADR (ticket T5) and close-out
DoD part A: read the five candidates (read-only fetches of public repos are allowed), amend
`docs/adr/0003-chassis.md` to `accepted` meeting T5's three criteria (grep counts recorded). Commit `Ticket: T5`.
DoD part B (close-out): full `make test` + `make lint` green; `adlc coldstart --all --offline --json` gap list
empty for T1–T5 (or each remaining gap named with its reason); `adlc fleet run --dry-run` exit 0; README
build-order table row 1 → "built locally, awaiting first push"; `records/TB5.md`. HANDOFF.md ends with
**"Aaron's kit"**: the exact commands, in order, for the first push, each one line, none run here:
`gh repo create musicofhel/software-factory --public --source . --push`; `./factory/bin/apply-branch-protection.sh
--apply`; the two secrets (`SUMMONER_WEBHOOK`, `DIGEST_WEBHOOK`) and one variable (`JANITOR_DRY_RUN=true`);
the `nodes` and `flaky-history` branch creation; the self-hosted runner registration (label `factory-node`,
repo-scoped runner group); and the live proofs due **at first push**: the real `POST git/refs` 422 CAS, the
janitor's first dry run, the mirror's first Issue. Any Q for Aaron in the TB_PROMPT's `### Q<n>` shape
(license confirmation is Q1 if nothing else: MIT is proposed in PROJECT.md).

---

## 3. Records and evidence

`specs/factory-step1-v1/records/TB<n>.md`: the commands run and their output, verbatim where short, with
exit codes. Every measured claim in a record names the command that produced it so a reader can re-run it.

## 4. Out of scope (named so nobody drifts into it)

Join wizard, run loop, vetto/Ralon/dcg/cux (step 2). Rails proof, scope, tamper, attest, commit-check bodies
(step 3; their stubs stay exit 2). Prosecution, verifier, digest body, drills (step 4). Preview, behavior-diff,
release/dsr (step 5). Distill, calibration, dashboard (step 6). Anything requiring a GitHub remote.
