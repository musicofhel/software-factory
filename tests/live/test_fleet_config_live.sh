#!/usr/bin/env bash
# specs/factory-step3-v1 TB5 against the REAL @adlc/fleet 1.12.0 (`make live`, never `make test`; no
# network once fleet is in the npx cache): main's `.adlc/config.json` fleet block, not a fixture's,
# is what fleet reads, gates on and preflights.
#
# The scratch repo is this repo's HEAD (`git archive`) with three files copied over it from the
# working tree: .adlc/config.json, factory/bin/build-test.sh and the Makefile (ticket T24 brings all
# three; once committed this is main's config as of this commit and the copy changes nothing). Then
# T-smoke, created by the real `adlc ticket create --write` as test_smoke_live.sh creates it, and one
# commit on `main`, so the tree is clean.
#
#   1. config   fleet's lib/config.mjs loadConfig (:51-60, `.fleet` of <dir>/config.json; a parse
#               error silently yields {}) and resolveRunConfig (:156-273), called the way fleet run
#               calls them (bin/fleet.mjs:173-187) with the flags run.sh passes (run.sh:19-20). Warnings
#               come back as resolveRunConfig's `warnings` array (:157, :271), which fleet run prints
#               (bin/fleet.mjs:191); there must be none.
#   2. preflight  bin/fleet.mjs runLive (:443), its default io (lib/live-deps.mjs:98 defaultIo) and its
#               default preflight (lib/preflight.mjs:54 runPreflight), which checks, in order: a gate
#               (:63-64), the sandbox backend, bwrap on PATH (:68-70, lib/sandbox.mjs:74-78), the repo
#               lock .adlc/fleet.lock (:73-78; gitignored), a clean tree (:81-82), the rail hook (:85-86,
#               a warning only: bin/fleet.mjs:476-479), the canary through fleet's own Sandbox
#               (:89-95, bin/fleet.mjs:486-499; it needs the factory bwrap shim first on PATH, as
#               run.sh gives it, test_bwrap_shim_live.sh), and merge-forecast (:98-103, evidence only:
#               `adlc` on PATH, live-deps.mjs:107-110). No claude binary, adapter or credential is
#               involved before dispatch. Only the two steps AFTER preflight are stubbed: `build`
#               (buildLiveDeps, which resolves the adapter and builds worktrees, bin/fleet.mjs:581) and
#               `run` (runFleet, the dispatch, :588). Each records that it was reached and does no work;
#               `emit` captures the --json result document instead of printing it.
#   3. I17      fleet's runGates (lib/gates.mjs:34-47, each command as ['/bin/sh','-c',cmd] at :21) on
#               a recording sandbox runs exactly the argv list `factory/bin/build-test.sh --list` gives
#               CI for the same config.
#   4. control  the same repo with `.fleet` deleted (one more commit, so the tree stays clean): the
#               real preflight refuses with fleet's own reason (preflight.mjs:63-64) and neither stub
#               is reached. Then the commit is dropped again.
#   5. INFO     `make lint` in fleet's real repo-command plane (its Sandbox, lib/env-scrub.mjs:108
#               repoCommandEnv, through the shim), the approach of specs/factory-step3-v1 TB5's plane
#               probe. Printed, never a check.
#
# Prints `SKIP <reason>` and exits 0 when Linux, bwrap, node, npx, npm, jq, git or fleet 1.12.0 is
# absent.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/../fakes/lib.sh"
echo "test_fleet_config_live"

[ "$(uname -s)" = Linux ] || { echo "SKIP not Linux (bubblewrap is the Linux sandbox backend)"; exit 0; }
for t in bwrap node npx npm jq git; do
  command -v "$t" >/dev/null || { echo "SKIP $t not installed"; exit 0; }
