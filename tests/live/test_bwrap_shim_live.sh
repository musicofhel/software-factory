#!/usr/bin/env bash
# T12 acceptance 5 against the REAL bwrap and the REAL @adlc/fleet 1.12.0 (`make live`, never
# `make test`): fleet's preflight canary run the way fleet runs it, through the bwrap shim
# (factory/bin/lib/bwrap-shim, ADR-0006). Prints `SKIP <reason>` and exits 0 only when a tool is
# absent.
#
# Each call reproduces bin/fleet.mjs dispatchCanary: a mkdtemp dir under os.tmpdir() with `.home` in
# it, `new Sandbox({mode, backend: detectBackend(), worktree, syntheticHome})` from fleet's own
# lib/sandbox.mjs, and `sb.run(argv, {env: repoCommandEnv(process.env, {syntheticHome})})`. The exec
# spawns argv[0] (`bwrap`, found on PATH) with that scrubbed env, so the PATH fleet would get from
# run.sh (`env PATH=<shim dir>:$PATH`) is the only thing that picks the shim. The shim directory is
# built as run.sh builds it: `bwrap` -> lib/bwrap-shim plus `fleet-pin`.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/../fakes/lib.sh"
echo "test_bwrap_shim_live"

[ "$(uname -s)" = Linux ] || { echo "SKIP not Linux (bubblewrap is the Linux sandbox backend)"; exit 0; }
for t in bwrap node npx npm curl jq; do
  command -v "$t" >/dev/null || { echo "SKIP $t not installed"; exit 0; }
