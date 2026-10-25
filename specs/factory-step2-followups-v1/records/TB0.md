# TB0 — Register and tickets T12–T16

Session date 2026-10-25. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2. Measured at `71d0896`
(= `origin/main` = local `main`: the SPEC commit on top of `e91ad26`). Nothing was pushed (I1). Every
GitHub call below is a read (`gh issue view`, `gh api …/contents`, `git ls-remote`). `a` =
`npx -y @adlc/cli@1.12.0` (a bash function; never a floating version). Blocks are `$ <command>`, its
output (trimmed where marked) and `exit=<code>`.

## 1. The register, re-measured

| key | SPEC §0 said | measured now | block |
|---|---|---|---|
| repo | `origin/main` = `e91ad26`; `make test` 14 files PASS, `make lint` 0; `make live` 3 files (smoke ends in fleet `preflight`) | `origin/main` = local = `71d0896` (the SPEC commit on top of `e91ad26`); `make test` 14 files PASS (1:12 wall); `make lint` exit 0; `make live` 3 files PASS, the smoke still ends in fleet `preflight` with `bwrap: execvp /bin/sh: No such file or directory` | §1.1 |
| fleet | `@adlc/cli` 1.12.0 newest; upstream main `455524c` has the same canary (L502–507); #1266 open; canary skipped only when `config.canary === false`, never set by `resolveRunConfig` (#639) | same on every point. `npm view @adlc/cli version` = `1.12.0` (published 2026-10-10; nothing newer); `@adlc/fleet` = `1.12.0`. Upstream `refs/heads/main` = `455524c411ff…`; its `bin/fleet.mjs` L502–507 is the canary. The npm 1.12.0 copy has the identical canary block at L491–496 (main has moved 13 diff lines elsewhere in the file). #1266 **OPEN**, 0 comments, created 2026-10-25T12:25:19Z. `canary` occurs 0 times in `lib/config.mjs` (npm 1.12.0 and main); the only reader is `bin/fleet.mjs` `config.canary === false`; #639 OPEN | §1.2 |
| fix by hand | `bwrap … --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 -- /bin/sh -c 'echo ok'` → `ok` | `ok`, exit 0, bubblewrap 0.9.0 | §1.3 |
| fleet source | `~/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc/fleet` (`lib/sandbox.mjs` buildSandboxArgv, `lib/bounded-model-plane.mjs` SYSTEM_ROOTS, `bin/fleet.mjs` canary) | present, `package.json` version 1.12.0; `buildSandboxArgv` exported at `lib/sandbox.mjs` L146; `SYSTEM_ROOTS` at `lib/bounded-model-plane.mjs` L33 = `['/usr','/lib','/lib64','/etc/ssl','/etc/resolv.conf','/etc/hosts']` | §1.4 |
| protection | reviews, status checks, `enforce_admins` in classic protection; only the merge queue in a ruleset; `FACTORY_APP_ID` a ruleset bypass actor | same. Classic: reviews (code owner, 1 approval, dismiss stale), 7 `gates / *` contexts strict, `enforce_admins: true`, force pushes and deletions off. Ruleset `main-merge-queue`: `merge_queue` only, `bypass_actors: []` (the App is added at apply time from `FACTORY_APP_ID`). The NOTE line the SPEC calls "`# NOTE: classic protection not bypassed`" reads, verbatim, `# NOTE: not covered by the bypass: classic branch protection on main (…)` (apply-branch-protection.sh L190, asserted by tests/test_halt_rules.sh L180–181) | §1.5 |
| labels | run.sh adds `needs-desk` on strikes-exhausted, flail, tamper, real scope failure; mirror.sh recomputes ready/needs-desk on every run | same: `label_desk` (run.sh L212–215, the only `--add-label needs-desk`); the reasons in run.sh's header L31/L38 and lib/run.sh L111; mirror.sh's `owned` labels (L134) include `needs-desk`, the gate at L212 recomputes it | §1.6 |
| join | no adversarial-review in the plan; no `cux add` line; the smoke installs adversarial-review 2.11.1 (integrity `sha512-LiPc…HCEA==`) and runs `cux add --no-alias` itself | same: `grep -c adversarial factory/bin/join.sh` = 0, `grep -c 'cux add' factory/bin/join.sh` = 0; tests/live/test_smoke_live.sh L52–53 pins `ADV_VERSION=2.11.1` and the integrity, L139 `cux add --no-alias`, L143 its own `npm install`. `npm view adversarial-review@2.11.1 dist.integrity` matches the pin byte for byte; 2.11.1 is still the newest | §1.7 |

