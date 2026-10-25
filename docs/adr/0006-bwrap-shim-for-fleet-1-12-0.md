# ADR-0006: A temporary bwrap shim so fleet 1.12.0's sandboxes can run a shell

- Status: accepted 2026-10-25 (ruling Q1 of `specs/factory-step2-v1/RULINGS.md`; ticket T12)
- Date: 2026-10-25
- Deciders: @musicofhel. The loop `specs/factory-step2-followups-v1` drafted it under ticket T12.

## Context

Every `fleet run` on a bubblewrap host stops at `preflight` (`specs/factory-step2-v1/records/TB6.md`
§3). fleet's preflight canary (`bin/fleet.mjs` `dispatchCanary`; upstream main `455524c`
`packages/fleet/bin/fleet.mjs` L502–507, L491–496 in the npm 1.12.0 copy) runs
`/bin/sh -c 'echo __fleet_canary_ok__'` inside a `Sandbox` on the repo-command profile. On bubblewrap
that sandbox binds only the canary's tmp dir and its `.home` (`tests/fixtures/bwrap-shim/canary.json`):
no `/usr`, no `/bin`. bwrap answers `execvp /bin/sh: No such file or directory`, the canary fails,
and fleet aborts before any dispatch. The repo-command plane (the gate `bash tests/test_hello.sh`,
init, build) is built the same way and would fail the same way after it. fleet's bounded model plane
does bind its own `SYSTEM_ROOTS` (`lib/bounded-model-plane.mjs`: `/usr`, `/lib`, `/lib64`, `/etc/ssl`,
`/etc/resolv.conf`, `/etc/hosts`), but not `/bin` or `/sbin`.

The canary is skipped only when `config.canary === false`, which `resolveRunConfig` never sets
(voodootikigod/adlc#639). Upstream issue: https://github.com/voodootikigod/adlc/issues/1266, filed
2026-10-25 and open; `@adlc/cli` 1.12.0 is still the newest release
(`specs/factory-step2-followups-v1/records/TB0.md` §1.2). Adding `--ro-bind /usr /usr` and the
merged-usr `--symlink`s to the canary's argv by hand makes it print `ok`.

Ruling Q1 (Aaron, 2026-10-25): report upstream and add a temporary shim behind an ADR that adds
read-only system roots only and retires when a fixed fleet is pinned.

## Decision

1. **A `bwrap` in front of the real one, on fleet's PATH only.** fleet spawns `bwrap` by name
   (argv[0] of every sandbox argv) and passes PATH through its env scrub (`lib/env-scrub.mjs`
   `repoCommandEnv` keeps PATH and drops nearly everything else). `factory/bin/lib/bwrap-shim` is
   linked as `bwrap` into `$FACTORY_HOME/run/bwrap-shim/slot-<n>/`, and run.sh runs fleet as
   `ralon run -C <wt> -- env PATH=<shim dir>:$PATH <fleet> …`. The node's login PATH, the loop's PATH
   and ralon's PATH are unchanged. The shim execs the first `bwrap` on PATH that is neither itself nor
   in its own or its invoked directory, by absolute path; none → exit 127.
2. **It prepends, never edits** (I12). For each of `/usr /bin /sbin /lib /lib64 /etc/ssl
   /etc/resolv.conf /etc/hosts` that the argv does not already mount (a mount destination equal to the
   path, or `/`, which skips everything), it inserts before fleet's first argument:
   - `--symlink <target> <p>` for `/bin`, `/sbin`, `/lib`, `/lib64` when the host path is a symlink
     (merged usr; on this box all four are). A path that is both a `SYSTEM_ROOT` and such a link
     (`/lib`, `/lib64`) gets the `--symlink` only.
   - `--ro-bind <p> <p>` for the other existing members of fleet's own `SYSTEM_ROOTS`. A symlinked
     file such as WSL2's `/etc/resolv.conf` (→ `/mnt/wsl/resolv.conf`) is bound through: bwrap follows
     the source, and a `--symlink` would dangle inside the sandbox.

   bwrap mounts in argv order and a later mount wins, so every mount fleet passed still lands on top
   of the shim's. Only `--ro-bind` and `--symlink` are ever added: no writable bind, no network or
   namespace flag, nothing of fleet's dropped or moved. An argv the shim cannot read (`--help`,
   `--version`, `--args FD`, an option bwrap 0.9.0 does not have, a truncated option) passes through
   unchanged. The transformation is idempotent. On the four argv shapes fleet 1.12.0 builds
   (`tests/fixtures/bwrap-shim/`, captured from the real modules by `capture.sh`), it adds all eight
   entries to the canary and the repo-command plane, `/bin` and `/sbin` to the bounded model plane
   (fleet binds its `SYSTEM_ROOTS` there itself), and nothing to the host-read model plane (`--ro-bind
   / /`).
