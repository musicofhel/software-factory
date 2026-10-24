---
name: join
description: Join this box to the Distributed Software Factory as a node. Probes the machine, installs the pinned toolchain in safe mode, registers a repo-scoped token and self-hosted runner, and commits the node manifest to the `nodes` branch. Use when a member says "join the factory", "set up my node", or runs /factory:join.
---

# /factory:join

**Status: build order step 2 (not built). This file is the contract the wizard will meet;
it changes nothing yet. Refuse to improvise the steps below by hand.**

Writes nowhere outside the clone and `~/.factory/`. Refuses to proceed if
`--dangerously-skip-permissions` is aliased in the shell. Never vibe mode.

## Steps (the wizard, `factory/bin/join.sh`, does these; print each before doing it)

1. **Probe.** `nproc`, total and free RAM, free disk, OS, which of `claude`, `codex`,
   `agy`, `opencode` are installed and authenticated. Timed dry run of the project's full
   suite sets `heavy_gates`.
2. **Install, pinned.** `@adlc/cli` 1.12.0 and the ADLC plugin; `vetto` 0.6.5 (sandbox);
   `ralon` 0.1.7 (rails path lock); `dcg` (destructive-command hook; `vallum` 0.8.16
   instead when the node runs Cursor or Gemini CLI); `tamperguard` 0.2.0; `cux` for account
   rotation; `adlc init` if `.adlc/` is missing.
3. **Register.** Fine-grained GitHub token scoped to this repo (contents: write on
   `ticket/**`, `nodes/**`, `refs/locks/**` only, 90-day expiry), stored in
   `~/.factory/token` (0600). Register the box as a self-hosted Actions runner with label
   `factory-node` in a runner group scoped to this repo.
4. **Manifest.** Write `nodes/<handle>.json` per `factory/nodes/manifest.schema.json`,
   commit to the `nodes` branch, push. That push is the first heartbeat.
5. **Print** the run-loop command and `factory/RULES.md`.

## Manifest defaults

`slots = floor(free RAM GB / 2) − 1`, capped at 8. `quota_cap = 0.4`. `quiet_hours` = the
owner's working day in their time zone. `accounts` = count only.
