# TB3 — The three diff gates: rails-proof, scope, tamper, one helper for node and CI (ticket T22)

Sessions 7–8, 2026-10-26. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2. Base: `1b8acd3` (TB2 +
ledger). Nothing was pushed, and nothing touched GitHub, the repo's own store, `~/.factory` or the
network (I1, I19). Every world is a temp dir.

**State: done.** Fixes ci:G2, ci:G6 (three of four stubs: rails-proof, scope, tamper; commit-check is
TB4's, attest-verify TB11's), node:G1, node:G4, node:G5, node:G16 and ci §1 (`:(glob)` pathspecs).

## 1. What was built

- **`factory/bin/lib/diff-gates.sh`** (new) is the one implementation, sourced by run.sh and by the
  three CI scripts (I17):
  - `dg_ticket <id> <base>` reads the ticket from the BASE commit's store at
    `.adlc/tickets/<slug>--<sha256 id>.json`, adlc's own name (`tickets/lib/filename.mjs:3-15`). It
    uses `git ls-tree` plus `git show`, as adlc's `stores/git-tree.mjs` does. A ticket that is absent,
    completed, or whose `.id` differs is refused (exit 2).
  - `dg_paths` / `dg_changed` run `git diff --no-renames --name-only -z BASE...HEAD`, so a rename out of
    a rail shows the old path. A failed diff is an error (exit 1), never an empty diff.
  - `dg_rails` fails (2) on the union of `git diff -- ':(glob)<rail>'…` and the fleet glob port. No
    rails declared → refused.
  - `dg_scope` fails (2) on any path that no scope glob matches (fleet port), and on any `.adlc/**`
    path even when a glob covers it. An empty scope → every path is out (fleet `gates.mjs:55-58`).
  - `dg_tamper_argv` prints `--range BASE...HEAD --json`. `dg_tamper_judge` accepts `0:ok`,
    `0:review` and `2:tamper`; everything else is `tamper-error`.
  - Pins: `DG_TAMPERGUARD_PIN=0.2.0`, `DG_TAMPERGUARD_PYTHON=3.14`.
  - Every call prints a `diff-gates: <fn> <argv>` trace on stderr. The I17 tests compare these
    traces between the node and CI.
- **`rails-proof.sh`, `scope-check.sh`** are now real. Each runs `gate_begin` (TB2) and then the
  helper. A non-`ticket` class passes with `class <c>: no ticket scope/rails (approvals gate it,
  TB10)`.
- **`tamper-check.sh`** (new) runs for every class: `need tamperguard`, the helper's argv, the JSON on
  stdout (the job log), then judge: tamper → 2, tamper-error → 1.
- **run.sh** now gates exactly the commit it pushes. The record commit is built first (`GATE_HEAD`).
  `GATE_BASE` is `git merge-base refs/remotes/origin/main GATE_HEAD`, never the lapsed tip
  (node:G5). The gates run in order, then the push:
  1. tamperguard (vetto + rendered policy, the argv from `dg_tamper_argv`, `dg_tamper_judge`);
  2. `rails-proof.sh`, where `rails-fail` goes to the desk and any other error is
     `rails-proof-error`;
  3. `scope-check.sh`, where `scope-fail` goes to the desk and any other error is
     `scope-check-error`;
  4. the push of that same sha (`push_record` is split into `record_commit` and `push_sha`).

  The ledger line now records `gate_base`, `gate_head`, `rails_proof` and `scope_check`. The
  `FACTORY_SCOPE_CHECK` seam and the `scope-check-not-built` hold are gone. run.sh also refuses to
  start without `adversarial-review` on PATH (node:G16).
- **`lib/policy-render.sh`**: `policy_tamperguard <wt> <policy> <argv...>` (it used to take a range).
- **gates.yml `tamper`** checks out the head and then the base into `.base`. It runs
  `setup-python` 3.14, then `pipx install --python python3.14 tamperguard==0.2.0`, then
  `./.base/factory/bin/tamper-check.sh`. It used to run `pipx run tamperguard==0.2.0 --base
  origin/main` on 3.12 from the head, an argparse error that read as rc 2 = tamper (ci:G2).
- **ADR-0005** gains the amendment "T22, the diff gates".
- **tests/fakes/adlc**: `FAKE_ADLC_GITSTORE` now names store files as adlc does,
  `<slug>--<sha256 id>.json`. It used to use the sha256 of the ticket JSON, which no reader by name
  could find.

## 2. Decisions

1. **Scope uses fleet's matcher exactly.** It is a jq port of `@adlc/core` `lib/glob.mjs:37-81`
   `globMatch`, reached from fleet `lib/gates.mjs:54-60` → `lib/tickets.mjs:136-138` `inScope`
   (@adlc/cli 1.12.0). The port was checked against real node on 442 + 112 cases with 0 mismatches
   (`.spec-loop/tb3/fleet.json`, `.spec-loop/tb3/extra.json`, 8 more patterns over 14 paths incl. a newline). The spec says that when the two
   differ, fleet's wins and the difference is recorded. Git's `:(glob)` differs in 3 of 442 cases:
   `src/**.js` ∋ `src/a/b.js` for fleet and not for git, while `a?c` and `[ab]x` are wildcards for
   git only.
