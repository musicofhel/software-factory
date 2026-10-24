# TB0 — Register: measure the scaffold, prove the toolchain, fix what the scaffold got wrong

Session date 2026-10-24. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2. Base commit `6b7c9fb` (LAUNCH) on top of the scaffold `f81c1c7`.
Every block below is `$ <command>` followed by its verbatim output and `exit=<code>`. `a` = `npx -y @adlc/cli@1.12.0` (a bash function; never a floating version).

## 1. Measured before any fix (the scaffold as committed)

```
$ make test
PASS tests/test_layout.sh
exit=0
```

```
$ make lint
actionlint not installed; skipped
exit=0
```
(The scaffold Makefile ran shellcheck through `uvx --from shellcheck-py` silently — clean — and skipped
actionlint. It would also have printed "shellcheck not installed; skipped" and exited 0 on a box with
neither shellcheck nor uvx: a false green, fixed below.)

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
$ a coldstart --all --offline --json
{
  "ok": true,
  "results": [
    {
      "id": "T1",
      "pass": true,
      "gaps": [],
      "cached": false,
      "offline": true
    },
    {
      "id": "T2",
      "pass": true,
      "gaps": [],
      "cached": false,
      "offline": true
    },
    {
      "id": "T3",
      "pass": true,
      "gaps": [],
      "cached": false,
      "offline": true
    },
    {
      "id": "T4",
      "pass": true,
      "gaps": [],
      "cached": false,
      "offline": true
    },
    {
      "id": "T5",
      "pass": true,
      "gaps": [],
      "cached": false,
      "offline": true
    }
  ]
}
exit=0
```

```
$ a merge-forecast --json
{
  "pairs": [
    {
      "pair": "T1–T2",
      "a": "T1",
      "b": "T2",
      "score": 1,
      "signal": "scope-overlap",
      "verdict": "VETO",
      "hardVeto": true
    },
    {
      "pair": "T1–T5",
      "a": "T1",
      "b": "T5",
      "score": 0,
      "signal": "none",
      "verdict": "PARALLEL",
      "hardVeto": false
    },
    {
      "pair": "T2–T3",
      "a": "T2",
      "b": "T3",
      "score": 1,
      "signal": "scope-overlap",
      "verdict": "VETO",
      "hardVeto": true
    },
    {
      "pair": "T2–T5",
      "a": "T2",
      "b": "T5",
      "score": 0,
      "signal": "none",
      "verdict": "PARALLEL",
      "hardVeto": false
    },
    {
      "pair": "T3–T4",
      "a": "T3",
      "b": "T4",
      "score": 1,
      "signal": "scope-overlap",
      "verdict": "VETO",
      "hardVeto": true
    },
    {
      "pair": "T3–T5",
      "a": "T3",
      "b": "T5",
      "score": 0,
      "signal": "none",
      "verdict": "PARALLEL",
      "hardVeto": false
    },
    {
      "pair": "T4–T5",
      "a": "T4",
      "b": "T5",
      "score": 0,
      "signal": "none",
      "verdict": "PARALLEL",
      "hardVeto": false
    }
  ],
  "waves": [
    [
      "T1",
      "T2",
      "T5"
    ],
    [
      "T3",
      "T4"
    ]
  ],
  "mergeOrder": [
    "T1",
    "T2",
    "T5",
    "T3",
    "T4"
  ],
  "firstWaveWidth": 2,
  "scheduleWidth": 2,
  "certifiedWidth": 2,
  "backpressureWidth": null,
  "recommendedWidth": 2,
  "warnings": [
    "co-change: empty co-change pairs in history"
  ],
  "gateFailures": [
    "2 high-risk pair(s) would run concurrently: T1–T2 (score 1, scope-overlap), T3–T4 (score 1, scope-overlap)"
  ],
  "pullQueueNote": "idle builders claim next unblocked"
}
exit=2
```

```
$ a fleet run --dry-run --json
{
  "integrationBranch": "fleet/run-<runId>",
  "concurrency": 2,
  "base": "main",
  "baseSha": "6b7c9fbb68767dba27fa1653f70769cd696bfb44",
  "readyNow": [
    "T1",
    "T5"
  ],
  "firstBatch": [
    "T1",
    "T5"
  ],
  "waitingOnDeps": [
    "T2",
    "T3",
    "T4"
  ],
  "subsetBlocked": [],
  "completedExcluded": 0,
  "worktreeRoot": "/home/musicofhel/software-factory",
  "plannedWorktrees": {
    "T1": "/home/musicofhel/software-factory/.worktrees/fleet-t1",
    "T5": "/home/musicofhel/software-factory/.worktrees/fleet-t5"
  },
  "integrationWorktree": "/home/musicofhel/software-factory/.worktrees/fleet-integration",
  "readPolicy": "host",
  "privateTmp": false,
  "gitSource": "shared",
  "mirror": null,
  "egress": "open",
  "workerDeps": null,
  "maxStrikes": 2,
  "wallClockMinutes": null,
  "noPr": false,
  "noComplete": false,
  "quartermaster": {
    "engaged": false,
    "seats": []
  }
}
exit=0
```

`claude --version`:
```
2.1.280 (Claude Code)
exit=0
```

`command -v shellcheck uvx bwrap unshare actionlint` (only found ones print):
```
/home/musicofhel/.local/bin/uvx
/usr/bin/unshare
```

## 2. Sandbox verdict for `adlc fleet run` on this box

`adlc fleet run --dry-run --json` exits **0** (above), but the dry-run does not probe the sandbox: it only plans.
The live run's preflight (`@adlc/fleet/lib/preflight.mjs` `resolveSandboxForRun` → `sandbox.mjs` `detectBackend`)
accepts **only `bwrap` on Linux**. The source says so (sandbox.mjs, comment above `detectBackend`): *"Plain
`unshare --net` is deliberately NOT accepted … A host with `unshare` but no `bwrap` therefore reports NO backend
and the fleet fails closed"*. The fleet README's "Live run — prerequisites" line ("`bwrap`/`unshare` on Linux")
is looser than the code; the code wins.

Probe, calling the installed 1.12.0 functions directly (no worker dispatched):
```
$ node --input-type=module -e "import { detectBackend } from '<npx>/@adlc/fleet/lib/sandbox.mjs'; import { resolveSandboxForRun } from '<npx>/@adlc/fleet/lib/preflight.mjs'; console.log(JSON.stringify({backend: detectBackend(), resolved: resolveSandboxForRun({})}))"
{"backend":null,"resolved":{"mode":null,"backend":null,"warnings":[],"refused":true,"reason":"No OS sandbox backend available and no operator-local disposable-container override. Refusing to dispatch (fail closed) — the repo-command plane runs arbitrary code and must be contained."}}
exit=0
```
(`<npx>` = `/home/musicofhel/.npm/_npx/45e3560a1487d0e5/node_modules`; `@adlc/fleet/package.json` version 1.12.0.)

**Verdict: the sandbox precondition is NOT met on this box.** `bwrap` missing; `unshare` present but rejected
by design. A live `fleet run` here would exit 1 at preflight (fleet README "Exit codes": 1 includes "sandbox
precondition unmet"). Not a blocker for step 1: nothing in TB1–TB5 dispatches a live fleet run, and TB5's DoD
is `fleet run --dry-run` exit 0. It matters for build order 2 (the run loop): a WSL2 node needs bubblewrap
installed (or the operator-local `--i-am-in-a-disposable-container`). Other live-run prerequisites also absent
today: `fleet.gate` in `.adlc/config.json` and a trusted `adversarial-review` on PATH (fleet README items 4–5).
Those belong to build order 2.

## 3. Scaffold defects found and fixed (one commit, `Ticket: scaffold`)

1. **The ticket DAG let scope-overlapping tickets run concurrently, so the factory's own merge-forecast gate
   failed (exit 2, section 1).** T1–T4 all declare `factory/bin/lib/**` and `tests/fakes/**`. The pairs the
   DAG left parallel-eligible were T1–T2, T2–T3 and T3–T4. merge-forecast reported
   `gateFailures: ["2 high-risk pair(s) would run concurrently: T1–T2 …, T3–T4 …"]` with wave 1 =
   `[T1, T2, T5]`. Under T4's acceptance criterion 1 (a ticket is `ready` only when its merge-forecast gate
   record is clean), every ticket would have mirrored as `needs-desk`. Fix: edges T1→T2, T2→T3 and T3→T4
   added through the CLI, never by hand: capture once with `a ticket show <id> --json`, `jq` the `.ticket`,
   `a ticket update <id> --input <file> --expect <ticketHash>` as a dry run, then the same with `--write`.
   No ticket declares rails, so no manifest key was needed and none was recorded. The original edges
   T1→T3, T1→T4 and T2→T4 stay because they are the semantic deps. The chain matches the spec's build order
   (TB1→TB4), so nothing downstream changes. Ticket hashes after: T1 `882cd7ad…`, T2 `175d5048…`,
   T3 `b03ce207…`, T5 `59c8363e…` (T4 unchanged `cd250456…`); storeHash `5b3ce43b…`.
2. **T5's title said "the four candidates", but its body and AC 1 say five.** A fresh agent would have had
   to guess. The title is now "Decide the chassis: read the five candidates (four alternatives plus the fleet
   default) and amend ADR-0003" (same CLI path).
3. **`make lint` could go green without linting anything.** (a) "shellcheck not installed; skipped" exited 0,
   an I4 false green. (b) shellcheck's own failure was lost because the recipe was one shell line with no
   `set -e` (proven below). (c) Only `factory/bin/*.sh factory/test.sh tests/*.sh` were linted, so
   `factory/bin/lib/`, `tests/fakes/` and `tests/fixtures/` (which TB1 and TB3 add) would have escaped.
   (d) actionlint never ran because it is absent. Fix: shellcheck is now required (the system binary, else
   the `uvx --from shellcheck-py` binary), the recipe runs under `set -e`, `SH_FILES` covers every `*.sh` under
   `factory/` and `tests/` plus every file under `tests/fakes/`, and actionlint runs from the system binary or
   `uvx --from actionlint-py`, with `-shellcheck` so workflow `run:` blocks get checked too. actionlint is
   best-effort because hosted runners ship shellcheck but not actionlint. README's testing line updated.

4. **The outer loop's `specs/factory-step1-v1/TB_PROMPT.md` sat untracked**, so the tree could never be clean (I6).
   It is loop runtime like `HANDOFF.md` and `.spec-loop/`, which `.gitignore` already ignores; `specs/**/TB_PROMPT.md` added beside them.

Red proofs for the lint fix. Each throwaway file was removed afterwards, and none was committed.
```
$ printf '#!/usr/bin/env bash\ncd /tmp\nx=1\n' > tests/zz_red.sh; make lint     # my FIRST Makefile draft, before set -e
… SC2164 (warning) and SC2034 (warning) printed …
red-sh exit=0            <- defect (b) reproduced in my own first draft: shellcheck's failure swallowed
# after adding `set -e`:
$ same tests/zz_red.sh; make lint                                                     -> red-sh exit=2
$ printf '#!/usr/bin/env bash\ncd /tmp\n' > tests/fakes/zzred; make lint              -> red-fake exit=2
$ .github/workflows/zz-red.yml containing `run: echo ${{ github.nope }}`; make lint
.github/workflows/zz-red.yml:7:23: property "nope" is not defined in object type {…} [expression]
make: *** [Makefile:13: lint] Error 1                                                 -> red-yml exit=2
$ PATH=/usr/bin:/bin make lint
lint: shellcheck not found (install it, or uv for uvx)
make: *** [Makefile:13: lint] Error 1                                                 -> no-shellcheck exit=2
```
(make exits 2 when a recipe fails. The recipe's own exit is 1 or shellcheck's code.)

Checked and found sound, no change needed: all seven workflows parse under actionlint 1.7.12 with shellcheck
on their `run:` blocks (no output, exit 0). Every JSON under `factory/policy/` and `factory/nodes/`, plus
`.adlc/config.json`, `.claude-plugin/marketplace.json` and `factory/.claude-plugin/plugin.json`, parses
(tests/test_layout.sh covers the policy and node files). Every backticked repo path in tracked `*.md` resolves,
except the ones that deliberately name future work: `factory/bin/join.sh`, `factory/bin/run-loop.sh`,
`factory/DESK.md`, `factory/HALT`, the TB1–TB4 test files, and `.adlc/tickets.json`, which ADR-0002 discusses
as superseded.

## 4. Measured after the fixes (the gate for this row)

```
$ make test
PASS tests/test_layout.sh
exit=0
```

```
$ make lint
exit=0
```

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
$ a ticket list --json
[
  {
    "id": "T1",
    "title": "Implement the git-ref claim protocol: claim, heartbeat, release",
    "ticketHash": "882cd7ad6a51c73f4652f1c01804f68304ecc0e2faf0bb5cc3257b7a036e9b77"
  },
  {
    "id": "T2",
    "title": "Implement the kill switch: halt-check, branch rules as code, halt notice",
    "ticketHash": "175d504874c21502d729318a370b0d87c9101696f15d58b2184debb17784e1b7"
  },
  {
    "id": "T3",
    "title": "Implement the clock and janitor: every TTL, heartbeat, stale and scheduled transition",
    "ticketHash": "b03ce207d054730ba73bb26e61afaa01566274262623626ae200eb0cd28056ef"
  },
  {
    "id": "T4",
    "title": "Implement the mirror and post-merge jobs: ticket store to Issues, completion only from main",
    "ticketHash": "cd2504564fbf2cef1be453cd711e6a99f4e0705e07f17aa9962cadd2579b21cd"
  },
  {
    "id": "T5",
    "title": "Decide the chassis: read the five candidates (four alternatives plus the fleet default) and amend ADR-0003",
    "ticketHash": "59c8363ea4f1d63538bcbffe23f3dc0fc5913ef606b89c1fecfc08c50f98687c"
  }
]
exit=0
```

