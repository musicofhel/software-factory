# factory/policy — the quality settings, as code, under CODEOWNERS

Lowering any of these is a visible PR needing two human approvals, never a config tweak.
Every node runs the same set, pinned by `factory/VERSION`.

| File | Consumer | Status |
|---|---|---|
| `prosecution.json` | run loop → `adversarial-review` (`--fail-on`, `--quorum`, `--loop-max`), fleet `prosecuteFailOn` | written |
| `budget.json` | run loop → `fleet --max-strikes --wall-clock-minutes` defaults per weight; claim TTLs | written |
| `quarantine.json` | flaky gate: quarantined tests, each with an expiry | written (empty) |
| `branch-protection.json` | `factory/bin/apply-branch-protection.sh` (repo admin runs it once) | written |
| `build.toml` | vetto 0.6.5 policy for build/test steps the run loop runs itself: no network, writes bounded to the worktree + `$HOME/.factory/cache`. `vetto --profile strict --policy … --tui none --` from the worktree root | written (T6) |
| `agent.toml` | vetto 0.6.5 policy for model-turn commands the run loop runs itself: egress only to the claude-code adapter's API hosts on 443. Needs `--agent claude` and `--net "$(factory/bin/lib/vetto-net.sh factory/policy/agent.toml)"` | written (T6) |
| `dcg.toml` | destructive-command-guard 0.15.3 config for the unattended shell hook: fail closed, deny by default, blocks pushes, GitHub writes, `--dangerously-skip-permissions`, `curl … \| sh`, loosening ralon/vetto | written (T6) |
| `adapters.json` | `version-check.sh` (its `pins_source`) and the join wizard: one key per fleet 1.12.0 adapter, `"x.y.z"` or `null` (= not pinned yet, no node claims with it). Ruling Q5 | written (T6) |
| `tamperguard.toml` | tamper scoring thresholds; exit 2 fails the gate | **build order 3** |
| `agent-perms.json` | agent-permissions deny-first template the rail author fills per ticket | **build order 4** |

vetto is fail-closed: a policy it cannot load stops the command rather than running it open. Its
exit status is 125 after every full-tier session, so callers read results from the command's own
output, never from vetto's status. vetto does not wrap `fleet run` (fleet's bwrap cannot start
inside it); ADR-0005 and `specs/factory-step2-v1/records/TB1.md` hold the measurements.

The per-ticket rails lock is not a file here: `factory/bin/lib/ralon-lock.sh <id> --worktree <wt>
--apply` renders it from the ticket's `rails` globs as `<wt>/agent.lock` (ralon 0.1.7's format,
patterns relative to the lock), always protecting `factory/policy/**`, and keeps it out of
`git status` through `info/exclude`.
