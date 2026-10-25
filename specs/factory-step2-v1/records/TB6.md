# TB6 — Live smoke on this box and close-out (ticket T11)

Sessions 10–11, 2026-10-25. No prep existed for this row (`specs/factory-step2-v1/prep/` is absent).

Commits: `beae2cd` (T11 WIP: the smoke, make-repo `main-dir`, README row 2), `746af02` (T9: the
bounded model plane the smoke found missing), and the T11 close-out commit that carries this file.

Files in T11's scope (`jq -c .scope .adlc/tickets/t11--*.json` = `tests/live/test_smoke*.sh`,
`tests/fixtures/**`, `README.md`): `tests/live/test_smoke_live.sh` (new), `tests/fixtures/make-repo.sh`
(`main-dir <dir>`), `README.md` (rows 1 and 2, the Joining heading). The fix in `746af02` is T9's
scope (`factory/bin/run.sh`, `tests/fakes/fleet`, `tests/test_run.sh`, ADR-0005) and carries
`Ticket: T9`.

## 1. What the smoke is

`tests/live/test_smoke_live.sh` (its header is the design). A `make live` test, never `make test`.
It prints `SKIP <reason>` and exits 0 when a tool is missing, the network is down, claude is not
logged in, or the governor will not claim (quota at the cap).

1. **origin**: `tests/fixtures/make-repo.sh` builds a bare origin. Its main is this repo's HEAD
   (`git archive`), plus T-smoke created by the real `npx -y @adlc/cli@1.12.0 ticket create --write`,
   `.fleet.gate.test = "bash tests/test_hello.sh"`, and `weights.light.wallClockMinutes = 15`.
2. **HOME**: a scratch HOME, because vetto 0.6.5 fails closed on this box's real HOME (TB1 §3.9).
   `.claude/.credentials.json` is a hard link to the real file. No copy of the secret is made, and
   the link is unlinked on exit.
3. **GitHub**: `tests/fakes/gh` backed by the fixture origin. The claim ref lands in the fixture.
   Nothing can reach github.com (I1).
4. **join**: `join.sh --handle dev-box --apply --remote origin` from a clone of the fixture.
5. **quota**: `cux add --no-alias` plus `cux usage refresh` into the scratch HOME's store.
6. **review**: adversarial-review 2.11.1 from npm, with its integrity pinned, under the scratch dir.
7. **run**: `run.sh --slot 1 --apply --once --json` with the real vetto, ralon, tamperguard, cux and
   `npx -y @adlc/cli@1.12.0 fleet`, adapter claude-code, at most 2 strikes in 15 min.

## 2. The three live runs and what each found

| run | log | fleet's answer | cause | fixed by |
|---|---|---|---|---|
| 1, 2 (session 10) | `~/.cache/smoke-run1.log`, `smoke-run2.log` | exit 1, `dispatch-refused`, in 2 s | `fleet: --model-plane-egress allowlist requires --model-plane-read bounded` (`@adlc/fleet lib/config.mjs:134`). run.sh's T9 argv passed allowlist alone, and the fake fleet did not model the coupling | `746af02` (T9): `--model-plane-read bounded --model-plane-git mirror --model-plane-git-mirror <m>`. Bounded reads require the mirror (config.mjs:117), and the mirror needs concurrency 1 (fleet.mjs:189). run.sh builds `$FACTORY_HOME/run/mirrors/<run id>.git` (`git init --bare --template=`, one branch `base` at the base sha, no remote). The fake now applies config.mjs's checks and `assertBareMirror`. ADR-0005 decision 14 |
| 3 (session 11) | `~/.cache/smoke-run3.log` | exit 1, `preflight`, in 3 s | `preflight failed: preflight canary failed (permission plumbing not working): bwrap: execvp /bin/sh: No such file or directory` | **not fixable in this repo**: §3 |
| `make live` ×2 (session 11) | `~/.cache/make-live-tb6.log`, `make-live-tb6b.log` | the same as run 3 | the same | — |

The prototype mirror was checked against the real code before it was coded in:
`node -e "import {assertBareMirror} from '…/@adlc/fleet/lib/git-mirror.mjs'; …"` →
`{"branches":["base"],"baseBranch":"base"}`.

## 3. The blocker: fleet 1.12.0's preflight canary cannot pass on any bubblewrap host

