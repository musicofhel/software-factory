# Draft upstream issue for voodootikigod/adlc (NOT filed; filing is Aaron's call)

Title: fleet: preflight canary cannot pass on any bubblewrap host (no system root bound, `/bin/sh` missing)

Body:

`fleet run` without `--dry-run` fails preflight on every Linux node using the bubblewrap backend:

```
preflight failed: preflight canary failed (permission plumbing not working): bwrap: execvp /bin/sh: No such file or directory
```

Version: `@adlc/cli` 1.12.0 (newest on npm). Also present on `main` at 455524c (`packages/fleet/bin/fleet.mjs` L502–507).
Host: Ubuntu 24.04 (WSL2), bubblewrap 0.9.0.

Cause: `dispatchCanary` in `bin/fleet.mjs` builds `new Sandbox({ mode, backend, worktree: tmp, syntheticHome, exec })`
with no `readOnlyPaths` and no `readPolicy`. `lib/sandbox.mjs` defaults to the bounded read policy with
`readOnlyPaths = []`, so `buildSandboxArgv` binds only the write roots. No `/usr` is bound, so `/bin/sh`
does not exist inside the sandbox, on merged-usr and split-usr layouts alike. Only the model plane
(`lib/extensions.mjs`, `SYSTEM_ROOTS`) adds the system roots.

The canary cannot be skipped either: `config.canary === false` is checked, but `resolveRunConfig` never
sets `canary` (same family as #639).

Reproduction with the canary's own argv shape:

```
T=$(mktemp -d); mkdir $T/.home
bwrap --unshare-net --die-with-parent --chdir $T --bind $T $T --bind $T/.home $T/.home \
  --setenv HOME $T/.home -- /bin/sh -c 'echo __fleet_canary_ok__'
# bwrap: execvp /bin/sh: No such file or directory   (rc=1)
bwrap --unshare-net --die-with-parent --chdir $T --bind $T $T --bind $T/.home $T/.home \
  --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
  --setenv HOME $T/.home -- /bin/sh -c 'echo ok'
# ok   (rc=0)
```

Suggested fix: give the canary the same `SYSTEM_ROOTS` (filtered by existence) as `readOnlyPaths` that the
bounded model plane uses, plus the `/bin`, `/lib`, `/lib64` symlinks on merged-usr hosts. That proves the
plumbing the real planes use instead of a configuration no real plane runs with.

`fleet run --dry-run` never runs the canary, so the failure only shows on the first live dispatch.