```
$ a coldstart --all --offline --json
{
  "ok": true,
  "results": [
    {
      "id": "T1",
      "pass": true,
      "gaps": [],
      "cached": false,
      "offline": true
    },
    {
      "id": "T2",
      "pass": true,
      "gaps": [],
      "cached": false,
      "offline": true
    },
    {
      "id": "T3",
      "pass": true,
      "gaps": [],
      "cached": false,
      "offline": true
    },
    {
      "id": "T4",
      "pass": true,
      "gaps": [],
      "cached": false,
      "offline": true
    },
    {
      "id": "T5",
      "pass": true,
      "gaps": [],
      "cached": false,
      "offline": true
    }
  ]
}
exit=0
```

```
$ a merge-forecast --json
{
  "pairs": [
    {
      "pair": "T1–T5",
      "a": "T1",
      "b": "T5",
      "score": 0,
      "signal": "none",
      "verdict": "PARALLEL",
      "hardVeto": false
    },
    {
      "pair": "T2–T5",
      "a": "T2",
      "b": "T5",
      "score": 0,
      "signal": "none",
      "verdict": "PARALLEL",
      "hardVeto": false
    },
    {
      "pair": "T3–T5",
      "a": "T3",
      "b": "T5",
      "score": 0,
      "signal": "none",
      "verdict": "PARALLEL",
      "hardVeto": false
    },
    {
      "pair": "T4–T5",
      "a": "T4",
      "b": "T5",
      "score": 0,
      "signal": "none",
      "verdict": "PARALLEL",
      "hardVeto": false
    }
  ],
  "waves": [
    [
      "T1",
      "T5"
    ],
    [
      "T2"
    ],
    [
      "T3"
    ],
    [
      "T4"
    ]
  ],
  "mergeOrder": [
    "T1",
    "T5",
    "T2",
    "T3",
    "T4"
  ],
  "firstWaveWidth": 2,
  "scheduleWidth": 2,
  "certifiedWidth": 2,
  "backpressureWidth": null,
  "recommendedWidth": 2,
  "warnings": [
    "co-change: empty co-change pairs in history"
  ],
  "gateFailures": [],
  "pullQueueNote": "idle builders claim next unblocked"
}
exit=0
```

