---
name: join
description: Join this box to the Distributed Software Factory as a node. Runs factory/bin/join.sh, which probes the machine, plans and installs the pinned toolchain in user space, prints the token and runner instructions, and commits the node manifest to the `nodes` branch. Use when a member says "join the factory", "set up my node", or runs /factory:join.
---

# /factory:join

**Status: built (build order step 2, ticket T7). Run the wizard; never do its steps by hand.**

```
factory/bin/join.sh --handle <your-github-login>              # dry run: prints every step, writes nothing
factory/bin/join.sh --handle <login> --apply --token-file <f> # does it
```

Run it from the root of your clone. Flags: `--owner O` (default the handle), `--remote NAME`
(default `origin`), `--repo owner/name` (default from the origin URL), `--quota-tier
free|pro|max|team|unknown`, `--quota-cap X` (default `budget.json` `governor.quotaCapDefault`,
0.4), `--accounts N` (a count, never names), `--tz ZONE` (default `$TZ`, then `/etc/localtime`),
`--quiet-start HH:MM` / `--quiet-end HH:MM` (default 09:00–17:00), `--token-file FILE|-`,
`--no-suite` (skip the timed suite; `heavy_gates` is then false), `--suite-timeout-seconds N`,
`--json` (one JSON report on stdout, narration on stderr). `join.sh --validate <manifest>` checks
one manifest against `factory/nodes/manifest.schema.json`.

Exit 0 joined (or, in a dry run, would join); 2 refused, with every cause printed together; 1 an
operational error (a failed install, an unreachable or missing `nodes` branch, a push that failed
without a race).

**Writes.** The dry run writes nothing: no file, no git object, no ref (the `nodes` tip is read
with `ls-remote`). `--apply` writes only inside the clone (the `nodes` commit) and under
`$FACTORY_HOME` (default `~/.factory`, mode 0700). It never uses `sudo`. It never writes to
`~/.claude`, so the dcg hook is **not** installed into Claude Code settings here: the run loop
(ticket T9) wires dcg into its own sessions.

## Steps (each is printed before it runs)

1. **Probe** (`factory/bin/lib/probe.sh`, read-only): OS (`linux`, `wsl2`, `macos`; WSL1 and others
   are unsupported), `nproc`, RAM total and available (GB here means GiB), free disk, the sandbox
   backend, the adapters `claude`, `codex`, `agy`, `opencode` (installed, version, authenticated).
   Only claude-code has a measured auth check (`claude auth status --json`, `.loggedIn`); the others
   report "not measured" and do not count. A timed `make test` in the clone (timeout
   `budget.json` `weights.light.suiteMinutesMax` × 60 = 600 s, in its own process group so a
   timeout stops every test) sets `heavy_gates`: true only when it passed in time.
   `slots = min(8, floor(free_GiB / 2) − 1)`.
2. **Install plan, pinned.** Every command is printed in the dry run; `--apply` runs them. A tool
   already on PATH at its pin is skipped. The rest install under `$FACTORY_HOME`:

   | tool | pin | how |
   |---|---|---|
   | `@adlc/cli` | 1.12.0 | `npm_config_cache=$FACTORY_HOME/npm npx -y @adlc/cli@1.12.0 --version` (primes the npx cache) |
   | `adlc init` | 1.12.0 | `adlc init --root <clone> --harness claude-code`, only when `.adlc/` is missing |
   | vetto, ralon | 0.6.5, 0.1.7 | `CARGO_HOME=$FACTORY_HOME/cargo cargo install --locked --root $FACTORY_HOME <crate>@<pin>` |
   | tamperguard | 0.2.0 | `uv tool install tamperguard==0.2.0` with every `UV_*` dir under `$FACTORY_HOME` |
   | dcg | v0.15.3 | release tarball from `Dicklesworthstone/destructive_command_guard`, sha256 pinned in `join.sh`, into `$FACTORY_HOME/bin` |
   | cux | v0.4.1 | release binary from `inulute/cux`, sha256 pinned in `join.sh`, into `$FACTORY_HOME/bin` |
   | adversarial-review | 2.11.1 | fleet's trusted reviewer (ruling Q4): `npm pack` into a temp dir under `$FACTORY_HOME/tmp`, the tarball's sha512 checked against the npm integrity pinned in `join.sh` (`sha512-LiPc0R5U…`), then `npm install -g --prefix $FACTORY_HOME` of that file and a receipt at `$FACTORY_HOME/receipts/adversarial-review@2.11.1`. A mismatch stops before npm installs anything. Only a copy under `$FACTORY_HOME` with that receipt counts as installed |
   | each usable adapter | `factory/policy/adapters.json` | claude-code: `npm install -g --prefix $FACTORY_HOME @anthropic-ai/claude-code@<pin>`; others have no recipe yet (install by hand) |

   ADLC 1.12.0 has no plugin-install command (`adlc --help`), so the wizard installs none.