**No fixed fleet has shipped** (newest `@adlc/cli` is 1.12.0, #1266 open, upstream main still carries the
canary unchanged). So TB1 stays the shim as specced. Had a fixed version shipped, TB1 would have become
"re-pin to the fixed version and delete nothing"; that branch is not taken.

### 1.1 Repo

```
$ git rev-parse origin/main HEAD
71d08961c9ae15cb5901f27a0b460886b85fa8fa
71d08961c9ae15cb5901f27a0b460886b85fa8fa
$ git status -sb | head -1
## main...origin/main
$ time make test          # (tail; every file's line)
PASS tests/test_claim.sh
PASS tests/test_governor.sh
PASS tests/test_halt_rules.sh
PASS tests/test_halt.sh
PASS tests/test_janitor.sh
PASS tests/test_join.sh
PASS tests/test_layout.sh
PASS tests/test_mirror.sh
PASS tests/test_policy.sh
PASS tests/test_post_merge.sh
PASS tests/test_revoke.sh
PASS tests/test_run.sh
PASS tests/test_summon.sh
PASS tests/test_version_check.sh
make test  65.40s user 15.17s system 111% cpu 1:12.56 total
exit=0
$ make lint
exit=0
$ time make live          # (excerpt)
PASS tests/live/test_join_live.sh
PASS tests/live/test_policy_live.sh
    INFO fleet stopped before any worker: preflight failed: preflight canary failed (permission plumbing not working): bwrap: execvp /bin/sh: No such file or directory
    ok     the canary failed INSIDE bwrap (enforced, not open)
  6. fleet reason 'preflight' -> loop reason 'preflight', outcome released, exit 1
    ok   preflight: exit 1, released, slot stopped
PASS tests/live/test_smoke_live.sh
make live  72.80s user 17.51s system 102% cpu 1:27.89 total
exit=0
```

### 1.2 fleet and the upstream issue (read-only)

```
$ npm view @adlc/cli version
1.12.0
exit=0
$ npm view @adlc/cli time --json | jq -r 'to_entries|sort_by(.value)|.[-3:][]|"\(.key) \(.value)"'
1.11.1 2026-09-09T12:35:26.327Z
1.12.0 2026-10-10T03:26:21.041Z
modified 2026-10-10T03:26:21.401Z
$ npm view @adlc/fleet version
1.12.0
$ gh issue view 1266 -R voodootikigod/adlc --json number,state,title,url,createdAt,updatedAt,comments,closedAt | jq '{number,state,title,url,createdAt,updatedAt,closedAt,comments:(.comments|length)}'
{
  "number": 1266,
  "state": "OPEN",
  "title": "fleet: preflight canary cannot pass on any bubblewrap host (no system root bound, `/bin/sh` missing)",
  "url": "https://github.com/voodootikigod/adlc/issues/1266",
  "createdAt": "2026-10-25T12:25:19Z",
  "updatedAt": "2026-10-25T12:25:19Z",
  "closedAt": null,
  "comments": 0
}
exit=0
$ gh issue view 639 -R voodootikigod/adlc --json number,state,title | jq -c .
{"number":639,"state":"OPEN","title":"fleet: `envPassthrough`, `adlcBin`, and `canary` are read at use sites but never plumbed through resolveRunConfig (silent no-ops)"}
$ git ls-remote https://github.com/voodootikigod/adlc.git refs/heads/main
455524c411ff3699e8e63fb05ced260e2fa5a892	refs/heads/main
$ gh api 'repos/voodootikigod/adlc/contents/packages/fleet/bin/fleet.mjs?ref=455524c411ff3699e8e63fb05ced260e2fa5a892' -H 'Accept: application/vnd.github.raw' > up-fleet.mjs; sed -n '502,507p' up-fleet.mjs
      const sb = new Sandbox({
        mode: sandboxSpec.mode, backend: sandboxSpec.backend, worktree: tmp, syntheticHome: join(tmp, '.home'),
        exec: async (argv, opts) => { … },
      });
      const out = await sb.run(['/bin/sh', '-c', 'echo __fleet_canary_ok__'], { env: repoCommandEnv(io.env, { syntheticHome: join(tmp, '.home') }), … });
      return { ok: String(out).includes('__fleet_canary_ok__'), output: String(out) };
$ grep -n 'canary === false' up-fleet.mjs
518:      dispatchCanary: config.canary === false ? undefined : dispatchCanary,
$ F=~/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc/fleet
$ diff <(sed -n '486,499p' $F/bin/fleet.mjs) <(sed -n '497,510p' up-fleet.mjs) && echo identical
identical
$ grep -c canary $F/lib/config.mjs; gh api '…/packages/fleet/lib/config.mjs?ref=455524c…' -H 'Accept: application/vnd.github.raw' | grep -c canary
0
0
```

