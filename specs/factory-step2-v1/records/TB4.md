# TB4 — Run loop and /factory:run (ticket T9)

Sessions 7–8, 2026-10-25 (local); landed as `45950bd` + `4b76353`.
Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2, jq-1.7, GNU
coreutils, claude-code 2.1.280. Session 7 wrote the loop, the fakes and 20 cases and stopped at the soft
gate in WIP commit `45950bd` (`Ticket: T9`) with 4 cases red on test-side bugs. Session 8 fixed those
in a new commit (no amend, I11), finished SKILL.md and the ADR-0005 amendment, and wrote this file.
Nothing was pushed (I1). No prep existed for this row (`specs/factory-step2-v1/prep/` is absent).

Files (all inside T9's scope globs): `factory/bin/run.sh`, `factory/bin/lib/run.sh`,
`factory/skills/run/SKILL.md`, `docs/adr/0005-run-loop-cli-reality.md` (amendment "T9, the run loop as
built"), `tests/test_run.sh`, `tests/fakes/fleet`, `tests/fakes/tamperguard`.

## 1. DoD and T9 acceptance → evidence

| item | where | proof (`tests/test_run.sh` case) |
|---|---|---|
| `run.sh --slot N`, one loop per slot, a shell script | `factory/bin/run.sh` (the header is the design) | `guards`: slot > manifest slots → 2; a live slot mutex → 2, nothing run; a dead holder's mutex broken; `$FACTORY_HOME/env` sourced |
| iteration order governor → claim → fetch → worktree → ralon … fleet → case reason | `iteration()` | `success`'s ledger `actions`: claim, fetch, worktree origin-main, ralon-lock, fleet-run, tamperguard, scope-check, push, pr-open, comment, keep-lock, worktree-remove (§3) |
| **AC1** every branch for its reason; fake fleet emits each; ralon/vetto fakes record argv | `dispatch()`, `on_success`, `on_pause`, `on_desk`, `finish_release` | `success` (push, PR, comment, lock kept, trailers), `scope-stub`, `tamper` (+ tamperguard error → exit 1), `quota-paused` (sleep 600), `wall-clock` (sleep 0), `strikes-exhausted`, `flail`, `review-unavailable` (sleep 1800, no comment), `anything-else` (lock-held / ticket-blocked / mirror-fetch-failed → nap 600; preflight / quarantined / dispatch-refused → exit 1; no JSON → `fleet-output-unreadable`; exit 0 without a merge → `no-merge`; free text in `reason` → `unrecognized`); plus `resume-in-place`, `resume-cap`, `lock-lost`, `governor`, `dry-run` |
| **AC2** argv matches ADR-0005's real flags | `fleet_argv()`, `run_fleet()`, `on_success()` | `argv`: ralon `run -C <wt> -- <fleet> …`; fleet argv exactly `run --tickets T-run --concurrency 1 --no-pr --no-complete --base <origin/main sha> --adapter claude-code --max-strikes 2 --wall-clock-minutes 45 --pre-strike-argv ["<abs>/quota-gate.sh"] --pre-strike-env {FACTORY_MANIFEST, FACTORY_NOW, HOME, PATH} --model-plane-egress allowlist --json`; PATH starts with `$FACTORY_HOME/bin` and reaches jq and cux; vetto `--profile strict --policy <abs>/build.toml --tui none --` and never around fleet; tamperguard `--range <base>..<integration tip> --json`; `adlc ticket show T-run --json` called once and ralon's `-C` dir held `agent.lock` with the ticket's rail |
| **AC3** resume from a lapsed `ticket/<id>/*`, dead-end material appended | `wt_make()`, `run_dead_end()` | `resume`: two lapsed branches, the newer wins; `.base = {kind: lapsed, sha, lapsed: ticket/T-run/old-node}`; fleet `--base` is that sha; `--dead-end-file <wt>/.factory-run/dead-end.md`; the material names the branch, its `Fleet-Reason: flail`, its commit and file; the new push descends from the lapsed tip; the other node's branch untouched |
| **AC4** I8: no prompt or file text in any outbound payload | `lib/run.sh` builders (`run_comment`, `run_pr_body`, `run_record_commit`, `run_code`) | `no-transcript`: marker planted in the ticket body, the Issue body, fleet's transcript, `tickets[].reason`/`warnings` and tamperguard's `detail`; it reached the node (fleet log, tamperguard log); every origin commit message, every gh call argv, PR bodies, Issue comments, the ledger and stdout are grepped for success, strikes-exhausted, quota-paused, review-unavailable, ticket-blocked, preflight and tamper — no hit |
| **AC5** `--once` runs exactly one iteration | main loop | `once`: one line, one `cux usage show`, no nap; `--max-iterations 2` → two lines, one 600 s nap; with a claim → one lock POST, one fleet run |
| **AC6** scope-check exit 2 → no push, record says "scope-check not built" | `on_success()` | `scope-stub`: exit 2, `.scope_check = "scope-check not built"`, reason `scope-check-not-built`, outcome `held`, no `ticket/*` on the origin, no PR, work kept on a LOCAL `ticket/T-run/dev-box`, lock released, comment gives the code, no `needs-desk` |
| **AC7** shellcheck -S warning clean | | `make lint` exit 0 (§2) |
| the fakes are themselves tested | `tests/fakes/fleet`, `tests/fakes/tamperguard` | `fakes`: an option 1.12.0 lacks → exit 1; relative pre-strike argv[0] → preflight; `--max-strikes 51` → preflight; success doc keys equal `lib/result.mjs` `resultDocument` at 1.12.0 in order; ticket reason → exit 2 with `tickets[].reasonCode`; run-level → exit 1; tamperguard tamper → exit 2 `{verdict, score, findings}`, review → 0, bad range → 1, no `--version` → 2 (as the real 0.2.0) |

## 2. Offline gates (working tree before the session-8 commit; re-run after it)

```
$ bash tests/test_run.sh 2>&1 | grep -E '^  (PASS|FAIL)'
  PASS success            PASS scope-stub        PASS tamper            PASS quota-paused
  PASS wall-clock         PASS resume-in-place   PASS resume-cap        PASS lock-lost
  PASS strikes-exhausted  PASS flail             PASS review-unavailable PASS anything-else
  PASS argv               PASS resume            PASS no-transcript     PASS once
  PASS governor           PASS dry-run           PASS guards            PASS fakes
(20 of 20; printed one per line, folded here)

$ make test 2>&1 | grep -E '^(PASS|FAIL)'; echo rc=$?
PASS tests/test_claim.sh
PASS tests/test_governor.sh
PASS tests/test_halt_rules.sh
PASS tests/test_halt.sh
PASS tests/test_janitor.sh
PASS tests/test_join.sh
PASS tests/test_layout.sh
PASS tests/test_mirror.sh
PASS tests/test_policy.sh
PASS tests/test_post_merge.sh
PASS tests/test_run.sh
PASS tests/test_summon.sh
PASS tests/test_version_check.sh
rc=0                                  (13 files; 12 before this row)

$ make lint; echo rc=$?
rc=0
```

Session 8 fixes on top of `45950bd` (all test-side but one):
- `tamper`, `resume`: `field -c .x` passed `-c` as the filter → `jq -c .x <<<"$LAST"`. `tamper`'s leak
  check grepped the whole fake Issue store, whose Issue body carries the planted marker by design → it
  now greps the comment bodies, the ledger and stdout.
- `argv`: the expected-argv jq expression → `.argv | del(.[16], .[18])` (the two JSON values are
  checked separately). The rails-lock check grepped a file that never exists → a `ralon` shim copies the
  `agent.lock` ralon reads, and the adlc log must show exactly one `ticket show T-run --json`.
- `no-transcript`: read tamperguard's output from the already-removed worktree → **run.sh change**:
  tamperguard's JSON is copied to `$FACTORY_HOME/run/logs/<run_id>.tamperguard.json` before the
  worktree goes (the owner keeps the findings; they never leave the node), and the case checks it there.
- shellcheck: run.sh `origin/main^{commit}` quoted (SC1083); unused test locals removed (SC2034);
  `FACTORY_MANIFEST=''` (SC1007).

## 3. What leaves the node (fake origin, `success`, `scope-stub` and `flail` runs)

Ledger line (built), also the `--json` stdout line:
```
{"slot":1,"iteration":1,"at":"2026-10-25T12:00:00Z","handle":"dev-box","adapter":"claude-code@2.1.280","tokens":null,"actions":["claim","fetch","worktree origin-main","ralon-lock","fleet-run","tamperguard","scope-check","push ticket/T-run/dev-box","pr-open","comment","keep-lock","worktree-remove"],"governor":{"action":"claim","reason":"ok","sleep_seconds":0},"issue":1,"run_id":"dev-box-s1-1792929600-1104509","weight":"light","ticket":"T-run","base":{"kind":"origin-main","sha":"84ca5e0582bf30c093f24cb9054131c25f7e487e"},"budget":{"max_strikes":2,"wall_clock_minutes":45},"fleet_exit":0,"fleet":{"run":"fake-1","exit_code":0,"reason":null,"merged":1,"strikes":1,"ticket_state":"merged"},"tamperguard":{"verdict":"ok","score":0,"findings":0},"scope_check":"pass","pushed":{"branch":"ticket/T-run/dev-box","sha":"c50e5e15dbcf7b4a5c086fce25a98ecdd67f317f"},"pr":2,"outcome":"built","sleep_seconds":0}
```
Issue comment: ``Node `dev-box` built `T-run` (fleet run `fake-1`): strikes 1 of 2, adapter claude-code@2.1.280, tokens not reported. Pushed `ticket/T-run/dev-box` at `c50e5e15dbcf`; PR #2.``

PR title `T-run: built by dev-box (issue #1)`; body:
```
Ticket: T-run
Issue: #1
Node: dev-box

| | |
|---|---|
| fleet run | `fake-1` |
| outcome | built (fleet exit 0, reason none) |
| strikes | 1 of 2 |
| adapter | claude-code@2.1.280 |
| tokens | not reported by fleet 1.12.0 |
| base | `84ca5e0582bf` (origin-main) |
| head | `c50e5e15dbcf` |
| tamperguard | ok (score 0, 0 finding(s)) |
| scope-check | pass |

Gate-manifest hashes:
- none recorded for this ticket

Transcripts never leave the node: this body carries ids, reason codes, counts and hashes only.
```
Record commit at the pushed tip:
```
factory: T-run built on dev-box

Factory-Outcome: built
Fleet-Run: fake-1
Fleet-Strikes: 1
Assisted-by: claude-code@2.1.280
Ticket: T-run
Node: dev-box
Signed-off-by: node <node@fake>
```
scope-check stub (exit 2): `…"scope_check":"scope-check not built","outcome":"held","reason":"scope-check-not-built","sleep_seconds":0}`, actions end `scope-check, local-branch ticket/T-run/dev-box, release-lock, comment, worktree-remove`.

flail comment: ``Node `dev-box` stopped `T-run`: reason `flail`, strikes 1 of 2, adapter claude-code@2.1.280. Branch `ticket/T-run/dev-box` at `3afbcefce131`. Labeled needs-desk; lock released.``

## 4. Mutation check (each mutation applied to run.sh / lib/run.sh alone, then restored)

| mutation | caught by |
|---|---|
| drop `--base "$BASE"` from fleet's argv | `argv` (5 checks) |
| scope-check stub treated as a real result (`if false`) | `scope-stub` (7) |
| `run_code` forwards any string | `anything-else` (3) |
| pause without heartbeating the lock | `quota-paused`, `wall-clock` (4) |
| `--once` ignored (runs 3 iterations) | `once` (4) |
| review-unavailable naps nothingClaimable | `review-unavailable` (2) |
| tamperguard `detail` copied into the ledger | `tamper` (2) |
| lapsed branch = the oldest, not the newest | `resume` (6) |
| desk without `needs-desk` | `strikes-exhausted`, `flail` (4) |
| `MAX_RESUMES=99` | `resume-cap` (4) |

## 5. Not proven here (by design)

- No live run: `make live` has no run-loop test; the real ralon + fleet + claude-code smoke is TB6 (T11).
  vetto's real behaviour around tamperguard is TB1's (`records/TB1.md`); TB6 re-proves it end to end.
- The success path never pushes today: scope-check is step 3's stub, so the live smoke ends in
  `scope-check-not-built` at best (ADR-0005 amendment, open point 4).
- `tests/fakes/gh` has no `pr create`; test_run.sh installs a shim in `$WORLD/bin` for it (T9's scope does
  not cover the shared fake gh).
- Open points for the desk are in ADR-0005's T9 amendment (labels contradiction, fleet's untrailered
  commits, claim skip list, scope stub, ralon coverage of fleet's worker worktree, kill mid-fleet).
