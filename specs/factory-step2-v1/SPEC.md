# SPEC — factory-step2-v1: build order step 2 of the Distributed Software Factory (join wizard and run loop with vetto, Ralon, dcg, cux) plus the step-1 rulings that land in code

**Status: ACTIVE v0.1, 2026-10-25 (launched without ratification per Aaron's 2026-09-30 rule). Project:
`~/software-factory`. Step 1 (`specs/factory-step1-v1`) is DONE and pushed; post-merge completed T1–T5 on
GitHub. Aaron ruled the nine step-1 calls on 2026-10-25 (`specs/factory-step1-v1/RULINGS.md`, all
recommendations): the chassis is **fleet** (ADR-0003 accepted), so this step codes against fleet.**

The spec's build order, step 2: *"Join wizard and run loop with vetto, Ralon, dcg, cux."* At the end of this
step a friend can clone the repo, run `/factory:join`, and get a node whose `/factory:run` claims a ticket,
builds it inside the sandbox and rails lock, and pushes a ticket branch. CI gate bodies (step 3) stay stubs.

**The design is `docs/spec/SPEC-v0.2.txt`:** Join wizard and Manifest (L295–345), Run loop (L349–405),
Freeze (L541–551), Enforced on the node (L816–823), Budget governor (L899–912). ADR-0003 (fleet, `bwrap`
required) and ADR-0002 (sharded ticket store) bind. A deviation is a new ADR, never a silent change.

---

## 0. The register (2026-10-25 03:10Z, measured by the launching session; TB0 re-measures every line)

| key | value | reading |
|---|---|---|
| repo | `origin/main` = `44ed6dd` (post-merge: complete T3); local = origin; `make test` 9 files PASS, `make lint` exit 0 | step 1 complete; T1–T5 completed in the store by post-merge on GitHub |
| GitHub | public, user-owned; `nodes` and `flaky-history` branches **do not exist** (Aaron's kit), so the hourly janitor is red (`couldn't find remote ref refs/heads/nodes`); no secrets set; no branch protection; Issue #1 (T3) | none of this is the loop's to change (I1) |
| sandbox | **`bwrap` 0.9.0 installed 2026-10-25** (`sudo apt-get install bubblewrap`, by the launching session); `bwrap --unshare-all true` runs; `unshare` present; LSM list includes landlock | ADR-0003's node precondition is now met on this box; TB0 re-runs `adlc fleet run --dry-run --json` to prove fleet agrees |
| pinned tools (registry, read 2026-10-25) | crates `vetto` **0.6.5**, `ralon` **0.1.7** (both = max stable); PyPI `tamperguard` **0.2.0**; `dcg` latest release **v0.15.3** (`Dicklesworthstone/destructive_command_guard`); `cux` = `inulute/cux` (Go, not archived, version not yet pinned); `@adlc/cli` **1.12.0** | **none of vetto, ralon, dcg, cux, tamperguard is installed**; `cargo`/`rustc` present in `~/.cargo`; `uv` present |
| adapters on this box | `claude` (claude-code) only; `codex`, `agy`, `opencode` absent | the live smoke uses claude-code |
| rulings that land here | Q4 retire = remove collaborator; Q5 `factory/policy/adapters.json` created here; Q6 post-merge pushes on a GitHub App token as ruleset bypass actor (the App itself is Aaron's) | TB1, TB5 |
| step-1 follow-ups (`records/TB5.md` of step 1) | (1) janitor ready-duty compares ids incl. completed tickets; (2) post-merge's commit carries no I5 trailers; (5) fine-grained PAT branch scoping unmeasured; (6) wizard must probe `bwrap` | TB5, TB2 |

---

## 1. Invariants (hard; a row that breaks one is red)

- **I1 This loop never writes to GitHub.** No `git push` to `origin`, no token creation, no runner
  registration, no secret/variable/label/Issue writes, no branch protection. Read-only `gh api` calls and
  read-only fetches of public repos, crates.io, PyPI and docs are allowed. The launching session pushes.
  Every live proof that needs GitHub runs against a **local bare origin** built by
  `tests/fixtures/make-repo.sh`, or goes into the close-out's "due at first join" list.
- **I2 Installs are user-space and pinned.** `cargo install --locked <crate>@<exact>` into `~/.cargo`,
  `uv tool install <pkg>==<exact>`, release binaries into `~/.local/bin` verified against the release's
  published checksum when one exists. **No `sudo`** (bwrap is already installed). Never a floating version.
  Every install the loop does on this box is a step the wizard itself performs, recorded with its exact
  command.
- **I3 Factory code is bash 4+ with `jq`, `git`, `gh`;** Node only via `npx -y @adlc/cli@1.12.0`; the pinned
  tools are called as CLIs. `set -euo pipefail`, `--dry-run` default on writers, `--json` on readers,
  exit 0/1/2 (3 = halted, as `halt-check.sh`), shellcheck `-S warning` clean.
- **I4 `make test` stays offline, keyless and tool-free.** Every pinned tool has a fake under `tests/fakes/`
  whose behaviour is itself tested. Tests that need the real tools live in `tests/live/` behind
  `make live`, print `SKIP <reason>` and exit 0 only when a tool is absent, and their output is pasted
  into the row's records. A live test never runs in `make test`.
- **I5 No false green.** A stub exits 2. A row is checked only when its cases pass in `make test` (and
  `make live` where the DoD names it) and its stubs are gone.
- **I6 Commit trailers on every commit**, ONE final trailer paragraph: `Assisted-by: claude-code@<claude
  --version>`, `Ticket: <T6–T11 | scaffold>`, `Node: dev-box`, then `git commit -s`. Check with
  `git log -1 --format='%(trailers:key=Ticket,valueonly)'` before ending the session (step 1's T3 lost its
  trailer this way).
- **I7 The real CLI is the truth.** Before coding against vetto, ralon, dcg, cux, tamperguard or fleet,
  read the pinned version's `--help` and README/docs and record the flags used. Where the real CLI differs
  from SPEC-v0.2's run-loop sketch (for example a fleet flag that does not exist at 1.12.0), code to the
  real CLI and write the difference into a new ADR. Never invent a flag.
- **I8 Transcripts never leave the node.** Ledger lines, PR bodies, Issue comments and manifests carry
  gate-manifest hashes, reason codes, strike counts, adapter names and token counts only. A test greps
  every outbound payload the run loop builds for prompt or file text.
- **I9 Never touch another window's loops** (`rb-spec-*` units; do not stop, inspect or wait on them).
- **I10 No wall-clock waits in any DoD.** Live proofs are "if it happened by then, else due at <event>".
- **I11 One row = at least one commit; the tree is clean at the end of every session. Never `git commit --amend` and never rewrite history:** the launching session pushes between iterations, so an amend forks local from origin (it happened at the end of step 1). Fix a commit with a new commit.

---

## 2. Rows (tracer bullets, in order; cap = 8 × 7 = 56 iterations)

### TB0 — Register, tickets T6–T11, and the pinned tools on this box
DoD: (a) `records/TB0.md` re-measures every register line with its command. (b) Install the pinned tools
in user space per I2 and record each `--version` and the `--help` of every subcommand the later rows use:
vetto 0.6.5, ralon 0.1.7, tamperguard 0.2.0, dcg v0.15.3, cux (pin the latest release tag that exists,
by tag and commit sha). `adlc fleet run --help` at 1.12.0 verbatim. (c) `adlc fleet run --dry-run --json`
on this box now that `bwrap` exists: exit code and the sandbox verdict. (d) A table "SPEC-v0.2 run-loop
sketch vs the real CLIs": every flag in L362–379 marked EXISTS / DIFFERENT (with the real spelling) /
MISSING; anything not EXISTS goes into `docs/adr/0005-run-loop-cli-reality.md` (proposed). (e) Create
tickets T6–T11 in the ADLC store through `adlc ticket create … --write` with the ADR-0002 header block
(`weight:`, `tier:`, `charter:`), acceptance criteria that each name a verification method, scope globs,
and edges T6→T7, T6→T9, T8→T9, T7→T11, T9→T11, T10→T11; `adlc ticket doctor` ok; `adlc coldstart --all
--offline --json` gap list empty for T6–T11 (fix gaps via `adlc ticket update --expect <hash> --write`).
Commit `Ticket: scaffold`.

### TB1 — Node policy: sandbox profiles, rails lock, destructive-command hook, adapter pins (ticket T6)
DoD: `factory/policy/build.toml` (deny all network; writes only to the worktree and the dependency cache)
and `factory/policy/agent.toml` (egress only to the adapter's API domain) written against vetto 0.6.5's
documented profile format; `factory/bin/lib/ralon-lock.sh` renders `.ralon/<id>.lock` from the ticket's
`rails` globs; `factory/policy/dcg.toml` (or the format dcg v0.15.3 documents) for the shell hook;
`factory/policy/adapters.json` (ruling Q5) pinning claude-code to the version on this box and every other
fleet adapter to `null` (= not pinned yet, refuse to claim with it); `version-check.sh` reads it (its
`pins_source` is no longer null). Tests: `make test` covers the lock renderer and adapters.json schema;
`make live` proves on this box, with output in records: build.toml denies `curl https://example.com`,
allows a write inside the worktree, denies a write outside it; agent.toml allows the adapter domain and
denies another; ralon denies a write to a rail path and allows a non-rail path; vetto refuses to start
with a malformed profile (fail-closed). Commit `Ticket: T6`. `records/TB1.md`.

### TB2 — Join wizard (ticket T7)
DoD: `factory/bin/join.sh` and `factory/skills/join/SKILL.md` updated from contract to built. Steps
exactly as SPEC-v0.2 L298–315 with these hard edges: probe (nproc, RAM total/free, disk, OS incl. WSL2
detection, adapters installed + authenticated, **`bwrap` on Linux / `sandbox-exec` on macOS required,
else refuse with the install line**); `slots = min(8, floor(free_ram_gb/2) − 1)` and refuse when < 1;
`heavy_gates` from a timed dry run of `make test` against the ticket timeout in `budget.json`; refuse when
`--dangerously-skip-permissions` is aliased or set in any shell rc or Claude settings it can read;
install plan pinned from `factory/policy/adapters.json` + the TB0 pins (dry-run prints every command;
`--apply` runs them, user space only); register step **prints** the fine-grained token instructions
(repo, the three ref patterns, 90-day expiry) and the runner command, and stores a provided token at
`~/.factory/token` mode 0600 — it never creates either; manifest built and validated against
`factory/nodes/manifest.schema.json`; commit to `nodes` and CAS-push (against the fixture origin in tests).
Writes nowhere outside the clone and `~/.factory/` (a test diffs `$HOME` before/after with a temp HOME).
Tests with fakes cover every refusal and the slots formula boundaries. `make live`: the wizard in
`--dry-run` on this box, output in records. Commit `Ticket: T7`. `records/TB2.md`.

### TB3 — Budget governor (ticket T8)
DoD: `factory/bin/governor.sh --json` composes, in the spec's order, version_check, heartbeat (hourly at
most; skips when `last_seen` < 60 min), kill_switch_check (`halt-check.sh`), quiet_hours_check (manifest
`quiet_hours` in its tz, wraps midnight), quota_check (`cux status --json` per the pinned cux's real
output; all accounts ≥ `quota_cap` → sleep until the earliest reset). Output: one JSON line `{action:
claim|sleep|refuse, reason, sleep_seconds}`. Tests with a fake `cux` and a fake clock (`FACTORY_NOW`) cover
each reason, the midnight wrap, DST boundary in a non-UTC tz, and a malformed cux payload (fail closed =
sleep, never claim). Commit `Ticket: T8`. `records/TB3.md`.

### TB4 — Run loop and /factory:run (ticket T9)
DoD: `factory/bin/run.sh --slot N` (one loop per slot, a shell script not an agent) and
`factory/skills/run/SKILL.md` built. Each iteration: governor → claim (step-1 `claim.sh`) → fetch →
worktree (resume from a lapsed `ticket/<id>/*` branch and append its dead-end material, else from
`origin/main`) → `ralon … -- vetto … -- fleet run …` with the real flags from TB0/ADR-0005 → `case reason`
on **fleet's closed reason set** (ADR-0003 link) exactly as SPEC-v0.2 L380–389: merged → tamperguard +
`scope-check` locally (scope-check stays a step-3 stub: the loop records "scope-check not built" and does
not push when it exits 2 — no false green), push `ticket/<id>/<handle>`, open PR, comment; quota-paused |
wall-clock → keep + heartbeat lock, push partial, sleep, resume; strikes-exhausted | flail → push, label
needs-desk, delete lock; review-unavailable → delete lock, sleep 30m; anything else → delete lock, comment
reason → worktree remove. A fake `fleet` emits each reason; fakes for ralon/vetto record their argv. Tests
cover every branch, the resume path, I8 (no prompt/file text in any outbound payload), and that a
`--once` flag runs exactly one iteration. Commit `Ticket: T9`. `records/TB4.md`.

### TB5 — Step-1 rulings and follow-ups in code (ticket T10)
DoD: (Q4) `factory/bin/revoke-collaborator.sh <handle> <owner>` (dry-run default; `--apply` runs `gh api
-X DELETE repos/{repo}/collaborators/{owner}`; refuses to remove a CODEOWNERS owner) and janitor.yml wires
it as `JANITOR_REVOKE_HOOK`. (Q6) post-merge.yml mints a token with `actions/create-github-app-token`
pinned by commit sha when `vars.FACTORY_APP_ID` is set and `secrets.FACTORY_APP_KEY` exists, else falls
back to `GITHUB_TOKEN` with a step-summary line saying so; `apply-branch-protection.sh` gains the App as a
ruleset bypass actor when `FACTORY_APP_ID` is given (dry-run prints it). Follow-up 2: post-merge's commit
carries trailers (`Ticket: post-merge`, `Node: github-actions`, `Assisted-by: none`) — record the
commit-check exemption need for step 3 in `factory/RULES.md`. Follow-up 1: janitor's ready-duty compares
open ticket ids only. Tests for each; actionlint clean. Commit `Ticket: T10`. `records/TB5.md`.

### TB6 — Live smoke on this box and close-out (ticket T11)
DoD part A (live, against a local bare origin built by the fixture — never GitHub): run `join.sh --apply`
with a temp `FACTORY_HOME` and the fixture origin, then `run.sh --slot 1 --once` on a toy ticket T-smoke
created in the fixture's store ("add `hello.sh` that prints hello, with a test"), with the claude-code
adapter, **real** vetto + ralon + fleet, wall clock ≤ 15 min, strikes ≤ 2. Record: the governor line, the
claim ref in the fixture, the fleet reason, the pushed `ticket/T-smoke/dev-box` branch in the fixture, the
ledger line, token count. A reason other than merged is still a pass for this row if every branch the loop
took was the specced one and the cause is named; a sandbox that ran open is a fail. DoD part B
(close-out): `make test` + `make lint` + `make live` green; coldstart gaps empty T6–T11; README build-order
row 2 → "built locally, awaiting first join"; `records/TB6.md`; HANDOFF ends with **"Aaron's kit"** (one
line each, none run): create the GitHub App (permissions: contents write, pull requests write, issues
write; install on this repo) and set `FACTORY_APP_ID` + `FACTORY_APP_KEY`; the step-1 kit lines still
open; the real `join.sh --apply` on dev-box; and the live proofs **due at first join** (fine-grained PAT
ref scoping, real 422 CAS on GitHub, first heartbeat on `nodes`). Any Q for Aaron in the TB_PROMPT
`### Q<n>` shape. Commit `Ticket: T11`.

---

## 3. Records and evidence

`specs/factory-step2-v1/records/TB<n>.md`: commands and output (verbatim where short) with exit codes;
every measured claim names the command that produced it so a reader can re-run it.

## 4. Out of scope (named so nobody drifts into it)

CI gate bodies, merge queue, `Depends-on:` hold, halt-guard check (step 3). Rail author charter,
prosecution, verifier, digest body (step 4). Preview, behavior diff, release (step 5). Distill,
calibration, dashboard (step 6). Anything that writes to GitHub (I1). Moving the repo to an organization.
