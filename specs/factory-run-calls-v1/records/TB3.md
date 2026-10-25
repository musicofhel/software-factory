# TB3 — The live run to `scope-check-not-built`, and close-out (ticket T19)

Session 5 of the loop, 2026-10-25 (~23:00Z). No prep exists for this spec (`prep/` is absent). Commit
`Ticket: T19` (hash in LEDGER). Nothing was pushed and nothing was written to GitHub (I1). GitHub was
only read: `gh secret list`, `gh variable list`, `gh api` GETs, `gh issue view`, `git ls-remote`.
Network use: npm registry reads, the Anthropic API (fleet's worker and the reviewer, on this box's own
claude-code login), and the live tests' reachability probes. No upstream issue was filed.

Tools: `@adlc/cli` 1.12.0 (fleet), vetto 0.6.5, ralon 0.1.7, tamperguard 0.2.0, cux 0.4.1,
adversarial-review 2.11.1 (join's), claude-code 2.1.280. Scratch: `~/.cache/tb3-run/` (node-local).

## 1. Verdict

**Part A passes.** The loop now ends `scope-check-not-built`, and every earlier step is the specified
one:

1. claim;
2. fleet in its bounded sandbox, past the preflight canary through the T12 shim;
3. one strike, gate passed, adversarial-review approve, merged;
4. tamperguard under vetto with this claim's rendered policy (T17): rc 0, verdict `ok`;
5. the scope-check stub says `not built`;
6. the ticket branch is held locally, nothing is pushed, the lock is released, and run.sh exits 2.

No sandbox ran open, and the tamperguard step ran inside vetto.

**Part B passes.** `make test` 16 PASS, `make lint` 0, `make live` 5 PASS (exit 0). Coldstart gaps are
empty for T17–T19. README row 2 is updated. The desk note and Aaron's kit are in HANDOFF.

## 2. What changed (T19's scope: `tests/live/test_smoke*.sh`, `tests/fixtures/make-repo.sh`, `README.md`)

`tests/live/test_smoke_live.sh`:

- **The fixture's `ticket create` passes `--allow-unsigned`.** HEAD's store holds the railed
  T17–T19, so it is a frozen trust root, and adlc 1.12.0 refuses an unkeyed write with
  `MANIFEST_KEY_REQUIRED` (records/TB0.md §2.1). This follows ruling Q1. The write lands in the
  fixture's copy only. Its stderr carries the expected `--allow-unsigned with no ADLC_MANIFEST_KEY`
  warning (`~/.cache/factory-smoke-evidence/ticket-create.err`).
- **The vetto check now reads the render, not `factory/policy/build.toml`.** It has three parts:
  - the latest session is `factory-build`, strict, `--policy <…>.build.toml`, and runs
    `tamperguard --range`;
  - vetto's history entry for `$FACTORY_HOME/run/policy/<run id>.build.toml`
    (`vetto audit --query <render> --json`, field `policy_path`) is that same session;
  - the render differs from the clone's `build.toml` only on its `allow_read` line (I14).

  A new check also asserts that tamperguard's stderr is kept in `$FACTORY_HOME/run/logs/<run id>.tamperguard.err`.
- **The recorded items** print the render's `allow_read`, the ledger's tamperguard object with
  tamperguard's stderr, and vetto's history entry for the render.

`README.md`: build-order row 2 (§5). `tests/fixtures/make-repo.sh` did not need a change.

### 2.1 Why the policy is matched through vetto's history (run 1)

Run 1 (`~/.cache/tb3-run/make-live-run1.log`) took the specified path to `scope-check-not-built`, but
one check of mine failed: `expected [factory-build true true] got [factory-build false true]`. That
check tested `.command | contains("--profile strict --policy $RENDER ")`.

vetto 0.6.5's session detail (`vetto audit --latest --json`) redacts a high-entropy path segment
inside `.command`. The render's path appears there as
`/home/musicofhel/.cache/factory-smoke.[REDACTED_HIGH_ENTROPY].build.toml`: the `mktemp` suffix, `fh/run/policy/` and the run id are all one token. The session detail has no `policy_path` field.

The history listing does keep the path whole. This was reproduced in a scratch HOME:
`vetto --profile strict --policy <dir>/fh/run/policy/dev-box-s1-1792969629-582411.build.toml -- true`,
then `vetto audit --query <that path> --json` returned
`[{"session_id":"session-622133",…,"policy_path":"<the whole path>",…}]`. That id equals `--latest`'s
`session_id`, and a query that matches nothing returns `[]`.

So the check joins the two outputs on the session id. The `[^ ]+\.build\.toml` pattern on the redacted
command cannot match the template path `…/factory/policy/build.toml`, which has `/` before `build`.
This was checked with jq on both strings. The redaction is vetto's privacy behaviour, not a stage
failure, so no upstream draft is written.

Run 2 is the run of record (§3).

## 3. Part A: the recorded items (run 2)

Command: `FACTORY_SMOKE_KEEP=$HOME/.cache/factory-smoke-evidence make live`. Log:
`~/.cache/tb3-run/make-live.log`. Evidence: `~/.cache/factory-smoke-evidence/` (node-local; it holds
fleet's and tamperguard's logs, never the credential).

| item | value |
|---|---|
| canary (shim) | `test_bwrap_shim_live`: "through the shim (pin 1.12.0) the canary prints `__fleet_canary_ok__`", status 0; without the shim, `bwrap: execvp /bin/sh: No such file or directory`, status 1. In the smoke, fleet got past preflight (a `fleetRunId`, a worker, a merge), and the ledger has `"bwrap_shim": true` |
| fleet run id | `20261025231123` (loop run `dev-box-s1-1792969879-817764`), integration branch `fleet/run-20261025231123`; fleet's stderr: `fleet run 20261025231123: 1 merged, 0 failed/blocked` |
| strikes | 1 of 2 (`strikesConsumed` 1, `tickets["T-smoke"].state` `merged`, `results` `{"T-smoke":"merged"}`, `warnings` `[]`) |
| gate | passed. The gate is `fleet.gate.test` = `bash tests/test_hello.sh`, followed by fleet's protected-file scan and `adlc rails-guard --ticket T-smoke` (rail `factory/policy/**`). fleet merges only after the whole gate pipeline passes, and it merged in strike 1. fleet 1.12.0's result document has no per-stage gate field (`gate` and `prosecution` are absent) |
| adversarial-review | `{"provider":null,"verdict":"approve","revision":"726391b0cdf35a9e3c9eafec0157fa209b0e98fa","rounds":1}` (join's 2.11.1 at `$FACTORY_HOME/bin/adversarial-review`, pinned integrity checked) |
| tamperguard under the rendered policy | `.factory-run/tamperguard.rc` 0, JSON `{"verdict":"ok","score":0,"findings":[]}`, stderr empty (kept at `run/logs/<run id>.tamperguard.err`). Ledger: `"tamperguard":{"verdict":"ok","score":0,"findings":0}` |
| the render | `$FH/run/policy/dev-box-s1-1792969879-817764.build.toml`. `diff` against HEAD's `factory/policy/build.toml` is the `allow_read` line only: `["$HOME/.factory/cache", <clone>/.git, <fh>/bin, <fh>/uv, /home/musicofhel/.local/share/uv/python/cpython-3.14.3-linux-x86_64-gnu]` |
| `vetto audit` session | `session-831288`: profile `factory-build`, tier `full`, `net_mode` `off`, `violations_total` 0, `events_total` 16, `filesystem_denials` `[]`. History: `policy_path` = the render above, `blocked_count` 0. The command is `vetto --profile strict --policy …[REDACTED_HIGH_ENTROPY].build.toml --tui none -- bash -c tamperguard --range "$1" --json >"$2" 2>"$3"; echo "$?" >"$4" tamperguard a725ccc5…..f0ee2588… .factory-run/tamperguard.{json,err,rc}` |
| final branch | `scope-check-not-built`. The smoke's step 6 line, verbatim: `fleet reason 'none (success)' -> loop reason 'scope-check-not-built', outcome held, exit 2`. The local `ticket/T-smoke/dev-box` = `f0ee2588687b7e2c98461551c7195afbd2ad2bbc`. Nothing is in the fixture origin, the lock `refs/locks/issue-1` is released, and the scope stub said `scope-check: not built` |
| governor line | `{"action":"claim","reason":"ok","sleep_seconds":0}` (cux five-hour utilization 33 %) |
| claim ref | `refs/locks/issue-1` → `4fdc748c…` (`{"handle":"dev-box","run_id":"dev-box-s1-1792969879-817764","slots":8,…}`), released |
| ledger actions | `claim, fetch, worktree origin-main, ralon-lock, mirror, fleet-run, policy-render, tamperguard, scope-check, local-branch ticket/T-smoke/dev-box, release-lock, comment, worktree-remove`; `fleet_exit` 0; `tokens` null (ADR-0005 d12) |
| fleet's policy echo | `readPolicy bounded`, `privateTmp true`, `gitSource mirror` (`<fh>/run/mirrors/<run id>.git`), `egress allowlist` = `api.anthropic.com:443, console.anthropic.com:443, platform.claude.com:443`; `homeBinds` = the credential and settings.json only; `writableRoots` = fleet's worker worktree, the mirror, the egress socket dir |
| Issue #1 | 2 comments (claim, then `released T-smoke: reason scope-check-not-built, strikes 1 of 2`); labels `in-progress,ready,w:light` (the janitor tidies labels; release.sh) |
| I8 | "no ticket text in a gh call, comment, pushed commit or ledger line" ok |
| tokens (scratch-HOME transcripts) | 2 messages, input 4, output 618, cache read 21 184, cache creation 25 678 (most likely the reviewer's call; fleet's worker runs in fleet's own synthetic HOME) |
| wall clock | run.sh 34 s |

Every smoke check is `ok`. Run 1 matches on every item except the failed check in §2.1 (fleet run
`20261025230711`, 1 strike, approve, tamperguard `ok`, `scope-check-not-built`, run.sh 51 s).

### 3.1 Observations (recorded, not acted on)

1. **The python dir under the real HOME is readable from vetto when vetto runs under a scratch HOME.**
   This was the register's "not measured" line. join installs the tool into `$FH/uv`, and its
   interpreter resolves to `/home/musicofhel/.local/share/uv/python/cpython-3.14.3-…`. The render adds
   that dir, and tamperguard ran. Under the real HOME, vetto does not start at all: `~/.aws` is a
   symlink (records/TB1.md §3, ruling Q2).
2. **vetto's recap reads like a failure when the step succeeded.** vetto prints `agent exited 125 …
   recap: sandbox refused fail-closed` while the command inside wrote rc 0 and an `ok` verdict. This is
   ADR-0005 amendment T6 item 1 (vetto exits 125 whatever happened), so run.sh reads the rc file. The
   message is misleading but not a stage failure, so no upstream draft is written.
3. **ralon's two known warnings** are unchanged (ADR-0005 open point 5): the
   `.worktrees/*/factory/policy/**` glob matches nothing, and `/mnt/wslg/distro/…` is a second path.
4. **voodootikigod/adlc#1266 is CLOSED** (2026-10-25T22:42:49Z, by commit `a0a986dd31` "fix(fleet):
   bind read-only system roots including /bin in preflight canary (#1266) (#1268)"). `npm view
   @adlc/cli version` is still `1.12.0`, so no release carries the fix yet, and the T12 shim stays.
   Re-pinning and retiring the shim are not this spec's work. #1272 (rails-guard strikes) is OPEN.

No stage failed for a reason inside fleet or vetto, so there is no upstream issue draft in this row.

## 4. Part B

```
$ make test                                  → 16 files PASS, test rc=0           (~/.cache/tb3-run/make-test.log)
$ make lint                                  → rc 0, after the last smoke edit    (~/.cache/tb3-run/make-lint.log)
$ FACTORY_SMOKE_KEEP=$HOME/.cache/factory-smoke-evidence make live   (run 2, the final tree)
  PASS tests/live/test_bwrap_shim_live.sh
  PASS tests/live/test_join_live.sh
  PASS tests/live/test_policy_live.sh
  PASS tests/live/test_render_live.sh
  PASS tests/live/test_smoke_live.sh
  live rc=0
$ npx -y @adlc/cli@1.12.0 coldstart --all --offline --json | jq '…T17,T18,T19'
  {"ok":true,"results":[{"id":"T17","pass":true,"gaps":[]},{"id":"T18","pass":true,"gaps":[]},{"id":"T19","pass":true,"gaps":[]}]}
$ npx -y @adlc/cli@1.12.0 ticket doctor        → All checks passed.  rc 0
$ npx -y @adlc/cli@1.12.0 merge-forecast --json → gateFailures [], waves [[T17],[T18],[T19]]  rc 0
$ ./factory/bin/ticket-check.sh                → 16 completed, T17–T19 ok, rc 0
$ grep -n 'step 2' README.md                   → 27 (the Joining heading); row 2 of the build-order table is L74
```

`make test` ran on the tree after the first smoke edit. The later edits touch only
`tests/live/test_smoke_live.sh` (which `factory/test.sh` does not run; it runs `tests/*.sh`) and
README, so the result holds for the committed tree. `make live` run 2 ran exactly the committed smoke.
The fixture's `main` is `git archive HEAD` (`58216c5`), and this row changes nothing the fixture
executes.

## 5. README row 2

> built (T17–T19 local, not pushed); on the dev box the toy ticket is built, reviewed and merged in
> fleet's sandbox, passes tamperguard under vetto with the claim's rendered policy, and the loop holds
> it at `scope-check-not-built` (scope-check is step 3); every open ticket declares a rail; awaiting
> first join (`specs/factory-step2-v1`, `specs/factory-step2-followups-v1`, `specs/factory-run-calls-v1`)

## 6. T19's acceptance criteria

| AC | result |
|---|---|
| 1. the loop ends `scope-check-not-built`; the recorded items exist with their commands | §3 |
| 2. fleet's sandbox and the tamperguard step were enforced | fleet's policy echo (§3), and vetto session `session-831288` under the render (`policy_path`) |
| 3. `make test`, `make lint`, `make live` exit 0 | §4 |
| 4. coldstart gaps empty for T17–T19 | §4 |
| 5. README row 2 updated | §5 |