### 1.3 The fix by hand

```
$ bwrap --version
bubblewrap 0.9.0
$ bwrap --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 -- /bin/sh -c 'echo ok'
ok
exit=0
```

### 1.4 fleet source on this box

```
$ jq -r .version $F/package.json
1.12.0
$ grep -n 'export function buildSandboxArgv' $F/lib/sandbox.mjs
146:export function buildSandboxArgv(backend, innerArgv, {
$ grep -n 'export const SYSTEM_ROOTS' $F/lib/bounded-model-plane.mjs
33:export const SYSTEM_ROOTS = Object.freeze(['/usr', '/lib', '/lib64', '/etc/ssl', '/etc/resolv.conf', '/etc/hosts']);
$ grep -n 'SYSTEM_ROOTS.filter' $F/lib/extensions.mjs
72:    const readOnlyPaths = dedupeList([...SYSTEM_ROOTS.filter((p) => pathExists(p)), ...(config.modelPlaneReadOnly ?? [])]);
```

The host shape TB1's shim meets (merged-usr, and one symlinked SYSTEM_ROOT):

```
$ ls -ld /bin /sbin /lib /lib64 /usr /etc/ssl /etc/resolv.conf /etc/hosts
lrwxrwxrwx  1 root root    7 Apr 22  2024 /bin -> usr/bin
-rw-r--r--  1 root root  417 Oct 14 07:35 /etc/hosts
lrwxrwxrwx  1 root root   20 Oct 25 08:25 /etc/resolv.conf -> /mnt/wsl/resolv.conf
drwxr-xr-x  4 root root 4096 Oct  1 06:06 /etc/ssl
lrwxrwxrwx  1 root root    7 Apr 22  2024 /lib -> usr/lib
lrwxrwxrwx  1 root root    9 Apr 22  2024 /lib64 -> usr/lib64
lrwxrwxrwx  1 root root    8 Apr 22  2024 /sbin -> usr/sbin
drwxr-xr-x 12 root root 4096 Jan  6  2025 /usr
$ bwrap --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 --ro-bind /etc/resolv.conf /etc/resolv.conf -- /bin/sh -c 'cat /etc/resolv.conf | head -2'
# This file was automatically generated by WSL. To stop automatic generation of this file, add the following entry to /etc/wsl.conf:
# [network]
exit=0
```

### 1.5 Protection

```
$ jq -c '.protection | {required_pull_request_reviews, required_status_checks, enforce_admins, allow_force_pushes, allow_deletions}' factory/policy/branch-protection.json
{"required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"required_approving_review_count":1},"required_status_checks":{"strict":true,"contexts":["gates / build-test","gates / rails-proof","gates / scope","gates / tamper","gates / dependencies","gates / attest-verify","gates / commit-check"]},"enforce_admins":true,"allow_force_pushes":false,"allow_deletions":false}
$ jq -c '.rulesets[] | {name, target, enforcement, bypass_actors, rules: [.rules[].type]}' factory/policy/branch-protection.json
{"name":"main-merge-queue","target":"branch","enforcement":"active","bypass_actors":[],"rules":["merge_queue"]}
$ grep -n 'NOTE' factory/bin/apply-branch-protection.sh tests/test_halt_rules.sh
tests/test_halt_rules.sh:180:  check "prints the NOTE: classic protection is not lifted by a ruleset bypass" \
tests/test_halt_rules.sh:181:    eval 'grep -q "^# NOTE: not covered by the bypass: classic branch protection on main" <<<"$OUT"'
factory/bin/apply-branch-protection.sh:20:# enforce_admins); every run with the App set prints that as a NOTE.
factory/bin/apply-branch-protection.sh:190:                            "# NOTE: not covered by the bypass: \(.not_covered)"),
```