done
FLEET="${FACTORY_FLEET_DIR:-}"
if [ -z "$FLEET" ]; then
  npx -y @adlc/cli@1.12.0 --version >/dev/null 2>&1 || { echo "SKIP @adlc/cli@1.12.0 not installable"; exit 0; }
  for p in "$(npm config get cache)"/_npx/*/node_modules/@adlc/fleet/package.json; do
    [ "$(jq -r .version "$p" 2>/dev/null)" = 1.12.0 ] && { FLEET="$(dirname "$p")"; break; }
  done
fi
[ -n "$FLEET" ] && [ -f "$FLEET/bin/fleet.mjs" ] || { echo "SKIP no @adlc/fleet 1.12.0 in the npx cache"; exit 0; }

info() { printf '    INFO %s\n' "$*"; }
quiet() { "$@" >/dev/null 2>&1; }
info "@adlc/fleet $(jq -r .version "$FLEET/package.json") at $FLEET"

S="$(mktemp -d)"
trap 'chmod -R u+w "$S" 2>/dev/null; rm -rf "$S"' EXIT
R="$S/repo"
mkdir -p "$S/shim" "$R"
ln -s "$BIN/lib/bwrap-shim" "$S/shim/bwrap"   # what run.sh builds for a slot (run.sh:181-187)
printf '1.12.0\n' >"$S/shim/fleet-pin"
# The node calls below see no operator ADLC_* setting (e.g. a quartermaster registry): this box's
# defaults, not the caller's shell.
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep -E '^ADLC_' || true)

# ---- the scratch repo: HEAD + the working tree's T24 files + T-smoke, committed ---------------------
git -C "$REPO_ROOT" archive HEAD | tar -x -C "$R"
for f in .adlc/config.json factory/bin/build-test.sh Makefile; do
  [ -f "$REPO_ROOT/$f" ] && command cp -p "$REPO_ROOT/$f" "$R/$f"
done
check "the scratch config carries a fleet block" eq "$(jq -r '.fleet | type' "$R/.adlc/config.json")" object
body="$(printf '%s\n' 'weight: light' 'tier: 0' 'charter: C5' '' \
  'Add an executable shell script `hello.sh` at the repository root that prints hello, on one line, and exits 0. Add `tests/test_hello.sh`, a bash test that runs ./hello.sh, compares its output with hello, prints PASS or FAIL and exits non-zero on a mismatch. Touch nothing else.' '' \
  'Acceptance criteria:' \
  '1. ./hello.sh prints hello and exits 0. Verify: `test "$(./hello.sh)" = hello`.' \
  '2. tests/test_hello.sh passes against hello.sh and fails when hello.sh prints anything else. Verify: `bash tests/test_hello.sh`.')"
jq -n --arg b "$body" '{id: "T-smoke", title: "Add hello.sh that prints hello, with a test", category: "feature",
    duration: 1, scope: ["hello.sh", "tests/test_hello.sh"], rails: ["factory/policy/**"], edges: [], body: $b}' >"$S/t-smoke.json"
# Unsigned, as test_smoke_live.sh writes it: the store is a frozen trust root (ruling Q1 of
# specs/factory-run-calls-v1).
rc=0
(cd "$R" && npx -y @adlc/cli@1.12.0 ticket create --input "$S/t-smoke.json" --write --allow-unsigned --json) >"$S/ticket-create.json" 2>"$S/ticket-create.err" || rc=$?
check "adlc ticket create --write T-smoke exits 0" eq "$rc" 0
check "T-smoke is in the scratch store" quiet ls "$R/.adlc/tickets/"t-smoke--*.json
commit() {  # commit <message>: everything, on main
  git -C "$R" add -A
  git -C "$R" -c user.name=fleet-config-live -c user.email=fleet-config-live@factory.invalid -c commit.gpgsign=false \
    commit -q --no-verify -m "$1"
}
git -C "$R" init -q -b main
commit "scratch: HEAD + working-tree T24 files + T-smoke"
check "the scratch tree is clean (fleet's preflight refuses a dirty one)" eq "$(git -C "$R" status --porcelain | wc -l)" 0
SHA="$(git -C "$R" rev-parse HEAD)"

# fleetjs <mode>: one node process importing fleet 1.12.0 by absolute path; prints one JSON object.
# The config is resolved as `fleet run` resolves it (bin/fleet.mjs:173-187) from the argv run.sh
# passes (run.sh:19-20). Modes: config | gates | live.
FLEET_ARGV="$(jq -cn --arg sha "$SHA" '["--tickets", "T-smoke", "--concurrency", "1", "--no-pr", "--no-complete",
  "--base", $sha, "--adapter", "claude-code", "--max-strikes", "2", "--wall-clock-minutes", "15", "--json"]')"
fleetjs() {
  (cd "$R" && PATH="$S/shim:$PATH" MODE="$1" FLEET_DIR="$FLEET" REPO="$R" FLEET_ARGV="$FLEET_ARGV" node --input-type=module -e '
    import { join } from "node:path";
    import { existsSync } from "node:fs";
    const F = process.env.FLEET_DIR, repo = process.env.REPO, mode = process.env.MODE;
    const dir = join(repo, ".adlc");
    const { loadConfig, resolveRunConfig } = await import(`${F}/lib/config.mjs`);
    const fleet = await import(`${F}/bin/fleet.mjs`);   // no argv[1]: the CLI does not run (bin/fleet.mjs:289-300)
    const flags = fleet.parseFlags(JSON.parse(process.env.FLEET_ARGV));
    const ext = fleet.extensionFlags(flags);
    const raw = loadConfig(dir);
    const config = resolveRunConfig(raw, {
      concurrency: flags.concurrency ? Number(flags.concurrency) : undefined,
      base: flags.base,
      disposableContainer: flags["i-am-in-a-disposable-container"] === true,
      adapter: flags.adapter, model: flags.model, modelAuthKey: flags["model-auth-key"],
      adapterCommand: flags["adapter-command"] ?? undefined,
      adapterArgs: flags["adapter-args"] ? flags["adapter-args"].split(",") : undefined,
      modelPlaneWritable: flags["model-plane-writable"] ?? undefined,
      ...ext,
    });
    const out = (o) => { process.stdout.write(JSON.stringify(o) + "\n"); process.exit(0); };
    if (mode === "config") {
      out({ raw, gate: config.gate, allowedCommands: config.allowedCommands, prosecuteFailOn: config.prosecuteFailOn,
            timeoutMinutes: config.timeoutMinutes, warnings: config.warnings });
    } else if (mode === "gates") {
      const { runGates } = await import(`${F}/lib/gates.mjs`);
      const argv = [];
      const sandbox = { run: async (a) => { argv.push(a); return ""; } };
      const r = await runGates(sandbox, config.gate, {}, {});
      out({ ok: r.ok, keys: r.results.map((x) => x.key), argv });
    } else if (mode === "live") {
      const { loadPlan } = await import(`${F}/lib/plan.mjs`);
      const tf = loadPlan(join(dir, "tickets.json"));   // as fleet run loads it (bin/fleet.mjs:193-199)
      const all = tf.tickets ?? tf;
      const onlyIds = flags.tickets ? flags.tickets.split(",").map((s) => s.trim()) : undefined;
      const stderr = [];
      console.error = (...a) => { stderr.push(a.map(String).join(" ")); };
      const rec = { build: null, run: null, emitted: null };
      const code = await fleet.runLive({ repo, dir, all, config, onlyIds, json: flags.json === true }, {
        build: ({ config: rc, sandboxSpec }) => {
          rec.build = { sandboxMode: rc.sandboxMode, backend: sandboxSpec?.backend?.name ?? null, baseSha: rc.baseSha, gate: rc.gate };
          return { describeSandbox: () => ({ stub: "build" }) };
        },
        run: async ({ all: tickets, config: rc }) => {
          rec.run = { tickets: tickets.filter((t) => (rc.onlyIds ?? []).includes(t.id)).map((t) => t.id) };
          return { merged: 0, results: {}, integrationBranch: null };
        },
        emit: (doc) => { rec.emitted = doc; },
      });
      const pf = stderr.find((l) => l.startsWith("preflight failed: "));
      out({ code, ticketErrors: tf.errors ?? [], ...rec, preflightFailed: pf ? pf.slice(18) : null,
            stderr, lockLeft: existsSync(join(dir, "fleet.lock")) });
    }
  ')
}

# ---- 1. the config parses for fleet, with no warning -------------------------------------------------
echo "  1. main's config through fleet's loadConfig + resolveRunConfig"
cfg="$(fleetjs config 2>"$S/config.err")" || true
check "fleet's loadConfig reads the file's .fleet block whole (a parse error would read {})" \
  eq "$(jq -cS .raw <<<"$cfg" 2>/dev/null)" "$(jq -cS .fleet "$R/.adlc/config.json")"
check "resolved gate is {build: make lint, test: make test}" eq "$(jq -cS .gate <<<"$cfg" 2>/dev/null)" '{"build":"make lint","test":"make test"}'
check "resolved allowedCommands equal the file's" eq "$(jq -c .allowedCommands <<<"$cfg" 2>/dev/null)" "$(jq -c .fleet.allowedCommands "$R/.adlc/config.json")"
check "resolved prosecuteFailOn is medium" eq "$(jq -r .prosecuteFailOn <<<"$cfg" 2>/dev/null)" medium
check "resolved timeoutMinutes is 30" eq "$(jq -r .timeoutMinutes <<<"$cfg" 2>/dev/null)" 30
check "resolveRunConfig returns no warning" eq "$(jq -c .warnings <<<"$cfg" 2>/dev/null)" "[]"

# ---- 2. the real preflight passes on main's config ----------------------------------------------------
echo "  2. fleet's runLive on T-smoke: real io and preflight, stubbed build and run"
live="$(fleetjs live 2>"$S/live.err")" || true
lf() { jq -r "$@" <<<"$live" 2>/dev/null; }
check "fleet loads the scratch store without error, T-smoke in it" eq "$(lf '.ticketErrors | length')" 0
check "the real preflight did not refuse" eq "$(lf '.preflightFailed // "none"')" none
check "the build stub was reached (preflight passed): sandbox mode on bubblewrap, base = the scratch HEAD" \
  eq "$(lf '"\(.build.sandboxMode) \(.build.backend) \(.build.baseSha)"')" "sandbox bubblewrap $SHA"
check "the build stub got main's gate" eq "$(lf -cS '.build.gate')" '{"build":"make lint","test":"make test"}'
check "the run stub was reached with T-smoke selected" eq "$(lf -c '.run.tickets')" '["T-smoke"]'
check "runLive exits 0 and its --json document says so" eq "$(lf '"\(.code) \(.emitted.exitCode) \(.emitted.reason)"')" "0 0 null"
check "the preflight lock is released" eq "$(lf .lockLeft)" false
info "fleet's stderr: $(lf '.stderr | map(gsub("\\s+"; " ") | ltrimstr(" ") | .[0:160]) | join(" | ")')"
[ -n "$(lf '.build // empty')" ] || sed -n '1,30p' "$S/live.err"

# ---- 3. I17: fleet's runGates and build-test.sh run one argv list --------------------------------------
echo "  3. I17: fleet's runGates vs build-test.sh --list on the same config"
gates="$(fleetjs gates 2>"$S/gates.err")" || true
list="$(bash "$R/factory/bin/build-test.sh" --config "$R/.adlc/config.json" --list 2>"$S/list.err")" || true
check "fleet's runGates ran every gate (recording sandbox), build then test" eq "$(jq -c '[.ok, .keys]' <<<"$gates" 2>/dev/null)" '[true,["build","test"]]'
check "build-test.sh --list lists the same keys" eq "$(jq -c '[.[].key]' <<<"$list" 2>/dev/null)" '["build","test"]'
check "fleet's argv list equals build-test.sh's (CI and node run one command list)" \
  eq "$(jq -c .argv <<<"$gates" 2>/dev/null)" "$(jq -c '[.[].argv]' <<<"$list" 2>/dev/null || echo "build-test.sh failed")"
info "argv: $(jq -c .argv <<<"$gates" 2>/dev/null)"

# ---- 4. control: no fleet block, the real preflight refuses -------------------------------------------
echo "  4. control: the same repo with .fleet deleted"
jq 'del(.fleet)' "$R/.adlc/config.json" >"$S/cfg.tmp" && mv "$S/cfg.tmp" "$R/.adlc/config.json"
commit "scratch: no fleet block"
live="$(fleetjs live 2>"$S/live-nofleet.err")" || true
check "the real preflight refuses with fleet's reason: fleet.gate must define ..." \
  eq "$(lf '.preflightFailed // "none" | test("^fleet\\.gate must define a build and/or test command")')" true
check "neither the build nor the run stub was reached" eq "$(lf '"\(.build) \(.run)"')" "null null"
check "runLive exits 1 with reason preflight" eq "$(lf '"\(.code) \(.emitted.exitCode) \(.emitted.reason)"')" "1 1 preflight"
info "fleet's reason: $(lf .preflightFailed)"
git -C "$R" reset -q --hard HEAD~1

# ---- 5. INFO: make lint in fleet's repo-command plane ---------------------------------------------------
echo "  5. INFO: make lint in fleet's repo-command plane"
plane="$(cd "$R" && PATH="$S/shim:$PATH" FLEET_DIR="$FLEET" WT="$R" SCRIPT="make lint" node --input-type=module -e '
  import { mkdirSync } from "node:fs";
  import { join } from "node:path";
  import { spawnSync } from "node:child_process";
  const F = process.env.FLEET_DIR;
  const { Sandbox, SANDBOX_MODES, detectBackend } = await import(`${F}/lib/sandbox.mjs`);
  const { repoCommandEnv } = await import(`${F}/lib/env-scrub.mjs`);
  const wt = process.env.WT, home = join(wt, ".fleet-home");
  mkdirSync(home, { recursive: true });
  let res = { status: null, stdout: "", stderr: "" };
  const sb = new Sandbox({ mode: SANDBOX_MODES.SANDBOX, backend: detectBackend(), worktree: wt, syntheticHome: home,
    exec: async (a, opts) => {
      const r = spawnSync(a[0], a.slice(1), { cwd: wt, env: opts.env, encoding: "utf8", timeout: 600000, maxBuffer: 1 << 28 });
      res = { status: r.status, stdout: r.stdout ?? "", stderr: r.error ? String(r.error) : (r.stderr ?? "") };
      return res.stdout;
    } });
  await sb.run(["/bin/sh", "-c", process.env.SCRIPT], { env: repoCommandEnv(process.env, { syntheticHome: home }) });
  console.log(JSON.stringify(res));
' 2>"$S/plane.err")" || true
prc="$(jq -r '.status // "null"' <<<"$plane" 2>/dev/null || echo "no-result")"
pline="$(jq -r '[(.stderr, .stdout) | split("\n")[] | select(test("\\S"))] | if $rc == "0" then .[-1] else .[0] end // ""' \
  --arg rc "$prc" <<<"$plane" 2>/dev/null || sed -n 1p "$S/plane.err")"
echo "    INFO: make lint in fleet's plane: rc=$prc (${pline:0:200})"

[ "$FAILED" = 0 ] && echo "PASS test_fleet_config_live" || echo "FAIL test_fleet_config_live ($FAILED)"
[ "$FAILED" = 0 ]
