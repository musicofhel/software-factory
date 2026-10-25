# TB2 — Join wizard (ticket T7)

Sessions 4 and 5, 2026-10-25 (local). Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2, 28 cpu, 47 GiB,
bubblewrap 0.9.0, claude-code 2.1.280. The work landed as `ae150fa` (session 4, partial, stopped by the soft
gate: join.sh, probe.sh, the fake, tests/test_join.sh, the schema enum) and `e3a0ea9` (session 5: SKILL.md,
nodes/README.md, tests/live/test_join_live.sh). This file and the ledger line land in the next commit.
Nothing was pushed (I1). No prep existed for this row (`specs/factory-step2-v1/prep/` is absent).

## 1. DoD and T7 acceptance → evidence

| item | where | proof |
|---|---|---|
| `factory/bin/join.sh` built; dry run is the default, `--apply` writes; exit 0/1/2 | `factory/bin/join.sh` (header documents every step and flag) | `make test` `tests/test_join.sh` (16 cases, §2); `make live` (§4) |
| `factory/skills/join/SKILL.md` from contract to built | names the real command, every flag, the exit codes, the install table and every refusal. `vallum` is gone, the TB0 pins are in. It says the dcg hook is not written into `~/.claude` (the run loop's job, T9) | `e3a0ea9` |
| probe: nproc, RAM total/free, disk, OS incl. WSL2, adapters installed + authenticated | `factory/bin/lib/probe.sh` (read-only; `FACTORY_PROBE_ROOT` for tests) | `dry-run-ok`, `refuse-other` (WSL1, unsupported OS); live §3 |
| `bwrap` (Linux) / `sandbox-exec` (macOS) required, else refuse with the install line | probe `.sandbox`, join step 1 | `refuse-no-sandbox` (absent; present but cannot start), `refuse-macos-sandbox`; live "the sandbox backend works" |
| `slots = min(8, floor(free_ram_gb/2) − 1)`, refuse < 1 | join step 1, GiB on whole kB | AC2 `slots`: 3.9/4/5.9/6/18/19/40 → refuse/1/1/2/8/8/8; live check against the probe |
| `heavy_gates` from a timed `make test` against budget.json's timeout | `weights.light.suiteMinutesMax` × 60 = 600 s, own process group | `heavy-gates` (pass, fail, timeout kills the tree); live: `suite {"ran":true,"seconds":60,"exit":0,...}` → true |
| refuse `--dangerously-skip-permissions` in any shell rc or Claude settings it can read | probe `.skip_permissions` | AC1 `refuse-skip-permissions-rc`, `refuse-skip-permissions-settings` |
| refuse when no authenticated adapter | join step 1 against adapters.json | AC1 `refuse-no-adapter` |
| install plan pinned from adapters.json + TB0 pins; dry run prints every command; `--apply` runs them, user space only | join step 2 | `plan` (every command, pins, `--root`, no sudo, blocked steps refuse); live part B: the real dcg and cux downloads, sha256 `OK`, npx cache, nothing under `~/.cargo/bin`, `~/.local/bin`, `~/.factory` |
| register prints token instructions (repo, 3 ref patterns, 90 days) and the runner command; stores a provided token at `~/.factory/token` 0600; never creates either | join step 3 | `refuse-other` (classic token refused), `home-diff` (token 0600); live part B "the token is stored at 0600, verbatim"; §3 text output |
| manifest built and validated against the schema | join step 4 + `join.sh --validate` (the schema interpreted by jq; an unknown keyword fails closed) | AC1 `refuse-schema`, `validator`; live "manifest.json passes --validate" |
| commit to `nodes` and CAS-push (fixture origin in tests) | join `--apply`: `commit-tree` on the fetched tip, plain push, ls-remote on failure, 3 attempts | AC4 `nodes-cas` (a racer wins once → retry; a held handle → 2; no `--force`), `no-nodes-branch` (exit 1); live part B: fast-forward of the fixture tip, alice untouched, second run fast-forwards again |
| writes nowhere outside the clone and `~/.factory/` (test diffs a temp `$HOME`) | | AC3 `home-diff` (dry run: zero changes; `--apply`: only `.factory/**`); live part A: the real clone's refs/objects/status and `~/.factory`, `~/.cargo/bin`, `~/.local/bin` unchanged |
| tests with fakes cover every refusal and the slots boundaries | `tests/fakes/join/multi` (one multi-call fake, symlinked as uname, nproc, df, sysctl, vm_stat, bwrap, claude, codex, make, cargo, uv, npx, npm, curl, sha256sum, id, sandbox-exec) | §2 |
| `make live`: the wizard in `--dry-run` on this box, output in records | `tests/live/test_join_live.sh` | §3 and §4 |
| AC6 shellcheck clean | | `make lint` exit 0 (§2) |

## 2. Offline gates (at `e3a0ea9`)

```
$ make test          # 11 files
PASS tests/test_claim.sh
PASS tests/test_halt_rules.sh
PASS tests/test_halt.sh
PASS tests/test_janitor.sh
PASS tests/test_join.sh
PASS tests/test_layout.sh
PASS tests/test_mirror.sh
PASS tests/test_policy.sh
PASS tests/test_post_merge.sh
PASS tests/test_summon.sh
PASS tests/test_version_check.sh
exit=0
$ make lint
exit=0
$ bash tests/test_join.sh | grep -E '^  (PASS|FAIL)'
  PASS dry-run-ok
  PASS slots
  PASS refuse-no-sandbox
  PASS refuse-macos-sandbox
  PASS refuse-skip-permissions-rc
  PASS refuse-skip-permissions-settings
  PASS refuse-no-adapter
  PASS refuse-schema
  PASS refuse-other
  PASS heavy-gates
  PASS plan
  PASS home-diff
  PASS nodes-cas
  PASS no-nodes-branch
  PASS validator
  PASS usage
exit=0
```

Mutations measured in session 4. Each one turns `tests/test_join.sh` red, so the cases bite:
- `git push --force` in the CAS loop: `nodes-cas` fails 5 checks. The racer is a reference-transaction
  hook on the clone that fires when the wizard's fetch writes `refs/remotes/origin/nodes`.
- dropping `--root` from `cargo install`: `plan` and `home-diff` fail.
- a `git fetch` in the dry run: `home-diff` fails.
- GB (10^9) instead of GiB in the slots formula: `slots` fails.

## 3. The wizard in its default dry run on this box (text mode)

```
$ factory/bin/join.sh --handle dev-box

== 1/5 probe ==
  os wsl2, Linux x86_64
  cpu 28, RAM 47.04 GB total, 34.03 GB free, disk 408.06 GB free
  sandbox bwrap: present true, works true
  adapter claude-code: 2.1.280 authenticated true
  adapter codex: absent
  adapter agy: absent
  adapter opencode: absent
  vetto masks /home/musicofhel/.aws, a symlink to a directory
  timed suite: make test in /home/musicofhel/software-factory, timeout 600s (budget.json weights.light.suiteMinutesMax)
  suite: exit 0 in 38s; heavy_gates true
  slots 8 (min(8, floor(free GB / 2) - 1)), heavy_gates true

== 2/5 install plan (pinned; user space under /home/musicofhel/.factory unless already on PATH at the pin) ==
  @adlc/cli 1.12.0: missing
    $ npm_config_cache=/home/musicofhel/.factory/npm npx -y @adlc/cli@1.12.0 --version
  adlc init 1.12.0: installed
  vetto 0.6.5: installed
  ralon 0.1.7: installed
  tamperguard 0.2.0: installed
  dcg 0.15.3: installed
  cux 0.4.1: installed
  claude-code 2.1.280: installed

== 3/5 register (by hand; the wizard never creates a token or a runner) ==
  a. Fine-grained personal access token: https://github.com/settings/personal-access-tokens/new
     Repository access: only musicofhel/software-factory. Repository permissions: Contents read and write (Metadata read is added).
     Expiration: 90 days. It may write only ticket/**, nodes/**, refs/locks/**: the token form has no ref field,
     so the repo rules hold that line (whether GitHub scopes it is measured at first join).
     Store it: re-run with --apply --token-file <file> (kept at /home/musicofhel/.factory/token, mode 0600).
  b. Self-hosted runner, label factory-node: https://github.com/musicofhel/software-factory/settings/actions/runners/new
     ./config.sh --url https://github.com/musicofhel/software-factory --token <registration token from that page> --labels factory-node --name dev-box
     (in a runner group scoped to this repo when the repo belongs to an organization; --ephemeral if the box can afford it)

== 4/5 manifest nodes/dev-box.json ==
  {
    "handle": "dev-box",
    "owner": "dev-box",
    "os": "wsl2",
    "cpu": 28,
    "ram_gb": 47,
    "slots": 8,
    "heavy_gates": true,
    "adapters": {
      "claude-code": "2.1.280"
    },
    "quota_tier": "unknown",
    "quota_cap": 0.4,
    "quiet_hours": {
      "tz": "America/New_York",
      "start": "09:00",
      "end": "17:00"
    },
    "accounts": 1,
    "factory_version": "0.1.0",
    "last_seen": "2026-10-25T04:05:10Z",
    "status": "joining"
  }
  origin has no nodes branch: --apply will stop here (the maintainer creates it)

== 5/5 run ==
  . /home/musicofhel/.factory/env   (written by --apply)
  factory/bin/run.sh --slot 1      # one loop per slot (/factory:run)
  factory/bin/run.sh --slot 2      # one loop per slot (/factory:run)
  factory/bin/run.sh --slot 3      # one loop per slot (/factory:run)
  factory/bin/run.sh --slot 4      # one loop per slot (/factory:run)
  factory/bin/run.sh --slot 5      # one loop per slot (/factory:run)
  factory/bin/run.sh --slot 6      # one loop per slot (/factory:run)
  factory/bin/run.sh --slot 7      # one loop per slot (/factory:run)
  factory/bin/run.sh --slot 8      # one loop per slot (/factory:run)
join: warning: vetto 0.6.5 masks /home/musicofhel/.aws (a symlink to a directory) and fails closed (exit 125) when it is a symlink, so the run loop's vetto steps will refuse on this HOME until it is a real directory or file
exit=0 (39 s; the timed suite took 38 s)
```

`factory/RULES.md` is printed between the run lines and the warning; it is left out here. Read the output:
- `@adlc/cli 1.12.0: missing` is correct. It counts as installed only in `$FACTORY_HOME/npm`'s npx cache,
  the cache the env file points npx at (decision 3). `~/.factory` does not exist on this box yet.
- "origin has no nodes branch" is the real GitHub state (Aaron's kit). `--apply` would exit 1 there.
- The `~/.aws` warning is the TB1 finding (vetto 0.6.5 fails closed on a symlinked mask path). It
  blocks the run loop's vetto steps on this HOME, not the join.

## 4. `make live`

```
$ make live
test_join_live
  part A: dry run in /home/musicofhel/software-factory
    ok   dry run exits 0
    ok   no refusal
    ok   mode is dry-run and the factory home is ~/.factory
    ok   the sandbox backend works
    ok   claude-code is usable: authenticated and at its adapters.json pin
    ok   the manifest has no schema error
    ok   the suite ran and heavy_gates is its verdict
    ok   slots = min(8, floor(free GiB / 2) - 1) from the probe
    ok   the plan names every pinned tool once
    ok   the dry run pushed nothing
    ok   the dry run wrote nothing under ~/.factory, ~/.cargo/bin, ~/.local/bin
    ok   the dry run wrote no ref, no git object and no file in the clone
    INFO probe: os wsl2, 28 cpu, 47.04 GiB total, 25.06 GiB free, sandbox bwrap
    INFO slots 8, heavy_gates true, suite {"ran":true,"seconds":60,"exit":0,"timed_out":false,"timeout_seconds":600}
    INFO plan: @adlc/cli 1.12.0 missing; adlc init 1.12.0 installed; vetto 0.6.5 installed; ralon 0.1.7 installed; tamperguard 0.2.0 installed; dcg 0.15.3 installed; cux 0.4.1 installed; claude-code 2.1.280 installed
    INFO nodes: {"remote":"origin","reachable":true,"tip":null,"pushed":false}
    INFO warning: vetto 0.6.5 masks /home/musicofhel/.aws (a symlink to a directory) and fails closed (exit 125) when it is a symlink, so the run loop's vetto steps will refuse on this HOME until it is a real directory or file
  part B: --apply against a fixture origin with a scratch FACTORY_HOME
    ok   the shadow PATH hides dcg and cux
    ok   --apply exits 0
    ok   no refusal
    ok   the plan installs exactly dcg, cux and the npx cache
    ok   dcg came from the release, checked against the pinned sha256
    ok   cux came from the release, checked against the pinned sha256
    ok   dcg is 0.15.3 in $FACTORY_HOME/bin
    ok   cux is 0.4.1 in $FACTORY_HOME/bin
    ok   @adlc/cli 1.12.0 sits in $FACTORY_HOME's npx cache
    ok   $FACTORY_HOME is 0700
    ok   the token is stored at 0600, verbatim
    ok   the install temp dirs are gone
    ok   manifest.json passes --validate
    ok   env puts $FACTORY_HOME/bin first
    ok   the fixture's nodes tip is the pushed commit
    ok   the push is a fast-forward of the old tip (no force)
    ok   nodes/dev-box.json on the tip is the manifest
    ok   alice's manifest is untouched
    ok   the commit carries Node: dev-box
    ok   nothing written under ~/.factory, ~/.cargo/bin, ~/.local/bin
    INFO plan: @adlc/cli 1.12.0 missing; adlc init 1.12.0 installed; vetto 0.6.5 installed; ralon 0.1.7 installed; tamperguard 0.2.0 installed; dcg 0.15.3 missing; cux 0.4.1 missing; claude-code 2.1.280 installed
    | == apply: install ==
    |   $ npm_config_cache=/home/musicofhel/.cache/factory-join-live.y4ebJQ/fh/npm npx -y @adlc/cli@1.12.0 --version
    | 1.12.0
    |   $ d=$(mktemp -d /home/musicofhel/.cache/factory-join-live.y4ebJQ/fh/tmp/dcg.XXXXXX) && curl -fsSL -o "$d/dcg-x86_64-unknown-linux-musl.tar.xz" https://github.com/Dicklesworthstone/destructive_command_guard/releases/download/v0.15.3/dcg-x86_64-unknown-linux-musl.tar.xz && printf '%s  %s\n' dc7dcec9679f74ac3e6990959771ca0c84168eba658eff64fe9e63f917a84cc4 "$d/dcg-x86_64-unknown-linux-musl.tar.xz" | sha256sum -c - && tar -xJf "$d/dcg-x86_64-unknown-linux-musl.tar.xz" -C "$d" dcg && install -m 0755 "$d/dcg" /home/musicofhel/.cache/factory-join-live.y4ebJQ/fh/bin/dcg && rm -rf "$d"
    | /home/musicofhel/.cache/factory-join-live.y4ebJQ/fh/tmp/dcg.Oo1bIU/dcg-x86_64-unknown-linux-musl.tar.xz: OK
    |   $ d=$(mktemp -d /home/musicofhel/.cache/factory-join-live.y4ebJQ/fh/tmp/cux.XXXXXX) && curl -fsSL -o "$d/cux-linux-amd64" https://github.com/inulute/cux/releases/download/v0.4.1/cux-linux-amd64 && printf '%s  %s\n' d336d1f8a6175265977f5a08ce53c20403e13752b90826df1128c29d89401df6 "$d/cux-linux-amd64" | sha256sum -c - && install -m 0755 "$d/cux-linux-amd64" /home/musicofhel/.cache/factory-join-live.y4ebJQ/fh/bin/cux && rm -rf "$d"
    | /home/musicofhel/.cache/factory-join-live.y4ebJQ/fh/tmp/cux.TB5aut/cux-linux-amd64: OK
    | 
    | == apply: register ==
    |   token stored at /home/musicofhel/.cache/factory-join-live.y4ebJQ/fh/token (0600)
    | 
    | == apply: commit nodes/dev-box.json to fixture/nodes (compare-and-swap, never force) ==
    |   pushed 2c02801d5106 to fixture nodes in 1 attempt(s): the first heartbeat
    | 
    | == 5/5 run ==
    ok   a second --apply with the env sourced exits 0
    ok   and installs nothing
    ok   and pushes the next heartbeat as a fast-forward
    ok   the token from the first run is kept
PASS test_join_live
PASS tests/live/test_join_live.sh
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
make live exit 0 in 69s
```

## 5. Decisions (why the code is the way it is)

1. **Installs go under `$FACTORY_HOME` (default `~/.factory`), not `~/.cargo` or `~/.local/bin`.** The DoD's
   write boundary (only the clone and `~/.factory/`) wins over I2's wording about locations. Each command
   was verified on this box. `CARGO_HOME=$FH/cargo cargo install --locked --root $FH <crate>@<pin>`.
   tamperguard installs with `UV_TOOL_DIR`, `UV_TOOL_BIN_DIR`, `UV_CACHE_DIR`, `UV_PYTHON_INSTALL_DIR`
   and `UV_PYTHON_BIN_DIR` all under `$FH`; `uv tool dir [--bin]` honours them and creates nothing.
   Release binaries go into `$FH/bin`. claude-code drift uses `npm install -g --prefix $FH`, and npx uses
   `npm_config_cache=$FH/npm`. A tool already on PATH at its pin is skipped. `--apply` writes `$FH/env`
   for the run loop to source. Live part B proves all of this with the real downloads.
2. **The release sha256 values are pinned inside join.sh.** They were read on 2026-10-25 from each
   release's own `.sha256` file: dcg v0.15.3 x86_64-unknown-linux-musl, aarch64-unknown-linux-gnu,
   x86_64-apple-darwin and aarch64-apple-darwin; cux v0.4.1 linux/darwin × amd64/arm64. Every dcg
   tarball holds `dcg` at its root (`curl … | tar -tJ`). Live part B re-checked both linux-x86_64 sums
   against fresh downloads (`sha256sum -c`: OK).
3. `@adlc/cli` counts as installed only when `$FH/npm/_npx/*/node_modules/@adlc/cli/package.json` is
   1.12.0. A check through npx would write `~/.npm/_logs` even on a miss (measured in session 4).
4. **ADLC plugin**: `adlc --help` at 1.12.0 lists no plugin installer, and the repo does not record a
   plugin command, so the wizard invents none. `adlc init --root <clone> --harness claude-code` runs only
   when `.adlc/` is missing.
5. **heavy_gates timeout** = `budget.json .weights.light.suiteMinutesMax` × 60 = 600 s, the only suite
   timeout in budget.json. The suite runs in its own process group (`set -m`), so a timeout kills make
   and every test under it.
6. All refusals are collected and printed together, then the wizard exits 2. A blocked install step
   refuses only when the tool is not already at its pin. A symlinked vetto mask path is a **warning**,
   not a refusal.
7. Only claude-code has a measured auth check: `claude auth status --json` → `.loggedIn` (2.1.280; it
   writes nothing). codex, agy and opencode report `authenticated: null` (not measured), and they are
   unpinned anyway. The probe never prints the email or the org.
8. The nodes push is a plain `git push <sha>:refs/heads/nodes`, never `--force`. On failure the wizard
   re-reads the tip with `ls-remote`: a moved tip means retry (3 attempts); an unmoved tip is a real
   error and exits 1. The dry run reads the tip with `ls-remote` only, so it writes no git objects or
   refs. A handle held by another owner exits 2. A missing `nodes` branch makes `--apply` exit 1.
9. A classic or app token (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`) is refused. The fine-grained token
   form has no ref field, so the wizard prints the three ref patterns and marks their enforcement
   "measured at first join" (step-1 follow-up 5).
10. Measured on this box: `~/.claude/settings.json` has `defaultMode: default`. It also has
    `skipDangerousModePermissionPrompt: true`, which only hides a prompt and is not a refusal. No rc
    file sets the flag. `~/.aws` → `/mnt/c/Users/aaron/.aws` (warning).
11. The dcg hook is not written into `~/.claude/settings.json`: that file is outside the write boundary.
    The run loop (T9) runs dcg in its own sessions (SKILL.md says so).

## 6. Due at first join (not provable here, I1)

- The real `join.sh --apply` on dev-box. It needs the `nodes` branch on GitHub (Aaron's kit).
- Whether GitHub enforces the fine-grained token's ref patterns (step-1 follow-up 5).
- A real CAS race on GitHub (a 422 / non-fast-forward against the real remote).
