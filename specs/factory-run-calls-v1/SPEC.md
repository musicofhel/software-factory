# SPEC — factory-run-calls-v1: the loop's tamperguard step under a per-run policy, a default rail, and a run to `scope-check-not-built`

**Status: ACTIVE v0.1, 2026-10-25 (launched without ratification per Aaron's 2026-09-30 rule). Project:
`~/software-factory`. `specs/factory-step2-followups-v1` is DONE and pushed (post-merge completed
T12–T16). Its live smoke built the toy ticket end to end inside fleet's sandbox, then the loop stopped
fail-closed at `tamperguard-error` (`specs/factory-step2-followups-v1/records/TB5.md` §4.3). Aaron ruled
the four run calls on 2026-10-25 (`specs/factory-step2-followups-v1/RULINGS.md`, all recommendations).
The rails-guard upstream issue is filed: https://github.com/voodootikigod/adlc/issues/1272.**

Goal: the dev-box smoke runs the toy ticket through fleet, tamperguard under vetto, and stops at
`scope-check-not-built` (scope-check is step 3), with every new ticket carrying a rail and a check that
refuses one without.

**Invariants: I1–I13 of `specs/factory-step2-followups-v1/SPEC.md` apply verbatim** (I1–I11 from
`specs/factory-step2-v1/SPEC.md` §1: never write to GitHub; user-space pinned installs, no sudo; bash +
jq + git + gh; `make test` offline and tool-free, real tools in `make live`; no false green; one trailer
paragraph with `Ticket:`; the real CLI is the truth; transcripts never leave the node; never touch
`rb-spec-*`; no wall-clock waits in a DoD; never `git commit --amend`; I12–I13 the bwrap shim). Plus:

- **I14 The rendered policy only adds read roots.** The per-claim copy of `factory/policy/build.toml`
  differs from the template only by extra absolute `allow_read` entries, each an existing directory the
  step needs (the clone's git dir, FACTORY_HOME's tool and interpreter dirs). It never adds a write
  root, never changes `[network]`, and never reads `$HOME` wholesale. A test diffs template and render.
- **I15 `factory/policy/**` is not edited by a ticket.** It is every ticket's rail (ruling Q2) and
  ralon-lock's protected glob. A change the template's comments need is written as a desk note in
  HANDOFF, not committed.

---

## 0. The register (2026-10-25 ~20:40Z, measured by the launching session; TB0 re-measures)

| key | value |
|---|---|
| repo | `origin/main` = `139a06b` (mirror + janitor use the empty forecast when no ticket is open); `make test` 15 files PASS, `make lint` 0 |
| store | T1–T16 all completed; every ticket has `rails: []` or none |
| tamperguard step | `factory/bin/run.sh` ~L353–376, `on_success`; under `vetto --profile strict --policy factory/policy/build.toml`; stderr goes to `.factory-run/tamperguard.err` and is not kept (records/TB5.md §6.2) |
| the fix by hand | `~/.cache/tb5/diag3/build-exp.toml` (`allow_read` += `$FH/bin`, `$FH/uv`, `~/.local/share/uv/python`, `$CLONE/.git`) → rc 0, `{"verdict":"ok","score":0,"findings":0}` |
| not measured | whether uv's python dir is readable under the real `$HOME` (not the smoke's scratch HOME) |
| rails | fleet's gate runs `adlc rails-guard --base <start> --ticket <id>`; exits 1 on no rails (`@adlc/rails-guard/lib/rails.mjs` `resolveRailGlobs`); the smoke's T-smoke declares `factory/policy/**` |
| fleet | `@adlc/cli` 1.12.0 still newest; #1266 and #1272 open |

---

## 1. Rows (tracer bullets, in order; cap = 8 × 4 = 32 iterations)

