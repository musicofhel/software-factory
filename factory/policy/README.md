# factory/policy — the quality settings, as code, under CODEOWNERS

Lowering any of these is a visible PR needing two human approvals, never a config tweak.
Every node runs the same set, pinned by `factory/VERSION`.

| File | Consumer | Status |
|---|---|---|
| `prosecution.json` | run loop → `adversarial-review` (`--fail-on`, `--quorum`, `--loop-max`), fleet `prosecuteFailOn` | written |
| `budget.json` | run loop → `fleet --max-strikes --wall-clock-minutes` defaults per weight; claim TTLs | written |
| `quarantine.json` | flaky gate: quarantined tests, each with an expiry | written (empty) |
| `branch-protection.json` | `factory/bin/apply-branch-protection.sh` (repo admin runs it once) | written |
| `build.toml` | vetto profile for test/build steps: no network, writes bounded to worktree + dep cache | **build order 2** (written against the pinned vetto version's documented format, never guessed) |
| `agent.toml` | vetto profile for model turns: egress only to the adapter's API domain | **build order 2** |
| `ralon.lock.tmpl` | per-ticket `agent.lock` template listing the rail paths | **build order 2** |
| `dcg.toml` | destructive-command-guard config | **build order 2** |
| `tamperguard.toml` | tamper scoring thresholds; exit 2 fails the gate | **build order 3** |
| `agent-perms.json` | agent-permissions deny-first template the rail author fills per ticket | **build order 4** |

vetto is fail-closed: a profile that cannot be applied stops the strike rather than
running open. That is the reason the two profiles are not stubbed here.
