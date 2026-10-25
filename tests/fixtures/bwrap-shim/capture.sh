#!/usr/bin/env bash
# Captures the four bwrap argv shapes @adlc/fleet 1.12.0 builds (ticket T12), by calling the real
# modules with `node -e`, into this directory: one JSON array per shape, argv[0] included. Paths are
# fixed strings shaped like fleet's own (the canary's mkdtemp dir, a loop worktree, the synthetic
# HOME), so the fixtures do not depend on the box; the argv builders are pure and read no file.
#
#   canary.json         bin/fleet.mjs dispatchCanary: Sandbox on the repo-command profile (network
#                       denied, bounded reads), worktree = the canary's tmp dir, synthetic HOME in it
#   repo-command.json   lib/live-deps.mjs sandboxFor: the same profile over a ticket worktree
#   bounded-model.json  lib/extensions.mjs → lib/bounded-model-plane.mjs buildBoundedModelPlaneArgv:
#                       the model plane run.sh asks for (--model-plane-read bounded, egress allowlist
#                       → --unshare-net), read-only set = SYSTEM_ROOTS present on a merged-usr host +
#                       node + the adapter executable, the synthetic HOME's leaves
#   host-read.json      lib/live-deps.mjs modelSandboxFor: READ_POLICY.HOST, NETWORK.ALLOW (the
#                       model plane without --model-plane-read bounded): `--ro-bind / /`
#
#   tests/fixtures/bwrap-shim/capture.sh [<@adlc/fleet dir>]
# Without an argument it primes the npx cache (`npx -y @adlc/cli@1.12.0 --version`) and uses the
# @adlc/fleet 1.12.0 found there. Needs node and npx; writes only the four fixtures.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
F="${1:-}"
if [ -z "$F" ]; then
  npx -y @adlc/cli@1.12.0 --version >/dev/null
  cache="$(npm config get cache)"
  for p in "$cache"/_npx/*/node_modules/@adlc/fleet/package.json; do
    [ "$(jq -r .version "$p" 2>/dev/null)" = 1.12.0 ] && { F="$(dirname "$p")"; break; }
  done
fi
[ -n "$F" ] && [ "$(jq -r .version "$F/package.json")" = 1.12.0 ] || { echo "capture: no @adlc/fleet 1.12.0 (got '${F:-none}')" >&2; exit 1; }

FLEET_DIR="$F" OUT_DIR="$here" node --input-type=module -e '
  import { writeFileSync } from "node:fs";
  const F = process.env.FLEET_DIR, OUT = process.env.OUT_DIR;
  const { Sandbox, SANDBOX_MODES, NETWORK, READ_POLICY } = await import(`${F}/lib/sandbox.mjs`);
  const { buildBoundedModelPlaneArgv, SYSTEM_ROOTS } = await import(`${F}/lib/bounded-model-plane.mjs`);
  const bwrap = { name: "bubblewrap", platform: "linux" };
  const save = (name, argv) => writeFileSync(`${OUT}/${name}.json`, JSON.stringify(argv) + "\n");

  const canaryTmp = "/tmp/fleet-canary-AbC123";
  save("canary", new Sandbox({ mode: SANDBOX_MODES.SANDBOX, backend: bwrap, worktree: canaryTmp,
    syntheticHome: `${canaryTmp}/.home` }).wrap(["/bin/sh", "-c", "echo __fleet_canary_ok__"]));

  const wt = "/home/node/factory/.worktrees/T-1/.fleet/worktrees/t-1";
  save("repo-command", new Sandbox({ mode: SANDBOX_MODES.SANDBOX, backend: bwrap, worktree: wt,
    syntheticHome: `${wt}/.fleet-home` }).wrap(["bash", "-c", "bash tests/test_hello.sh"]));

  const home = "/home/node", stage = "/tmp/fleet-stage-XyZ789";
  const node = "/home/node/.nvm/versions/node/v22.22.0/bin/node";
  const claude = "/home/node/.local/share/claude/versions/2.1.280";
  save("bounded-model", buildBoundedModelPlaneArgv({
    worktree: wt,
    writableRoots: [`${stage}/egress`],
    readOnlyPaths: [...SYSTEM_ROOTS, `${F}/lib/egress-bridge.mjs`, node, claude],
    home,
    homeBinds: [
      { source: `${stage}/home/.claude/.credentials.json`, target: `${home}/.claude/.credentials.json` },
      { source: `${stage}/home/.claude/settings.json`, target: `${home}/.claude/settings.json` },
    ],
    homeWritableFiles: [{ source: `${stage}/home/.claude.json`, target: `${home}/.claude.json` }],
    homeScratchDirs: [`${home}/.claude/projects`, `${home}/.claude/todos`, `${home}/.cache/claude`],
    unshareNet: true,
    isFile: (p) => !SYSTEM_ROOTS.includes(p),
  }, [claude, "-p", "--output-format", "json"]).map((a) => a.replace(F, "/opt/adlc/fleet")));

  save("host-read", new Sandbox({ mode: SANDBOX_MODES.SANDBOX, backend: bwrap, worktree: wt, syntheticHome: null,
    writablePaths: [`${home}/.claude`, `${home}/.claude.json`, "/tmp"], network: NETWORK.ALLOW,
    readPolicy: READ_POLICY.HOST }).wrap(["claude", "-p", "--output-format", "json"]));
'
echo "captured from $F: $(cd "$here" && ls ./*.json | tr '\n' ' ')"