### TB0 — Register and tickets T17–T19
DoD: `records/TB0.md` re-measures every register line with its command (issues by read-only `gh issue
view`). If a fleet past 1.12.0 has shipped, record it and change nothing else (re-pinning is not this
spec's). Create T17 (per-run policy), T18 (rail convention + check), T19 (smoke + close-out) through
`adlc ticket create … --write` with the ADR-0002 header block, verification-method acceptance criteria,
scope globs, **`rails: ["factory/policy/**"]` on each** (ruling Q2, before T18's check exists), edges
T17→T19 and T18→T19 (plus T17→T18, measured in session 1); doctor ok; coldstart gaps empty; merge-forecast exit 0. Commit `Ticket: scaffold`.
**Amended 2026-10-25 by ruling Q1 (RULINGS.md):** rails freeze the store, so write T19 first (no flag), then
T18 and T17 with `--allow-unsigned`; T18's draft scope gains `factory/bin/post-merge.sh` and
`tests/test_post_merge.sh` before it is written (re-prove the drafts in a fresh scratch clone).

### TB1 — The rendered per-run policy (ticket T17; ruling Q1)
DoD: run.sh renders, per claim, a copy of `factory/policy/build.toml` into the claim's run dir (outside
`/tmp`; see build.toml's own notes) with absolute `allow_read` roots for: the clone's common git dir
(`git rev-parse --git-common-dir`, resolved), FACTORY_HOME's `bin` and `uv` dirs, and the interpreter
dir that tamperguard's python resolves to (`readlink -f`, its install root, measured not guessed). The
tamperguard step uses the render; build.toml is the template and is not edited (I15). The render is
TOML-valid for vetto 0.6.5 (unknown keys are errors). Keep tamperguard's stderr next to its JSON in the
claim's log base (records/TB5.md §6.2). ADR-0005 gains an amendment: decision 8 now runs under the
rendered policy, with I14. `tests/test_run.sh` (fakes): the render differs from the template only by
`allow_read` entries (I14, a jq/awk diff on the parsed tables), every entry exists, no `$HOME` root,
`[network]` unchanged; a missing interpreter dir fails closed (`tamperguard-error`, never a run without
the root); stderr kept. `make live` (`tests/live/`): under the real vetto, a render for a linked worktree
gives tamperguard rc 0 and a JSON verdict under a scratch `$HOME` whose render points at the real uv tool
and python dirs (ruling Q2: vetto cannot start under this box's real `$HOME`, `~/.aws` symlink, ADR-0005
T6 item 10; record that it fails closed there and which python dir was used). Commit `Ticket: T17`. `records/TB1.md`.

### TB2 — The default rail and the check (ticket T18; ruling Q2)
DoD: the desk's ticket convention (where ADR-0002's header block and factory/RULES.md describe ticket
content) states that every ticket declares at least `factory/policy/**` in `rails`. A check refuses a
ticket whose `rails` is empty or missing: mirror.sh's ready conditions gain `rails` (no rails → no
`ready`, `needs-desk` with the reason `rails: none declared`), and the ticket checks behind `make
tickets` (or the existing desk check; cite which) fail on it. Completed tickets are never relabeled for
it (T1–T16 stay as they are). **Ruling Q1:** post-merge.sh passes `--allow-unsigned` to `adlc ticket
complete --write --authorize`, with a test (fake adlc refuses a railed store's write without it). Tests: an open ticket with `rails: []` gets `needs-desk` with the reason;
with the rail it can be `ready`; a completed ticket without rails is untouched; the fake adlc carries
`rails` through `ticket show`. Commit `Ticket: T18`. `records/TB2.md`.

### TB3 — The live run to `scope-check-not-built`, and close-out (ticket T19)
DoD part A: `FACTORY_SMOKE_KEEP=$HOME/.cache/factory-smoke-evidence make live`. Record: canary pass
(shim), fleet run id, strikes, gate, adversarial-review verdict, tamperguard verdict under the rendered
policy with its `vetto audit` session, and the loop's final branch. Pass = the loop ends
`scope-check-not-built` with every earlier step the specced one; a sandbox that ran open or a tamperguard
step that ran outside vetto is a fail. If a later stage fails for a reason in fleet or vetto itself,
name it, draft (never file) an upstream issue in records, and add a Q. DoD part B: `make test` + `make
lint` + `make live` green; coldstart gaps empty T17–T19; README build-order row 2 updated; any desk
note for build.toml's comments (I15) in HANDOFF; `records/TB3.md`; HANDOFF ends with "Aaron's kit" (the
step-2 kit lines still open, one line each, re-checked read-only) and any `### Q<n>` blocks. Commit
`Ticket: T19`.

---

## 2. Out of scope

Step 3 (CI gate bodies, merge queue, halt-guard, scope-check body, and main's `.adlc/config.json`
`fleet` block — ruling Q3 puts it there). Filing anything upstream. Any write to GitHub (I1). Editing
`factory/policy/**` (I15). Moving the repo to an organization or making it private.