3. **Gated on the pin twice** (I13). run.sh builds the shim directory only when the fleet pin
   (`FACTORY_FLEET_PIN`, else the `<v>` of `@adlc/cli@<v>` in the fleet command) is exactly `1.12.0`,
   and removes a stale one otherwise. The shim reads the pin from `fleet-pin` beside the link it was
   invoked through (a file, not an env var, because fleet's env scrub would drop the variable) and is a
   pure pass-through at any other pin or none. The run ledger line records `.bwrap_shim` true/false.
4. **join and the probe say when the shim cannot help.** `probe.sh` reports `.sandbox.shim`
   (`bwrap-shim probe`: the real bwrap, what each host path gets, `merged_usr`, `ready`). join.sh warns,
   without refusing, when the shim is not ready (no real bwrap, no `/usr`) or the host is not merged
   usr.

## Consequences

- fleet's canary passes on this box and the repo-command plane can run `bash`. Measured by
  `tests/live/test_bwrap_shim_live.sh` (`make live`) through fleet's own `Sandbox` and `repoCommandEnv`:
  through the shim it prints `__fleet_canary_ok__`; without it, or with a shim at pin 1.12.1, it fails
  `execvp /bin/sh`; `touch /usr/x` fails `Read-only file system` and nothing reaches the host;
  `curl` in the canary's `--unshare-net` sandbox fails `(6) Could not resolve host`.
- fleet's repo-command plane, documented as "reads bounded to the worktree", now also reads the
  system roots its model plane already reads. They hold no factory secret; `/etc/ssl/private` keeps its
  host mode (root 0700) inside the bind. fleet's policy echo in `--json` does not list the shim's
  additions; the run ledger's `.bwrap_shim` is where they are recorded.
- **Known limit.** On a host whose `/bin` is a real directory (not merged usr) the shim binds only
  `SYSTEM_ROOTS`, so `/bin/sh` is still missing and the canary still fails; join warns. Binding a
  classic `/bin` would go past ruling Q1's "fleet's own system roots", so it waits for a ruling if a
  non-merged-usr node ever joins.
- One more moving part in front of the sandbox, which is why it carries its own test file, a live
  test and a removal list.

### Removal (I13): when a fleet that fixes #1266 is pinned

1. Re-pin fleet (`@adlc/cli@<fixed>`) in run.sh's fleet command, join.sh's install plan, the Makefile
   targets and wherever else `1.12.0` is the fleet pin. From that moment run.sh builds no shim
   directory and the shim is inert, so the steps below are cleanup, not a fix.
2. Run `make live` (the smoke must pass preflight without the shim), then delete:
   `factory/bin/lib/bwrap-shim`; in run.sh the shim block (`SHIM_DIR`, `FLEET_ENV`, the `env PATH=`
   prefix), `FLEET_PIN`/`FACTORY_FLEET_PIN` if nothing else reads it, the `.bwrap_shim` ledger field and
   the header lines about the shim; probe.sh's `.sandbox.shim` and its report line; join.sh's two shim
   warnings and their header lines; `tests/test_bwrap_shim.sh`, `tests/fixtures/bwrap-shim/`,
   `tests/live/test_bwrap_shim_live.sh`; the `bwrap-shim` path in the Makefile's `SH_FILES`; the
   `bwrap-shim` case in `tests/test_run.sh` (and `FACTORY_FLEET_PIN` in its `run_setup`, and the
   `env PATH=` prefix its `argv` case expects); the `shim-prereqs` case and the merged-usr probe root
   in `tests/test_join.sh`.
3. Mark this ADR superseded by the re-pin's ticket.

## References

- voodootikigod/adlc#1266 (upstream issue, body `specs/factory-step2-v1/records/upstream-fleet-canary-issue.md`),
  voodootikigod/adlc#639 (`canary` is not a config key).
- `specs/factory-step2-v1/RULINGS.md` Q1; `specs/factory-step2-v1/records/TB6.md` §3;
  `specs/factory-step2-followups-v1/SPEC.md` I12, I13, TB1; `.../records/TB1.md`.
- @adlc/fleet 1.12.0: `bin/fleet.mjs` (`dispatchCanary`), `lib/sandbox.mjs` (`Sandbox.wrap`),
  `lib/bounded-model-plane.mjs` (`SYSTEM_ROOTS`), `lib/env-scrub.mjs` (`repoCommandEnv`).