done
FLEET="${FACTORY_FLEET_DIR:-}"
if [ -z "$FLEET" ]; then
  npx -y @adlc/cli@1.12.0 --version >/dev/null 2>&1 || { echo "SKIP @adlc/cli@1.12.0 not installable"; exit 0; }
  for p in "$(npm config get cache)"/_npx/*/node_modules/@adlc/fleet/package.json; do
    [ "$(jq -r .version "$p" 2>/dev/null)" = 1.12.0 ] && { FLEET="$(dirname "$p")"; break; }
  done
fi
[ -n "$FLEET" ] && [ -f "$FLEET/lib/sandbox.mjs" ] || { echo "SKIP no @adlc/fleet 1.12.0 in the npx cache"; exit 0; }

FAILED=0
info() { printf '    INFO %s\n' "$*"; }
info "$(bwrap --version 2>&1 | head -n1); @adlc/fleet $(jq -r .version "$FLEET/package.json") at $FLEET"
REAL_BWRAP="$(command -v bwrap)"

S="$(mktemp -d)"
trap 'rm -rf "$S"' EXIT
mkshim() {  # mkshim <dir> <pin>: what run.sh builds for a slot
  mkdir -p "$1"
  ln -s "$BIN/lib/bwrap-shim" "$1/bwrap"
  printf '%s\n' "$2" >"$1/fleet-pin"
}
mkshim "$S/shim" 1.12.0
mkshim "$S/shim-other" 1.12.1

# canary <PATH for fleet> <sh script>: the canary's sandbox running `/bin/sh -c <script>`. Prints one
# JSON object: {status, stdout, stderr, argv, tmp, mode, backend}. The canary's own script is
# `echo __fleet_canary_ok__`.
canary() {
  FLEET_DIR="$FLEET" FLEET_PATH="$1" SCRIPT="$2" node --input-type=module -e '
    import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
    import { tmpdir } from "node:os";
    import { join } from "node:path";
    import { spawnSync } from "node:child_process";
    const F = process.env.FLEET_DIR;
    const { Sandbox, SANDBOX_MODES, detectBackend } = await import(`${F}/lib/sandbox.mjs`);
    const { repoCommandEnv } = await import(`${F}/lib/env-scrub.mjs`);
    process.env.PATH = process.env.FLEET_PATH;
    const tmp = mkdtempSync(join(tmpdir(), "fleet-canary-"));
    mkdirSync(join(tmp, ".home"), { recursive: true });
    const backend = detectBackend();
    let res = { status: null, stdout: "", stderr: "" }, argv = null;
    const sb = new Sandbox({ mode: SANDBOX_MODES.SANDBOX, backend, worktree: tmp, syntheticHome: join(tmp, ".home"),
      exec: async (a, opts) => {
        argv = a;
        const r = spawnSync(a[0], a.slice(1), { cwd: opts.cwd, env: opts.env, encoding: "utf8", timeout: 60000 });
        res = { status: r.status, stdout: r.stdout ?? "", stderr: r.error ? String(r.error) : (r.stderr ?? "") };
        return res.stdout;
      } });
    await sb.run(["/bin/sh", "-c", process.env.SCRIPT], { env: repoCommandEnv(process.env, { syntheticHome: join(tmp, ".home") }) });
    rmSync(tmp, { recursive: true, force: true });
    console.log(JSON.stringify({ ...res, argv, tmp, mode: SANDBOX_MODES.SANDBOX, backend: backend?.name ?? null }));
  '
}
field() { jq -r "$1" <<<"$2"; }
HOST_PATH="$PATH"

# --- the canary, exactly
on="$(canary "$S/shim:$HOST_PATH" 'echo __fleet_canary_ok__')"
check "fleet's backend on this host is bubblewrap" eq "$(field .backend "$on")" bubblewrap
check "fleet's canary argv starts with a PATH-resolved bwrap (so the shim can sit first on PATH)" eq "$(field '.argv[0]' "$on")" bwrap
check "through the shim (pin 1.12.0) the canary prints __fleet_canary_ok__" eq "$(field '.stdout | contains("__fleet_canary_ok__")' "$on")" true
check "through the shim the canary exits 0" eq "$(field .status "$on")" 0
info "canary through the shim: status $(field .status "$on"), stdout $(field '.stdout | rtrimstr("\n")' "$on")"

# --- controls: without the shim (and with a shim at another pin) the canary fails as #1266 says
off="$(canary "$HOST_PATH" 'echo __fleet_canary_ok__')"
check "without the shim the canary fails (voodootikigod/adlc#1266)" eq "$(field '.status != 0 and (.stdout | contains("__fleet_canary_ok__") | not)' "$off")" true
check "without the shim the failure is the missing /bin/sh" eq "$(field '.stderr | test("execvp /bin/sh")' "$off")" true
info "canary without the shim: status $(field .status "$off"), stderr $(field '.stderr | rtrimstr("\n")' "$off")"
other="$(canary "$S/shim-other:$HOST_PATH" 'echo __fleet_canary_ok__')"
check "a shim at pin 1.12.1 passes the argv through, so the canary fails as without it (I13)" \
  eq "$(field '.status != 0 and (.stderr | test("execvp /bin/sh"))' "$other")" true
check "the shim at another pin still execs the real bwrap (the canary reached bwrap, not exit 127)" \
  eq "$(field '.status != 127' "$other")" true

# --- I12 live: the system roots are read-only, the worktree stays writable
probe=".factory-shim-live-$$"
w="$(canary "$S/shim:$HOST_PATH" "touch /usr/$probe")"
check "inside the shimmed canary, a write to /usr fails" eq "$(field '.status != 0' "$w")" true
check "the /usr write fails on a read-only file system" eq "$(field '.stderr | test("Read-only file system")' "$w")" true
check "nothing reached the host's /usr" eq "$([ -e "/usr/$probe" ] && echo present || echo absent)" absent
info "touch /usr/$probe: status $(field .status "$w"), stderr $(field '.stderr | rtrimstr("\n")' "$w")"
for d in /bin /etc/ssl; do
  w="$(canary "$S/shim:$HOST_PATH" "touch $d/$probe")"
  check "a write under $d fails too" eq "$(field '.status != 0' "$w")" true
  check "nothing reached the host's $d" eq "$([ -e "$d/$probe" ] && echo present || echo absent)" absent
done
w="$(canary "$S/shim:$HOST_PATH" 'touch "$PWD/wrote" && echo wrote-ok')"
check "the canary's own worktree stays writable (fleet's --bind is untouched)" eq "$(field '.stdout | contains("wrote-ok")' "$w")" true

# --- I12 live: the shim adds no network. The canary's profile passes --unshare-net; curl, now found
# through the shim's /usr, must still fail to reach anything.
check "the canary argv carries --unshare-net" eq "$(field '.argv | index("--unshare-net") != null' "$on")" true
outside="$(curl -sS -o /dev/null --max-time 15 -w '%{http_code}' https://example.com/ 2>/dev/null || true)"
check "outside any sandbox this host reaches example.com (else a deny proves nothing)" eq "$([ "${outside:0:1}" = 2 ] || [ "${outside:0:1}" = 3 ] && echo yes || echo "no ($outside)")" yes
n="$(canary "$S/shim:$HOST_PATH" 'curl -sS -o /dev/null --max-time 15 https://example.com/; echo "curl-exit=$?"')"
rc="$(field '.stdout | capture("curl-exit=(?<c>[0-9]+)").c // "none"' "$n")"
check "curl inside the shimmed --unshare-net sandbox fails to connect (exit 6 or 7, not 127/0)" eq "$( [ "$rc" = 6 ] || [ "$rc" = 7 ] && echo yes || echo "no (curl exit $rc)")" yes
info "curl inside: exit $rc, $(field '.stderr | rtrimstr("\n")' "$n")"

# --- the real bwrap the shim found is the host's, not itself
check "the shim's probe names the host's real bwrap" eq "$(PATH="$S/shim:$HOST_PATH" "$BIN/lib/bwrap-shim" probe | jq -r .bwrap)" "$REAL_BWRAP"

[ "$FAILED" = 0 ] && echo "PASS test_bwrap_shim_live" || echo "FAIL test_bwrap_shim_live ($FAILED)"
[ "$FAILED" = 0 ]
