# TB7 — The desk gates: records `ready` needs, contract lint, the manifest chain (ticket T26)

Sessions 14 and 15, 2026-10-27. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2. Base: `036a114`
(TB6 + ledger). Nothing was pushed and nothing was written to GitHub, the repo's own store or
`~/.factory` (I1, I19). Real-adlc measurements ran in a clean worktree (`.spec-loop/tb7/wt`, detached
at `036a114`) and in temp worlds. No prep exists for this spec.

**State: done.** Fixes intake:I1, intake:I5, intake:I6, intake:I7, intake:I10, intake:I11, intake:I14,
merge:G14 and merge:G20. No new question for Aaron.

## 1. Measured this row (all against real @adlc/cli 1.12.0 in the npx cache)

- **spec-lint records.** `adlc spec-lint <file> --json --record --ticket <id> --dir <D>` appends a
  record only on a pass (`@adlc/spec-lint` bin/spec-lint.mjs:118-127, lib/record.mjs:28-36). Its
  `files` is `{"<file as given>": sha256}`. desk-gates runs it with cwd = a temp dir and the file
  `<id>.md`.
- **spec-lint found no criteria in any ticket.** It reads criteria only as list items under a heading
  (`#…` or a bold-only line) matching acceptance|criteria|… (lib/parse.mjs:10,113-116). The desk's
  form `Acceptance criteria:` is a plain line. desk-gates therefore lints a rendering of the body in
  which that one line becomes `## Acceptance criteria`. With that rendering T26–T31 pass, for example
  6/6 and 5/5 criteria verified. A spec-lint record counts as stale when no verified record's `files`
  holds the sha256 of the current rendering.
- **coldstart records.** `coldstart <id> --offline --json` is deterministic: body, scope, rails and
  edge targets (lib/gate.mjs:213-280). Its result is recorded through
  `coldstart <id> --prompt-only --record-verdict -` (bin/coldstart.mjs:94-113, lib/verdict.mjs:58-68)
  as the verdict `{pass, gaps, ticketHash, method: "offline"}`. The live audit
  (`--tier cheap --json`) writes its own cache entry `{ticketHash, model, gaps}` (lib/cache.mjs:85-95);
  `--coldstart live` uses it. The mirror's `coldstart_shape` reads both shapes. A coldstart record is
  stale when its ticketHash is not the ticket's.
- **Record writes need no `--allow-unsigned`** on the frozen store. Ticket writes still do.
- **merge-forecast has no record command** (`adlc merge-forecast --help` lists none). The mirror's
  per-ticket merge-forecast record requirement is dropped, and the live forecast it already ran
  still certifies wave 1 (SPEC TB7: "cite either way").
- **The manifest chain** (gate-manifest lib/record.mjs:117-131): `prev` = sha256 of the raw previous
  line, `seq` = previous + 1. Two branches that append from one main, joined, give: `gate-manifest
  verify --json` exits 2 with `{"valid": false, "message": "chain broken at seq 38 (line 39): prev
  hash mismatch", …}`; `show` still reports 0 skipped (so verify is the check that matters); `ticket
  doctor` fails `store:storehash-manifest-bind` MANIFEST_CHAIN_INVALID, exit 2.
- **merge-forecast warnings** naming a ticket: `ticket "<id>" has no scope defined` and `ticket "<id>"
  scope matches 0 files in repo` (lib/forecast.mjs:69-72). The second makes the ticket `unscoped`, and
  the forecast sequences it behind every other ticket.
- **adlc merge-forecast walks the filesystem** (lib/signals.mjs walkTree skips only node_modules and
  .git). In the main checkout it crawls the gitignored sim worlds under `.spec-loop/`, which takes
  minutes. Run real measurements in a clean worktree.
- **The archive marker.** Real `ticket doctor` refuses `.adlc/ticket-archive/.store.json` unless it
  says `{"format":"adlc-ticket-archive","version":1}` (`store:archive: unsupported ticket store
  manifest (expected format version 1)`). The sim world had seeded the directory's marker there since
  TB1. Only real adlc caught this (§3).
- `adlc ticket create --help`: "Omit it on create and the store mints a ULID (T-01K...); supply one
  only to keep an existing T<n> id." The desk always supplies one (ADR-0002 amendment T26).

## 2. What was built

