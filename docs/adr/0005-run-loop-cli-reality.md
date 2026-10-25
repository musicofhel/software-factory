# ADR-0005: The run-loop sketch against the real CLIs (vetto 0.6.5, ralon 0.1.7, cux v0.4.1, fleet 1.12.0)

- Status: proposed
- Date: 2026-10-24
- Deciders: @musicofhel

## Context

SPEC-v0.2 "Run loop" (L349–405) sketches the inner call of every iteration as

```
ralon run --lock .ralon/<id>.lock -- \
vetto --profile factory/policy/build.toml -- \
  fleet run --tickets <id> --concurrency 1 --no-pr --no-complete \
         --adapter <preferred adapter> --worker-deps <lockfile cache> \
         --max-strikes <budget.strikes> --wall-clock-minutes <budget.minutes> \
    --pre-strike-argv '["cux","status","--json"]' --json
case reason: merged into fleet/run-* | quota-paused | wall-clock | strikes-exhausted | flail
             | review-unavailable | anything else
```

and says build.toml applies to test and build steps while agent.toml applies to model turns.
factory-step2-v1 SPEC I7: the real CLI is the truth; a difference is written here, never coded
around silently. Every reading below was taken on 2026-10-24 from the installed pinned binaries and
the pinned sources; the commands and verbatim help are in `specs/factory-step2-v1/records/TB0.md`.