```
$ a fleet run --dry-run --json
{
  "integrationBranch": "fleet/run-<runId>",
  "concurrency": 2,
  "base": "main",
  "baseSha": "6b7c9fbb68767dba27fa1653f70769cd696bfb44",
  "readyNow": [
    "T1",
    "T5"
  ],
  "firstBatch": [
    "T1",
    "T5"
  ],
  "waitingOnDeps": [
    "T2",
    "T3",
    "T4"
  ],
  "subsetBlocked": [],
  "completedExcluded": 0,
  "worktreeRoot": "/home/musicofhel/software-factory",
  "plannedWorktrees": {
    "T1": "/home/musicofhel/software-factory/.worktrees/fleet-t1",
    "T5": "/home/musicofhel/software-factory/.worktrees/fleet-t5"
  },
  "integrationWorktree": "/home/musicofhel/software-factory/.worktrees/fleet-integration",
  "readPolicy": "host",
  "privateTmp": false,
  "gitSource": "shared",
  "mirror": null,
  "egress": "open",
  "workerDeps": null,
  "maxStrikes": 2,
  "wallClockMinutes": null,
  "noPr": false,
  "noComplete": false,
  "quartermaster": {
    "engaged": false,
    "seats": []
  }
}
exit=0
```

`make lint` prints nothing on success: shellcheck is clean on every file in `SH_FILES` and actionlint is clean
on all seven workflows.