3. **Register, by hand.** The wizard prints the fine-grained token page (only this repository;
   Contents read and write; 90-day expiry; it may write only `ticket/**`, `nodes/**`,
   `refs/locks/**` — the token form has no ref field, so the repo's rules hold that line, and
   whether GitHub scopes it is measured at first join) and the self-hosted runner page and
   `./config.sh … --labels factory-node --name <handle>` command. It never creates either.
   `--token-file` stores a `github_pat_…` token at `$FACTORY_HOME/token` (0600).
   It also prints the line **you** run once for the quota reading (ruling Q5), after
   `. $FACTORY_HOME/env`: `cux add --no-alias`. Why: the run loop's governor
   (`factory/bin/lib/governor.sh`) reads `cux usage show` before every claim and never claims on an
   unknown reading, so with no cux account every slot sleeps `governor.unknownStateSleepMinutes`.
   `--no-alias` because the factory counts accounts and never names them. The wizard never runs
   `cux add` and never reads, writes or passes the account's credential.
4. **Manifest.** `nodes/<handle>.json` (status `joining`), validated against the schema, committed
   on top of `<remote>/nodes` and pushed **without force**. A push that loses the race re-fetches,
   rebuilds and retries (3 attempts). The push is the node's first heartbeat. `--apply` also
   writes `$FACTORY_HOME/manifest.json` and `$FACTORY_HOME/env` (PATH with `$FACTORY_HOME/bin`
   first, `FACTORY_MANIFEST`, `FACTORY_HANDLE`, `npm_config_cache`) for the run loop to source.
5. **Print** `. $FACTORY_HOME/env`, one `factory/bin/run.sh --slot <n>` per slot, and
   `factory/RULES.md`.

## Refusals (exit 2, all printed together)

- running as root;
- an unsupported OS (WSL1, anything but Linux, WSL2, macOS);
- no sandbox backend: `bwrap` on Linux and WSL2, `sandbox-exec` on macOS (ADR-0003). The install
  line is printed (for example `sudo apt-get install bubblewrap`; the wizard never runs it). Also
  refused: `bwrap` present but unable to start a sandbox;
- `slots < 1` (less than 4 GiB available);
- `--dangerously-skip-permissions` (or `defaultMode: bypassPermissions`) in any shell rc, rc
  directory, or Claude Code settings file it can read (user, project, managed). Never vibe mode;
- no adapter that is installed, authenticated and pinned in `factory/policy/adapters.json`;
- an install step that cannot run (no cargo, uv, npx, npm, curl, sha256 or sha512 tool, or no
  release asset for this OS and arch) for a tool that is not already at its pin;
- a classic or app token (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`), or anything not `github_pat_…`;
- an unknown time zone, or a manifest that fails the schema;
- (`--apply`) a handle another owner already holds on the `nodes` branch.

A vetto-masked path in `$HOME` that is a symlink (`~/.ssh`, `~/.aws`, `~/.gnupg`, `.env`, `.npmrc`,
`.docker/config.json`, `.config/gh/hosts.yml`) is a **warning**: vetto 0.6.5 refuses to start
(exit 125) on such a HOME, so the run loop's vetto steps fail until it is a real directory or file.

## Manifest defaults

`slots` above. `ram_gb` = MemTotal in GiB, rounded. `quota_cap = 0.4`. `quiet_hours` = 09:00–17:00
in the owner's time zone. `accounts` = 1 (a count only). `status = joining`. `review` =
`{"tool": "adversarial-review", "pin": "2.11.1", "same_family": true}` on a box with one usable
adapter (claude-only: the reviewer runs on the builder's model family, accepted until build-order
step 4).