| Sketch | Verdict | Real (pinned) | Source |
|---|---|---|---|
| `ralon run` | EXISTS | `ralon run [OPTIONS] <COMMAND>...` | `ralon run --help` |
| `ralon run --lock <file>` | DIFFERENT | no `--lock`; `-C, --dir <DIR>` names the directory holding **`agent.lock`** (YAML `protect:` list, patterns relative to the lock's own directory, `..`/absolute/`~`/`!` refused, empty lock refused) | `ralon run --help`; Ralon README "The policy file" (tag v0.1.7, `ccbe22b`) |
| `vetto --profile <toml path>` | DIFFERENT | `--profile <NAME>` is a **built-in** profile name (default, strict, permissive, audit); a policy file is `--policy <PATH>` ("explicit policy TOML layer applied after the profile and project policy") | `vetto --help`; vetto docs/profiles.md |
| `vetto … -- <cmd>` | EXISTS | `vetto [OPTIONS] [-- <COMMAND [ARGS...]>...]` | `vetto --help` |
| network policy inside the profile | DIFFERENT | the CLI flag `--net off\|allowlist:<d,…>\|strict:<d:port,…>` sets it; a policy file may carry `[network]` (`net_presets`, `allow_cidr`, `net_quota`) and `[net_ports]` | `vetto --help`; vetto docs/network.md |
| build.toml for build/test steps and agent.toml for model turns, both under one `vetto` | DIFFERENT | `vetto` wraps one process tree with one policy; it cannot switch policy between fleet's strike phases. fleet already runs build/test/init in its own bwrap sandbox ("network denied, reads/writes bounded to the worktree") and the model plane under `--model-plane-egress allowlist` (adapter `egressHosts` only) | fleet README "What it does", "Composing fleet" |
| `fleet run --tickets <id>` | EXISTS | `--tickets <value>` | `adlc fleet run --help` |
| `--concurrency 1` | EXISTS | `--concurrency <value>` | same |
| `--no-pr` | EXISTS | | same |
| `--no-complete` | EXISTS | | same |
| `--adapter <name>` | EXISTS | operator-local; registered adapters: claude-code, codex, gemini, agy, jetski, opencode, pi, cursor, copilot | same; `@adlc/fleet/lib/adapters/index.mjs` |
| `--worker-deps <lockfile cache>` | DIFFERENT | `--worker-deps <abs node_modules>`: a plain copy of a caller-built **node_modules** tree into the worker worktree before every strike; the configured `init` does not run. Not a generic lockfile cache | fleet README "Composing fleet" |
| `--max-strikes <n>` | EXISTS | integer 1..50, default 2 | same |
| `--wall-clock-minutes <m>` | EXISTS | deadline for the whole run; reason `wall-clock`, exit 2, resumable | same |
| `--pre-strike-argv '["cux","status","--json"]'` | DIFFERENT | flag exists, but `argv[0]` **must be absolute**, there is no shell, and the environment is EXACTLY `--pre-strike-env <json-object>` (fleet adds nothing). Non-zero exit → `quota-paused` | same |
| `cux status --json` | MISSING | cux 0.4.1 `status` accepts only `-no-refresh` (`--json` → "flag provided but not defined: -json", exit 2). The JSON surfaces are `cux usage show` (the on-disk usage cache: an object keyed by account e-mail, each `{polled_at, five_hour: {utilization 0–100, resets_at}, seven_day: {…}, <model windows>…, token_expired?, retry_after?, failures?}`), `cux usage refresh` and `cux commands` | `cux status --json`; cux `internal/usage/usage.go` (tag v0.4.1, `4408a4d`) |
| `--json` | EXISTS | one document on stdout: `fleetRunId, exitCode, reason, integrationBranch, merged, results, strikes, strikesConsumed, review, tickets{state,strikes,reason,reasonCode,review}`, policy echo | fleet README; `@adlc/fleet/lib/result.mjs` |
| reason `merged into fleet/run-*` | DIFFERENT | success has **no reason**: `exitCode 0`, `reason: null`, `integrationBranch: fleet/run-<id>`, `merged ≥ 1` | `result.mjs` `resultDocument` |
| `quota-paused`, `wall-clock`, `strikes-exhausted`, `flail`, `review-unavailable` | EXISTS | members of the closed ticket set | `@adlc/fleet/lib/scheduler.mjs` `REASON_CODES` |
| (anything else) | EXISTS, wider than the sketch | ticket reasons not in the sketch: `lock-held`, `ticket-blocked`, `mirror-fetch-failed`; run-level reasons outside the closed set: `quarantined`, `pr-open-failed`, `preflight`, `resume-refused`, `dispatch-refused`, `pipeline-error` (the last is in code, not in the README) | `scheduler.mjs`, `result.mjs` `RUN_REASONS` |
| `git worktree add .worktrees/<id> origin/main` then fleet inside it | DIFFERENT (side effect) | fleet itself cuts `.worktrees/fleet-<id>` and `.worktrees/fleet-integration` **under its working directory** and appends `.worktrees/`, `.adlc/fleet-status.json`, `.adlc/fleet-logs/`, `.adlc/fleet.lock/` to that tree's `.gitignore` | `@adlc/fleet/lib/worktrees.mjs` |
| `tamperguard` | EXISTS | `tamperguard [--range RANGE] [--json] [--fail-on {tamper,review,never}] [path]`; exit 2 = tamper; no `--version` flag (version from `uv tool list`) | `tamperguard --help` |

Live-run prerequisites fleet 1.12.0 names that the sketch does not: a `fleet.gate` key in
`.adlc/config.json` (absent today), a trusted `adversarial-review` binary on the orchestrator's PATH
(absent today; prosecution fails closed without it, so nothing merges), and the ADLC Claude Code plugin
in worker worktrees. The sandbox precondition itself is met on the dev box since bwrap 0.9.0 was
installed (`detectBackend()` → `bubblewrap`, `resolveSandboxForRun({})` → `refused: false`).

## Decision (proposed; decision 2 rewritten by the T6 amendment below)

The run loop codes to the real CLIs. **vetto does not wrap fleet** (measured in T6: fleet's bwrap
cannot start inside vetto 0.6.5), so the outer call is ralon around fleet:

```
ralon run -C <worktree> -- \
  fleet run --tickets <id> --concurrency 1 --no-pr --no-complete --adapter <adapter> \
    --max-strikes <n> --wall-clock-minutes <m> \
    --pre-strike-argv '["<abs path>/factory/bin/quota-gate.sh"]' --pre-strike-env '{"PATH":…,"HOME":…}' \
    --model-plane-egress allowlist [--worker-deps <abs node_modules> only when the ticket is Node] --json
```

and vetto wraps only the commands the loop runs itself, from the worktree root, on the ticket branch:

```
vetto --profile strict --policy factory/policy/build.toml --tui none -- <build/test step>
vetto --profile strict --agent claude --policy factory/policy/agent.toml \
      --net "$(factory/bin/lib/vetto-net.sh factory/policy/agent.toml)" --tui none -- <model-turn command>
```

1. **ralon**: `factory/bin/lib/ralon-lock.sh` renders `agent.lock` at the root of the ticket's worktree
   (`<lockdir>` = that worktree), not `.ralon/<id>.lock`: patterns are relative to the lock and `..` is
   refused, so a lock under `.ralon/` could not name a repo path. The file is kept out of `git status`
   through `info/exclude` so fleet's dirty-tree check does not trip. Because fleet cuts its worktrees
   beneath its own cwd, each rail glob is rendered both as itself and under `.worktrees/*/`. T6 proved
   the placement live; the `.worktrees/*/` form covers only worktrees that exist when ralon starts
   (amendment, ralon 3).
2. **vetto** (rewritten by T6): vetto wraps the loop's own steps, never fleet. The build/test
   "deny all network" half inside a fleet run is fleet's own bwrap repo-command plane
   (`--unshare-net`); the model plane is fleet's `--model-plane-egress allowlist` (the adapter's
   `egressHosts`, the same three hosts `agent.toml` lists). `build.toml` wraps a build or test step
   the loop runs itself (the local tamperguard/test pass after `merged`); `agent.toml` wraps a
   model-turn command the loop runs itself, with `--net` rendered from the file because
   `--agent claude` otherwise replaces the file's network table. The loop never branches on vetto's
   exit status (always 125 in the full tier); it reads the command's own output or effects.
