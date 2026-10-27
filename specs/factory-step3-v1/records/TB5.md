# TB5 — main's `fleet` block and the build-test gate from the base config (ticket T24)

Sessions 10 and 11, 2026-10-26. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2. Base: `cba5a89`
(TB4 + ledger). Nothing was pushed and nothing was written to GitHub, the repo's own store or
`~/.factory` (I1, I19). The only network use was read-only PyPI metadata (§1) and the `uv tool
install`s on this box named in §1. Every world is a temp dir. No prep exists for this spec.

**State: done.** Fixes node:G10 and merge:G19 (ruling Q3 of factory-step2-followups-v1). It opens one
question for Aaron, HANDOFF Q1: `make test` cannot pass inside fleet 1.12.0's repo-command plane (§1).

## 1. Measured this row

### fleet 1.12.0's config reader (`@adlc/fleet`, the npx cache of `@adlc/cli@1.12.0`)

- `lib/config.mjs:16-25` DEFAULTS (`reviewMaxBytes` 262144 at `:25`); `:44-48`
  OPERATOR_LOCAL_EXTENSION_KEYS (noPr, noComplete, deadEndFile, maxStrikes, wallClockMinutes,
  charterFile, preStrikeArgv, preStrikeEnv, modelPlaneRead, modelPlaneReadOnly, modelPlaneGit,
  modelPlaneGitMirror, modelPlaneEgress, workerDeps); `:51-60` loadConfig (`.fleet` of
  `.adlc/config.json`; a parse error silently yields `{}`).
- `:156-273` resolveRunConfig. The repo keys it reads are gate, init, allowedCommands, concurrency,
  base, timeoutMinutes, prosecuteFailOn, reviewBin, reviewProvider, reviewMaxBytes (`:209-219`, checked at
  `:203-207`) and adapterStdin (`:245`, honored only when `=== true`). It warns about and ignores
  disposableContainer, adapterCommand, adapterArgs, adapter, model, modelAuthKey and
  modelPlaneWritable (`:158-198`), and also every OPERATOR_LOCAL_EXTENSION_KEYS key (`:196-198`).
  Warnings come back as the returned `warnings` (`:157`, `:271`) and `fleet run` prints them
  (`bin/fleet.mjs:191`).
