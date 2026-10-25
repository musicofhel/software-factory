# TB1 — The bwrap shim and ADR-0006 (ticket T12; ruling Q1)

Sessions 2–3, 2026-10-25 (session 2 stopped at the soft gate with the code written and uncommitted;
session 3 finished it). No prep existed for this row (`specs/factory-step2-followups-v1/prep/` is
absent). Box: WSL2, bubblewrap 0.9.0, node v22, `@adlc/fleet` 1.12.0 from the npx cache
(`~/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc/fleet`). TB0 found no fixed fleet (`@adlc/cli`
1.12.0 newest, #1266 open), so this row is the shim, not a re-pin. Nothing was pushed (I1).

Commits: `7545a15` (`Ticket: scaffold`: T12's scope gains `Makefile`, body wording, §4) and the
`Ticket: T12` commit that carries this file.

## 1. What was built

| File | What |
|---|---|
| `factory/bin/lib/bwrap-shim` | The shim (its header is the design). Invoked as `bwrap`: reads `fleet-pin` beside the link it was invoked through; at exactly `1.12.0` prepends `--symlink <target> <p>` for `/bin /sbin /lib /lib64` that are host symlinks and `--ro-bind <p> <p>` for the other existing `SYSTEM_ROOTS` (`/usr /lib /lib64 /etc/ssl /etc/resolv.conf /etc/hosts`), skipping any path the argv already mounts and everything when it mounts `/`; then execs the first `bwrap` on PATH that is not itself (absolute dirs only; skips its own and its invoked dir and anything whose realpath is the shim); none → 127. An argv it cannot read (`--help`, `--version`, `--args`, an option not in bwrap 0.9.0's `--help`, a truncated option) passes through unchanged. Invoked as `bwrap-shim`: `argv <pin> [args]` (JSON array, no exec) and `probe` (JSON). `FACTORY_SHIM_ROOT` is a test-only host-root prefix. |
| `tests/fixtures/bwrap-shim/{canary,repo-command,bounded-model,host-read}.json` + `capture.sh` | The four argv shapes, captured from the real fleet 1.12.0 modules with `node -e` (§2). |
| `tests/test_bwrap_shim.sh` | 8 cases, 97 checks (§3). |
| `factory/bin/run.sh` | `FLEET_PIN` (`FACTORY_FLEET_PIN`, else the `<v>` of `@adlc/cli@<v>` in the fleet command). After the slot mutex: `rm -rf $FACTORY_HOME/run/bwrap-shim/slot-<n>`; at pin 1.12.0 recreate it with `bwrap -> lib/bwrap-shim` and `fleet-pin`, and run fleet as `ralon run -C <wt> -- env PATH=<shim dir>:$PATH <fleet> …`. The ledger line gains `.bwrap_shim` (true/false). |
| `factory/bin/lib/probe.sh` | `.sandbox.shim` = `bwrap-shim probe` on linux/wsl2 (`null` elsewhere), and a report line. |
| `factory/bin/join.sh` | Two warnings (not refusals): shim not ready (no real bwrap / no `/usr`); host not merged usr. |
| `tests/test_run.sh`, `tests/test_join.sh` | Case `bwrap-shim` (20 checks); case `shim-prereqs` (7); `run_setup` exports `FACTORY_FLEET_PIN=1.12.0`; the `argv` case expects the `env PATH=` prefix; join's probe root is merged usr by default. |
| `tests/live/test_bwrap_shim_live.sh` | `make live`, 20 checks (§5). |
| `docs/adr/0006-bwrap-shim-for-fleet-1-12-0.md`, `docs/adr/README.md` | The ADR (accepted under ruling Q1; cites #1266, upstream `455524c` L502–507; I13 removal steps); the README gains an index of 0001–0006. |
| `Makefile` | `SH_FILES` adds `-o -path factory/bin/lib/bwrap-shim` (it has no `.sh`, so `make lint` skipped it). |

Every changed path is in T12's scope (`jq -r '.scope[]' .adlc/tickets/t12--*.json`, after §4), apart
from this records file and the LEDGER (spec bookkeeping, as in every row).

## 2. The fixtures

```
$ bash tests/fixtures/bwrap-shim/capture.sh
captured from /home/musicofhel/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc/fleet: ./bounded-model.json ./canary.json ./host-read.json ./repo-command.json
$ git status --short tests/fixtures      # re-run in session 3: byte-identical to session 2's capture
 A tests/fixtures/bwrap-shim/…   (5 files, no modification)
```

`canary.json` (fleet's exact canary argv for `/tmp/fleet-canary-AbC123`):
`["bwrap","--unshare-net","--die-with-parent","--chdir",T,"--bind",T,T,"--bind",T/.home,T/.home,"--setenv","HOME",T/.home,"--","/bin/sh","-c","echo __fleet_canary_ok__"]`.

What the shim prepends on this box (`bwrap-shim argv 1.12.0 <fixture minus argv[0]>`, the prefix):

| shape | inserted |
|---|---|
| canary, repo-command | `--ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib --symlink usr/lib64 /lib64 --ro-bind /etc/ssl /etc/ssl --ro-bind /etc/resolv.conf /etc/resolv.conf --ro-bind /etc/hosts /etc/hosts` |
| bounded-model | `--symlink usr/bin /bin --symlink usr/sbin /sbin` (fleet binds its SYSTEM_ROOTS there itself) |
| host-read | nothing (`--ro-bind / /`) |

## 3. Offline proofs (`make test`)

`tests/test_bwrap_shim.sh`, cases `fixtures i12 inserts idempotent version-gate exec left-alone probe`:

- **I12 (acceptance 1)**: each of the 4 shapes × 3 host layouts under `FACTORY_SHIM_ROOT` (merged usr; a
  classic `/bin` directory; none of the paths). A jq parser independent of the shim's own (bwrap 0.9.0
  arities) reads before and after: the write-bind set, the network flags and the namespace flags are
  equal; the output is exactly `<inserted> + <input>` (nothing dropped or moved); every inserted
  option is `--ro-bind` or `--symlink`.
- **Exact insertions** per shape and layout (the table in §2 on merged usr).
- **Idempotence (acceptance 2)**: shim(shim(argv)) = shim(argv) on every shape and layout.
- **Version gate (acceptance 3)**: pins `1.12.1 1.13.0 1.11.9 2.0.0 1.12.0-rc.1 v1.12.0 "1.12.0 " ""`
  → output = input; in exec mode a `fleet-pin` of 1.13.0, or none, passes fleet's argv unchanged.
- **exec**: through a link to the shim in a slot-like dir with a recording fake bwrap later on PATH:
  the fake gets the transformed argv; a shim-of-shim (a second shim dir, the shim's own dir and a
  relative entry ahead of the real one) still reaches the real bwrap with the argv shimmed once; no
  real bwrap → 127, named on stderr.
- **left-alone**: `--help`, `--version`, `--args 3`, an option bwrap 0.9.0 lacks (`--overlay-src`, named on
  stderr), a truncated `--bind`.
- **probe**: merged usr ready; classic `/bin` not merged but ready; no bwrap and no `/usr` not ready.

`tests/test_run.sh` `bwrap-shim` (acceptance 4): pin read from `@adlc/cli@1.12.0` → fleet's PATH is
`<shim dir>:<node PATH>`, ralon's PATH is the node's, `env` sets PATH only, the dir holds only `bwrap`
(→ lib/bwrap-shim) and `fleet-pin` = `1.12.0`, ledger `.bwrap_shim = true`; pins 1.12.1 and 1.13.0 →
no `env`, stale dir removed, ledger false; `FACTORY_FLEET_PIN=1.12.1` with no version in the command
and no pin at all → no shim. `tests/test_join.sh` `shim-prereqs` (acceptance 6): merged usr → the
probe carries every path, no warning; `/bin` a directory → exit 0 with a warning naming `/bin/sh` and
#1266; no `/usr` → the "cannot run" warning; no bwrap → the sandbox refusal only; macOS → `shim: null`.

## 4. Desk change to T12 (`Ticket: scaffold`, `7545a15`)

`make lint`'s `SH_FILES` takes only `*.sh` and `tests/fakes/*`, so the extension-less shim would have
shipped unlinted (acceptance 7). `Makefile` was not in T12's scope, so the ticket changed first. The
body also said "exists on the host and is not a symlink", which TB0 gotcha 1 showed is wrong for
WSL2's `/etc/resolv.conf`; it now says a symlinked file is bound through and a path that is both a
SYSTEM_ROOT and a merged-usr link gets the `--symlink` only.

```
$ a ticket update T12 --input t12-new.json --expect 5966ee8cd52b…7432 --json
{"ok":false,"kind":"policy","code":"AUTHORIZATION_REQUIRED","message":"update requires authorization: scope-widening"}   exit=2
$ a ticket update T12 --input t12-new.json --expect 5966ee8cd52b…7432 --authorize --json      → changedFields [body, scope], sensitive [scope-widening], validation valid, dryRun true   exit=0
$ a ticket update T12 --input t12-new.json --expect 5966ee8cd52b…7432 --authorize --write --json → {"applied":true,"ticketHash":"f0482404634b…3a22"}   exit=0
$ a ticket doctor                       → All checks passed.   exit=0
$ a coldstart --all --offline --json    → ok true; T12–T16 pass, gaps []
$ a merge-forecast --json               → {"gateFailures":[],"waves":[["T12","T13"],["T15","T14"],["T16"]]}   exit=0
$ make -n lint | grep -o 'factory/bin/lib/bwrap-shim\|tests/live/test_bwrap_shim_live.sh'   → both listed
```

(`--authorize` for scope widening is the precedent of step-1 TB2; the manifest gained seq 13
`ticket-update`.)

## 5. Live proofs (`make live`: `tests/live/test_bwrap_shim_live.sh`)

Each call is fleet's `dispatchCanary` rebuilt from fleet's own modules: `mkdtemp(tmpdir(),
'fleet-canary-')` + `.home`, `new Sandbox({mode: SANDBOX, backend: detectBackend(), worktree,
syntheticHome})`, `sb.run(['/bin/sh','-c',<script>], {env: repoCommandEnv(process.env,
{syntheticHome})})`, with an exec that spawns argv[0] from that scrubbed env. Only the PATH differs
between calls, as it does between run.sh with and without the shim.

```
$ bash tests/live/test_bwrap_shim_live.sh
    INFO bubblewrap 0.9.0; @adlc/fleet 1.12.0 at /home/musicofhel/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc/fleet
    ok   fleet's backend on this host is bubblewrap
    ok   fleet's canary argv starts with a PATH-resolved bwrap (so the shim can sit first on PATH)
    ok   through the shim (pin 1.12.0) the canary prints __fleet_canary_ok__
    ok   through the shim the canary exits 0
    INFO canary through the shim: status 0, stdout __fleet_canary_ok__
    ok   without the shim the canary fails (voodootikigod/adlc#1266)
    ok   without the shim the failure is the missing /bin/sh
    INFO canary without the shim: status 1, stderr bwrap: execvp /bin/sh: No such file or directory
    ok   a shim at pin 1.12.1 passes the argv through, so the canary fails as without it (I13)
    ok   the shim at another pin still execs the real bwrap (the canary reached bwrap, not exit 127)
    ok   inside the shimmed canary, a write to /usr fails
    ok   the /usr write fails on a read-only file system
    ok   nothing reached the host's /usr
    INFO touch /usr/.factory-shim-live-4174917: status 1, stderr touch: cannot touch '/usr/.factory-shim-live-4174917': Read-only file system
    ok   a write under /bin fails too
    ok   nothing reached the host's /bin
    ok   a write under /etc/ssl fails too
    ok   nothing reached the host's /etc/ssl
    ok   the canary's own worktree stays writable (fleet's --bind is untouched)
    ok   the canary argv carries --unshare-net
    ok   outside any sandbox this host reaches example.com (else a deny proves nothing)
    ok   curl inside the shimmed --unshare-net sandbox fails to connect (exit 6 or 7, not 127/0)
    INFO curl inside: exit 6, curl: (6) Could not resolve host: example.com
    ok   the shim's probe names the host's real bwrap
PASS test_bwrap_shim_live
```

The control (no shim) is the no-false-green half: the same harness, the same fleet code, fails exactly
as #1266 describes, so the pass above is the shim's doing.

## 6. Gates (session 3, final tree, run concurrently)

| gate | result |
|---|---|
| `make test` | 15 files PASS (14 + `test_bwrap_shim.sh`), exit 0 |
| `make lint` | exit 0 (shellcheck `-S warning` over SH_FILES, now with the shim and the new live test; actionlint) |
| `bash tests/live/test_bwrap_shim_live.sh` | PASS (20 checks) |
| `bash tests/live/test_join_live.sh` | PASS |
| `bash tests/live/test_policy_live.sh` | PASS |
| `tests/live/test_smoke_live.sh` | **not run in TB1, on purpose.** With the shim in run.sh the smoke now gets past preflight and runs a real claude worker for up to its 15-minute budget; that run is TB5 Part A (ticket T16), where the evidence is recorded. |

## 7. Decisions and deviations

1. **Prepend, not "before fleet's own binds" by position-finding.** Prepending puts every insertion
   before every fleet argument, which satisfies the spec's order rule with no parsing of where fleet's
   binds start, and leaves fleet's argv a verbatim suffix (the I12 test checks exactly that).
2. **The pin is a file beside the link, not an env var**: fleet's `repoCommandEnv` scrubs the env
   before spawning bwrap and keeps PATH, so a variable would be gone; the directory on PATH is what
   survives.
3. **Gated twice** (run.sh does not build the dir; the shim passes through) so either alone holds I13.
4. **`FACTORY_FLEET_PIN`** is a new run.sh knob (tests; a fleet command that names no version). Without
   it and without `@adlc/cli@<v>` in the command, no shim.
5. **`/etc/resolv.conf` is bound through** (TB0 gotcha 1); `/lib` and `/lib64` get one `--symlink` each.
6. **Known limit (ADR-0006)**: a host whose `/bin` is a real directory still fails the canary, because
   the spec binds only `SYSTEM_ROOTS` plus merged-usr links; join warns. Not a question for Aaron now:
   every node so far is merged usr; it becomes one if a non-merged-usr node joins.
7. **The repo-command plane reads more**: with the shim, fleet's build/test sandbox also reads the
   system roots (read-only). Stated in ADR-0006's consequences; fleet's policy echo does not show it,
   the run ledger's `.bwrap_shim` does.
