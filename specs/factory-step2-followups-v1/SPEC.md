# SPEC — factory-step2-followups-v1: Aaron's five step-2 rulings in code, then a live run past fleet's preflight

**Status: ACTIVE v0.1, 2026-10-25 (launched without ratification per Aaron's 2026-09-30 rule). Project:
`~/software-factory`. Step 2 (`specs/factory-step2-v1`) is DONE and pushed; post-merge completed T6–T11.
Its live smoke stopped at fleet 1.12.0's preflight canary, which binds no system root, so `/bin/sh` is
missing inside it on every bubblewrap host (`specs/factory-step2-v1/records/TB6.md` §3). Aaron ruled the
five step-2 calls on 2026-10-25 (`specs/factory-step2-v1/RULINGS.md`, all recommendations). The upstream
issue is filed: https://github.com/voodootikigod/adlc/issues/1266.**

Goal: a dev-box node builds a toy ticket end to end inside the sandbox, against a local fixture origin,
and every ruling is in code with tests.

**Invariants: I1–I11 of `specs/factory-step2-v1/SPEC.md` §1 apply verbatim** (never write to GitHub;
user-space pinned installs, no sudo; bash + jq + git + gh; `make test` offline and tool-free, real tools in
`make live`; no false green; one trailer paragraph with `Ticket:`; the real CLI is the truth; transcripts
never leave the node; never touch `rb-spec-*`; no wall-clock waits in a DoD; never `git commit --amend`).
Plus:

- **I12 The shim only adds read-only binds.** It never adds a writable bind, never adds or removes a
  network or namespace flag, and never drops an argument fleet passed. A test asserts this on every argv
  shape fleet 1.12.0 produces (canary, repo-command plane, bounded model plane, host read policy).
- **I13 The shim is temporary by construction.** It is active only while the pinned fleet is exactly
  `1.12.0` (the version that has issue #1266). Any other pin turns it off, and ADR-0006 names the
  removal steps.

---

## 0. The register (2026-10-25 ~12:30Z, measured by the launching session; TB0 re-measures)

| key | value |
|---|---|
| repo | `origin/main` = `e91ad26`; `make test` 14 files PASS, `make lint` 0; `make live` 3 files (smoke ends in fleet `preflight`) |
| fleet | `@adlc/cli` 1.12.0 newest on npm; upstream main `455524c` has the same canary (`packages/fleet/bin/fleet.mjs` L502–507); issue #1266 open; the canary is skipped only when `config.canary === false`, which `resolveRunConfig` never sets (#639) |
| the fix by hand | `bwrap … --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 -- /bin/sh -c 'echo ok'` → `ok` (records/TB6.md §3) |
| fleet source | `~/.npm/_npx/45e3560a1487d0e5/node_modules/@adlc/fleet` (`lib/sandbox.mjs` buildSandboxArgv, `lib/bounded-model-plane.mjs` SYSTEM_ROOTS, `bin/fleet.mjs` canary) |
| protection | `factory/policy/branch-protection.json`: reviews, status checks, `enforce_admins` in classic protection; only the merge queue in a ruleset; `FACTORY_APP_ID` is a ruleset bypass actor (step-2 TB5) |
| labels | run.sh adds `needs-desk` on strikes-exhausted, flail, tamper, real scope failure (ADR-0005 d13); mirror.sh recomputes ready/needs-desk from the store on every run |
| join | no adversarial-review in the plan; no `cux add` line; the smoke installs adversarial-review 2.11.1 (`sha512-LiPc0R5UXJQ/tsUd3yEOVkISYxtbyFlvDlMFPtLW1lcVNhLjOqluDZXaVmYYEb0oONdsSs+xVbAbyWN2e0HCEA==`) and runs `cux add --no-alias` itself |

---

## 1. Rows (tracer bullets, in order; cap = 8 × 6 = 48 iterations)

### TB0 — Register and tickets T12–T16
DoD: `records/TB0.md` re-measures every register line with its command, including the state of issue
#1266 (read-only `gh issue view`) and `npm view @adlc/cli version`. If a fixed fleet has shipped by then,
record it, and TB1 becomes "re-pin to the fixed version and delete nothing" instead of the shim (write
that branch into the records; do not decide anything else differently). Create tickets T12–T16 through
`adlc ticket create … --write` with the ADR-0002 header block, verification-method acceptance criteria,
scope globs, and edges T12→T16, T15→T16; doctor ok; coldstart gaps empty; merge-forecast exit 0. Commit
`Ticket: scaffold`.

### TB1 — The bwrap shim and ADR-0006 (ticket T12; ruling Q1)
DoD: `factory/bin/lib/bwrap-shim` (bash) that run.sh puts first on fleet's `PATH` only (never the node's
login PATH) and that `exec`s the real bwrap found by absolute path. It inserts read-only binds for the
existing members of fleet's own `SYSTEM_ROOTS` (`/usr`, `/lib`, `/lib64`, `/etc/ssl`, `/etc/resolv.conf`,
`/etc/hosts`) plus `--symlink` entries for merged-usr hosts (`/bin`, `/sbin`, `/lib`, `/lib64` when they
are symlinks on the host), and only when the argv does not already bind `/` or that path. Bind order:
inserted before fleet's own binds so fleet's later binds still win. `docs/adr/0006-bwrap-shim-for-fleet-1-12-0.md`
(accepted under ruling Q1; cites #1266; names I13's removal steps). `tests/test_bwrap_shim.sh`: the four
argv shapes from fleet 1.12.0's real `buildSandboxArgv` (captured by calling the real module with
`node -e`, recorded as fixtures), each proving I12 (set difference of write binds, net and namespace
flags = empty; only `--ro-bind`/`--symlink` added); idempotence (shim of shim = shim); version gate off for
any pin other than 1.12.0. `make live`: the canary's exact argv through the shim prints
`__fleet_canary_ok__`; a write to `/usr` inside it fails; `curl` inside a `--unshare-net` call still
fails. join.sh probes for the shim's prerequisites. Commit `Ticket: T12`. `records/TB1.md`.

