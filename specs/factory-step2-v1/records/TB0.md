# TB0 — Register, tickets T6–T11, and the pinned tools on this box

Session date 2026-10-24 (local; GitHub timestamps below are UTC and read 2026-10-25). Box: WSL2,
Linux 6.18.33.2-microsoft-standard-WSL2. Measured at `3ec73fa` (= `origin/main`; the SPEC's own commit,
which the session's starting snapshot listed, with the same subject, as `fa80fdc`). Nothing was pushed (I1).
Every block is `$ <command>`, its verbatim output and `exit=<code>`. `a` = `npx -y @adlc/cli@1.12.0`
(a bash function; never a floating version). Long `--help` texts are in the appendix (§8), verbatim.

## 1. The register, re-measured

| key | SPEC §0 said | measured now | block |
|---|---|---|---|
| repo | `origin/main` = `44ed6dd`; local = origin; `make test` 9 files PASS; `make lint` 0 | `origin/main` = local = `3ec73fa` (the SPEC commit on top of `44ed6dd`); `make test` 9 files PASS; `make lint` 0 | §1.1 |
| GitHub | public, user-owned; no `nodes`/`flaky-history`; janitor red on `refs/heads/nodes`; no secrets; no protection; Issue #1 | same on every point: public, `User`; only `main` on the remote; last 3 scheduled janitor runs `failure`, log `fatal: couldn't find remote ref refs/heads/nodes`; 0 secrets, 0 variables; main "Branch not protected", 0 rulesets; Issue #1 (T3) the only Issue, open | §1.2 |
| sandbox | bwrap 0.9.0; `bwrap --unshare-all true` runs; unshare; landlock in LSM list | bwrap 0.9.0 ✔; **`bwrap --unshare-all true` exits 1** ("execvp true: No such file or directory": with no binds there is no `/usr` inside); with `--ro-bind / / --dev /dev --proc /proc` it exits 0 and runs a shell as uid 1001. `unshare` 2.39.3 ✔. `/sys/kernel/security/lsm` is absent (securityfs not mounted in WSL2); the kernel config has `CONFIG_SECURITY_LANDLOCK=y`, `CONFIG_LSM="landlock,…"`, and `vetto doctor` reports Landlock ABI 7 available | §1.3, §3 |
| pinned tools | vetto 0.6.5, ralon 0.1.7 (max stable), tamperguard 0.2.0, dcg v0.15.3, cux unpinned, @adlc/cli 1.12.0; none installed | registry: same versions (vetto, ralon max stable; tamperguard 0.2.0; dcg latest v0.15.3; @adlc/cli latest 1.12.0); **cux latest release v0.4.1** (tag commit `4408a4dd4c2800e2e8a1db78ae9b3a2bb4c3f773`, repo not archived, Go). All five now installed in user space (§2) | §1.4, §2 |
| adapters | claude only | claude 2.1.280 (Claude Code); codex, agy, opencode absent | §1.5 |
| rulings | Q4, Q5, Q6 land here | `specs/factory-step1-v1/RULINGS.md` read: Q4 remove collaborator, Q5 adapters.json in step 2, Q6 App as bypass actor | (file) |
| follow-ups | (1) ready-duty incl. completed; (2) no post-merge trailers; (5) PAT scoping unmeasured; (6) wizard probes bwrap | (1) still true: `factory/bin/janitor.sh:252` `open="$(jq -c '[.[].id] \| sort' …)"` over the full list; (2) still true: `factory/bin/post-merge.sh:193` commits with `-m "post-merge: complete …" -m "Through: …"` only; (5) unmeasured (due at first join, I1); (6) `factory/bin/join.sh` does not exist yet (TB2 creates it) | (grep) |

### 1.1 Repo

```
$ git rev-parse origin/main HEAD; git status -sb | head -1
3ec73fad3faf253791794ba099e66ed0aab6d408
3ec73fad3faf253791794ba099e66ed0aab6d408
## main...origin/main
exit=0
```

```
$ make test 2>&1 | grep -E '^(PASS|FAIL)'; exit ${PIPESTATUS[0]}
PASS tests/test_claim.sh
PASS tests/test_halt_rules.sh
PASS tests/test_halt.sh
PASS tests/test_janitor.sh
PASS tests/test_layout.sh
PASS tests/test_mirror.sh
PASS tests/test_post_merge.sh
PASS tests/test_summon.sh
PASS tests/test_version_check.sh
exit=0
```

```
$ make lint
exit=0
```

(`make test` before any change printed the same nine PASS lines and exit 0; full per-case output is long and unchanged, so only the summary lines are kept.)

### 1.2 GitHub (read-only calls only)

```
$ gh api repos/musicofhel/software-factory --jq '{visibility, owner_type: .owner.type, default_branch}'
{"default_branch":"main","owner_type":"User","visibility":"public"}
exit=0
```

```
$ git ls-remote origin refs/heads/nodes refs/heads/flaky-history refs/heads/main
3ec73fad3faf253791794ba099e66ed0aab6d408	refs/heads/main
exit=0
```

```
$ gh run list -R musicofhel/software-factory --workflow janitor.yml --limit 3 --json conclusion,createdAt,event --jq '.[] | [.createdAt,.event,.conclusion] | @tsv'
2026-10-25T02:34:43Z	schedule	failure
2026-10-25T01:35:38Z	schedule	failure
2026-10-25T01:00:06Z	schedule	failure
exit=0
```

```
$ gh api repos/musicofhel/software-factory/actions/secrets --jq .total_count; gh api repos/musicofhel/software-factory/actions/variables --jq .total_count
0
0
exit=0
```

```
$ gh api repos/musicofhel/software-factory/branches/main/protection 2>&1 | head -c 300; echo; gh api repos/musicofhel/software-factory/rulesets --jq length
{"message":"Branch not protected","documentation_url":"https://docs.github.com/rest/branches/branch-protection#get-branch-protection","status":"404"}gh: Branch not protected (HTTP 404)

0
exit=0
```

```
$ gh issue list -R musicofhel/software-factory --state all --json number,title,state --jq '.[] | [.number,.state,.title] | @tsv'
1	OPEN	Implement the clock and janitor: every TTL, heartbeat, stale and scheduled transition
exit=0
```

```
$ id=$(gh run list -R musicofhel/software-factory --workflow janitor.yml --limit 1 --json databaseId --jq '.[0].databaseId'); echo run=$id; gh run view $id -R musicofhel/software-factory --log-failed 2>&1 | grep -iE "couldn't find|error|fatal" | head -5
run=40154977001
janitor	janitor sweep	2026-10-25T02:34:48.8425864Z fatal: couldn't find remote ref refs/heads/nodes
janitor	janitor sweep	2026-10-25T02:34:48.8467532Z ##[error]Process completed with exit code 1.
exit=0
```

### 1.3 Sandbox primitives

```
$ bwrap --version; bwrap --unshare-all true; echo bwrap_unshare_all_exit=$?
bubblewrap 0.9.0
bwrap: execvp true: No such file or directory
bwrap_unshare_all_exit=1
exit=0
```

```
$ command -v unshare; unshare --version
/usr/bin/unshare
unshare from util-linux 2.39.3
exit=0
```

```
$ cat /sys/kernel/security/lsm; echo
cat: /sys/kernel/security/lsm: No such file or directory

exit=0
```

```
$ uname -r; grep -i microsoft /proc/version >/dev/null && echo WSL2
6.18.33.2-microsoft-standard-WSL2
WSL2
exit=0
```

```
$ bwrap --unshare-all --ro-bind / / --dev /dev --proc /proc true; echo exit_ro_bind=$?; bwrap --unshare-all --ro-bind / / --dev /dev --proc /proc sh -c 'echo inside-sandbox; id -u'
exit_ro_bind=0
inside-sandbox
1001
exit=0
```

```
$ zcat /proc/config.gz | grep -E '^CONFIG_(LSM|SECURITY_LANDLOCK)='; ls /sys/kernel/security 2>&1 | head -3
CONFIG_SECURITY_LANDLOCK=y
CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,integrity,selinux,apparmor,tomoyo"
exit=0
```

### 1.4 Registries (read-only)

```
$ for c in vetto ralon; do curl -fsS -A 'software-factory-tb0 (wobbly@bitcoinsapi.com)' https://crates.io/api/v1/crates/$c | jq -r '.crate | [.name, .max_stable_version, .max_version, .updated_at, .repository] | @tsv'; done
vetto	0.6.5	0.6.5	2026-10-11T17:27:58.583729Z	https://github.com/shleder/vetto
ralon	0.1.7	0.1.7	2026-08-28T18:09:52.355743Z	https://github.com/stoneware-dev/Ralon
exit=0
```

```
$ curl -fsS https://pypi.org/pypi/tamperguard/json | jq -r '[.info.name, .info.version, (.info.project_urls|tostring)] | @tsv'
tamperguard	0.2.0	{"Homepage":"https://github.com/fernforge/tamperguard","Issues":"https://github.com/fernforge/tamperguard/issues"}
exit=0
```

```
$ gh api repos/Dicklesworthstone/destructive_command_guard/releases/latest --jq '[.tag_name, .published_at, ([.assets[].name]|join(" "))] | @tsv'
v0.15.3	2026-10-08T06:15:06Z	dcg-aarch64-apple-darwin.tar.xz dcg-aarch64-apple-darwin.tar.xz.minisig dcg-aarch64-apple-darwin.tar.xz.sha256 dcg-aarch64-apple-darwin.tar.xz.sigstore.json dcg-aarch64-pc-windows-msvc.zip dcg-aarch64-pc-windows-msvc.zip.minisig dcg-aarch64-pc-windows-msvc.zip.sha256 dcg-aarch64-pc-windows-msvc.zip.sigstore.json dcg-aarch64-unknown-linux-gnu.tar.xz dcg-aarch64-unknown-linux-gnu.tar.xz.minisig dcg-aarch64-unknown-linux-gnu.tar.xz.sha256 dcg-aarch64-unknown-linux-gnu.tar.xz.sigstore.json dcg-x86_64-apple-darwin.tar.xz dcg-x86_64-apple-darwin.tar.xz.minisig dcg-x86_64-apple-darwin.tar.xz.sha256 dcg-x86_64-apple-darwin.tar.xz.sigstore.json dcg-x86_64-pc-windows-msvc.zip dcg-x86_64-pc-windows-msvc.zip.minisig dcg-x86_64-pc-windows-msvc.zip.sha256 dcg-x86_64-pc-windows-msvc.zip.sigstore.json dcg-x86_64-unknown-linux-musl.tar.xz dcg-x86_64-unknown-linux-musl.tar.xz.minisig dcg-x86_64-unknown-linux-musl.tar.xz.sha256 dcg-x86_64-unknown-linux-musl.tar.xz.sigstore.json install.ps1 install.ps1.minisig install.ps1.sha256 install.ps1.sigstore.json install.sh install.sh.minisig install.sh.sha256 install.sh.sigstore.json SHA256SUMS SHA256SUMS.minisig
exit=0
```

```
$ gh api repos/inulute/cux --jq '[.full_name, .archived, .language, .default_branch, .pushed_at] | @tsv'; gh api repos/inulute/cux/releases --jq '.[0:5][] | [.tag_name, .published_at, .prerelease, ([.assets[].name]|join(" "))] | @tsv'; gh api repos/inulute/cux/tags --jq '.[0:5][] | [.name, .commit.sha] | @tsv'
inulute/cux	false	Go	main	2026-09-23T14:32:19Z
v0.4.1	2026-09-23T14:30:58Z	false	cux-darwin-amd64 cux-darwin-amd64.sha256 cux-darwin-arm64 cux-darwin-arm64.sha256 cux-linux-amd64 cux-linux-amd64.sha256 cux-linux-arm64 cux-linux-arm64.sha256 cux-windows-amd64.exe cux-windows-amd64.exe.sha256
v0.4.0	2026-09-22T17:24:31Z	false	cux-darwin-amd64 cux-darwin-amd64.sha256 cux-darwin-arm64 cux-darwin-arm64.sha256 cux-linux-amd64 cux-linux-amd64.sha256 cux-linux-arm64 cux-linux-arm64.sha256 cux-windows-amd64.exe cux-windows-amd64.exe.sha256
v0.3.13	2026-09-12T15:48:21Z	false	cux-darwin-amd64 cux-darwin-amd64.sha256 cux-darwin-arm64 cux-darwin-arm64.sha256 cux-linux-amd64 cux-linux-amd64.sha256 cux-linux-arm64 cux-linux-arm64.sha256 cux-windows-amd64.exe cux-windows-amd64.exe.sha256
v0.3.12	2026-08-31T04:52:35Z	false	cux-darwin-amd64 cux-darwin-amd64.sha256 cux-darwin-arm64 cux-darwin-arm64.sha256 cux-linux-amd64 cux-linux-amd64.sha256 cux-linux-arm64 cux-linux-arm64.sha256 cux-windows-amd64.exe cux-windows-amd64.exe.sha256
v0.3.11	2026-08-21T04:41:17Z	false	cux-darwin-amd64 cux-darwin-amd64.sha256 cux-darwin-arm64 cux-darwin-arm64.sha256 cux-linux-amd64 cux-linux-amd64.sha256 cux-linux-arm64 cux-linux-arm64.sha256 cux-windows-amd64.exe cux-windows-amd64.exe.sha256
v0.4.1	4408a4dd4c2800e2e8a1db78ae9b3a2bb4c3f773
v0.4.0	778a846d001b6c2fe2a70f62bd92a6ac9e3ce310
v0.3.13	0d55c4d56c2819736c8548f0c0c7b27632d39ea8
v0.3.12	11279673e41480157d0b74ab02aed13fdcb6d176
v0.3.11	105ca68214024ada95ddcf23ff99008eb2caa33f
exit=0
```

```
$ npm view @adlc/cli version dist-tags --json
{
  "version": "1.12.0",
  "dist-tags": {
    "latest": "1.12.0"
  }
}
exit=0
```

### 1.5 Adapters

```
$ for a in claude codex agy opencode; do printf '%s ' $a; command -v $a || echo absent; done; claude --version
claude /home/musicofhel/.nvm/versions/node/v22.22.0/bin/claude
codex absent
agy absent
opencode absent
2.1.280 (Claude Code)
exit=0
```

## 2. Installs (I2: user space, pinned, no sudo)

These are the exact commands the join wizard (TB2) must reproduce. Each one ran on this box in this
session. Cargo builds ran in the background with their logs in `/tmp/tb0/*-install.log`; the lines below
are those logs' install lines.

```
$ cargo install --locked vetto@0.6.5
  Installing vetto v0.6.5
  Installing /home/musicofhel/.cargo/bin/vetto
   Installed package `vetto v0.6.5` (executable `vetto`)
exit=0
$ cargo install --locked ralon@0.1.7
  Installing ralon v0.1.7
  Installing /home/musicofhel/.cargo/bin/ralon
   Installed package `ralon v0.1.7` (executable `ralon`)
exit=0
$ uv tool install tamperguard==0.2.0
Resolved 1 package in 445ms
Prepared 1 package in 111ms
Installed 1 package in 5ms
 + tamperguard==0.2.0
Installed 1 executable: tamperguard
exit=0
```

dcg and cux are release binaries, each verified against the release's published `.sha256` before it is
installed into `~/.local/bin` (dcg also publishes `SHA256SUMS`, minisign and sigstore files; the
`SHA256SUMS` line for the musl tarball was checked by hand and matches:
`dc7dcec9679f74ac3e6990959771ca0c84168eba658eff64fe9e63f917a84cc4`). The musl build is used because it
has no glibc floor.

```
$ d=$(mktemp -d) && cd "$d" && base=https://github.com/Dicklesworthstone/destructive_command_guard/releases/download/v0.15.3 && curl -fsSLO "$base/dcg-x86_64-unknown-linux-musl.tar.xz" && curl -fsSLO "$base/dcg-x86_64-unknown-linux-musl.tar.xz.sha256" && sha256sum -c dcg-x86_64-unknown-linux-musl.tar.xz.sha256 && tar -xJf dcg-x86_64-unknown-linux-musl.tar.xz dcg && install -m 0755 dcg ~/.local/bin/dcg && command -v dcg && dcg --version
dcg-x86_64-unknown-linux-musl.tar.xz: OK
/home/musicofhel/.local/bin/dcg
0.15.3

  ╭─────────────────────────────────────────╮
  │  🛡  Destructive Command Guard               │
  │     dcg v0.15.3                           │
  │                                         │
  │  Built: 2026-10-08                   │
  │  Rustc: 1.100.0-nightly                      │
Rustc release: 1.100.0-nightly
Rustc commit: 90850177249efe0321573c569aec5d12b257f8d6
Rustc date: 2026-08-30
Rustc host: x86_64-unknown-linux-gnu
  │  Target: x86_64-unknown-linux-musl         │
  │  Commit: v0.15.3                │
Git SHA: 3eec165ae64a56bfbb2cecaa2510d82076010851
  │                                         │
  │  Protecting your code from destructive ops  │
  ╰─────────────────────────────────────────╯

exit=0
```

```
$ d=$(mktemp -d) && cd "$d" && base=https://github.com/inulute/cux/releases/download/v0.4.1 && curl -fsSLO "$base/cux-linux-amd64" && curl -fsSLO "$base/cux-linux-amd64.sha256" && cat cux-linux-amd64.sha256 && sha256sum -c cux-linux-amd64.sha256 && install -m 0755 cux-linux-amd64 ~/.local/bin/cux && command -v cux && cux --version
d336d1f8a6175265977f5a08ce53c20403e13752b90826df1128c29d89401df6  cux-linux-amd64
cux-linux-amd64: OK
/home/musicofhel/.local/bin/cux
cux 0.4.1
exit=0
```

Versions as installed:

| tool | pin | `--version` | source sha (for reading docs at the pin) |
|---|---|---|---|
| vetto | crates.io 0.6.5 | `vetto 0.6.5` | crate source `~/.cargo/registry/src/*/vetto-0.6.5` (the crate's `repository` URL `github.com/shleder/vetto` returns "repository not found" to `git clone`, so the published crate is the source of record) |
| ralon | crates.io 0.1.7 | `ralon 0.1.7` | `stoneware-dev/Ralon` tag v0.1.7 = `ccbe22bf3f26531fb628df6cf79586cc45f01ee5` |
| tamperguard | PyPI 0.2.0 | no `--version` flag (exit 2, §8); `uv tool install` reports `tamperguard==0.2.0` | `fernforge/tamperguard` tag v0.2.0 = `8e03b6e03ecec41483cb64f1f0425b5b3178eb70` |
| dcg | release v0.15.3 (`x86_64-unknown-linux-musl`) | `0.15.3`, Git SHA `3eec165ae64a56bfbb2cecaa2510d82076010851` | tag v0.15.3 = `3eec165…` |
| cux | release **v0.4.1** (`cux-linux-amd64`, sha256 `d336d1f8a6175265977f5a08ce53c20403e13752b90826df1128c29d89401df6`) | `cux 0.4.1` | `inulute/cux` tag v0.4.1 = `4408a4dd4c2800e2e8a1db78ae9b3a2bb4c3f773` |
| @adlc/cli | npm 1.12.0 | `1.12.0` | npx cache `~/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc/*` (fleet 1.12.0) |

The tag shas were read with `git clone -q --depth 1 --branch <tag> https://github.com/<repo>` then
`git rev-parse HEAD` (cux's also matches `gh api repos/inulute/cux/tags`, §1.4).

```
$ uv tool install tamperguard==0.2.0; tamperguard --version
`tamperguard==0.2.0` is already installed
usage: tamperguard [-h] [--range RANGE] [--json] [--no-color]
                   [--fail-on {tamper,review,never}]
                   [path]
tamperguard: error: unrecognized arguments: --version
exit=2
```

## 3. fleet at 1.12.0 on this box: help, dry run, sandbox verdict

`adlc fleet run --help` verbatim:

```
$ a --version; a fleet run --help
1.12.0
usage: fleet [options]

options:
  --concurrency <value>
  --dry-run
  --tickets <value>
  --base <value>
  --json
  --i-am-in-a-disposable-container
  --adapter <value>
  --model <value>
  --model-auth-key <value>
  --adapter-command <value>
  --adapter-args <value>
  --model-plane-writable <value...>
  --no-pr
  --no-complete
  --dead-end-file <value>
  --max-strikes <value>
  --wall-clock-minutes <value>
  --charter-file <value>
  --pre-strike-argv <value>
  --pre-strike-env <value>
  --model-plane-read <value>
  --model-plane-read-only <value>
  --model-plane-git <value>
  --model-plane-git-mirror <value>
  --model-plane-egress <value>
  --worker-deps <value>
  -h, --help                         show this help
exit=0
```

The dry run, before the tickets existed (T1–T5 all completed, so nothing is ready) and after T6–T11
were written (§5):

```
$ a fleet run --dry-run --json > /tmp/tb0/fleet-dry.json; e=$?; jq -c "{keys: keys}" /tmp/tb0/fleet-dry.json; jq -c ".sandbox // .preflight // empty" /tmp/tb0/fleet-dry.json; exit $e
{"keys":["base","baseSha","completedExcluded","concurrency","egress","firstBatch","gitSource","integrationBranch","integrationWorktree","maxStrikes","mirror","noComplete","noPr","plannedWorktrees","privateTmp","quartermaster","readPolicy","readyNow","subsetBlocked","waitingOnDeps","wallClockMinutes","workerDeps","worktreeRoot"]}
exit=0
```

```
$ a fleet run --dry-run --json > /tmp/tb0/fleet-dry2.json; e=$?; jq -c '{baseSha, readyNow, firstBatch, waitingOnDeps, completedExcluded, concurrency, maxStrikes, readPolicy, egress, plannedWorktrees}' /tmp/tb0/fleet-dry2.json; git worktree list; exit $e
{"baseSha":"3ec73fad3faf253791794ba099e66ed0aab6d408","readyNow":["T6","T8"],"firstBatch":["T6","T8"],"waitingOnDeps":["T10","T11","T7","T9"],"completedExcluded":5,"concurrency":2,"maxStrikes":2,"readPolicy":"host","egress":"open","plannedWorktrees":{"T6":"/home/musicofhel/software-factory/.worktrees/fleet-t6","T8":"/home/musicofhel/software-factory/.worktrees/fleet-t8"}}
/home/musicofhel/software-factory  3ec73fa [main]
exit=0
```

The dry run only plans; it does not probe the sandbox (step 1 records/TB0.md §2). The live run's
preflight does, and accepts only `bwrap` on Linux. Calling the installed 1.12.0 functions directly, as
step 1 did (no worker dispatched):

```
$ cd /home/musicofhel/software-factory && node --input-type=module -e "import { detectBackend } from '/home/musicofhel/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc/fleet/lib/sandbox.mjs'; import { resolveSandboxForRun } from '/home/musicofhel/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc/fleet/lib/preflight.mjs'; console.log(JSON.stringify({backend: detectBackend(), resolved: resolveSandboxForRun({})}))"; jq -r .version /home/musicofhel/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc/fleet/package.json
{"backend":{"name":"bubblewrap","platform":"linux"},"resolved":{"mode":"sandbox","backend":{"name":"bubblewrap","platform":"linux"},"warnings":[],"refused":false}}
1.12.0
exit=0
```

(`<npx>` = `/home/musicofhel/.npm/_npx/45e3560a1487d0e5/node_modules`.)

**Verdict: the sandbox precondition is now MET on this box** (step 1 measured `backend: null,
refused: true`). `adlc fleet run --dry-run --json` exits 0. Other live-run prerequisites fleet names are
still absent and belong to TB4/TB6:

```
$ jq -c '{tickets: .readyNow, firstBatch, waitingOnDeps, readPolicy, egress, worktreeRoot, maxStrikes}' /tmp/tb0/fleet-dry.json; jq -c '.fleet // "no fleet key"' .adlc/config.json; command -v adversarial-review || echo 'adversarial-review: absent'
{"tickets":[],"firstBatch":[],"waitingOnDeps":[],"readPolicy":"host","egress":"open","worktreeRoot":"/home/musicofhel/software-factory","maxStrikes":2}
"no fleet key"
adversarial-review: absent
exit=0
```

The two other sandbox layers, read on the same box:

```
$ vetto doctor --json | jq -c 'to_entries[] | {k: .key, status: (.value.status? // .value.overall_status? // (.value|tostring|.[0:80]))}'
{"k":"verdict","status":"pass"}
{"k":"exit_code","status":"0"}
{"k":"landlock","status":"available"}
{"k":"namespaces","status":"available"}
{"k":"cgroups_v2","status":"available"}
{"k":"seccomp","status":"available"}
{"k":"runtime_paths","status":"available"}
exit=0
```

```
$ vetto doctor --json | jq -c '.landlock | {abi, status, message}'
{"abi":null,"status":"available","message":"Landlock LSM supported (ABI 7)"}
exit=0
```

```
$ ralon status; echo "ralon_status_exit=$?"
ralon: no agent.lock found in /home/musicofhel/software-factory or any parent directory (run `ralon init`)
ralon_status_exit=2
exit=0
```

(`ralon status` exits 2 with no `agent.lock` in the tree: ralon is idle until a lock exists, as its README
says. Nothing in this row ran `ralon install`, `vetto enable` or `dcg install`; all three would edit
`~/.claude/settings.json` or shell rc files, which is the wizard's decision in TB2, not this row's.)

## 4. SPEC-v0.2 run-loop sketch (L362–379) vs the real CLIs

The full table, with sources, is `docs/adr/0005-run-loop-cli-reality.md` (status: proposed). Summary:

| flag / form in the sketch | verdict | real spelling |
|---|---|---|
| `ralon run … -- <cmd>` | EXISTS | |
| `ralon run --lock .ralon/<id>.lock` | DIFFERENT | `ralon run -C <dir> -- <cmd>`, reading `<dir>/agent.lock`; patterns relative to the lock |
| `vetto --profile factory/policy/build.toml` | DIFFERENT | `vetto --policy <path>` (`--profile` takes a built-in name) |
| `vetto … -- <cmd>` | EXISTS | |
| build.toml for build steps + agent.toml for model turns under one vetto | DIFFERENT | one vetto = one policy; fleet's own bwrap plane denies network to build/test |
| `fleet run --tickets <id>` | EXISTS | |
| `--concurrency 1` | EXISTS | |
| `--no-pr` | EXISTS | |
| `--no-complete` | EXISTS | |
| `--adapter <preferred adapter>` | EXISTS | |
| `--worker-deps <lockfile cache>` | DIFFERENT | `--worker-deps <abs node_modules>` (a node_modules copy, not a cache) |
| `--max-strikes <budget.strikes>` | EXISTS | 1..50 |
| `--wall-clock-minutes <budget.minutes>` | EXISTS | |
| `--pre-strike-argv '["cux","status","--json"]'` | DIFFERENT | argv[0] must be absolute; env only from `--pre-strike-env` |
| `cux status --json` | MISSING | `cux status` has only `-no-refresh`; JSON is `cux usage show` |
| `--json` | EXISTS | |
| reason `merged into fleet/run-*` | DIFFERENT | success = `exitCode 0`, `reason null`, `integrationBranch fleet/run-<id>` |
| `quota-paused`, `wall-clock`, `strikes-exhausted`, `flail`, `review-unavailable` | EXISTS | closed set `REASON_CODES` |
| "anything else" | EXISTS | also `lock-held`, `ticket-blocked`, `mirror-fetch-failed`, and run-level `quarantined`, `pr-open-failed`, `preflight`, `resume-refused`, `dispatch-refused`, `pipeline-error` |
| `git worktree add .worktrees/<id>` then fleet in it | DIFFERENT (side effect) | fleet cuts `.worktrees/fleet-<id>` under its own cwd and appends to that tree's `.gitignore` |

Where the facts came from (beyond the `--help` texts in §8): fleet README and
`@adlc/fleet/lib/{result,scheduler,worktrees,adapters/index,adapters/claude-code}.mjs` in the npx cache;
Ralon README at v0.1.7; vetto `docs/profiles.md`, `docs/network.md`, `docs/exit-codes.md` in the 0.6.5
crate; cux `internal/usage/usage.go` and `cmd/cux/main.go` (`cmdUsageShow` prints the usage cache) at
v0.4.1. claude-code's `egressHosts` at fleet 1.12.0: `api.anthropic.com:443`, `console.anthropic.com:443`,
`platform.claude.com:443`.

## 5. Tickets T6–T11

Written through the CLI only, never by hand. Each input document is `{id, title, body, category,
duration, scope, rails: [], edges}`; the body opens with the ADR-0002 header block (`weight:`, `tier:`,
`charter:`), and every acceptance criterion ends in `Verify: <command>`. Explicit ids `T6`…`T11` keep the
step-1 `T<n>` naming (ADR-0002 allows a supplied id). Created in reverse dependency order so each
edge's target already existed: T11, T10, T9, T8, T7, T6, each first as a dry run
(`a ticket create --input <file>` → `"validation": "valid"`, `"dryRun": true`), then with `--write`:

```
$ for t in T11 T10 T9 T8 T7 T6; do out=$(a ticket create --input /tmp/tb0/tk/$t.json --write --json 2>&1); e=$?; echo "$t exit=$e $(jq -c '{ticketId, validation, graphEffects, dryRun}' <<<"$out")"; done
T11 exit=0 {"ticketId":"T11","validation":"valid","graphEffects":[],"dryRun":false}
T10 exit=0 {"ticketId":"T10","validation":"valid","graphEffects":[],"dryRun":false}
T9 exit=0 {"ticketId":"T9","validation":"valid","graphEffects":[],"dryRun":false}
T8 exit=0 {"ticketId":"T8","validation":"valid","graphEffects":[],"dryRun":false}
T7 exit=0 {"ticketId":"T7","validation":"valid","graphEffects":[],"dryRun":false}
T6 exit=0 {"ticketId":"T6","validation":"valid","graphEffects":[],"dryRun":false}
```
(Each `--write --json` printed a second JSON document after the plan, which this `jq` projection showed
as an all-null line `{"ticketId":null,…}` after every ticket; those six lines are dropped above.)

**No ticket declares `rails`.** `adlc ticket create --help`: once any ticket declares a rail the store
becomes a frozen trust root and every later `--write` needs `ADLC_MANIFEST_KEY` (or a permanent unsigned
manifest entry). The store has had no rails since step 1, and this row has no key, so T6–T11 stay
rail-free. The rails the run loop locks come from the claimed ticket at run time (TB1/TB4; the TB6 smoke
ticket lives in the fixture's own store).

Edges as the SPEC lists them: T6→T7, T6→T9, T8→T9, T7→T11, T9→T11, T10→T11. First check after writing:

```
$ a ticket doctor
  ok  	config-valid
  ok  	tickets-load
  ok  	store:active-store
  ok  	store:transactions
  ok  	store:writer-lock
  ok  	store:current-ticket
  ok  	store:storehash-manifest-bind
  ok  	store:manifest-forest
  ok  	store:archive
  ok  	schema-drift

All checks passed.
exit=0
```

```
$ a coldstart --all --offline --json | jq -c '.ok, (.results[] | {id, pass, gaps})'
true
{"id":"T10","pass":true,"gaps":[]}
{"id":"T11","pass":true,"gaps":[]}
{"id":"T6","pass":true,"gaps":[]}
{"id":"T7","pass":true,"gaps":[]}
{"id":"T8","pass":true,"gaps":[]}
{"id":"T9","pass":true,"gaps":[]}
exit=0
```

```
$ a merge-forecast --json > /tmp/tb0/mf.json; e=$?; jq -c '(.pairs[] | select(.verdict != "PARALLEL") | {pair, signal, verdict}), {gateFailures, waves}' /tmp/tb0/mf.json; exit $e
{"pair":"T10–T6","signal":"co-change","verdict":"SEQUENCE"}
{"pair":"T10–T9","signal":"co-change","verdict":"SEQUENCE"}
{"gateFailures":["1 high-risk pair(s) would run concurrently: T10–T6 (score 0.5, co-change)"],"waves":[["T10","T6","T8"],["T7","T9"],["T11"]]}
exit=2
```

merge-forecast failed (exit 2): T10 and T6 both sat in wave 1 and their files have a **co-change**
history (score 0.5, high risk: `factory/bin/version-check.sh` in T6 and `factory/bin/janitor.sh` /
`.github/workflows/janitor.yml` in T10 were changed together by T3). Step 1 hit the same class of failure
and fixed it the same way (step 1 records/TB0.md §3.1): serialize through the CLI, never by hand —
`a ticket show <id> --json`, `jq` the `.ticket` with the new edge, `a ticket update <id> --input <file>
--expect <ticketHash>` as a dry run, then with `--write`.

1. **T6→T10** added (`expect 8d2a1d8e…`, dry run valid, then written). merge-forecast still exit 2:
   `T10–T9 (score 0.5, co-change)` in wave 2 (`[["T6","T8"],["T7","T10","T9"],["T11"]]`).
2. **T9→T10** added (same path). merge-forecast exit 0, `gateFailures: []`.

Both added edges follow the row order (TB1 = T6, TB4 = T9, TB5 = T10), so nothing downstream moves; the
SPEC's six edges are all present. Final state:

```
$ for t in T6 T7 T8 T9 T10 T11; do a ticket show $t --json | jq -r '[.ticket.id, .ticketHash[0:12], (.ticket.edges // [] | map(.to) | join(",")), (.ticket.body | split("\n")[0:3] | join(" ")), .ticket.title] | @tsv'; done
T6	a60e7d078cdd	T7,T9,T10	weight: light tier: 0 charter: C5	Write the node policy: vetto sandbox profiles, the ralon rails lock, the dcg hook, adapter pins
T7	a8b0ff6525dc	T11	weight: light tier: 1 charter: C5	Build the join wizard: probe, pinned install plan, token instructions, manifest committed to nodes
T8	72dd2f20ccf7	T9	weight: light tier: 0 charter: C5	Build the budget governor: version, heartbeat, kill switch, quiet hours and quota checks in one JSON verdict
T9	2b8a04f018df	T11,T10	weight: light tier: 1 charter: C5	Build the run loop and /factory:run: claim, sandboxed fleet run, and a branch per fleet reason
T10	f00b5e905e24	T11	weight: light tier: 0 charter: C3	Land the step-1 rulings in code: revoke hook, App-token post-merge, post-merge trailers, open-only ready duty
T11	26df53842c2e		weight: heavy tier: 2 charter: C5	Prove step 2 live on the dev box against a local origin, and close it out
exit=0
```

```
$ a ticket doctor | tail -1
All checks passed.
exit=0
```

```
$ a coldstart --all --offline --json | jq -c '.ok, (.results[] | {id, pass, gaps})'
true
{"id":"T10","pass":true,"gaps":[]}
{"id":"T11","pass":true,"gaps":[]}
{"id":"T6","pass":true,"gaps":[]}
{"id":"T7","pass":true,"gaps":[]}
{"id":"T8","pass":true,"gaps":[]}
{"id":"T9","pass":true,"gaps":[]}
exit=0
```

```
$ a merge-forecast --json | jq -c '{gateFailures, waves}'
{"gateFailures":[],"waves":[["T6","T8"],["T7","T9"],["T10"],["T11"]]}
exit=0
```

Scopes are narrow on purpose (each ticket names its own fakes and lib files rather than
`tests/fakes/**` / `factory/bin/lib/**`, which made every step-1 pair overlap); `tests/fixtures/**` is in
T9 and T11 only, and they are serialized. The ticket texts name ADR-0005's real flags so a fresh agent
does not code against the SPEC-v0.2 sketch.

## 6. Gotchas found (for the next rows)

1. **ralon's lock cannot live under `.ralon/`.** Patterns are relative to the `agent.lock` file and
   `..` is refused, so the lock has to sit at the root of the tree it protects and be kept out of
   `git status` (`info/exclude`), or fleet's dirty-tree check refuses. ADR-0005 decision 1; T6 proves it.
2. **One vetto cannot hold two policies.** The SPEC's build.toml/agent.toml split maps to: outer vetto
   with the agent policy + fleet's own bwrap repo-command plane (network denied) + `--model-plane-egress
   allowlist`. Whether bwrap nests inside vetto here is unmeasured — a T6 live proof.
3. **cux has no `status --json`.** The governor and the pre-strike gate read `cux usage show` (keyed by
   account e-mail: local only, never in an outbound payload, I8). With no account added it prints `{}`
   (`cux usage show` → `{}`, exit 0; it also ignores `--help`, §8);
   T8 must treat `{}` as "no quota data" and decide fail-closed vs. claim explicitly.
4. **fleet's success has no reason**: key the `case` on `exitCode == 0 && reason == null`.
5. **`--pre-strike-argv` needs an absolute argv[0] and an explicit env** (`--pre-strike-env`); fleet adds
   nothing to that env.
6. **fleet writes `.gitignore` and `.worktrees/` inside whatever tree it runs in.** Running it inside a
   loop-made worktree makes nested worktrees; the run loop must expect that.
7. **Live fleet still lacks `fleet.gate` and `adversarial-review`.** Without the latter prosecution fails
   closed and nothing merges (a TB6 cause to name, or to provide).
8. **`bwrap --unshare-all true` with no binds fails** on any box (no `/usr` in the new root). The join
   wizard's probe must bind `/` read-only, as §1.3 does, or it will refuse a good node.
9. `/sys/kernel/security/lsm` does not exist on WSL2; probe landlock with `vetto doctor --json` (or
   `/proc/config.gz`), not securityfs.
10. vetto's crate `repository` URL is dead; read docs from the crate source at the pin.

## 7. Result

DoD (a) §1; (b) §2 + §8; (c) §3 (dry run exit 0, sandbox `bubblewrap`, `refused: false`); (d) §4 + ADR-0005
(proposed); (e) §5 (doctor ok, coldstart gaps empty T6–T11, merge-forecast clean). `make test` 9 files
PASS, `make lint` exit 0 (§1.1). Commit `Ticket: scaffold`.

## 8. Appendix: `--help` of every subcommand the later rows use (verbatim)

### tamperguard 0.2.0

```
$ tamperguard --help
usage: tamperguard [-h] [--range RANGE] [--json] [--no-color]
                   [--fail-on {tamper,review,never}]
                   [path]

tamperguard — flag when a diff weakens tests to fake a green build.

Usage:
  git diff | tamperguard                 # scan a piped diff
  tamperguard --range origin/main...HEAD # scan a git range
  tamperguard path/to.diff               # scan a saved diff file
  tamperguard --json                     # machine output
Exit code: 0 = ok/review, 2 = tamper (so CI can gate on it).

positional arguments:
  path                  a saved unified-diff file

options:
  -h, --help            show this help message and exit
  --range RANGE         git range, e.g. origin/main...HEAD
  --json                machine-readable output
  --no-color
  --fail-on {tamper,review,never}
                        exit non-zero at/above this verdict (default: tamper)
exit=0
```

### dcg 0.15.3

```
$ dcg --help

  🛡  dcg 0.15.3
     Destructive Command Guard - multi-agent safety hook

  USAGE
  ──────────────────────────────────────────────────
    Runs as a pre-execution shell hook for Claude Code, Codex CLI,
    Gemini CLI, GitHub Copilot CLI, Cursor IDE, Hermes Agent,
    OpenCode, and Oh My Pi (omp).
    Compatible agents, including Codex, receive protocol-specific stdout JSON.

  CONFIGURATION
  ──────────────────────────────────────────────────
    Installers configure supported agent hooks automatically.
    Common Claude Code config in ~/.claude/settings.json:

    Hook commands must use the resolved absolute dcg executable path.
    Run dcg install to install or repair it safely.

  OPTIONS
  ──────────────────────────────────────────────────
    --version, -V     Print version information
    --help, -h        Print this help message

  COMMANDS
  ──────────────────────────────────────────────────
    test         Test a command against enabled packs
    explain      Explain why a command would be blocked/allowed
    doctor       Check installation and hook registration
    packs        List all available packs and their status
    pack         Pack management commands (info, validate)
    allowlist    Manage allowlist entries (add, list, remove)
    allow        Add a rule to the allowlist
    unallow      Remove a rule from the allowlist
    allow-once   Allow a blocked command once via short code
    create-new    Create a new file from stdin without overwriting
    scan         Scan files for destructive commands
    simulate     Simulate policy evaluation on command logs
    config       Show current configuration
    init         Generate a sample configuration file
    install      Install the hook into Claude Code settings
    uninstall    Remove the hook from Claude Code settings
    update       Update dcg to the latest release
    stats        Show local statistics from the log file
    history      Query command history database
    suggest-allowlist  Suggest allowlist patterns from history
    corpus       Run regression corpus tests
    hook         Run in explicit hook mode (batch support)
    completions  Generate shell completion scripts
    dev          Developer tools for pack development
    mcp-server   Start MCP server for agent integration

    Run dcg <command> --help for detailed help on a command.

  ENVIRONMENT
  ──────────────────────────────────────────────────
    DCG_VERBOSE=0-3     Verbosity level (0 = quiet, 3 = trace)
    DCG_LOG=<filter>    Hook-mode tracing to stderr (e.g. debug)
    DCG_QUIET=1       Suppress non-error output
    DCG_NO_COLOR=1    Disable colored output (same as NO_COLOR)
    DCG_FORMAT=text|json|sarif  Default output format (command-specific).
                          `sarif` is real SARIF only for `dcg scan`; on every
                          other command `sarif`/`structured` is an alias for
                          JSON, and `text` an alias for pretty. Per-command
                          accepted values: see `dcg <command> --help`.
    DCG_CONFIG=/path  Use explicit config file
    DCG_HOOK_TIMEOUT_MS=ms  Hook evaluation timeout budget
    DCG_ROBOT=1      Robot mode for AI agents (JSON output, no stderr)
    DCG_FAIL_CLOSED=1  Block (deny) on unparseable hook input (default: fail-open)

  BLOCKED COMMANDS
  ──────────────────────────────────────────────────

    Git (core.git pack)
      • git reset --hard
      • git checkout -- <path>
      • git restore (without --staged)
      • git clean -f
      • git push --force
      • git branch -D
      • git stash drop/clear

    Filesystem (core.filesystem pack)
      • rm -rf outside literal /tmp and /var/tmp subtrees

    📦 Additional packs: containers.docker, kubernetes.kubectl,
       database.postgresql, infrastructure.terraform, and more.

  ──────────────────────────────────────────────────
    📖 https://github.com/Dicklesworthstone/destructive_command_guard

exit=0
```

```
$ dcg test --help
Test a command against enabled packs

Two differences from the hook are worth knowing before you use this to validate an override or replay a corpus of real blocks (#402):

The hook evaluates the full tool payload, including heredoc bodies; `dcg test` evaluates the command line you give it.

The hook is told which tool it is gating, so a `Bash` payload is evaluated as POSIX. `dcg test` has no such context and defaults to `--dialect unknown`, which can deny where the hook allows.

That union is not proven complete in both directions, so do not read an `allow` here as "no hook would block this". The example this warning used to carry is fixed — `Remove-Item -Recurse -Force /etc` denied under `--dialect ps` and was ALLOWED by the default, and now denies under both (#491) — but only that one command was measured, not every pack. Pass the dialect you actually care about when the answer matters; `--dialect posix` reproduces the `Bash` hook path exactly (#451).

Usage: dcg test [OPTIONS] [COMMAND]

Arguments:
  [COMMAND]
          Command to test

Options:
      --stdin
          Read the command to test from stdin
          
          This keeps destructive test text off the parent shell command line, which is useful when dcg is itself installed as that shell's hook.

  -v, --verbose...
          Increase verbosity (-v, -vv, -vvv)
          
          [env: DCG_VERBOSE=]

  -c, --config <PATH>
          Use a specific config file (overrides default config discovery)

  -q, --quiet
          Suppress non-error output
          
          [env: DCG_QUIET=]

      --legacy-output
          Use legacy output rendering (fallback if rich output causes issues)
          
          [env: DCG_LEGACY_OUTPUT=]

      --with-packs <WITH_PACKS>
          Additional packs to enable for this test

      --explain
          Show detailed decision trace (same as `dcg explain`)

  -f, --format <FORMAT>
          Output format (json for structured output, pretty for human-readable)

          Possible values:
          - pretty: Human-readable colored output
          - json:   Structured JSON output
          - toon:   TOON output for token-efficient structured data
          
          [env: DCG_FORMAT=]
          [default: pretty]

      --no-suggestions
          Disable suggestion output in warnings/denials
          
          [env: DCG_NO_SUGGESTIONS=]

      --no-color
          Disable colored output

      --robot
          Enable robot/machine mode for AI agent integration
          
          When enabled: - All output is JSON on stdout - stderr is completely silent (no rich output, no human messages) - Exit codes follow standardized values (see docs/adr-002-robot-mode-api.md) - Human-friendly decorations are suppressed
          
          This flag is designed for AI coding agents (Claude Code, Gemini CLI, etc.) that need to parse dcg's output programmatically.
          
          Exit codes in robot mode: - 0: Success / Allow - 1: Denied / Blocked / Indeterminate - 2: Warning (with --fail-on warn) - 3: Configuration error - 4: Parse/input error - 5: IO error
          
          Enable robot mode for machine-friendly output (also enabled by DCG_ROBOT=1 env var). In robot mode: always outputs JSON, silent stderr, standardized exit codes.

      --agent <AGENT>
          Override automatic agent detection for agent-specific profiles

      --heredoc-scan
          Enable heredoc/inline-script scanning (overrides config)

      --no-heredoc-scan
          Disable heredoc/inline-script scanning (overrides config)

      --heredoc-timeout <MS>
          Timeout budget for heredoc extraction (milliseconds)

      --heredoc-languages <LANGS>
          Languages to scan (comma-separated). Example: python,bash,javascript

      --enforce-budget
          Apply the live hook's wall-clock evaluation deadline

      --force
          Bypass a soft block from the graduated response system

      --dialect <DIALECT>
          Evaluate a single shell dialect instead of all of them (#269)
          
          `--dialect posix` reproduces the evaluation path the Bash PreToolUse hook takes; the default (`unknown`) fans out to every dialect because the CLI cannot know the source shell.

          Possible values:
          - unknown: Union over dialects (CLI default; matches no single hook path)
          - posix:   POSIX shell — the dialect the `Bash` PreToolUse hook resolves
          - ps:      PowerShell — the dialect the `PowerShell` PreToolUse hook resolves
          - cmd:     Windows `cmd.exe`
          
          [env: DCG_DIALECT=]
          [default: unknown]

  -h, --help
          Print help (see a summary with '-h')

exit=0
```

```
$ dcg explain --help
Explain why a command would be blocked or allowed (decision trace)

Shows the full decision pipeline: keyword gating, pack evaluation, pattern matching, and allowlist checks.

Usage: dcg explain [OPTIONS] <COMMAND>

Arguments:
  <COMMAND>
          Command to explain

Options:
  -f, --format <FORMAT>
          Output format

          Possible values:
          - pretty:  Human-readable colored output
          - compact: Compact single-line output
          - json:    Structured JSON output
          
          [env: DCG_FORMAT=]
          [default: pretty]

  -v, --verbose...
          Increase verbosity (-v, -vv, -vvv)
          
          [env: DCG_VERBOSE=]

  -q, --quiet
          Suppress non-error output
          
          [env: DCG_QUIET=]

      --with-packs <WITH_PACKS>
          Additional packs to enable for this evaluation

      --dialect <DIALECT>
          Evaluate a single shell dialect instead of all of them (#269)
          
          `--dialect posix` reproduces the evaluation path the Bash PreToolUse hook takes; the default (`unknown`) fans out to every dialect because the CLI cannot know the source shell.

          Possible values:
          - unknown: Union over dialects (CLI default; matches no single hook path)
          - posix:   POSIX shell — the dialect the `Bash` PreToolUse hook resolves
          - ps:      PowerShell — the dialect the `PowerShell` PreToolUse hook resolves
          - cmd:     Windows `cmd.exe`
          
          [env: DCG_DIALECT=]
          [default: unknown]

      --legacy-output
          Use legacy output rendering (fallback if rich output causes issues)
          
          [env: DCG_LEGACY_OUTPUT=]

      --no-color
          Disable colored output globally
          
          [env: DCG_NO_COLOR=]

      --no-suggestions
          Disable suggestion output in warnings/denials
          
          [env: DCG_NO_SUGGESTIONS=]

      --robot
          Enable robot/machine mode for AI agent integration
          
          When enabled: - All output is JSON on stdout - stderr is completely silent (no rich output, no human messages) - Exit codes follow standardized values (see docs/adr-002-robot-mode-api.md) - Human-friendly decorations are suppressed
          
          This flag is designed for AI coding agents (Claude Code, Gemini CLI, etc.) that need to parse dcg's output programmatically.
          
          Exit codes in robot mode: - 0: Success / Allow - 1: Denied / Blocked / Indeterminate - 2: Warning (with --fail-on warn) - 3: Configuration error - 4: Parse/input error - 5: IO error
          
          Enable robot mode for machine-friendly output (also enabled by DCG_ROBOT=1 env var). In robot mode: always outputs JSON, silent stderr, standardized exit codes.

      --agent <AGENT>
          Override automatic agent detection for agent-specific profiles

  -h, --help
          Print help (see a summary with '-h')

exit=0
```

```
$ dcg hook --help
Run in hook mode with batch processing support

Explicit hook mode for processing commands from stdin. Any batch option — `--batch`, `--parallel`, `--workers`, `--continue-on-error` or `--with-packs` — reads JSONL (one JSON hook input per line), outputs JSONL with decisions, and exits non-zero if any line was denied.

With no batch option, `dcg hook` behaves identically to running `dcg` with no subcommand: one hook payload in, one agent-protocol response out, carrying a denial on stdout with exit 0.

Usage: dcg hook [OPTIONS]

Options:
      --batch
          Enable batch mode: read JSONL from stdin, output JSONL results
          
          Each line should be a JSON hook input: ```jsonl {"tool_name":"Bash","tool_input":{"command":"rm -rf /"}} {"tool_name":"Bash","tool_input":{"command":"git status"}} ```
          
          Output format: ```jsonl {"index":0,"decision":"deny","rule_id":"core.filesystem:rm-rf-root"} {"index":1,"decision":"allow"} ```

  -v, --verbose...
          Increase verbosity (-v, -vv, -vvv)
          
          [env: DCG_VERBOSE=]

      --parallel
          Process commands in parallel (implies --batch)
          
          Uses multiple threads to evaluate commands concurrently. Output maintains input order via the `index` field.

  -q, --quiet
          Suppress non-error output
          
          [env: DCG_QUIET=]

      --legacy-output
          Use legacy output rendering (fallback if rich output causes issues)
          
          [env: DCG_LEGACY_OUTPUT=]

      --workers <WORKERS>
          Number of parallel workers (default: number of CPUs)
          
          [default: 0]

      --continue-on-error
          Continue processing on parse errors (skip invalid lines)

      --no-color
          Disable colored output globally
          
          [env: DCG_NO_COLOR=]

      --no-suggestions
          Disable suggestion output in warnings/denials
          
          [env: DCG_NO_SUGGESTIONS=]

      --with-packs <WITH_PACKS>
          Additional packs to enable for this hook run (comma-separated)
          
          Mirrors `dcg test --with-packs`: enables extra packs (e.g. `containers.docker`, `kubernetes.kubectl`) for the batch evaluation without editing a config file (issue #151).

      --robot
          Enable robot/machine mode for AI agent integration
          
          When enabled: - All output is JSON on stdout - stderr is completely silent (no rich output, no human messages) - Exit codes follow standardized values (see docs/adr-002-robot-mode-api.md) - Human-friendly decorations are suppressed
          
          This flag is designed for AI coding agents (Claude Code, Gemini CLI, etc.) that need to parse dcg's output programmatically.
          
          Exit codes in robot mode: - 0: Success / Allow - 1: Denied / Blocked / Indeterminate - 2: Warning (with --fail-on warn) - 3: Configuration error - 4: Parse/input error - 5: IO error
          
          Enable robot mode for machine-friendly output (also enabled by DCG_ROBOT=1 env var). In robot mode: always outputs JSON, silent stderr, standardized exit codes.

      --agent <AGENT>
          Override automatic agent detection for agent-specific profiles

  -h, --help
          Print help (see a summary with '-h')

exit=0
```

```
$ dcg init --help
Generate a sample configuration file

Usage: dcg init [OPTIONS]

Options:
  -o, --output <OUTPUT>
          Output path (defaults to stdout)

  -v, --verbose...
          Increase verbosity (-v, -vv, -vvv)
          
          [env: DCG_VERBOSE=]

      --force
          Overwrite existing file

  -q, --quiet
          Suppress non-error output
          
          [env: DCG_QUIET=]

      --auto
          Auto-detect packs from project files in the current directory

      --legacy-output
          Use legacy output rendering (fallback if rich output causes issues)
          
          [env: DCG_LEGACY_OUTPUT=]

      --dry-run
          Preview what --auto would enable without writing anything

      --no-color
          Disable colored output globally
          
          [env: DCG_NO_COLOR=]

      --no-suggestions
          Disable suggestion output in warnings/denials
          
          [env: DCG_NO_SUGGESTIONS=]

      --project-dir <PROJECT_DIR>
          Directory to scan for project files (defaults to current directory)

      --robot
          Enable robot/machine mode for AI agent integration
          
          When enabled: - All output is JSON on stdout - stderr is completely silent (no rich output, no human messages) - Exit codes follow standardized values (see docs/adr-002-robot-mode-api.md) - Human-friendly decorations are suppressed
          
          This flag is designed for AI coding agents (Claude Code, Gemini CLI, etc.) that need to parse dcg's output programmatically.
          
          Exit codes in robot mode: - 0: Success / Allow - 1: Denied / Blocked / Indeterminate - 2: Warning (with --fail-on warn) - 3: Configuration error - 4: Parse/input error - 5: IO error
          
          Enable robot mode for machine-friendly output (also enabled by DCG_ROBOT=1 env var). In robot mode: always outputs JSON, silent stderr, standardized exit codes.

      --agent <AGENT>
          Override automatic agent detection for agent-specific profiles

  -h, --help
          Print help (see a summary with '-h')

exit=0
```

```
$ dcg config --help
Show current configuration (or manage config tooling)

With no subcommand, prints the effective merged configuration. The `schema` subcommand emits the JSON Schema for `config.toml` (for editor autocomplete/validation via Even Better TOML / taplo).

Usage: dcg config [OPTIONS] [COMMAND]

Commands:
  schema  Print the JSON Schema for dcg's `config.toml`
  help    Print this message or the help of the given subcommand(s)

Options:
      --format <FORMAT>
          Output format (`pretty` for humans, `json` for agents/scripts)

          Possible values:
          - pretty: Human-readable text output
          - json:   Structured JSON output for programmatic consumption
          
          [env: DCG_FORMAT=]
          [default: pretty]

  -v, --verbose...
          Increase verbosity (-v, -vv, -vvv)
          
          [env: DCG_VERBOSE=]

  -q, --quiet
          Suppress non-error output
          
          [env: DCG_QUIET=]

      --legacy-output
          Use legacy output rendering (fallback if rich output causes issues)
          
          [env: DCG_LEGACY_OUTPUT=]

      --no-color
          Disable colored output globally
          
          [env: DCG_NO_COLOR=]

      --no-suggestions
          Disable suggestion output in warnings/denials
          
          [env: DCG_NO_SUGGESTIONS=]

      --robot
          Enable robot/machine mode for AI agent integration
          
          When enabled: - All output is JSON on stdout - stderr is completely silent (no rich output, no human messages) - Exit codes follow standardized values (see docs/adr-002-robot-mode-api.md) - Human-friendly decorations are suppressed
          
          This flag is designed for AI coding agents (Claude Code, Gemini CLI, etc.) that need to parse dcg's output programmatically.
          
          Exit codes in robot mode: - 0: Success / Allow - 1: Denied / Blocked / Indeterminate - 2: Warning (with --fail-on warn) - 3: Configuration error - 4: Parse/input error - 5: IO error
          
          Enable robot mode for machine-friendly output (also enabled by DCG_ROBOT=1 env var). In robot mode: always outputs JSON, silent stderr, standardized exit codes.

      --agent <AGENT>
          Override automatic agent detection for agent-specific profiles

  -h, --help
          Print help (see a summary with '-h')

exit=0
```

```
$ dcg pack --help
Pack management commands (info, validate)

Usage: dcg pack [OPTIONS] <COMMAND>

Commands:
  info      Show information about a specific pack (built-in or external)
  validate  Validate an external pack YAML file
  help      Print this message or the help of the given subcommand(s)

Options:
  -v, --verbose...
          Increase verbosity (-v, -vv, -vvv)
          
          [env: DCG_VERBOSE=]

  -q, --quiet
          Suppress non-error output
          
          [env: DCG_QUIET=]

      --legacy-output
          Use legacy output rendering (fallback if rich output causes issues)
          
          [env: DCG_LEGACY_OUTPUT=]

      --no-color
          Disable colored output globally
          
          [env: DCG_NO_COLOR=]

      --no-suggestions
          Disable suggestion output in warnings/denials
          
          [env: DCG_NO_SUGGESTIONS=]

      --robot
          Enable robot/machine mode for AI agent integration
          
          When enabled: - All output is JSON on stdout - stderr is completely silent (no rich output, no human messages) - Exit codes follow standardized values (see docs/adr-002-robot-mode-api.md) - Human-friendly decorations are suppressed
          
          This flag is designed for AI coding agents (Claude Code, Gemini CLI, etc.) that need to parse dcg's output programmatically.
          
          Exit codes in robot mode: - 0: Success / Allow - 1: Denied / Blocked / Indeterminate - 2: Warning (with --fail-on warn) - 3: Configuration error - 4: Parse/input error - 5: IO error
          
          Enable robot mode for machine-friendly output (also enabled by DCG_ROBOT=1 env var). In robot mode: always outputs JSON, silent stderr, standardized exit codes.

      --agent <AGENT>
          Override automatic agent detection for agent-specific profiles

  -h, --help
          Print help (see a summary with '-h')

exit=0
```

### cux 0.4.1

```
$ cux --help
cux — Run multiple Claude Code Pro/Max accounts as one

USAGE
  cux [claude-args...]                    run claude under the wrapper (default)
  cux run [claude-args...]                same, explicit
  cux add [--slot N] [--alias NAME] [--no-alias] [--force]
                                          add the currently logged-in account
  cux list                                list managed accounts
  cux alias <slot|email|alias> <name>     set a short alias (e.g. work, personal)
  cux project create <name> [--dir PATH]  scope a directory to its own seat pool
  cux project assign <name> <seat> [...]  add seats to a project (seats can be shared)
  cux project unassign <name> <seat> [...]
  cux project list [--refresh]            projects + live usage of their seats
  cux project stats <name>                usage detail for one project
  cux project remove <name>               unbind a directory (accounts untouched)
  cux alias <slot|email|alias> --clear    remove alias
  cux switch <slot|email|alias>           swap the active account (manual; requires
                                          restart unless run from /switch inside)
  cux force-switch [slot|email|alias]     emergency swap for an active cux session
                                          when Claude will not run /switch
  cux remove [--force] <slot|email|alias> remove an account from cux
  cux status                              show live login + cux state
  cux sessions                            list running cux sessions, and recently ended ones with their resume line
  cux attach [pid]                        watch and control a running session
  cux support                             show support URL
  cux docs                                show documentation URL
  cux setup                               install /switch, /cux:* + Claude Code hooks
  cux install-hooks                       install Claude Code hooks only
  cux uninstall-hooks                     remove cux's entries from settings.json
  cux history [-n N] [--json]             show recent account swaps
  cux history --clear                     delete the swap history
  cux config show                         print current configuration
  cux config keys                         list every settable key
  cux config edit                         interactive settings editor
  cux config set <key> <value>            update a single setting
  cux usage refresh                       fetch fresh usage for every account
  cux usage show                          print the on-disk usage cache (JSON)
  cux commands                            print cux's command surface (JSON)
  cux upgrade                             update cux using npm or the installer
  cux hook <event>                        internal: invoked by Claude Code
  cux version                             print version
  cux help                                show this help

INLINE SWITCHING
  Once set up, type /switch [<slot|email|alias>] from inside a Claude Code
  session started via cux. You can also use /cux:switch, /cux:add,
  /cux:list, /cux:status, /cux:support, /cux:config, /cux:remove,
  and /cux:usage-refresh from inside the
  session. Manual and rate-limit swaps reconnect with --resume.
exit=0
```

```
$ cux version
cux 0.4.1
exit=0
```

```
$ cux status --help
Usage of status:
  -no-refresh
    	show cached usage without fetching fresh data
exit=0
```

```
$ cux status --json
flag provided but not defined: -json
Usage of status:
  -no-refresh
    	show cached usage without fetching fresh data
exit=2
```

```
$ cux usage show --help
{}
exit=0
```

```
$ cux commands
{
  "schema": 1,
  "version": "0.4.1",
  "commands": [
    {
      "path": [
        "add"
      ],
      "summary": "add the currently logged-in account",
      "mutates": true
    },
    {
      "path": [
        "alias"
      ],
      "summary": "set or clear an account's short alias",
      "args": [
        {
          "name": "account",
          "kind": "ident",
          "required": true
        },
        {
          "name": "alias",
          "kind": "ident",
          "required": false
        }
      ],
      "mutates": true
    },
    {
      "path": [
        "attach"
      ],
      "summary": "attach to a running session",
      "args": [
        {
          "name": "pid",
          "kind": "ident",
          "required": false
        }
      ],
      "mutates": true
    },
    {
      "path": [
        "commands"
      ],
      "summary": "print cux's command surface as JSON",
      "mutates": false
    },
    {
      "path": [
        "config"
      ],
      "summary": "cux configuration",
      "mutates": false
    },
    {
      "path": [
        "config",
        "edit"
      ],
      "summary": "interactive settings editor",
      "mutates": true
    },
    {
      "path": [
        "config",
        "keys"
      ],
      "summary": "list every settable key",
      "mutates": false
    },
    {
      "path": [
        "config",
        "set"
      ],
      "summary": "update a single setting",
      "args": [
        {
          "name": "key",
          "kind": "ident",
          "required": true
        },
        {
          "name": "value",
          "kind": "text",
          "required": true
        }
      ],
      "mutates": true
    },
    {
      "path": [
        "config",
        "show"
      ],
      "summary": "print the current configuration as JSON",
      "mutates": false
    },
    {
      "path": [
        "docs"
      ],
      "summary": "show the documentation URL",
      "mutates": false
    },
    {
      "path": [
        "force-switch"
      ],
      "aliases": [
        "rescue-switch"
      ],
      "summary": "emergency swap for an active cux session",
      "args": [
        {
          "name": "account",
          "kind": "ident",
          "required": false
        }
      ],
      "mutates": true
    },
    {
      "path": [
        "help"
      ],
      "aliases": [
        "--help",
        "-h"
      ],
      "summary": "print help",
      "mutates": false
    },
    {
      "path": [
        "history"
      ],
      "summary": "show or clear recent account swaps",
      "mutates": false
    },
    {
      "path": [
        "install-hooks"
      ],
      "summary": "install Claude Code hooks only",
      "mutates": true
    },
    {
      "path": [
        "list"
      ],
      "aliases": [
        "ls"
      ],
      "summary": "list managed accounts",
      "mutates": false
    },
    {
      "path": [
        "project"
      ],
      "summary": "scope directories to their own seat pools",
      "mutates": false
    },
    {
      "path": [
        "project",
        "assign"
      ],
      "summary": "add seats to a project",
      "args": [
        {
          "name": "name",
          "kind": "ident",
          "required": true
        },
        {
          "name": "seat",
          "kind": "ident",
          "required": true,
          "variadic": true
        }
      ],
      "mutates": true
    },
    {
      "path": [
        "project",
        "create"
      ],
      "summary": "scope a directory to its own seat pool",
      "args": [
        {
          "name": "name",
          "kind": "ident",
          "required": true
        },
        {
          "name": "dir",
          "kind": "path",
          "required": false
        }
      ],
      "mutates": true
    },
    {
      "path": [
        "project",
        "list"
      ],
      "aliases": [
        "ls"
      ],
      "summary": "projects and the live usage of their seats",
      "mutates": false
    },
    {
      "path": [
        "project",
        "remove"
      ],
      "aliases": [
        "rm"
      ],
      "summary": "unbind a directory, leaving accounts untouched",
      "args": [
        {
          "name": "name",
          "kind": "ident",
          "required": true
        }
      ],
      "mutates": true
    },
    {
      "path": [
        "project",
        "stats"
      ],
      "summary": "usage detail for one project",
      "args": [
        {
          "name": "name",
          "kind": "ident",
          "required": true
        }
      ],
      "mutates": false
    },
    {
      "path": [
        "project",
        "unassign"
      ],
      "summary": "remove seats from a project",
      "args": [
        {
          "name": "name",
          "kind": "ident",
          "required": true
        },
        {
          "name": "seat",
          "kind": "ident",
          "required": true,
          "variadic": true
        }
      ],
      "mutates": true
    },
    {
      "path": [
        "remove"
      ],
      "aliases": [
        "rm"
      ],
      "summary": "remove an account from cux",
      "args": [
        {
          "name": "account",
          "kind": "ident",
          "required": true
        }
      ],
      "mutates": true
    },
    {
      "path": [
        "run"
      ],
      "summary": "run claude under the wrapper",
      "args": [
        {
          "name": "claude-args",
          "kind": "text",
          "required": false,
          "variadic": true
        }
      ],
      "mutates": false
    },
    {
      "path": [
        "sessions"
      ],
      "summary": "list running cux sessions",
      "mutates": false
    },
    {
      "path": [
        "setup"
      ],
      "summary": "install slash commands and Claude Code hooks",
      "mutates": true
    },
    {
      "path": [
        "status"
      ],
      "summary": "show the live login and cux state",
      "mutates": false
    },
    {
      "path": [
        "support"
      ],
      "summary": "show the support URL",
      "mutates": false
    },
    {
      "path": [
        "switch"
      ],
      "summary": "swap the active account",
      "args": [
        {
          "name": "account",
          "kind": "ident",
          "required": true
        }
      ],
      "mutates": true
    },
    {
      "path": [
        "uninstall-hooks"
      ],
      "summary": "remove cux's entries from settings.json",
      "mutates": true
    },
    {
      "path": [
        "upgrade"
      ],
      "summary": "update cux using npm or the installer",
      "mutates": true
    },
    {
      "path": [
        "usage"
      ],
      "summary": "the usage cache",
      "mutates": false
    },
    {
      "path": [
        "usage",
        "refresh"
      ],
      "summary": "fetch fresh usage for every account",
      "mutates": true
    },
    {
      "path": [
        "usage",
        "show"
      ],
      "summary": "print the on-disk usage cache as JSON",
      "mutates": false
    },
    {
      "path": [
        "version"
      ],
      "aliases": [
        "--version"
      ],
      "summary": "print the cux version",
      "mutates": false
    }
  ],
  "notes": {
    "flags": "not described; every command parses its own flags, so a client that needs one must hard-code it",
    "internal": "commands cux reserves for its own hooks and slash commands are omitted"
  }
}
exit=0
```

### vetto 0.6.5

```
$ grep -E "^(  Installing|   Installed|exit=)" /tmp/tb0/vetto-install.log; vetto --version; vetto --help
  Installing vetto v0.6.5
  Installing /home/musicofhel/.cargo/bin/vetto
   Installed package `vetto v0.6.5` (executable `vetto`)
exit=0
vetto 0.6.5
1. vetto enable <agent>
2. Run your agent as usual — it runs in the sandbox under the hood.

Daemon-less sandbox + security layer for AI coding agents.

Usage: vetto [OPTIONS] [-- <COMMAND [ARGS...]>...] [COMMAND]

Commands:
  mask          Stream stdin to stdout with real-time secret and API key redaction
  enable        Enable transparent sandbox wrapper for an AI coding agent (e.g. `vetto enable claude`)
  disable       Disable transparent sandbox wrapper for an AI coding agent (e.g. `vetto disable claude`)
  allow         Grant the agent access to a path or network domain (writes policy)
  deny          Explicitly deny reads of a path (secret masking) or network domain in the policy
  doctor        Diagnose platform support: tiers, landlock ABI, userns, seccomp, audit feed
  status        List active sandboxed sessions and cleanup stale metadata
  kill          Terminate a running session or process, or kill hung runaway sessions
  verify        Verify the sandbox boundary WITHOUT running any agent: secret paths, network reachability, and write-outside checks execute inside a throwaway sandbox built from the resolved policy
  run           Run an agent command under the Vetto sandbox supervisor
  undo          Restore project files from a previous session snapshot (instant rollback)
  ephemeral     Run an agent in a disposable ephemeral sandbox with instant rollback on cancel/failure
  bench         High-throughput benchmark execution fast-path (SWE-bench adapter)
  diff          Inspect agent changes against session snapshot (modified/added/deleted files & security)
  watchdog      Inspect active autonomous loop counters, failing commands, and monitored workspaces
  init          Analyze project ecosystem and generate a tailored policy.toml policy
  mcp           Run or wrap Model Context Protocol (MCP) servers
  policy        Explain the effective policy or lint it for dangerous configurations
  completions   Print shell completion script for the requested shell
  man           Generate man page to stdout
  shell-env     Print environment variable export lines for shell integration and PS1
  scan-secrets  Scan project directory for exposed secrets and credentials
  events        Tail and filter JSONL session event logs
  audit         Inspect recorded session events, filesystem denials, blocked egress, and filtered syscalls
  update        Print instructions and commands to update Vetto to the latest release
  help          Print this message or the help of the given subcommand(s)

Arguments:
  [COMMAND [ARGS...]]...  Agent command to supervise; everything after `--`

Options:
      --profile <NAME>                 Built-in policy profile [default: default]
      --preset <PRESET>                Base security preset: paranoid | balanced | yolo
      --policy <PATH>                  Explicit policy TOML layer applied after the profile and project policy
      --net <MODE>                     Network mode: off | allowlist:<domain,domain,...> | strict:<domain:port,domain:port,...>
      --tui <MODE>                     UI mode: statusline | none
      --backend <BACKEND>              Explicit sandbox backend: auto | process
      --lpac                           Run Windows AppContainer in Less Privileged AppContainer (LPAC) mode
      --observe-seccomp                Attach a best-effort blocked-attempt observation tap (Linux). Observation ONLY — Landlock remains the sole enforcer
      --read-only-caches               Mount host package caches (npm, pip, cargo, etc.) read-only to prevent tampering
      --tmpfs-tmp                      Mount a 512MB tmpfs over /tmp (requires Linux)
      --shadow                         Shadow mode: policy layer logs "would deny" instead of blocking in verification/preflight. Note: Kernel sandbox (Landlock/seccomp) cannot be shadowed; shadow mode applies to policy-layer verification
      --jsonl <PATH>                   Append every session event as JSON lines to PATH
      --report <FMTS>                  Post-session report formats, comma separated: html,md,json,sarif
      --report-dir <PATH>              Directory in which reports are stored (defaults to $PROJECT/.vetto/reports)
      --report-auto-cleanup            Compatibility spelling for report retention cleanup
      --no-report-auto-cleanup         Keep reports without automatic retention cleanup
      --report-retention <COUNT>       Maximum number of reports to retain (default: 50)
      --report-max-age-secs <SECONDS>  Remove reports older than this many seconds when cleanup is enabled
      --fail-on-block [<THRESHOLD>]    Exit non-zero when at least THRESHOLD blocked attempts are observed. With no value, THRESHOLD defaults to 1
      --git-ssh                        Route git/SSH connections through vetto's in-process relay helper
      --timeout <DURATION>             Kill the sandboxed session after DURATION without the agent finishing (e.g. 90s, 30m, 2h). Enforced with --tui=none (CI mode); other TUI modes warn and ignore it
      --adaptive-timeout               Calculate and use an adaptive timeout based on past successful sessions
      --limits <SPEC>                  Resource ceilings for the agent process, comma separated: cpu=SECONDS, as=BYTES, procs=N, nofile=N, fsize=BYTES. Merged strictest-wins with any limits from the policy layers
      --verify                         Run the boundary verification battery against the resolved policy before spawning the agent. Any leak aborts the session (fail-closed)
      --dry-run                        Print resolved policy + tier plan and exit (nothing enforced)
      --ci                             Non-interactive mode for CI: implies --tui=none and a JSON summary on stdout
  -q, --quiet                          Suppress diagnostic and non-essential progress messages on stderr
  -v, --verbose                        Verbose diagnostics on stderr
  -a, --agent <NAME>                   Select an agent preset
      --deny-glob <PATTERN>            Additional glob patterns to resolve and deny (e.g. "**/*.pem")
      --git-guard                      Enforce Git branch protection (refuse write on main/master) and block destructive git pushes
      --auto-branch                    Automatically create and switch to a temporary session branch if on main/master
      --snapshot                       Take a project snapshot before session starts and enable rollback
      --ephemeral                      Disposable session: auto-rollback on failure, or prompt [Y/n] to keep changes on success
      --auto-deny-secrets              Automatically scan project for secrets at session start and deny them
      --mask-secrets                   Redact secrets in real-time from stdout/stderr streams
      --no-mask-secrets                Disable real-time secret redaction
      --net-quota <DOMAIN=SIZE>        Per-domain network traffic quota (e.g. --net-quota api.openai.com=100mb, --net-quota github.com=1gb)
      --block-doh                      Block DNS-over-HTTPS (DoH) and DNS-over-TLS (DoT) endpoints
      --no-block-doh                   Disable DoH and DoT blocking
      --is-container                   Exits with 0 (and prints true) if running inside a container, 1 otherwise
      --benchmark                      Fast-path benchmark mode (sub-4ms cold-start, pure JSON telemetry)
  -h, --help                           Print help
  -V, --version                        Print version

Examples:
  vetto enable claude
  vetto enable codex
  claude
  vetto doctor
  vetto status
  vetto allow ./target
  vetto deny ~/.aws/credentials
  vetto -- python agent.py
exit=0
```

```
$ vetto run --help
Run an agent command under the Vetto sandbox supervisor

Usage: vetto run [OPTIONS] [COMMAND] [ARGS]...

Arguments:
  [COMMAND]  Target agent binary or command
  [ARGS]...  Arguments passed to the agent

Options:
      --benchmark  Run in high-throughput SWE-bench benchmark mode (isolated CoW tmpfs, cgroups limits, no DB)
  -q, --quiet      Suppress diagnostic and non-essential progress messages on stderr
  -v, --verbose    Verbose diagnostics on stderr
  -h, --help       Print help
exit=0
```

```
$ vetto policy --help
Explain the effective policy or lint it for dangerous configurations

Usage: vetto policy [OPTIONS] <COMMAND>

Commands:
  explain  Print the effective policy after all layers merge: tier, network, roots, masked secrets, limits, environment
  show     Show the resolved effective policy
  lint     Check the resolved policy for dangerous configurations. Exits non-zero with --strict when any finding is reported
  import   Import permissions from external agent configurations (e.g. claude, codex)
  use      Adopt a community policy into the current project
  list     List available community policies
  help     Print this message or the help of the given subcommand(s)

Options:
  -q, --quiet    Suppress diagnostic and non-essential progress messages on stderr
  -v, --verbose  Verbose diagnostics on stderr
  -h, --help     Print help
exit=0
```

```
$ vetto verify --help
Verify the sandbox boundary WITHOUT running any agent: secret paths, network reachability, and write-outside checks execute inside a throwaway sandbox built from the resolved policy

Usage: vetto verify [OPTIONS]

Options:
      --json            Emit machine-readable JSON
      --profile <NAME>  Built-in policy profile to verify (e.g. claude, codex, default, strict)
      --policy <PATH>   Explicit policy TOML layer applied after the profile
      --simulate        Fast simulated verification mode (evaluates sealed contract without sandbox spawn)
  -q, --quiet           Suppress diagnostic and non-essential progress messages on stderr
  -v, --verbose         Verbose diagnostics on stderr
  -h, --help            Print help
exit=0
```

```
$ vetto doctor --help
Diagnose platform support: tiers, landlock ABI, userns, seccomp, audit feed

Usage: vetto doctor [OPTIONS]

Options:
      --probe               Additionally verify that every display_only_deny path is truly unreachable from inside a throwaway sandbox
      --check-agent <NAME>  Probe a known agent executable with a bounded --version command
      --fix                 Show concrete remediation commands and steps for missing sandbox primitives
      --preflight           Run comprehensive diagnostic preflight verification
      --json                Emit machine-readable diagnostic JSON
  -q, --quiet               Suppress diagnostic and non-essential progress messages on stderr
  -v, --verbose             Verbose diagnostics on stderr
  -h, --help                Print help
exit=0
```

```
$ vetto init --help
Analyze project ecosystem and generate a tailored policy.toml policy

Usage: vetto init [OPTIONS]

Options:
  -f, --force    Overwrite existing policy if present
  -q, --quiet    Suppress diagnostic and non-essential progress messages on stderr
  -v, --verbose  Verbose diagnostics on stderr
  -h, --help     Print help
exit=0
```

### ralon 0.1.7

```
$ grep -E "^(  Installing|   Installed|exit=)" /tmp/tb0/ralon-install.log; ralon --version; ralon --help
  Installing ralon v0.1.7
  Installing /home/musicofhel/.cargo/bin/ralon
   Installed package `ralon v0.1.7` (executable `ralon`)
exit=0
ralon 0.1.7
Filesystem policy for AI coding agents: kernel-enforced write protection driven by an agent.lock file

Usage: ralon [OPTIONS] <COMMAND>

Commands:
  install    Set this machine up once. After that: declare a policy, and enforcement starts on its own
  scope      Manage the directories your projects live in
  uninstall  Remove the background supervisor and release everything it holds
  pause      Release one project so its policy can be edited, then take it back
  resume     Resume enforcement for a paused project
  daemon     The background supervisor itself. Started by the OS, not by people
  init       Write a starter agent.lock and wire up the agents
  check      Report what the policy protects, or whether given paths are protected
  status     Show the policy and which enforcement backends this kernel offers
  hook       Install or run the agent hook
  guard      Protect the project against every process, with no command to wrap
  run        Run a command that cannot modify the protected paths
  help       Print this message or the help of the given subcommand(s)

Options:
  -C, --dir <DIR>  Directory to look for agent.lock in (default: the current directory)
  -h, --help       Print help
  -V, --version    Print version
exit=0
```

```
$ ralon run --help
Run a command that cannot modify the protected paths

Usage: ralon run [OPTIONS] <COMMAND>...

Arguments:
  <COMMAND>...
          Command to run, e.g. `ralon run -- claude`

Options:
      --backend <BACKEND>
          Enforcement backend

          Possible values:
          - auto:      Pick the strongest backend the kernel supports
          - mount:     Read-only bind mounts in a locked mount namespace. Precise: only the protected paths change behaviour
          - landlock:  Landlock LSM. Needs no namespaces, but cannot express "everything except this file", so directories leading to a protected path become create-restricted
          - locks:     Windows: exclusive share-mode handles. Blocks every process rather than every agent, and lasts exactly as long as the process holding them — `run` for the life of the command, `guard` until it is stopped
          - seatbelt:  macOS: a Seatbelt profile, which can express a denial directly. Precise like `mount`, inherited like `landlock`, and the only backend whose rules cover files that do not exist yet
          - immutable: macOS: `chflags uchg`, the user immutable flag. The only mechanism here that can be imposed on a process nobody started, which is what a guard needs — and a narrowing rather than a boundary, because the agent can run `chflags nouchg` too. Never chosen by `run`, which has Seatbelt
          
          [default: auto]

  -C, --dir <DIR>
          Directory to look for agent.lock in (default: the current directory)

      --dry-run
          Print what would be enforced and exit

  -q, --quiet
          Do not print the lock summary before running

  -h, --help
          Print help (see a summary with '-h')
exit=0
```

```
$ ralon check --help
Report what the policy protects, or whether given paths are protected

Exits 1 if any given path is protected, which makes it usable as an agent pre-write hook.

Usage: ralon check [OPTIONS] [PATH]...

Arguments:
  [PATH]...
          Paths to test. With none, lists everything the policy protects

Options:
  -C, --dir <DIR>
          Directory to look for agent.lock in (default: the current directory)

  -h, --help
          Print help (see a summary with '-h')
exit=0
```

```
$ ralon status --help
Show the policy and which enforcement backends this kernel offers

Usage: ralon status [OPTIONS]

Options:
  -C, --dir <DIR>  Directory to look for agent.lock in (default: the current directory)
  -h, --help       Print help
exit=0
```

```
$ ralon init --help
Write a starter agent.lock and wire up the agents

Usage: ralon init [OPTIONS]

Options:
  -C, --dir <DIR>  Directory to look for agent.lock in (default: the current directory)
      --force      Overwrite an existing agent.lock
      --no-hooks   Write the policy only, and configure nothing
  -h, --help       Print help
exit=0
```