2. **Rails freeze the union** of `:(glob)` (the spec's text) and the fleet port (what fleet's own
   rails-guard uses). Whichever reading reaches a path, the path is frozen, so neither matcher leaves
   a hole.
3. **A rails failure exits 2, not 1.** The spec's TB3 text says exit 1. The T22 ticket body and the
   factory's convention (common.sh, AGENTS.md: 1 operational, 2 gate fail) say 2. A 1 would read as an
   operational error on the node (`rails-proof-error`, released) instead of a desk matter.
4. **The node gates the record commit, not fleet's tip.** The record commit is empty (same tree), so
   the diff is the same, but the sha CI sees is the sha the node gated. The I17 comparisons need that.
5. **The ticket comes from the base's store.** A branch cannot widen its own scope or drop its own
   rails. Both are tested: the head edits its store file and is still gated by the base's.
6. **Non-ticket classes** (desk, halt, human) pass rails/scope here. Approvals gate them (TB10).
   tamper runs on every class.

## 3. Measured this row (session 7; `.spec-loop/tb3/`)

- fleet's scope matcher path and semantics (above), and the npx cache dir
  `~/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc/`.
- Real tamperguard 0.2.0 on this box:
  - It takes `--range A...B --json`. On a new `@pytest.mark.skip` it returned rc 2 with
    `{"verdict": "tamper", …}`.
  - `--base` is an argparse error, rc 2, with no JSON. That is why the judge requires the parsed
    verdict.
  - `uv tool list --show-python` gives `tamperguard v0.2.0 [CPython 3.14.3]`.
- The store's filename rule: adlc `tickets/lib/filename.mjs:3-15`, e.g. `sha256("T20")` =
  `aa6f…88bc`.

## 4. Scope deviation (recorded, not hidden)

T22's scope (records/tickets/T22.json) does not list `tests/test_gate_context.sh`. Two of its cases
pinned exactly what T22 replaces:
- `gate-stubs`: rails-proof and scope-check exit 2 with "not built".
- `gates-yml-base-scripts`: the base-script job list did not include `tamper`.

`make test` (acceptance 6) cannot pass without editing them. The edit is minimal (6+/5−):
- the stub loop keeps commit-check and attest-verify;
- `tamper` joins the job list and the checkout loop.

The context-first and identity-refusal coverage for rails-proof and scope-check moved to
`test_diff_gates.sh` `classes`, which now covers tamper-check too. The scope gate this row builds
would flag the path, which is the point of recording it. Desk note: T22's scope should have listed it.

Carried, outside T22's scope:
- `tests/live/test_render_live.sh:59` still calls `policy_tamperguard <wt> <policy> "$B..$T"`. Under
  the new signature that is a path argument. Owner: TB12, or whichever row next touches tests/live.
  The fix is `--range "$B...$T" --json`.
- `tests/live/test_smoke_live.sh:231` and `factory/skills/run/SKILL.md:65` still describe
  `scope-check-not-built`. Owner: TB12 (close-out docs).
- join.sh installs tamperguard without `--python 3.14`. Owner: TB10 (T29 edits join.sh).

## 5. Tests and red proofs

`tests/test_diff_gates.sh` (new) has 8 cases, all PASS:
- `glob-table`: 17 patterns over 26 paths, against fleet's measured lists, plus git's three
  disagreements on real files.
- `rails`: pass; fail naming the path; a plain pathspec `factory/*.sh` would freeze
  `factory/bin/x.sh` but the rail does not; `factory/x.sh` is frozen; the union (`lib/**.js` via
  fleet, `a?c` via git); a rename out of a rail; a head that drops its rails in its own store; no
  rails; an absent ticket; a bad base (exit 1).
- `scope`: pass; fail naming each path; `.adlc/**` under a `**` scope; an empty scope; completed; absent;
  the head widening its own scope; a bad head (exit 1).
- `tamper`: ok, review (0); tamper (2); a tamperguard error (1, tamper-error); argparse's rc 2 with no
  JSON (1); the judge's mismatched rc/verdict pairs; no tamperguard on PATH (1); the argv.
- `classes`: a human PR passes rails/scope and is still tamper-checked; a foreign `Ticket:` body is
  refused before any diff-gates call, for all three scripts.
- `ci-equals-node`: for each script, the node's call and CI's pull_request call give the same rc, the
  same `diff-gates:` lines, the same output and the same tamperguard argv (I17).
- `run-call-sites`: run.sh sources the helper, calls both scripts with `--base "$GATE_BASE" --head
  "$GATE_HEAD"`, feeds tamperguard `dg_tamper_argv` and judges with `dg_tamper_judge`, takes the merge-base
  with origin/main, has no seam or hold, and requires adversarial-review.
- `gates-yml-tamper`: the checkout order, setup-python = `DG_TAMPERGUARD_PYTHON`, the pipx pin =
  `DG_TAMPERGUARD_PIN`, the base's script, no `if:`.