Read from `~/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc/fleet` (1.12.0):

- `bin/fleet.mjs:486–498` `dispatchCanary` builds `new Sandbox({mode, backend, worktree: tmp,
  syntheticHome: tmp/.home, exec})`. It passes no `readOnlyPaths` and no `readPolicy`, then runs
  `['/bin/sh', '-c', 'echo __fleet_canary_ok__']`.
- `lib/sandbox.mjs:230–232`: `readPolicy` defaults to `BOUNDED` and `readOnlyPaths` to `[]`.
- `lib/sandbox.mjs:171–175` (`buildSandboxArgv`, bubblewrap, bounded) binds only the write roots and
  `readOnlyPaths`. `/usr` is not bound, nor is any other system root. Only the model plane
  (`lib/extensions.mjs:72`, `SYSTEM_ROOTS`) adds `/usr`, `/lib`, `/lib64` and the rest.
- `bin/fleet.mjs:507`: the canary is skipped only when `config.canary === false`, and
  `resolveRunConfig` (`lib/config.mjs`) never sets a `canary` key. No flag and no repo config turns
  it off. `--i-am-in-a-disposable-container` drops the sandbox entirely, which DoD Part A calls a
  fail.

The same argv, by hand, on this box:

```
$ bwrap --unshare-net --die-with-parent --chdir $T --bind $T $T --bind $T/.home $T/.home \
    --setenv HOME $T/.home -- /bin/sh -c 'echo __fleet_canary_ok__'
bwrap: execvp /bin/sh: No such file or directory          rc=1
$ bwrap … --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
    -- /bin/sh -c 'echo with-usr-ok'
with-usr-ok                                               rc=0
```

With no `/usr`, no `/bin/sh` exists inside on any Linux layout, merged-usr or not. So `fleet run`
without `--dry-run` cannot get past preflight on any bwrap node. `npm view @adlc/cli versions` lists
1.12.0 as the newest (published 2026-10-10), so no fixed version exists to pin. TB0 measured only
`fleet run --dry-run`, which never runs the canary, so nothing earlier could have caught this.

This is the cause DoD Part A asks to be named. The canary failed **inside** bwrap, so the sandbox
was enforced and refused, never open. The loop took the specified branch for a run-level reason
(ADR-0005 decision 11): release the lock, comment `reason \`preflight\``, remove the worktree and
the mirror, stop the slot with exit 1. Getting further needs a decision only Aaron can make
(HANDOFF Q1).

## 4. Part A: the six recorded items (from `make live`, §6)

Command: `FACTORY_SMOKE_KEEP=$HOME/.cache/factory-smoke-evidence make live` (session 11, full log
`~/.cache/make-live-tb6b.log`). The six items:

| item | value |
|---|---|
| governor line | `{"action":"claim","reason":"ok","sleep_seconds":0}` |
| claim ref in the fixture | `refs/locks/issue-1` → `0beeaee7…` (`{"handle":"dev-box","run_id":"dev-box-s1-1792907110-2217083",…}`), released by the loop afterwards |
| fleet reason | `preflight` (exit 1, `fleetRunId` null, 0 strikes): the canary, §3 |
| pushed `ticket/T-smoke/dev-box` | **absent**, in the fixture and locally. That is the specified branch for a run-level reason: nothing to push, release, stop the slot |
| ledger line | actions `claim, fetch, worktree origin-main, ralon-lock, mirror, fleet-run, release-lock, comment, worktree-remove`; outcome `released`, reason `preflight`, run.sh exit 1 |
| token count | 0 messages / 0 tokens (no worker ran). The ledger says `null`: fleet 1.12.0's result has no count (ADR-0005 decision 12) |

Verbatim smoke section (`.git/objects` lines of the join test omitted; nothing else cut):