3. **quota**: the pre-strike command is an absolute factory script that reads `cux usage show` and
   exits non-zero when every account is at or above `quota_cap`; the governor (T8) reads the same JSON.
4. **reasons**: the loop's `case` keys on `reason`; success is `exitCode 0 && reason == null`. Every
   reason outside the five the sketch names takes the "anything else" branch.

## Amendment 2026-10-24: T6 measurements (vetto 0.6.5, ralon 0.1.7, dcg 0.15.3)

Commands and output: `specs/factory-step2-v1/records/TB1.md`; the live proofs re-run with `make live`
(`tests/live/test_policy_live.sh`).

vetto 0.6.5:
1. **Exit status is 125 after every full-tier session**, whatever the command returned (`exit 0`
   and `exit 3` both give 125): `src/sandbox/linux/mod.rs:309` `child_exit` ignores its code. 0.6.5
   is the newest release on crates.io (2026-10-11).
2. **`--profile strict` is required.** A `--policy` layer cannot lower the CLI's base profile, and
   `extends = "strict"` under `--profile strict` is "policy inheritance cycle" (125). The default
   profile adds writable /tmp, ~/.cache and /run/user.
3. `$PROJECT` is vetto's **working directory**, not the git top level: run it from the worktree root.
4. A cwd under /tmp fails silently (125, no message): strict mounts a private tmpfs on /tmp.
5. A write root that does not exist is dropped with a warning: create `$HOME/.factory/cache` first.
6. A policy file's `[network]` is enforced (build.toml: example.com → no connection; agent.toml
   without `--agent`: github.com, registry.npmjs.org, example.com → no connection, api.anthropic.com
   → 404, platform.claude.com → 200, plain http to api.anthropic.com → 501). **But `--agent claude`
   replaces it** with vetto's built-in agent allowlist (github.com and registry.npmjs.org → 200 under
   agent.toml + `--agent claude`), and an explicit `--net` replaces both (`--net off` → no DNS).
   `factory/bin/lib/vetto-net.sh` renders `--net` from the file so the file stays the one list.
   `--dry-run`'s `net:` line does not show the file's table (it shows `off`, or the agent preset).
7. A typo'd network mode (`"offf"`) is accepted silently and the command runs; an unknown table or
   key fails closed (125, "Security policy load failure", the command never runs). `vetto-net.sh`
   and `tests/test_policy.sh` pin the mode values.
8. `--agent claude` adds ~/.claude and related roots, and a git guard that refuses `main`/`master`.
9. **bwrap does not nest inside vetto**: "Can't read /proc/sys/kernel/overflowuid"; allowing that
   read only moves the failure to "Failed to create NETLINK_ROUTE socket". fleet's repo-command plane
   uses `--unshare-net` (`@adlc/fleet lib/sandbox.mjs:157`), so fleet cannot run inside vetto.