## 5. Found but not fixed here (each is owned by a later row; recorded so it is not lost)

- **TB3 / `.github/workflows/janitor.yml`:** the workflow passes `--dry-run` or nothing. I2 makes `--dry-run`
  the default on writers, so flipping `JANITOR_DRY_RUN=false` would never take effect. The workflow needs the
  script's explicit apply flag, whatever TB3 names it. The step also reads `${{ env.DRY_RUN }}` in the same
  step that sets it; the shell's `$DRY_RUN` is the unambiguous form. And `halt-check.sh` exits 3 when halted,
  which would fail the job red on every hourly tick during a halt; the step should turn exit 3 into a clean
  skip. TB3's DoD already says "janitor.yml reviewed against the script's flags".
- **TB2 / `factory/policy/branch-protection.json`:** the ruleset `halt-removal-needs-two` uses
  `"path_filter": {"paths": [...], "on": "deletion"}`. As far as this session knows, that is not a GitHub
  rulesets API field: rulesets have `file_path_restriction` push rules and `pull_request` rules, and neither
  is keyed on add-versus-delete. TB2 must verify this against the API docs (read-only lookups are allowed).
  Separately, `require_code_owner_reviews` plus `factory/HALT @musicofhel` in CODEOWNERS plus
  `required_approving_review_count: 1` means ADDING the HALT file needs one owner approval, not the zero
  SPEC-v0.2 says. TB2 must either find a real API expression or record the deviation as an ADR (I7). Its DoD
  makes `apply-branch-protection.sh` print every call from this file, so it will run into this directly.
- **Step 3 (out of scope):** the `gates.yml` `tamper` job runs `pipx run tamperguard==0.2.0 --base origin/main`.
  This session did not verify either the `pkg==ver` form for `pipx run` or tamperguard's `--base` flag. It is a
  stub-era job.