- **`factory/bin/desk-gates.sh`** (new).
  - `--dry-run` (default) and `--write`: the spec-lint and coldstart records for every open ticket,
    or for each `--ticket`, whose record is missing or stale. A failing spec-lint records nothing. A
    coldstart with gaps is recorded and stays failing until the desk edits the ticket. Each ticket and
    check prints one JSON line (`check, ticket, state, action, result, reasons`). Exit 2 on any fail.
  - `--check`: the `desk` job. It passes at once when BASE...HEAD touches no `.adlc/` path.
    Otherwise it runs five checks:
    - manifest-extends: the base's bytes are the head's prefix (also for the base's `manifest.d/`
      segments);
    - manifest-verify;
    - manifest-skipped = 0;
    - doctor;
    - ticket-check.

    Then, for every open ticket the PR adds or changes (the `.id` in each ticket file it adds or
    modifies), the records must be current and passing, and CI's own re-run of spec-lint and
    coldstart --offline must agree. In CI it takes the base and head from gate-context (I16: the
    base's copy runs). Locally it takes `--base/--head`, or the merge-base with origin/main. It refuses
    a head that is not the clean checkout, because adlc reads the checkout's store.
  - **Why only the touched tickets.** Untouched open tickets are not the PR's business. A desk may
    keep a ticket unclaimable, with no records. T20–T31 are such tickets: this loop builds them, so
    no node may claim them. A check over every open ticket would have forced the first desk PR after
    T26 to make all of them `ready`.
- **`factory/bin/ticket-check.sh`** (`make tickets`) is now a contract lint, with these rules:
  - rails;
  - header (mirror.sh's reasons word for word);
  - scope: every glob matches a tracked path, or a path declared on a `New paths:` line of the
    ticket or of any ticket it waits on;
  - edges: every target exists;
  - tier: an **open** parent's tier is never higher than its child's (a completed parent orders
    nothing);
  - forecast: any warning containing `ticket "<id>"` fails.

  It uses tracked files only, because CI's `./.base` is untracked.
- **`factory/bin/mirror.sh`**: the merge-forecast record reason is gone. The header says why.
- **`.github/workflows/gates.yml`**: a `desk` job (head checkout, then the base into `.base`,
  setup-node 22, then `./.base/factory/bin/desk-gates.sh --check`). It has no `if:`, so it reports on
  pull_request and merge_group (I18). The SPEC's "`make tickets`" is `ticket-check.sh` itself: `make
  tickets` is `adlc ticket list` plus that script.
- **Docs.**
  - `factory/RULES.md` has the desk runbook: a child and its parent's edge go in one PR; run
    `desk-gates.sh --write`, which re-records the parent's coldstart; `New paths:`; at least one
    existing path in scope; redo the writes on the current main, never join manifests.
  - ADR-0002 has amendment T26: ids are `T<n>`; completed means merged to main (I20); the desk's
    records.
  - The Makefile `tickets` comment is updated.
- **`tests/fakes/adlc`**, git-store mode:
  - a hash-chained manifest;
  - `spec-lint`;
  - `gate-manifest verify`;
  - `ticket doctor` (chain and archive marker);
  - `coldstart --offline` and `--prompt-only --record-verdict`;
  - the two forecast warnings.

## 3. Tests and gates

### New and changed tests (drafted by three parallel subagents, reviewed and re-run here)

- `tests/test_desk_gates.sh` (new): 20 cases. They cover dry-run, write, stale after an edit,
  spec-lint fail, coldstart gaps, completed tickets, the --ticket filter (a repeat records once),
  argument errors, and --check. The --check cases: no .adlc path; a desk commit passes; an untouched
  ticket without records is not the PR's; an edge added to a parent makes it stale; missing, stale
  and gapped records; the chain race; a stale base; a rewritten or deleted manifest; ticket-check
  failing; doctor failing on the archive marker; the merge-base; --head not the checkout and
  uncommitted .adlc edits. Every read failure exits 1 with no line for that read.
- `tests/test_ticket_check.sh`: 13 cases (header, scope, new paths from parents, edges, tier with a
  completed parent, forecast, multiple reasons; every case runs in a git checkout).
- `tests/test_mirror.sh`: 21 cases. `gated` no longer writes a merge-forecast record. T5 and T11 are
  the new truth (no record → ready; a failing record is ignored). New `parent-edge-stale` (intake:I10)
  shows that a parent edge makes the parent stale, which is expected, and that a fresh coldstart
  restores it.
- `tests/test_gate_context.sh`: the `desk` job runs a base script, checks out head then base, and has
  no `if:`. **Scope deviation:** this file is not in T26's scope. It holds the list of base-script
  jobs, as in TB3–TB5.
- `tests/test_layout.sh`: ADR-0002's two T26 rulings, and every store id is `T<n>` (intake:I11's
  proposed test). **Scope deviation:** this file is not in T26's scope either.

The subagents found three real bugs in the draft, all fixed and covered:
- a repeated `--ticket` recorded twice;
- a recorded gap listed twice in `--check` (the reasons are now de-duplicated);
- `--check --head <sha>` read the checkout's store instead of `<sha>`, so it now refuses a head that
  is not the clean checkout.

They also flagged the tier rule refusing a child of a completed higher-tier parent (fixed).

### The sim

The walk now writes the records with `desk-gates.sh --write` in the same push as the tickets. No
record is written by hand, and `records_standin` is gone. The scenario tickets work the same way.

New stages:
- `S.desk-chain-race`: two desk branches from one main, joined → the desk job fails, `chain broken`.
- `S.desk-stale-base`: a desk PR from the seed's main → `does not extend the base`.
- `S.desk-no-records`: a ticket without records → `T-sim-nr … missing record`.
- `P/C.pr/mg.desk` (no `.adlc/` path: pass).

Flipped: `P.mirror-ready` and `S.desk-pr` → pass. EXPECTED.md: 117 = 91 pass + 26 red.

- Fake: `sim.sh --adlc fake` exits 0, equal to EXPECTED (also inside `make test`).
- Real (adlc 1.12.0): the first run went red on `S.desk-pr` only, `doctor: store:archive:
  unsupported ticket store manifest`, the sim world's wrong archive marker (§1). The fix is in
  `tests/sim/lib/world.sh`, and the fake's doctor now models the check (test_desk_gates
  `check-doctor-fails`). Rerun: `sim.sh --adlc real` exits 0, 117 stages equal to EXPECTED (6m28s).

### Gates (the uncommitted T26 tree, session 15)

- `make test`: 22 suites PASS, 0 FAIL (5m57s; includes the fake sim through test_sim.sh).
- `make lint`: exit 0 (after the last RULES.md edit too).
- Session 16, before the commit: `desk-gates.sh` usage() printed `sed -n '2,54p'` of a header that
  now ends at line 57; fixed to `'2,57p'`. `bash tests/test_desk_gates.sh` PASS (argument-errors
  included) and `make lint` 0 re-run on that tree. Nothing else changed after the suites above.
- Real adlc on main's store (clean worktree at 036a114, the tree's scripts): `ticket-check.sh` rc 0,
  T20–T31 all `ok` (26 s); `desk-gates.sh` (dry-run) rc 0, 24 lines, each `missing planned pass`
  (47 s), and the worktree is unchanged.

### Red proofs (the new tests on `036a114`, worktree `/tmp/tb7red`, the new tests, tests/fakes and tests/sim copied in)

| suite | on 036a114 | failing cases |
|---|---|---|
| test_desk_gates | rc 1, 20 of 20 fail | all (no desk-gates.sh) |
| test_ticket_check | rc 1, 10 of 13 fail | passes-store-as-it-stands, refuses-open-without-rails, read-failures, header, scope, scope-new-paths-from-parents, edges, tier, forecast, multiple-reasons |
| test_mirror | rc 1, 13 of 21 fail | the old mirror still demands the merge-forecast record that nothing writes: creates, updates-idempotent, ready-only-when-gated, parent-edge-stale, rails-required, closes-completed, stranger-issues, node-needs-desk, forecast-file, depends-on-blocked, forecast-wave-blocked, in-review, close-removes-gate-labels |
| test_gate_context | rc 1, 1 fails | gates-yml-base-scripts (no `desk` job) |
| test_layout | rc 1 | the two ADR-0002 T26 lines |
| sim (fake) | rc 1, a harness error | `desk-gates.sh --write failed`: the walk's first desk push needs the script (`./factory/bin/desk-gates.sh: No such file or directory`) |

## 4. Deviations and decisions

- **Scope deviations:** `tests/test_gate_context.sh` and `tests/test_layout.sh` (§3). The dogfooded
  scope-check names them plus `specs/factory-step3-v1/records/TB7.md`.
- **No records for T20–T31 on main.** The loop builds these tickets itself, so they stay `needs-desk`
  (`no record`) and no node can claim them. `--check` looks only at the tickets a PR adds or changes,
  so an unrelated desk PR is not blocked. When the desk wants one of them claimable, it runs
  `desk-gates.sh --write --ticket T<n>` in a desk PR. This needs no kit line.
- **A desk PR racing a merge.** post-merge appends to main's manifest. An open desk PR then fails
  manifest-extends on the queue (merge_group's base is the new main) and must redo its writes on the
  current main. The runbook says so. This is the SPEC's "fail here, never on main".
- **An edge cycle** passes ticket-check silently. It is not a T26 rule. The fake's forecast errors on
  one; what real adlc's forecast and doctor do with a cycle was not measured. Carry to TB8, which
  owns the `Depends-on:` hold.
- **Live coldstart** (`--coldstart live`) is built and documented but was not run: it calls the LLM
  with the desk's key. The offline contract check is the default and the sim's path.