10. **On this box the real HOME fails closed**: `~/.aws` is a symlink to a directory on `/mnt/c`, and
    vetto's mask binds /dev/null over it ("Not a directory", 125). Any symlink-to-directory at a
    masked secret path reproduces it. A vetto defect; the join wizard (T7) must probe for it.

ralon 0.1.7:
1. `ralon run` passes the command's status through (`exit 7` → 7); no lock, an empty lock or a bad
   pattern → 2; `ralon check` → 1 for a protected path; agent.lock protects itself.
2. bwrap nests inside ralon (works), so `ralon run -C <wt> -- fleet run …` is viable.
3. **A worktree created after ralon starts is not protected** (mount and landlock backends alike):
   `.worktrees/*/…` covers only worktrees present at start. fleet cuts its worker worktree during
   the run, so rails inside it rest on fleet's own scope/control-file checks and the CI rails gate
   (step 3). T9 must not claim ralon covers fleet's worker worktree.
4. ralon silently strips a leading `/` from a pattern (`/rail/**` matches as `rail/**`), so the
   renderer refuses absolute globs itself. On WSL ralon warns that `/mnt/wslg/distro/…` is a second,
   unrestricted path to the project.

dcg 0.15.3: a config that fails to load prints only "Warning: Failed to load config" and runs on
defaults (even with `--robot`); a partial `[interactive]` table fails the load; unknown keys are
ignored silently. The live test asserts the warning is absent. `echo git push` and `gh pr view` are
denied too (accepted over-block).

## Amendment 2026-10-25: T9, the run loop as built (`factory/bin/run.sh`)

Cases: `tests/test_run.sh` (20); commands and output: `specs/factory-step2-v1/records/TB4.md`.

The outer call, as coded (the fake `fleet` refuses any option 1.12.0 lacks, so the argv is checked
against the real flag set):

```
ralon run -C <clone>/.worktrees/<id> -- npx -y @adlc/cli@1.12.0 fleet run --tickets <id> \
  --concurrency 1 --no-pr --no-complete --base <sha> --adapter <adapter> \
  --max-strikes <weights.W.maxStrikes> --wall-clock-minutes <weights.W.wallClockMinutes> \
  --pre-strike-argv '["<FACTORY_ROOT>/factory/bin/quota-gate.sh"]' \
  --pre-strike-env '{"PATH":"$FACTORY_HOME/bin:…","HOME":…,"FACTORY_MANIFEST":…}' \
  --model-plane-egress allowlist [--dead-end-file <wt>/.factory-run/dead-end.md] --json
```

T9 decisions beyond decisions 1–4:

5. **`--base <sha>`.** fleet's base defaults to the local `main` ref, which a node's clone does not
   keep current. The loop fetches and passes the exact sha it cut the worktree at.
