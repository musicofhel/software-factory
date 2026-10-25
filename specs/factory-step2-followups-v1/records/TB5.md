# TB5 — The live run past preflight, and close-out (ticket T16)

Session 8, 2026-10-25. No prep existed for this row (`specs/factory-step2-followups-v1/prep/` is
absent). Nothing was pushed and nothing was written to GitHub (I1). Network use: npm registry reads
(join's installs into scratch dirs), the Anthropic API (the fleet worker and the reviewer, on this
box's own claude-code login), and example.com / api.anthropic.com reachability probes in the live
tests. No upstream issue was filed.

Commit: the `Ticket: T16` commit that carries this file. T16's scope is `tests/live/test_smoke*.sh`,
`tests/fixtures/make-repo.sh` and `README.md`; this row touched the smoke and README only.

## 1. Verdict

**Part A passes.** The toy ticket T-smoke now gets past fleet 1.12.0's preflight on this bubblewrap
host through the T12 shim. fleet builds it in its bounded sandbox in one strike. The gate
`bash tests/test_hello.sh` passes, adversarial-review 2.11.1 (join's, T15) approves, and fleet
merges it into its integration branch. The loop then runs its own tamperguard step under vetto.
The step cannot work: tamperguard's binary may not be executed inside vetto, and the worktree's
git dir may not be read there (§4.3). The loop fails closed with reason `tamperguard-error` and
takes the specified branch for it: release the lock, comment, remove the worktree and the mirror,
stop the slot with exit 1 (run.sh header "anything else"; ADR-0005 decision 11, "the loop's own
failures"). Every sandbox was enforced, and none ran open. The best case, `scope-check-not-built`,
needs the tamperguard step fixed first. That fix is outside T16's scope, so it is Q1 in HANDOFF.md.

**Part B passes.** `make test` 15 files PASS, `make lint` 0, and `make live` 4 files PASS (exit 0).
Coldstart `gaps: []` for T12–T16. README row 2 is updated.

## 2. The runs, in order

| # | what | log | fleet result | loop reason | cause |
|---|---|---|---|---|---|
| 1 | `FACTORY_SMOKE_KEEP=… make live`, smoke as committed at `40238ac` | `~/.cache/tb5/live.out` | exit 2 `ticket-blocked`, run `20261025134000`, 1 strike | `ticket-blocked` (release, nap 600 s; specified) | the worker could not `chmod +x hello.sh` (§4.1). The cause was invisible in run 1, because run.sh removes fleet's transcript with the worktree (§6.2) |
| d1 | diagnostic copy of the smoke (below), unchanged config | `~/.cache/tb5/diag.out`, `~/.cache/tb5/diag1/` | the same `ticket-blocked` | (the diagnostic patch broke run.sh's tail, so its own checks failed; only the transcript was the point) | fleet's transcript: `TICKET-BLOCKED: chmod +x needs approval this session didn't get` |
| d2 | diagnostic copy + `fleet.allowedCommands` | `~/.cache/tb5/diag2.out`, `~/.cache/tb5/diag2/` | exit 2 `strikes-exhausted`, 2 strikes | `strikes-exhausted` (push the record branch, needs-desk, release; specified) | strike 1's gate failed at rails-guard: `ticket T-smoke has no rails declared and no --rails flag supplied` (§4.2). Strike 2 changed nothing, so fleet's `git commit` failed |
| d3 | diagnostic copy + allowedCommands + `rails: ["factory/policy/**"]` | `~/.cache/tb5/diag3.out`, `~/.cache/tb5/diag3/` | exit 0, merged 1, 1 strike, review approve | `tamperguard-error` | §4.3, reproduced by hand in the kept clone |
| 2 | **`FACTORY_SMOKE_KEEP=$HOME/.cache/factory-smoke-evidence make live`**, the final smoke | `~/.cache/make-live-tb5.log` (= `~/.cache/tb5/live2.out`) | exit 0, merged 1, 1 strike, review approve | `tamperguard-error` | the same as d3, with the same vetto signature (12 events, 528 bytes written, empty tamperguard.json) |

The diagnostic copy was `~/.cache/tb5/smoke-diag.sh`, which was never committed. It is the smoke
with three changes:
1. It sources `tests/fakes/lib.sh` by absolute path.
2. It keeps `$S` instead of deleting it.
3. After cloning, it patches the *clone's* `factory/bin/run.sh` so that `wt_remove` first copies
   `$WT/.adlc` (fleet's `fleet-logs/T-smoke.log` and `fleet-status.json`) to
   `$FACTORY_HOME/diag/`.

The fixture origin's `factory/bin` stayed HEAD's. Each kept `$S` held a hard link to the claude
credential, and each was deleted after its evidence was copied out (`ls ~/.cache | grep
factory-smoke` → `factory-smoke-evidence` only). The `FACTORY_SMOKE_KEEP` dir holds no credential.

## 3. Part A: the recorded items (run 2, the final smoke)

Command: `FACTORY_SMOKE_KEEP=$HOME/.cache/factory-smoke-evidence make live`.

| item | value |
|---|---|
| canary | passes through the shim. `test_bwrap_shim_live`: "through the shim (pin 1.12.0) the canary prints `__fleet_canary_ok__`", and without the shim `bwrap: execvp /bin/sh: No such file or directory`. In the smoke, fleet got past preflight: a `fleetRunId`, a worker, a merge. The ledger has `"bwrap_shim": true` |
| fleet run id | `20261025135148` (loop run `dev-box-s1-1792936305-2051672`) |
| strikes | 1 of 2 (`strikesConsumed` 1, ticket state `merged`) |
| the gate `bash tests/test_hello.sh` | passed. fleet merges only after its gate pipeline (build/test → protected-file scan → rails-guard) passes. d3's `fleet-status.json` has `"state":"merged","prosecution":"pass"`, and the worker's own run printed `PASS` (d3 transcript) |
| adversarial-review | `{"provider":null,"verdict":"approve","revision":"e3f65612…","rounds":1}`. This is join's 2.11.1, resolved at `$FACTORY_HOME/bin/adversarial-review` |
| tamperguard under vetto | ran under `vetto --profile strict --policy …/factory/policy/build.toml`. **tamperguard itself never executed** (exit 126, §4.3). tamperguard.json is empty, so the loop recorded `tamperguard-error` |
| first `vetto audit` session | `session-2052838`: profile `factory-build`, tier `full`, command `vetto --profile strict --policy /home/…/factory-smoke.dag0ud/clone/factory/policy/build.toml --tui none -- bash -c tamperguard --range "$1" --json >"$2" 2>"$3"; echo "$?" >"$4" tamperguard 4508acd7…..7dd875be… .factory-run/tamperguard.json .factory-run/tamperguard.err .factory-run/tamperguard.rc`. The smoke now checks this (`tamperguard ran under vetto: the latest session is factory-build, strict, running tamperguard over the range`) |
| fleet's policy echo | `readPolicy bounded`, `privateTmp true`, `gitSource mirror` (`…/fh/run/mirrors/dev-box-s1-1792936305-2051672.git`), `egress allowlist` = `api.anthropic.com:443, console.anthropic.com:443, platform.claude.com:443`; `homeBinds` = the credential and settings.json only; `writableRoots` = fleet's worker worktree, the mirror, the egress socket dir |
| final branch | `tamperguard-error`: outcome `released`, run.sh exit 1, lock released, nothing pushed (no `ticket/T-smoke/dev-box` in the fixture or the clone), slot stopped |
| governor line | `{"action":"claim","reason":"ok","sleep_seconds":0}` (cux five-hour utilization 26 %) |
| claim ref | `refs/locks/issue-1` → `9b53716c…` (`{"handle":"dev-box","run_id":"dev-box-s1-1792936305-2051672",…}`), released |
| ledger line | actions `claim, fetch, worktree origin-main, ralon-lock, mirror, fleet-run, tamperguard, release-lock, comment, worktree-remove`; `fleet_exit` 0; `tokens` null (fleet 1.12.0 reports none; ADR-0005 d12) |
| tokens (node-local transcripts under the scratch HOME) | 2 messages, input 4, output 652, cache read 21 184, cache creation 25 618. Most likely adversarial-review's call (it runs on the host under the scratch HOME); not verified. fleet's worker runs in its own synthetic HOME, which fleet deletes. d3's `.adlc/manifest.jsonl` p4 entry has the worker's: input 18, output 2 926, cached 212 666 |
| I8 | "no ticket text in a gh call, comment, pushed commit or ledger line" ok |
| wall clock | run.sh 35 s |

The smoke's step 6 line, verbatim: `fleet reason 'none (success)' -> loop reason 'tamperguard-error', outcome released, exit 1`.
The full smoke section is in `~/.cache/make-live-tb5.log`. Its checks are all `ok`.

## 4. Causes found, each with its evidence

### 4.1 fleet's worker may run only the gate, `allowedCommands` and read-only git (run 1, d1)

`@adlc/fleet/lib/adapters/claude-code.mjs` `buildSettings` writes the worker's
`.claude/settings.local.json`. The allow list is `config.init`, `gate.build`, `gate.test`,
`config.allowedCommands` (each as `Bash(<cmd>)`), and `git status|diff|log`. Nothing else is allowed,
and `claude -p` denies anything outside it. `allowedCommands` is a repo key
(`lib/config.mjs` `resolveRunConfig`: `allowedCommands: config.allowedCommands ?? []`). The worker's
words (d1 transcript): `TICKET-BLOCKED: chmod +x needs approval this session didn't get, so hello.sh
isn't executable and \`bash tests/test_hello.sh\` exits 1 (Permission denied)`.

Fix, in T16's scope: the smoke's fixture config now carries
`fleet.allowedCommands = ["chmod +x hello.sh", "chmod +x hello.sh tests/test_hello.sh", "./hello.sh",
"bash tests/test_hello.sh:*"]`, and a check pins it. **main's own `.adlc/config.json` has no `fleet`
block at all** (no gate, no allowedCommands), so a real ticket would meet the same wall: Q3.

### 4.2 fleet's gate refuses a ticket with no rails (d2)

fleet's gate runs `adlc rails-guard --base <start> --ticket <id>` (`lib/live-deps.mjs` railsGuard).
`@adlc/rails-guard/lib/rails.mjs` `resolveRailGlobs`: with no `--rails`, `ticket.rails` must be
non-empty, else `ticket <id> has no rails declared`, exit 1. The README says "If neither is
available the tool exits 1". fleet passes no `--rails`, and no fleet flag or config key adds one.
So `rails: []` fails the gate on every strike. The worker said so on strike 2 ("Prior attempt: it
failed with `ticket T-smoke has no rails declared and no --rails flag supplied`"). It then changed
nothing, and fleet's host-side `git commit` failed on the empty change. The result was
`strikes-exhausted` with both strikes spent on a cause no worker can fix.

Fix, in T16's scope: T-smoke declares `rails: ["factory/policy/**"]`. That is the glob ralon-lock.sh
protects for every ticket anyway, and the toy ticket does not touch it. **Every ticket in main's
store has `rails: []` or none (T1–T16)**, so a real ticket would fail the same way: Q2.

fleet's side of this (the strikes spent on a deterministic configuration error) is drafted as an
upstream issue in §5. It was not filed: Q4.

### 4.3 The loop's tamperguard step cannot run under vetto + build.toml (d3, run 2)

The step (`run.sh` `on_success`; ADR-0005 decision 8) is `cd $WT && vetto --profile strict --policy
factory/policy/build.toml --tui none -- bash -c 'tamperguard --range B..TIP --json >f 2>e; echo $? >rc'`.
It was reproduced by hand in d3's kept clone: a detached worktree at the merged tip, the same
command, the same HOME and PATH. Two independent refusals:

1. **Exec of the tool.** `tamperguard.rc` = `126` and `tamperguard.err` =
   `…/fh/bin/tamperguard: Permission denied`. join installs tamperguard with uv under
   `$FACTORY_HOME` (`$FH/bin/tamperguard` → `$FH/uv/tools/tamperguard/bin/tamperguard`, interpreter
   `$FH/uv/tools/tamperguard/bin/python` → `~/.local/share/uv/python/cpython-3.14…`).
   Probe scripts run under the same vetto call:
   - `$HOME/.factory/cache/probe.sh` ran.
   - `$HOME/.local/bin/probe.sh` ran.
   - `$HOME/.factory/bin/probe.sh` was refused (`Permission denied`, rc 126).
   - `$FACTORY_HOME/bin/probe.sh` was refused the same way.

   So this is not the smoke's layout: a real node's `~/.factory/bin` is refused the same way.
   Adding `allow_read` entries for those bin dirs makes the probes run. tamperguard then fails on its
   interpreter (`bad interpreter: Permission denied`) until the uv tool dir and the uv python dir
   are readable too.
2. **The git dir.** The loop's worktree is a linked worktree (`$WT/.git` = `gitdir:
   $CLONE/.git/worktrees/<name>`), and `$CLONE/.git` is outside vetto's read roots: `git rev-parse
   HEAD` → `fatal: not a git repository`, `ls $CLONE/.git` → `Permission denied`. tamperguard then
   prints `empty diff, nothing to scan`, exits **0**, and writes **no JSON**. run.sh's `case
   "$tg:$verdict"` accepts only `0:ok|0:review`, so it refuses that as `tamperguard-error`. That is
   the right answer: no false green.

With a scratch copy of build.toml (`~/.cache/tb5/diag3/build-exp.toml`) whose `allow_read` adds
`$FH/bin`, `$FH/uv`, `~/.local/share/uv/python` and `$CLONE/.git`, the same command gives rc 0 and
`{"verdict":"ok","score":0,"findings":0}` (`~/.cache/tb5/diag3/tamperguard-with-reads.json`).

`vetto audit` does not show either refusal: `violations_total 0`, `filesystem_denials []`, 12
events. Only the command's own stderr names the cause, and run.sh does not keep that file (§6.2).

Why this is not fixed here: the fix changes `factory/policy/build.toml` (desk work, CODEOWNERS two
humans), `factory/bin/run.sh` (T9's scope; build.toml can name only `$HOME`/`$PROJECT`-relative
roots, and the clone's git dir and FACTORY_HOME are per node), and ADR-0005 decision 8. T16's
scope is the smoke, the fixture and README. Q1 lays out the options.

## 5. Upstream issue draft (NOT filed; Q4)

> **fleet spends every strike on a ticket rails-guard cannot evaluate**
>
> `@adlc/cli` 1.12.0 / `@adlc/fleet` (same in upstream main as far as read). A ticket with
> `rails: []` (valid for `adlc ticket create` and `ticket doctor`) is dispatched normally. After
> the worker's first strike, the gate pipeline's rails-guard stage runs `adlc rails-guard --base
> <start> --ticket <id>`, which exits 1 with `ticket <id> has no rails declared` (an operational
> error per rails-guard's README, not a rail violation). fleet treats it as a gate failure and
> starts strike 2. The worker cannot change the ticket's rails (`.adlc/` is protected), so it
> changes nothing, and the host-side `git commit -q -m "feat(<id>): fleet worker build"` fails on
> the empty change. Result: `strikes-exhausted` after spending the whole strike budget (two model
> calls) on a deterministic configuration error.
>
> Expected: either (a) the plan or preflight refuses a ticket with no rails before dispatch (no
> strike spent; a run-level or ticket-level reason such as `rails-undeclared`), or (b) an
> operational rails-guard exit (1) is not charged as a strike and is reported with its own reason
> code. Separately, (c) a strike in which the worker changed nothing could be reported as such
> rather than as a `git commit` failure.
>
> Repro: any repo with `fleet.gate.test` set and a ticket with `rails: []`; `adlc fleet run
> --tickets <id> --max-strikes 2`.

## 6. Other observations (recorded, not acted on)

1. **The worker loads the account's claude.ai connectors.** The worker's own summary mentions "a
   set of claude.ai connectors (Slack, Linear, Notion and others) need authorizing … and the Claude
   Docs server failed to connect". fleet's `claude -p` does not pass `--strict-mcp-config`, so
   account-level connectors are offered to the worker. Under the egress allowlist they did not
   connect. On an account where they are authorized, the worker's tools could include them, and
   so could the I8 surface (ticket text leaving the node through a connector). This is fleet's
   adapter, not the factory's. A candidate for a step-4 review.
2. **The loop discards fleet's transcript.** fleet writes `<worktree>/.adlc/fleet-logs/<id>.log`
   (`lib/live-deps.mjs` `fleetLogPath`) and `fleet-status.json`. run.sh's `wt_remove` deletes the
   worktree, so a `ticket-blocked` reason reaches the node owner with no cause. It took a
   diagnostic run to read it. Keeping both files in `$FACTORY_HOME/run/logs/<run id>.*` stays
   node-local (I8). The same holds for `.factory-run/tamperguard.err`. This is a run.sh change
   (T9's scope), so it is a follow-up for the desk.
3. **`$HOME/.factory/cache` does not exist** when the tamperguard step runs. vetto logs
   "allow_write path … does not exist; dropped". build.toml's header says the caller creates it.
   In the smoke, FACTORY_HOME is `$S/fh`, not `$HOME/.factory`, and run.sh does not create it.
   This is harmless for tamperguard, which writes nothing there, but the build steps step 3 adds
   will need it.
4. **`in-progress` stays on the Issue after a release.** This is specified: release.sh says "Labels
   and comments are not touched; … the janitor tidies labels".
5. ralon still warns that `.worktrees/*/factory/policy/**` matches nothing at lock time and that
   the `/mnt/wslg/distro/…` path is a second path to the project. Both are known (ADR-0005 open
   point 5).

## 7. Part B

```
$ make test   → 15 files PASS, exit 0   (before the edits and again on the final tree, ~/.cache/tb5/test2.out)
$ make lint   → exit 0                  (on the final tree, ~/.cache/tb5/lint2.out)
$ FACTORY_SMOKE_KEEP=$HOME/.cache/factory-smoke-evidence make live
  PASS tests/live/test_bwrap_shim_live.sh
  PASS tests/live/test_join_live.sh      (incl. part C, the tampered-pin fail-closed install)
  PASS tests/live/test_policy_live.sh
  PASS tests/live/test_smoke_live.sh
  exit=0
$ npx -y @adlc/cli@1.12.0 coldstart --all --offline --json
  {"ok":true,"results":[{"id":"T12","pass":true,"gaps":[]}, … T13, T14, T15, T16 the same]}
$ npx -y @adlc/cli@1.12.0 ticket doctor        → All checks passed.  exit 0
$ npx -y @adlc/cli@1.12.0 merge-forecast --json → gateFailures [], waves [[T12,T13],[T15,T14],[T16]]  exit 0
$ grep -n 'step 2' README.md   → 27 (Joining heading) and row 2 of the build-order table
```

`make live` ran the working-tree smoke, whose blob is `124c2de6…`. The `Ticket: T16` commit carries
the same blob, so the run tested exactly what is committed. The fixture's `main` is `git archive
HEAD`, and none of HEAD's files changed in this row except the smoke and README, which the fixture
does not execute.

## 8. What changed in the repo

- `tests/live/test_smoke_live.sh`:
  - The fixture config gains `fleet.allowedCommands`, and a check pins it.
  - T-smoke declares `rails: ["factory/policy/**"]`.
  - New check: whenever the loop ran its tamperguard step, the latest `vetto audit` session is the
    factory-build / strict / build.toml call running `tamperguard --range`.
  - The header says why the first two exist.
- `README.md`: build-order row 2.
