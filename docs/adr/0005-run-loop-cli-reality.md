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

## Decision (proposed)

The run loop codes to the real CLIs:

```
ralon run -C <lockdir> -- \
  vetto --policy factory/policy/agent.toml --net allowlist:<adapter API hosts> [--ci] -- \
    fleet run --tickets <id> --concurrency 1 --no-pr --no-complete --adapter <adapter> \
      --max-strikes <n> --wall-clock-minutes <m> \
      --pre-strike-argv '["<abs path>/factory/bin/quota-gate.sh"]' --pre-strike-env '{"PATH":…,"HOME":…}' \
      --model-plane-egress allowlist [--worker-deps <abs node_modules> only when the ticket is Node] --json
```

1. **ralon**: `factory/bin/lib/ralon-lock.sh` renders `agent.lock` at the root of the ticket's worktree
   (`<lockdir>` = that worktree), not `.ralon/<id>.lock`: patterns are relative to the lock and `..` is
   refused, so a lock under `.ralon/` could not name a repo path. The file is kept out of `git status`
   through `info/exclude` so fleet's dirty-tree check does not trip. Because fleet cuts its worktrees
   beneath its own cwd, each rail glob is rendered both as itself and under `.worktrees/*/`. T6 proves
   the exact placement live.
2. **vetto**: policy files go through `--policy`; network goes through `--net` (plus `[network]` in the
   file where vetto accepts it). The outer vetto runs with the agent policy because the model turns need
   egress; the build/test "deny all network" half is fleet's own bwrap repo-command plane, and
   `build.toml` is used by vetto where the loop runs a build step itself (the local tamperguard/test
   pass). Whether bwrap nests inside vetto's sandbox on this kernel is a live proof for T6/T11; if it
   does not, this ADR gains the measured answer before T9 codes it.
3. **quota**: the pre-strike command is an absolute factory script that reads `cux usage show` and
   exits non-zero when every account is at or above `quota_cap`; the governor (T8) reads the same JSON.
4. **reasons**: the loop's `case` keys on `reason`; success is `exitCode 0 && reason == null`. Every
   reason outside the five the sketch names takes the "anything else" branch.

## Consequences

- SPEC-v0.2's sketch is wrong in five spellings (ralon `--lock`, vetto `--profile`, `cux status --json`,
  the `merged` reason, `--worker-deps` meaning) and one structure (two vetto profiles cannot alternate
  inside one fleet run). The spec text is not edited; this ADR is the correction T9 cites.
- `--worker-deps` only helps Node tickets; other ecosystems get their dependency cache through vetto's
  writable roots instead.
- A live run needs `fleet.gate` and a trusted `adversarial-review`; both are T11's to provide or to name
  as the cause when the smoke ends in a reason other than success.
- Accepting this ADR is the desk's call once T6 and T9 have proven the decision live.