6. **The lapsed-branch resume** (SPEC-v0.2 "worktree from the lapsed `ticket/<id>/*` branch, dead-end
   material appended"): the worktree starts at the newest `origin/ticket/<id>/*` by committer date.
   "Appended to the ticket" is fleet's `--dead-end-file`, because `.adlc/tickets.json` is desk-only
   (AGENTS.md). The file carries the branch name, its record-commit trailers, its commit subjects and
   the files it touched, never file contents. It sits in `<wt>/.factory-run/`, which `info/exclude`
   keeps out of `git status`.
7. **The node's own pause/resume**: on `quota-paused` or `wall-clock` the loop saves the exact fleet
   argv in `$FACTORY_HOME/run/slot-N.json`, keeps the worktree and the lock, and re-runs the identical
   argv in the same worktree on the next iteration (fleet's resume reconciliation). At most 3 resumes
   per claim; the 4th pause is handled as `strikes-exhausted`.
8. **vetto around tamperguard only**: `vetto --profile strict --policy factory/policy/build.toml --tui
   none -- bash -c 'tamperguard --range B..TIP --json >f; echo $? >rc'`, from the worktree root. The
   verdict is the rc file plus the JSON, never vetto's 125 (decision 2).
9. **Every push ends in an empty record commit** (`git commit-tree` on fleet's tip) carrying the I6
   trailers (`Assisted-by`, `Ticket`, `Node`, `Signed-off-by` = `git var GIT_COMMITTER_IDENT`) plus
   `Factory-Outcome`, `Fleet-Reason`, `Fleet-Strikes`, `Fleet-Run`. The push is
   `--force-with-lease` against the fetched value of this node's own `ticket/<id>/<handle>`.
10. **scope-check is step 3's stub** (exit 2, "not built"). On success the loop records
    `scope-check-not-built`, keeps the work on a LOCAL `ticket/<id>/<handle>`, releases the lock and
    stops the slot (exit 2). It pushes nothing: a push would claim a gate passed that does not exist
    (I5). The call is `scope-check.sh --ticket <id> --base <sha> --head <sha>`; step 3 owns the real
    interface.
11. **Reason routing beyond the sketch**: `lock-held`, `ticket-blocked`, `mirror-fetch-failed` →
    release, comment, nap `nothingClaimableSleepMinutes` (no hot loop). Run-level reasons
    (`preflight`, `quarantined`, `dispatch-refused`, `resume-refused`, `pr-open-failed`,
    `pipeline-error`), unreadable output, `exitCode 0` without a merge, and the loop's own failures
    (worktree, rails lock, ticket unresolved) → release, comment, **stop the slot (exit 1)**: fleet's
    `result.mjs` says these need a human and a re-claim would repeat them.
12. **I8**: fleet's `reason` is sent only when it matches `^[a-z][a-z0-9-]{0,47}$`, else as
    `unrecognized`. `tickets[].reason`, `warnings`, `results` and tamperguard's `detail` (which
    quotes the diff) stay in `$FACTORY_HOME/run/logs/`. PR title `<id>: built by <handle> (issue #n)`
    carries no ticket text. Token counts are `null`: fleet 1.12.0's result document has none.
13. **Labels**: the loop adds `needs-desk` on `strikes-exhausted`, `flail`, `tamper` and a real scope
    failure, as the TB4 row says. See open point 1.

Measured gaps and open points (none blocks T9):

1. SPEC-v0.2 contradicts itself: the run-loop sketch says "label Issue needs-desk", the claim
   protocol says "No node ever edits labels other than adding in-progress", and mirror.sh recomputes
   `ready`/`needs-desk` from the store on every run, so the node's label can be flipped back. A
   ruling for the desk (TB6 close-out carries it as a question).
2. fleet's own commits (`feat(<id>): fleet worker build`, its integration merges) carry no I6
   trailers; only the loop's record commit does. Step 3's commit-check needs a rule for them (for
   example "the branch tip's trailers cover the range").
3. claim.sh has no skip list: a ticket that ended in `lock-held` or `ticket-blocked` is
   re-claimable after the 10-minute nap.
4. While scope-check is a stub the success path never pushes, so the first live smoke (T11) ends in
   `scope-check-not-built` at best.
5. ralon covers `<wt>/agent.lock`'s rails in the loop's worktree only; fleet's worker worktree is cut
   after ralon starts and is not covered (amendment above, ralon 3).
6. Killing a loop mid-fleet leaves the lock held with no slot state; the janitor's stale-lock duty
   (24 h) or `/factory:release` frees it.

## Consequences

- SPEC-v0.2's sketch is wrong in five spellings (ralon `--lock`, vetto `--profile`, `cux status --json`,
  the `merged` reason, `--worker-deps` meaning) and one structure (two vetto profiles cannot alternate
  inside one fleet run). The spec text is not edited; this ADR is the correction T9 cites.
- `--worker-deps` only helps Node tickets; other ecosystems get their dependency cache through vetto's
  writable roots instead.
- A live run needs `fleet.gate` and a trusted `adversarial-review`; both are T11's to provide or to name
  as the cause when the smoke ends in a reason other than success.
- vetto's sandbox covers the loop's own steps only; inside a fleet run the sandbox is fleet's bwrap
  planes, which TB0 measured as `refused: false` on this box. Rails inside fleet's worker worktree
  are not ralon-enforced (amendment, ralon 3).
- Nothing keys on vetto's exit status; every vetto call needs a result marker in the output.
- Accepting this ADR is the desk's call once T6 and T9 have proven the decision live.