### TB2 — Protection rules into the ruleset (ticket T13; ruling Q2)
DoD: `factory/policy/branch-protection.json` moves required reviews (with code-owner review), required
status checks, non-fast-forward and deletion from classic protection into the `main` ruleset, with the
App as the only bypass actor when `FACTORY_APP_ID` is set; classic protection keeps nothing the ruleset
covers (or is removed, if nothing is left). Field names only from GitHub's REST ruleset schema (cite the
docs page read). `apply-branch-protection.sh` and its tests updated: dry run prints every call; second
`--apply` is a no-op; refuses unknown fields; the TB5 `# NOTE: classic protection not bypassed` line is
gone because the case no longer exists. ADR-0004's HALT interim still holds and is restated in the
ruleset. Commit `Ticket: T13`. `records/TB2.md`.

### TB3 — needs-desk survives the mirror (ticket T14; ruling Q3)
DoD: mirror.sh keeps a `needs-desk` label that a node added (identified by the run loop's result comment
marker on the Issue, which run.sh writes with the reason; the marker format is defined once in
`factory/bin/lib/`), and drops it only when the store's state changes (a desk edit or a new claim cycle),
with the rule written in `factory/RULES.md` as the claim-protocol exception. Tests: node-added label
preserved across two mirror runs; removed after a store edit; a label added without the marker is
recomputed as before. Commit `Ticket: T14`. `records/TB3.md`.

### TB4 — The reviewer pin and the cux line in join (ticket T15; rulings Q4, Q5)
DoD: join.sh's install plan pins `adversarial-review` 2.11.1 with its npm integrity (install fails closed
on a mismatch; same user-space rule as the other tools) and records in the manifest's adapters/tools that
review is same-family on a claude-only box (a field the schema allows, or a schema change with a test);
the register step prints the exact `cux add --no-alias` line and why; nothing in join handles a
credential (test greps join's argv log). The smoke test drops its own adversarial-review install and
uses join's. Commit `Ticket: T15`. `records/TB4.md`.

### TB5 — The live run past preflight, and close-out (ticket T16)
DoD part A: `FACTORY_SMOKE_KEEP=$HOME/.cache/factory-smoke-evidence make live` with the shim. Record how
far the toy ticket gets: canary pass, fleet run id, strikes, the gate `bash tests/test_hello.sh`,
adversarial-review's verdict, tamperguard under vetto with the first `vetto audit` session (step-2 AC2's
open half), fleet's policy echo (`bounded`/`mirror`/`allowlist` with the claude-code hosts), and the
loop's final branch (best case `scope-check-not-built`, since scope-check is step 3). Pass = the run gets
past preflight and every branch the loop took is the specced one with the cause named; a sandbox that ran
open is a fail. If a later fleet stage fails for a reason in fleet itself, name it, draft (never file) an
upstream issue in records, and add a Q. DoD part B: `make test` + `make lint` + `make live` green;
coldstart gaps empty T12–T16; README build-order row 2 updated; `records/TB5.md`; HANDOFF ends with
"Aaron's kit" (step-2's kit lines still open, one line each) and any `### Q<n>` blocks. Commit
`Ticket: T16`.

---

## 2. Out of scope

Step 3 (CI gate bodies, merge queue, halt-guard, scope-check body). Filing anything upstream. Any write to
GitHub (I1). Moving the repo to an organization.