- `lib/preflight.mjs:63-64`: no gate, or neither build nor test, refuses ("fleet.gate must define a
  build and/or test command in .adlc/config.json; an ungated fleet must not run").
- `lib/gates.mjs:21` runs each command as `['/bin/sh','-c',cmd]`; `:34-47` runGates does build, then
  test, skips an empty one and stops at the first failure.
- `lib/prosecute.mjs:11` SEVERITY_ORDER is low|medium|high|critical, and an unknown value falls back to
  medium silently (`:26`). timeoutMinutes is never validated (`lib/live-deps.mjs:255` multiplies it).
  So the `test_policy.sh` fleet-config case is the only guard for both.
- `lib/adapters/claude-code.mjs:100-122` buildSettings turns init, gate.build, gate.test and each
  allowedCommands entry into a `Bash(<cmd>)` rule, so allowedCommands need not repeat the gates.
- `lib/live-deps.mjs:662` runs the gates on the integration worktree. `envPassthrough`
  (`live-deps.mjs:291`) is never set by resolveRunConfig, so it is not a usable key.

### fleet's repo-command plane (session 10, scratch `.spec-loop/tb5/plane.sh`)

`plane.sh <wt> <script>` runs a script exactly as fleet runs a gate: fleet's own `Sandbox`
(`lib/sandbox.mjs:146-177`, the BOUNDED read policy), `repoCommandEnv` and a synthetic HOME, through
the factory bwrap shim at pin 1.12.0.

- The plane binds only the worktree, `<wt>/.fleet-home` (as HOME) and the shim's system roots, and it has
  `--unshare-net`. It has **no `/dev`, no `/proc`, no `/tmp` and no `/etc`** beyond `/etc/ssl`,
  resolv.conf and hosts. It has no `$HOME`, so `~/.local/bin` and `~/.nvm` are invisible. PATH
  passes through, but only `/usr/bin` tools resolve: bash, make, jq and git do; shellcheck, uvx and node
  do not. The root tmpfs is writable (`mkdir /tmp` works).
- The **old `make lint`** in the plane exits 2: `bash: /dev/null: No such file or directory`, then
  "lint: shellcheck not found".
- The **old `make test`** in the plane fails from the first suite (`mktemp: … /tmp/vc.XXXXXX: No such
  file or directory`).
- The **new lint recipe** in the plane passes (rc 0: `lint: shellcheck 0.11.0 at /opt/sc/shellcheck`,
  `actionlint ok`) with shellcheck 0.11.0 and actionlint ro-bound at /opt/sc (scratch `shimB`). So
  gate.build works in fleet's plane once shellcheck sits under a system root.
- **`make test` with `--dev /dev --proc /proc --tmpfs /tmp` added** (scratch `shimA`, an experiment,
  not the factory shim): 7 suites pass and 13 fail. The first cause is `awk: command not found`:
  `/usr/bin/awk` links to `/etc/alternatives/awk`, and `/etc` is not bound.
- **Session 11, live** (test_fleet_config_live.sh step 5, INFO): `make lint` in fleet's real plane on
  this box gives rc=2 (`lint: shellcheck not found: install it (join.sh prints how), or set
  SHELLCHECK`). This box's only shellcheck is `~/.local/bin`.

### Tools

- PyPI, read-only: shellcheck-py 0.11.0.1 (MIT) and actionlint-py 1.7.12.25.
- This box: `uv tool install shellcheck-py==0.11.0.1` and `uv tool install actionlint-py==1.7.12.25`,
  both in user space under `~/.local/bin`. `make lint` needs them now that the uvx fallback is gone. There
  is no system shellcheck, so join now refuses this box (§2), and the kit line is `sudo apt-get install
  shellcheck`.

## 2. What was built

- **`.adlc/config.json`** (a desk commit; `.adlc/**` is outside every ticket's scope): `fleet` =
  `gate {build: "make lint", test: "make test"}`, `allowedCommands ["bash tests/:*", "make sim",
  "./factory/test.sh", "chmod +x:*"]`, `prosecuteFailOn "medium"`, `timeoutMinutes 30`. The last two
  equal fleet's defaults and are written so the desk owns them. The adapter, the model and the key
  stay CLI-only. `adlc ticket doctor` is ok and `merge-forecast --json` exits 0 with the block in place.
- **`factory/bin/build-test.sh`** (new): runs `fleet.gate` from the config beside the script (the
  base's in CI, I16) or from `--config`. It runs build, then test, each as `/bin/sh -c`, in the cwd, and
  stops at the first failure. `--list` prints `[{key, command, argv}]`. Exit 0 pass, 2 a gate failed,
  1 unusable config (missing, not a JSON object, a non-string gate value, no command, which is
  preflight.mjs:63-64's refusal too). It loops by index, so a gate command never reads the list as
  stdin.
- **`Makefile` `lint`**: no download fallback and no `/dev/null`. shellcheck is `$SHELLCHECK`, else
  PATH, and is required. actionlint is `$ACTIONLINT`, else PATH, and best-effort until T29. The recipe
  prints the shellcheck version and path it used.
- **`.github/workflows/gates.yml` `build-test`**: checks out the head (GATE_HEAD) and the base into
  `.base`, installs `shellcheck-py==0.11.0.1` with pipx and checks `version: 0.11.0`, then runs
  `./.base/factory/bin/build-test.sh`. No hard-coded `make test` or `make lint` is left in any job.
- **`factory/bin/lib/probe.sh`** `.lint = {needed, shellcheck, version, in_plane, install_line}`.
  `needed` is true when the clone's `fleet.gate.build|test` or `fleet.init` runs `make lint`.
  `shellcheck` is the first on PATH whose directory and real path both lie under `/usr`, `/lib` or
  `/lib64` (what the shim binds), else the first on PATH. `in_plane` is null on macOS (not measured).
- **`factory/bin/join.sh`**: `SHELLCHECK_PIN=0.11.0`. It refuses when lint is needed and no shellcheck
  is in the plane, naming why and printing the distribution's install line (never run). It warns when
  the in-plane version is not the pin.
- **The sim**: the runner's `pipx` stub also simulates `install shellcheck-py==0.11.0.1`. The walk's
  "fleet without its config preflight" stand-in is gone: `$X.fleet-preflight` is a judge on run.sh's
  ledger line (`fleet-run` in `.actions`, and no `preflight` reason). A new scenario,
  `S.head-edits-gate-config`, has the head rewrite `fleet.gate` to `echo head-gate`, and build-test's
  trace must be exactly the base's two lines.
- **ADR-0005** gains the amendment "T24, main's fleet block and the build-test gate".

## 3. Tests and gates

### New and changed tests

- **`tests/test_build_test.sh`** (new, 8 cases, 49 checks):
  - `list`: main's config, an empty or null key skipped.
  - `runs`: order, the caller's cwd, the trace.
  - `stops-at-first-failure`: exit 2, and the test command never runs.
  - `config-errors`: seven unusable configs, each exits 1 and runs nothing.
  - `base-config` (I16): the base's script run from a head cwd runs the base's list.
  - `stdin`: a gate command reads the caller's stdin, not the list, and a command passes byte for byte.
  - `gates-yml`: build-test runs `./.base/factory/bin/build-test.sh` with no args, after a head
    checkout and a base checkout into `.base`. No job runs `make test` or `make lint`. The pipx pin is
    `SHELLCHECK_PIN`.
  - `node-ci-same-list` (I17).
- **`tests/test_policy.sh` `fleet-config`**: a jq validator over `.fleet`, with fleet's file:line
  citations in its comment. Unknown keys and operator-local keys are errors, and each key is typed.
  Main's config gives 0 errors, and 16 bad fixtures each give exactly their error.
- **`tests/test_join.sh` `lint-shellcheck`** (13 checks):
  - No shellcheck: refused, with the install line, never run.
  - Only under `$HOME/.local`: refused, "not visible in fleet's sandbox".
  - A link under /usr into `$HOME/.local`: refused.
  - `$HOME/.local` first and /usr second: ok, and the /usr one is reported.
  - Another version: ok, with one warning naming the pin, which is the one gates.yml installs.
  - A gate without `make lint`: nothing needed.
  - `fleet.init` running `make lint`: needed, and Fedora's install line.
  - `make lint-docs`: not `make lint`.
- **`tests/test_gate_context.sh`**: `build-test` joins the jobs that must run a base script and check
  out head, then base (a scope deviation, §4).
- **`tests/live/test_fleet_config_live.sh`** (new, 23 checks). It works on a `git archive HEAD` scratch
  with T-smoke from the real `adlc ticket create --write --allow-unsigned`.
  1. fleet's `loadConfig` and `resolveRunConfig`, called as `fleet run` calls them, read main's block
     whole with 0 warnings.
  2. `runLive` with fleet's real io and preflight, with only `build`/`run` (the steps after preflight)
     stubbed: the preflight passes on main's config, and the stubs are reached with bubblewrap and
     T-smoke.
  3. I17: fleet's `runGates` on a recording sandbox gives `[["/bin/sh","-c","make lint"],
     ["/bin/sh","-c","make test"]]`, equal to `build-test.sh --list`.
  4. Control: with `.fleet` deleted, the real preflight refuses with "fleet.gate must define a build
     and/or test command in .adlc/config.json; an ungated fleet must not run", and no stub is
     reached.
  5. INFO: `make lint` in fleet's real plane gives rc=2, because shellcheck is not under a system root
     on this box.
- **`tests/live/test_join_live.sh`**: if the probe says lint is needed and not in the plane, part A
  asserts exit 2 and the shellcheck refusal first. The only other refusal it allows is the manifest's
  `heavy_gates: expected boolean, got null`, which follows from it: a step-1 refusal skips the suite.
  It then prints `SKIP part A's no-refusal checks: <reason> (kit: <install line>)`. Parts B and C
  empty `fleet.gate.build` in their scratch clones and print a NOTE saying so, because they measure
  the installs, not the gate.

### The sim

110 stages = 74 pass + 36 red (before: 109 = 71 + 38). Flipped: `P.fleet-preflight`,
`C.fleet-preflight`. New and passing: `S.head-edits-gate-config`. The "fleet without its config
preflight" stand-in is gone.

### Gates (the T24 tree, after the desk commit `606e8c2`)

- `make test`: 21 PASS, 0 FAIL, rc 0. It includes test_sim with the real adlc 1.12.0.
- `make lint`: rc 0, `lint: shellcheck 0.11.0 at /home/musicofhel/.local/bin/shellcheck`, actionlint
  1.7.12 ok.
- `bash tests/sim/sim.sh --adlc fake`: rc 0. `--adlc real` also gives rc 0 on the drafts, in
  `.spec-loop/tb5/simk-real`, and again inside `make test`.
- live:
  - test_fleet_config_live PASS;
  - test_join_live PASS, with part A on the refusal branch (this box has no system shellcheck);
  - test_policy_live PASS;
  - test_bwrap_shim_live PASS.
  - **test_render_live FAIL, pre-existing:** "tamperguard rc 0 and a JSON verdict": expected `rc=0
    verdict=ok`, got `rc=1 verdict=none`. It fails identically on `cba5a89` (worktree
    `/tmp/tb5-red`), and it is carry 4 (owner TB12).
  - test_smoke_live was not run. It writes its own fixture `.fleet`, so main's block does not reach
    it, and it costs a real claude run.
- `yq -o=json . .github/workflows/gates.yml` parses.

### Red proofs (the new tests on `cba5a89`, worktree `/tmp/tb5-red`, the new files copied in)

- test_build_test: all 8 cases FAIL (no build-test.sh).
- test_policy: only `fleet-config` FAILs (13 failed checks, the first "main's .adlc/config.json: the
  .fleet block reads clean").
- test_join: only `lint-shellcheck` FAILs (12 failed checks).
- test_fleet_config_live: FAIL, starting with "the scratch config carries a fleet block".
- The sim harness of this row on `cba5a89` (worktree `/tmp/tb5-red-sim`, `tests/sim/` copied in,
  `--adlc fake`): rc 1, `sim: no PR for T-sim-parent after the node ran: … "reason":"preflight"`. The
  walk stops at the first flipped stage.

## 4. Deviations

- **Scope:** `tests/test_gate_context.sh` is outside T24's scope globs. Its TB2 assertion lists exactly
  the jobs that run a base script, and `build-test` now does (I16), so the list gained `build-test`,
  and so did the head-then-base checkout loop. That is two lines, and dogfooded scope-check names this
  file.
- **The node's test gate cannot pass in fleet's plane yet** (§1). This row does not widen the shim
  (I12) and does not weaken `fleet.gate`. The choice is HANDOFF Q1.
- **This box is now refused by join** until `sudo apt-get install shellcheck` (Aaron's kit). That is
  the intended behavior of the new check, which is why `test_join_live` part A asserts it.
- **join's follow-on refusal:** any step-1 refusal also yields the manifest's `heavy_gates` schema
  refusal, because the suite was skipped. This predates TB5 and is left as it is; the live test names
  it.