```
test_smoke_live
  1. fixture origin: this repo's HEAD + T-smoke + fleet.gate
    ok   adlc ticket create --write T-smoke exits 0
    ok   T-smoke is in the fixture's store
    ok   the fixture's main carries T-smoke and the gate
    ok   main's factory/bin is this repo's HEAD factory/bin, byte for byte and mode for mode
  2. node: scratch HOME, fake gh on the fixture, no GitHub reachable
    ok   gh is the fake, on the fixture
    ok   claude is logged in under the scratch HOME
  3. join.sh --apply against the fixture
    ok   join --apply exits 0
    ok   no refusal
    ok   nodes/dev-box.json is on the fixture's nodes tip, a fast-forward
    INFO join plan: @adlc/cli 1.12.0 missing; adlc init 1.12.0 installed; vetto 0.6.5 installed; ralon 0.1.7 installed; tamperguard 0.2.0 missing; dcg 0.15.3 installed; cux 0.4.1 installed; claude-code 2.1.280 installed
    INFO manifest: {"handle":"dev-box","slots":8,"heavy_gates":false,"adapters":{"claude-code":"2.1.280"},"quota_cap":0.95,"quiet_hours":{"tz":"UTC","start":"00:00","end":"00:00"}}
  4. cux account and adversarial-review 2.11.1
    ok   cux add (the logged-in account, into the scratch HOME's store)
    INFO cux usage: [{"five_hour":2,"seven_day":null}]
    ok   adversarial-review 2.11.1 installs, integrity as pinned
    ok   fleet will resolve it on the orchestrator PATH
  5. run.sh --slot 1 --apply --once (real vetto, ralon, fleet; claude-code)
    INFO dry run: {"mode":"dry-run","slot":1,"handle":"dev-box","adapter":"claude-code@2.1.280","capacity":"light","governor":{"action":"claim","reason":"ok","sleep_seconds":0},"would_claim":1}
    ok   one ledger line, the same on stdout and in the ledger
    ok   the governor said claim
    ok   the loop claimed Issue #1 for T-smoke (weight light)
    ok   the budget is 2 strikes in 15 minutes
    ok   the claim POSTed refs/locks/issue-1 on the fixture's ref API
    ok   the lock commit is in the fixture and names dev-box and this run
    ok   ralon rendered the rails lock and fleet ran under it
    ok   fleet printed its --json result document
    ok   strikes <= 2
    ok   fleet's wall clock held (run.sh took 3 s; 15 min + the loop's own steps)
    INFO fleet stopped before any worker: preflight failed: preflight canary failed (permission plumbing not working): bwrap: execvp /bin/sh: No such file or directory
    ok   fleet stopped before any worker: no run id, no strike consumed
    ok     the loop built the model-plane mirror its bounded argv names
    ok     fleet's stderr names the cause
    ok     the canary failed INSIDE bwrap (enforced, not open)
    ok   fleet did not refuse its sandbox
  6. fleet reason 'preflight' -> loop reason 'preflight', outcome released, exit 1
    ok   preflight: exit 1, released, slot stopped
    ok   no ticket text in a gh call, comment, pushed commit or ledger line (I8)
  recorded items
    INFO governor line: {"action":"claim","reason":"ok","sleep_seconds":0}
    INFO claim ref: refs/locks/issue-1 -> 0beeaee712b9afb54786cba09caf3f3a7d827362 in the fixture ({"handle":"dev-box","run_id":"dev-box-s1-1792907110-2217083","slots":8,"claimed_at":"2026-10-25T05:45:10Z"}); now released
    INFO fleet: {"run":"unknown","exit_code":1,"reason":"preflight","merged":0,"strikes":0,"ticket_state":null}; doc reason preflight, ticket reasonCode null, review null
    INFO pushed: origin ticket/T-smoke/dev-box absent; local ticket/T-smoke/dev-box absent
    INFO ledger line: {"slot":1,"iteration":1,"at":"2026-10-25T05:45:10Z","handle":"dev-box","adapter":"claude-code@2.1.280","tokens":null,"actions":["claim","fetch","worktree origin-main","ralon-lock","mirror","fleet-run","release-lock","comment","worktree-remove"],"governor":{"action":"claim","reason":"ok","sleep_seconds":0},"issue":1,"run_id":"dev-box-s1-1792907110-2217083","weight":"light","ticket":"T-smoke","base":{"kind":"origin-main","sha":"3deb1cd2ac836d0d884f560aba0cc5866d93474d"},"budget":{"max_strikes":2,"wall_clock_minutes":15},"fleet_exit":1,"fleet":{"run":"unknown","exit_code":1,"reason":"preflight","merged":0,"strikes":0,"ticket_state":null},"outcome":"released","reason":"preflight","sleep_seconds":0}
    INFO tokens (node-local claude transcripts; fleet 1.12.0's result has no count, so the ledger says null): {"messages":0,"input":0,"output":0,"cache_read":0,"cache_creation":0}
    INFO wall clock: run.sh 3 s
    INFO fleet policy echo: {"readPolicy":"host","privateTmp":false,"gitSource":"shared","mirror":null,"egress":"open","egressAllowlist":[],"homeBinds":[],"writableRoots":[]}
    INFO issue #1: labels in-progress,ready,w:light, 2 comment(s)
    | comment: Claimed by node `dev-box`: fleet run `dev-box-s1-1792907110-2217083`, 8 slot(s), expected finish 2026-10-25T06:00:10Z (w:light, 15 min wall clock). Lock `refs/locks/issue-1` at `0beeaee712b9afb54786cba09caf3f3a7d827362`.
    | comment: Node `dev-box` released `T-smoke`: reason `preflight`, strikes 0 of 2, adapter claude-code@2.1.280. Lock released.
    INFO vetto audit: no session (the loop's vetto step, tamperguard, runs only after fleet merges)
PASS test_smoke_live
```