Red proofs (outputs in `.spec-loop/tb3/red/`):
- **A**: the new test on `1b8acd3`'s code fails all 8 cases (rc 1).
- **B–G**: a mutant of the new helper each, in a throwaway worktree. Each one fails the case that
  guards it:

| mutant | what it changes | case that fails |
|---|---|---|
| B | no git `:(glob)` half | union |
| C | no fleet half | union |
| D | no `.adlc/` rule | `.adlc/**` under `**` |
| E | any rc 2 counts as tamper | argparse rc 2, and judge rc 2 + ok |
| F | the ticket read from the head's tree | both "head edits its own store" checks |
| G | plain pathspecs | `factory/*.sh` does not cross `/` |

Acceptance criterion 2 (the lapsed-resume range), proven red twice:
- **H**: the new `test_run.sh` `lapsed-range` on `1b8acd3`'s code fails. It ends `held` with
  `.gate_base` null.
- **I**: the new code with one mutant, `GATE_BASE="$BASE"` (the lapsed tip), fails. Both
  `.gate_base` and tamperguard's range start at the lapsed tip (`356ece…`), not main (`2f743a…`).

`tests/test_run.sh` (by a subagent; diff reviewed hunk by hunk) has 28 cases and 288 checks, all PASS.
- **Setup:** T-run is in main's store (scope `["hello.sh"]`, rails `["tests/rail/**"]`), and a fake
  `adversarial-review` is on PATH.
- **Removed:** the `scope-stub` case and the `FACTORY_SCOPE_CHECK` stub.
- **New cases:**
  - `scope-fail` (fleet writes `outside.sh`): desk, nothing pushed;
  - `rails-fail` (`tests/rail/x`): desk, scope never runs;
  - `no-adversarial-review`: exit 1 before any lock or API call;
  - `lapsed-range`: built from a lapsed branch with `.gate_base` = main and the range main...pushed;
    a second lapsed branch with an out-of-scope file ends in scope-fail.
- **Changed cases:**
  - `success`: `.gate_base` = origin main, the pushed sha = `.gate_head`, and the order
    tamper → rails → scope → push;
  - `argv`: `--range <main>...<pushed> --json`;
  - `desk-marker`: uses the real scope-check.

`tests/test_gate_context.sh` has 11 cases, all PASS (see §4).

## 6. Stage table delta (tests/sim/EXPECTED.md)

There are now **109 stages = 63 pass + 46 red**. Before, there were 105 = 40 pass + 65 red. That is
19 flips plus 4 new pass stages.
- **Flipped to pass:**
  - `P/C.node-scope`;
  - `P/C.{pr,mg}.{rails-proof,scope,tamper}`;
  - `S.out-of-scope`, `S.tamper-skip`, `S.rail-edit`, `S.head-edits-gate`, `S.ticket-adlc`.
- **New pass stages:**
  - `P/C.node-rails` (the node's ledger has `.rails_proof == "pass"`);
  - `P/C.i17-argv`: the node's `gate_base`/`gate_head` equal the PR's base and head. For each of
    rails-proof, scope and tamper, the node's `diff-gates:` lines equal the pull_request job's. The node's
    tamperguard argv equals CI's and equals `["--range","B...H","--json"]`.
- **Removed:** the node-scope stand-in (the scope-pass stub and the `FACTORY_SCOPE_CHECK` re-run).
- **Still red:**
  - `commit-check` (P/C pr and mg, and `S.no-trailer`), which is TB4's;
  - `attest-verify`, which is now noted "skipped behind the red commit-check (TB4)" and is a stub
    (TB11).

The sim work was done by a subagent; its diff was reviewed:
- `world.sh`: the pipx shim accepts only `install --python python3.14 tamperguard==0.2.0` and links
  the fake into `$PIPX_BIN_DIR`. Each node gets an `adversarial-review` that fails loudly if anything
  ever calls it.
- `driver.sh`: each job gets its own `PIPX_BIN_DIR` first on PATH, as GitHub has one VM per job.
- `sim.sh`: the stand-in is removed, and the stages `node-rails` and `i17-argv` are added.

## 7. Timings (this box, with six jobs running at once)

| run | wall |
|---|---|
| `make lint` | 16 s |
| `sim.sh --adlc fake` | 2 min 22 s |
| `sim.sh --adlc real` | 5 min 30 s |
| `make test` (19 suites) | 5 min 3 s |

## 8. Gates

All are from session 8, against the final tree (`.spec-loop/tb3/s8-*.out`):
- `make lint` exited 0. That is shellcheck -S warning on every shell file, plus actionlint.
- `make test` exited 0, with 19 suites PASS. These include `test_diff_gates.sh` (new),
  `test_run.sh`, `test_gate_context.sh` and `test_sim.sh`.
- `sim.sh --adlc fake` exited 0, and `sim.sh --adlc real` (real `@adlc/cli` 1.12.0) exited 0. Both
  match EXPECTED.md: 109 stages, 63 pass and 46 red.