### 1.6 Labels

```
$ grep -n 'needs-desk' factory/bin/run.sh factory/bin/lib/run.sh factory/bin/mirror.sh
factory/bin/lib/run.sh:111:        + " Labeled needs-desk; lock released."
factory/bin/run.sh:31:#                                   scope failure → label needs-desk, release, no push. scope-check
factory/bin/run.sh:38:#     strikes-exhausted | flail     push the branch, label needs-desk, comment, release
factory/bin/run.sh:213:  if gh issue edit "$ISSUE" --repo "$REPO" --add-label needs-desk >/dev/null 2>>"$LOGBASE.err"; then act label-needs-desk
factory/bin/run.sh:214:  else act label-needs-desk-failed; fi
factory/bin/mirror.sh:21:# `needs-desk` otherwise:
factory/bin/mirror.sh:134:def owned: test("^(ready|needs-desk|w:.+|tier:.+)$");
factory/bin/mirror.sh:212:          | (if $reasons == [] then "ready" else "needs-desk" end) as $gate
factory/bin/mirror.sh:253:    ready) echo 0e8a16 ;; needs-desk) echo d93f0b ;; w:*) echo 1d76db ;; *) echo 5319e7 ;;
```

### 1.7 Join

```
$ grep -c adversarial factory/bin/join.sh; grep -c 'cux add' factory/bin/join.sh
0
0
$ grep -n 'ADV_VERSION=\|ADV_INTEGRITY=\|cux add --no-alias\|npm install' tests/live/test_smoke_live.sh
52:ADV_VERSION=2.11.1
53:ADV_INTEGRITY=sha512-LiPc0R5UXJQ/tsUd3yEOVkISYxtbyFlvDlMFPtLW1lcVNhLjOqluDZXaVmYYEb0oONdsSs+xVbAbyWN2e0HCEA==
139:check "cux add (the logged-in account, into the scratch HOME's store)" quiet cux add --no-alias
143:npm install --prefix "$S/review" --no-audit --no-fund --ignore-scripts "adversarial-review@$ADV_VERSION" >"$S/review.log" 2>&1 || rc=$?
$ npm view adversarial-review@2.11.1 dist.integrity version; npm view adversarial-review version
dist.integrity = 'sha512-LiPc0R5UXJQ/tsUd3yEOVkISYxtbyFlvDlMFPtLW1lcVNhLjOqluDZXaVmYYEb0oONdsSs+xVbAbyWN2e0HCEA=='
version = '2.11.1'
2.11.1
```

## 2. Tickets T12–T16

Written through the CLI only. Each input document is `{id, title, body, category, duration, scope,
rails: [], edges}`; the body opens with the ADR-0002 header block (`weight:`, `tier:`, `charter:`) and
every acceptance criterion ends in `Verify: <command>`. No ticket declares `rails` (same reason as
step-2 TB0 §5: a rail freezes the store behind `ADLC_MANIFEST_KEY`). Created in reverse dependency
order (an edge to a not-yet-written ticket fails validation: the first dry run of T15 printed
`{"ok":false,"kind":"invalid","code":"INVALID_TICKET_STORE",…,"details":["T15: edge to unknown ticket T16"]}`),
each as a dry run, then `--write`:

```
$ for t in T16 T15 T14 T13 T12; do d=$(a ticket create --input tk/$t.json --json); …; out=$(a ticket create --input tk/$t.json --write --json); …; done
T16 dry exit=0 {"validation":"valid","dryRun":true} write exit=0 {"ticketId":"T16","validation":"valid","graphEffects":[],"dryRun":false}
T15 dry exit=0 {"validation":"valid","dryRun":true} write exit=0 {"ticketId":"T15","validation":"valid","graphEffects":[],"dryRun":false}
T14 dry exit=0 {"validation":"valid","dryRun":true} write exit=0 {"ticketId":"T14","validation":"valid","graphEffects":[],"dryRun":false}
T13 dry exit=0 {"validation":"valid","dryRun":true} write exit=0 {"ticketId":"T13","validation":"valid","graphEffects":[],"dryRun":false}
T12 dry exit=0 {"validation":"valid","dryRun":true} write exit=0 {"ticketId":"T12","validation":"valid","graphEffects":[],"dryRun":false}
```

Charters: T12, T15, T16 C5 (node, join, run loop); T13 C3 (post-merge's direct push, as T10 was);
T14 C2 (the claim-protocol exception). Edges as the SPEC lists them: T12→T16, T15→T16.

First merge-forecast:

```
$ a merge-forecast --json | jq -c '(.pairs[] | select(.verdict != "PARALLEL") | {pair, signal, score, verdict}), {gateFailures, waves}'
{"pair":"T12–T14","signal":"scope-overlap","score":1,"verdict":"VETO"}
{"pair":"T12–T15","signal":"scope-overlap","score":1,"verdict":"VETO"}
{"pair":"T13–T14","signal":"co-change","score":0.5,"verdict":"SEQUENCE"}
{"gateFailures":["3 high-risk pair(s) would run concurrently: T12–T14 (score 1, scope-overlap), T12–T15 (score 1, scope-overlap), T13–T14 (score 0.5, co-change)"],"waves":[["T12","T13","T14","T15"],["T16"]]}
exit=2
```

The overlaps are real: T12 and T14 both edit `factory/bin/run.sh` and `tests/test_run.sh` (the shim's
PATH; the needs-desk marker); T12 and T15 both edit `factory/bin/join.sh` and `tests/test_join.sh` (the
shim probe; the reviewer pin and cux line); T13 and T14 have co-change history (T10 changed
apply-branch-protection.sh and RULES.md together). Serialized through the CLI as in step-2 TB0 §5
(`a ticket show <id> --json` → `jq` the `.ticket` with the new edge → `a ticket update <id> --input <f>
--expect <ticketHash>` dry run, then `--write`), in row order (TB1 = T12, TB2 = T13, TB3 = T14,
TB4 = T15), so no row moves:

```
T12->T14 expect aa980372f416 dry exit=0 {"validation":"valid","dryRun":true} write exit=0 {"ticketId":"T12","validation":"valid","dryRun":false}
T12->T15 expect a69dd874f005 dry exit=0 {"validation":"valid","dryRun":true} write exit=0 {"ticketId":"T12","validation":"valid","dryRun":false}
T13->T14 expect 69ee75c328cf dry exit=0 {"validation":"valid","dryRun":true} write exit=0 {"ticketId":"T13","validation":"valid","dryRun":false}
$ a merge-forecast --json | jq -c '(.pairs[] | select(.verdict != "PARALLEL")), {gateFailures, waves}'
{"gateFailures":[],"waves":[["T12","T13"],["T15","T14"],["T16"]]}
exit=0
```

Final state:

```
$ for t in T12 T13 T14 T15 T16; do a ticket show $t --json | jq -r '[.ticket.id, .ticketHash[0:12], (.ticket.edges // [] | map(.to) | join(",")), (.ticket.body | split("\n")[0:3] | join(" ")), .ticket.title] | @tsv'; done
T12	5966ee8cd52b	T16,T14,T15	weight: light tier: 1 charter: C5	Add a temporary read-only bwrap shim so fleet 1.12.0's preflight canary can run (ADR-0006)
T13	5b60e17ab336	T14	weight: light tier: 0 charter: C3	Move main's classic branch protection into the ruleset the factory App bypasses
T14	e7a67bf1f133		weight: light tier: 0 charter: C2	Keep a node-added needs-desk label across mirror runs until the store changes
T15	3dcfea7ce0d8	T16	weight: light tier: 1 charter: C5	Pin fleet's reviewer adversarial-review 2.11.1 by integrity in join, and print the cux add line
T16	3302976077ce		weight: heavy tier: 2 charter: C5	Run the toy ticket past fleet's preflight on the dev box, and close out the step-2 follow-ups
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
$ a coldstart --all --offline --json | jq -c '.ok, (.results[] | {id, pass, gaps})'
true
{"id":"T12","pass":true,"gaps":[]}
{"id":"T13","pass":true,"gaps":[]}
{"id":"T14","pass":true,"gaps":[]}
{"id":"T15","pass":true,"gaps":[]}
{"id":"T16","pass":true,"gaps":[]}
exit=0
```

Scopes (from the ticket JSON): T12 `factory/bin/lib/bwrap-shim`, `factory/bin/lib/probe.sh`,
`factory/bin/run.sh`, `factory/bin/join.sh`, `docs/adr/0006-bwrap-shim-for-fleet-1-12-0.md`,
`docs/adr/README.md`, `tests/test_bwrap_shim.sh`, `tests/test_run.sh`, `tests/test_join.sh`,
`tests/fixtures/bwrap-shim/**`, `tests/live/test_bwrap_shim_live.sh`. T13 `factory/policy/branch-protection.json`,
`factory/bin/apply-branch-protection.sh`, `docs/adr/0004-halt-two-person-rule.md`, `tests/test_halt_rules.sh`.
T14 `factory/bin/mirror.sh`, `factory/bin/lib/desk-marker.sh`, `factory/bin/lib/run.sh`, `factory/bin/run.sh`,
`factory/RULES.md`, `tests/test_mirror.sh`, `tests/test_run.sh`. T15 `factory/bin/join.sh`,
`factory/skills/join/SKILL.md`, `factory/nodes/manifest.schema.json`, `factory/nodes/example.json`,
`factory/nodes/README.md`, `tests/test_join*.sh`, `tests/fakes/join/**`, `tests/live/test_join*.sh`.
T16 `tests/live/test_smoke*.sh`, `tests/fixtures/make-repo.sh`, `README.md`. T16's scope is
`tests/fixtures/make-repo.sh`, not `tests/fixtures/**`, so it does not overlap T12's fixture dir.

## 3. Gotchas for the next rows

1. **`/etc/resolv.conf` is a symlink on WSL2** (`-> /mnt/wsl/resolv.conf`). `--ro-bind /etc/resolv.conf
   /etc/resolv.conf` still works (bwrap follows the source; §1.4 prints the file inside), but TB1's rule
   "bind if it exists and is not a symlink, `--symlink` if it is" must only apply the `--symlink` branch to
   the merged-usr dirs (`/bin`, `/sbin`, `/lib`, `/lib64`). A `--symlink /mnt/wsl/resolv.conf
   /etc/resolv.conf` would dangle inside the sandbox. fleet's own `SYSTEM_ROOTS.filter(pathExists)`
   binds it as a file.
2. On this host `/lib` and `/lib64` are SYSTEM_ROOTS **and** merged-usr symlinks: the shim must emit one
   entry for each (the `--symlink`), not a bind and a symlink.
3. The npm 1.12.0 `bin/fleet.mjs` and upstream main differ by 13 diff lines; quote line numbers from the
   npm copy (canary L491–496) in code and tests, and upstream's (L502–507) only when citing #1266.
4. `a ticket create` validates edges against the store, so a dry run of a ticket whose edge target is
   not yet written fails (`INVALID_TICKET_STORE`); create in reverse dependency order.
5. Ticket writes touch only new `.adlc/tickets/t<n>--<hash>.json` files (no `.store.json` /
   `manifest.jsonl` change in this store mode, `securityMode: unsigned-fallback`).

## 4. Result

Every register line re-measured (§1), none moved; no fixed fleet, so TB1 = the shim. T12–T16 written
through `adlc ticket create … --write` with the ADR-0002 header block, `Verify:` criteria, scope globs,
the SPEC's edges T12→T16 and T15→T16 plus T12→T14, T12→T15, T13→T14 (merge-forecast's veto); doctor ok,
coldstart gaps empty, merge-forecast exit 0 (§2). `make test` 14 PASS, `make lint` 0, `make live` 3 PASS
(§1.1). Commit `Ticket: scaffold`.