## 5. AC2 (the sandbox was enforced): what exists and what does not

- **fleet**: the bwrap canary refusal above. That is enforcement, but it is not the model plane's
  policy. fleet's policy echo in a preflight document is the pre-dispatch default
  (`readPolicy host`, `egress open`), not the bounded plane the argv asks for. So the smoke now
  checks the echo only once fleet has dispatched (`fleetRunId != null`). Before that, it checks: no
  run id and no strike; the loop built the mirror its bounded argv names; fleet's stderr names the
  cause; a canary failure happened inside bwrap. The argv itself is checked in `make test`
  (test_run.sh `argv`).
- **ralon**: `ralon: 2 paths locked via the mount backend` on fleet's stderr (the loop worktree's
  `agent.lock`).
- **vetto**: **no session from this smoke.** The loop's only vetto step is tamperguard, after fleet
  merges (ADR-0005 decision 2), and fleet never dispatched. `vetto audit` output for the policy
  files was recorded live in TB1 (records/TB1.md). AC2's vetto half is therefore **unmet by this
  smoke and due with the first run that gets past preflight**, together with the policy-echo check.

## 6. Part B gates

```
$ make test     → 14 files PASS, exit 0 (after 746af02; test_run.sh: 20 cases, 197 checks)
$ make lint     → exit 0 (re-run after the last edit, see the close-out commit)
$ make live     → PASS test_join_live, PASS test_policy_live, PASS test_smoke_live; rc=0
                  (~/.cache/make-live-tb6b.log)
$ npx -y @adlc/cli@1.12.0 coldstart --all --offline --json   → exit 0;
  jq over .results: T6..T11 gaps [] each
$ grep -n 'awaiting first join' README.md
27:## Joining (build order step 2: built locally, awaiting first join)
74:| 2 | Join wizard and run loop (vetto, Ralon, dcg, cux) | **built locally, awaiting first join** (`specs/factory-step2-v1`) |
```

The first `make live` of session 11 (`~/.cache/make-live-tb6.log`) failed `test_join_live` only. I had
edited README.md during its before/after snapshot of the clone (its `git status` showed the new
` M README.md`). Nothing else changed, and the re-run above was made with the repo untouched.

T9 fix mutations (each applied alone, `CASES=argv bash tests/test_run.sh`, then restored):

| mutation | caught by |
|---|---|
| `--model-plane-read bounded` dropped from `fleet_argv` | `argv`: the argv check, the mirror-path check, and the fake refusing (`dispatch-refused`) |
| the mirror not removed in `wt_remove` | `argv`: "the mirror was built before fleet and removed with the worktree" |

## 7. Open points carried to Aaron (HANDOFF `### Q` blocks)

1. fleet 1.12.0's canary (§3).
2. The ruling Q6 bypass does not cover classic protection (records/TB5.md §6).
3. The label contradiction (ADR-0005 T9 open point 1).
4. join.sh does not install adversarial-review. On a claude-only box the reviewer is the same model
   family (still true: `grep -n adversarial-review factory/bin/join.sh` finds nothing).
5. join.sh does not run or print `cux add`, so a fresh node sleeps `quota_unknown` (still true:
   `grep -n 'cux add' factory/bin/join.sh` finds nothing).
