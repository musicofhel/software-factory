# TB4 — The reviewer pin and the cux line in join (ticket T15; rulings Q4, Q5)

Session 7, 2026-10-25. No prep existed for this row (`specs/factory-step2-followups-v1/prep/` is
absent). Nothing was pushed and nothing was written to GitHub (I1). The network reads were npm
registry reads (`npm view`, `npm pack`, `npm install` into scratch dirs under `~/.cache`) and the
live join test's fixture runs.

Commits: `595e933` (`Ticket: scaffold`, the desk update in §4) and the `Ticket: T15` commit that
carries this file.

## 1. What was built

Step-2 rulings (`specs/factory-step2-v1/RULINGS.md`): Q4 "Pin adversarial-review 2.11.1 by npm
integrity in join's plan; same-family review accepted until step 4". Q5 "join.sh prints the `cux add`
line in the register step; it handles no credential".

- **`factory/bin/join.sh`, install plan.** There is a new plan step, `adversarial-review 2.11.1`,
  between cux and the adapters. Its single command, as printed by the dry run, is:
  ```
  rm -f $FH/receipts/adversarial-review@2.11.1 && d=$(mktemp -d $FH/tmp/adversarial-review.XXXXXX) &&
  trap 'rm -rf "$d"' EXIT && npm pack adversarial-review@2.11.1 --pack-destination "$d" --cache $FH/npm
  --silent >/dev/null && printf '%s  %s\n' <ADV_SHA512> "$d/adversarial-review-2.11.1.tgz" | sha512sum -c - &&
  npm install -g --prefix $FH --cache $FH/npm --no-audit --no-fund --ignore-scripts "$d/adversarial-review-2.11.1.tgz" &&
  mkdir -p $FH/receipts && printf '%s\n' <ADV_INTEGRITY> >$FH/receipts/adversarial-review@2.11.1
  ```
  - The order of the steps is what makes it fail closed:
    1. The old receipt is removed first.
    2. The tarball's sha512 is checked against the pin before npm sees the tarball.
    3. npm installs that same file, never a registry spec.
    4. The receipt is written last.
    5. The temp dir is removed either way.
  - On macOS the check is `shasum -a 512 -c -`.
  - `ADV_INTEGRITY` is the ruling's pin. `ADV_SHA512` is the same digest in hex. A test decodes one and
    compares it with the other.
  - **State.** The step counts as `installed` only when all of these hold: the package under
    `$FH/lib/node_modules/adversarial-review` is at 2.11.1, `$FH/bin/adversarial-review` is executable,
    and the receipt holds the pinned integrity. Otherwise the state is `drift` (a found version, or
    "2.11.1 without a verified install"), or `missing`. A copy elsewhere on PATH does not count, since
    there is no receipt to check. The env file puts `$FH/bin` first, so fleet resolves join's copy
    (`lib/review-runner.mjs` `resolveTrustedBin` takes the first absolute PATH hit).
  - **Blocked.** If npm or the sha512 tool is missing, the step is a refusal. That applies only when
    the reviewer is not already verified at its pin.
  - **After `--apply`.** join checks the package version, the bin link and the receipt again, and
    stops with exit 1 if any of them is wrong.
- **Manifest `review` field.** The manifest gains
  `review: {tool: "adversarial-review", pin: "2.11.1", same_family: <bool>}`.
  - `same_family` is true when the node has one usable adapter (`adapters | length <= 1`). In that
    case the reviewer can only run on the builder's model family. Today only claude-code can be usable,
    because only claude-code has a measured auth check, so `same_family` is always true for now.
  - `factory/nodes/manifest.schema.json` adds `review` as an optional property
    (`additionalProperties: false`, `tool` enum, `pin` semver, `same_family` boolean). It is optional
    so that manifests already on `nodes` still validate. join always writes it.
  - `example.json` carries it. README and SKILL document it.
- **Register step, line c.**
  ```
    c. Quota account, run by you after `. $FH/env` (the wizard never runs it): cux add --no-alias
       Why: the run loop's governor (factory/bin/lib/governor.sh) reads `cux usage show` before every
       claim and never claims on an unknown reading: with no cux account every slot sleeps 10 minutes
       (budget.json governor.unknownStateSleepMinutes) and never claims.
       --no-alias: the factory counts accounts and never names them, so no alias is taken from the
       account display name. cux reads the account from your claude-code login; the wizard never
       reads, writes or passes that credential.
  ```
  In `--json` mode this is `register.quota` (`command`, `after`, `run_by`, `why`, `no_alias`).
- **`tests/live/test_smoke_live.sh`** has no reviewer install of its own (`grep -c 'npm install'` = 0)
  and no `cux add` of its own:
  - It reads `register.quota.command` from join's JSON report, checks that it is exactly
    `cux add --no-alias`, and runs it as the owner would.
  - It checks that join installed 2.11.1 with the pinned receipt.
  - It checks that `command -v adversarial-review` is `$FH/bin/adversarial-review`.
  - `$S/review/node_modules/.bin` is gone from its PATH.
- **Fakes and tests.**
  - `tests/fakes/join/multi` gains `npm pack`, a tarball `npm install -g` (`FAKE_NPM_INSTALL_NOOP`),
    `sha512sum` / `shasum -a 512` (logs `bits`; `FAKE_SHA512_MISMATCH`), and `cux --version`.
  - The fake curl's cux is now a copy of the fake, so an installed cux logs every call and refuses any
    verb other than `--version`.
  - `tests/test_join.sh` has three new cases (`review-pin`, `review-field`, `cux-line`). It also
    extends `dry-run-ok`, `plan`, `home-diff` and `validator`.
  - `tests/live/test_join_live.sh` part B now installs the real reviewer. A new part C proves the
    fail-closed path with the real npm and sha512sum.

## 2. Decisions (and why)

1. **Verify the tarball, then install the file.** npm 10's `-g` install writes no lockfile, and the
   installed `package.json` carries no `_integrity`; both were measured, see §3.1. So after the fact
   nothing on disk says which bytes were installed. Checking the packed tarball's sha512 before npm
   installs exactly that file is the only point where the pin can be enforced. It also does not rely
   on npm's registry metadata agreeing with the pin. The package has no dependencies (§3.1), so the one
   tarball is the whole install and the pin covers all of it.
2. **A receipt, written last.** AC1 says "nothing recorded as installed". The receipt is that record:
   - It is removed before an install starts and written only after a verified install.
   - A failed or partial run leaves no receipt, so the next plan says `missing` or `drift`.
   - Without a receipt, a 2.11.1 that some other process put into `$FH` would count as installed
     unverified.
3. **The reason printed for the cux line is the governor's, not fleet's.** The ticket body said
   "fleet's pre-strike quota gate reads cux usage". `grep -rn -i cux` over fleet 1.12.0's `lib/` and
   `bin/` finds nothing. The reader is `factory/bin/lib/governor.sh`, which fails closed on `{}` (cux
   manages no account). The desk update in §4 corrected the body before any code was written.
4. **The smoke runs join's printed line.** Q5 has the owner run `cux add`. The smoke stands in for the
   owner, so it runs the exact string join printed (after checking that string). That way the printed
   line is exercised live, and the smoke carries no `cux add` of its own.
5. **`review` is optional in the schema.** Making it required would turn every manifest already on a
   `nodes` branch invalid until that node re-joins. The wizard always writes it, and a test pins that.
6. **The GitHub token is not part of this row.** `--token-file` (T7) still stores a `github_pat_…`
   token at `$FH/token`, using bash builtins only. Q5 is about the cux account. AC3's check is that no
   tool join runs gets a credential in its argv, and that join never runs `cux add`. The `cux-line`
   test asserts both with a token and a planted claude credential in place.

## 3. Evidence

### 3.1 The package, measured

```
$ npm view adversarial-review@2.11.1 dist.integrity bin dependencies engines --json
{ "dist.integrity": "sha512-LiPc0R5UXJQ/tsUd3yEOVkISYxtbyFlvDlMFPtLW1lcVNhLjOqluDZXaVmYYEb0oONdsSs+xVbAbyWN2e0HCEA==",
  "bin": { "adv-review": "bin/cli.js", "adversarial-review": "bin/cli.js" }, "engines": { "node": ">=18.0.0" } }
  (no dependencies, optionalDependencies or peerDependencies key)
$ npm pack adversarial-review@2.11.1 --pack-destination $T --cache $T/npm --json | jq '.[0] | {filename, integrity, version}'
{"filename":"adversarial-review-2.11.1.tgz","integrity":"sha512-LiPc0R5U…HEA==","version":"2.11.1"}
$ sha512sum adversarial-review-2.11.1.tgz
2e23dcd11e545c943fb6c51ddf210e564212631b5bc8596f0e53053ed2d6d657153612e33aa96e0d95da56661811bd2838d76c4acfb155b01bc963767b41c210
$ echo LiPc0R5U…HEA== | base64 -d | od -An -tx1 -v | tr -d ' \n'      → the same hex
$ npm install -g --prefix $T/fh --cache $T/npm --no-audit --no-fund --ignore-scripts $T/adversarial-review-2.11.1.tgz
  rc=0; $T/fh/bin/{adversarial-review,adv-review} -> ../lib/node_modules/adversarial-review/bin/cli.js
  $T/fh/lib/node_modules/.package-lock.json: absent
$ $T/fh/bin/adversarial-review --version   → "Unknown option --version"   (so no version probe; --help exits 0)
```

fleet 1.12.0's reviewer lookup is `lib/review-runner.mjs` `resolveTrustedBin(bin, PATH, worktree)`. It
takes the first absolute, non-worktree PATH dir that holds `adversarial-review`. fleet has no `cux`
reference anywhere in `lib/` or `bin/` (`grep -rn -i cux` is empty).

### 3.2 Offline gates

Run on the final tree, after the lint fixes:

```
$ make test   → PASS tests/test_bwrap_shim.sh … PASS tests/test_version_check.sh   (15 files, exit 0)
$ make lint   → exit 0
$ bash tests/test_join.sh → PASS on all 20 cases, including review-pin, review-field and cux-line
```

The first `make lint` failed on three test-only warnings: SC2010 `ls | grep` in the live part C,
SC2115 `rm -rf "$fh/lib"`, and SC2034 `cred0` read only inside an `eval` string. All three were fixed
before the run above.

### 3.3 Mutation check (each mutant of join.sh run against `tests/test_join.sh`, then restored; `cmp` clean)

| mutant | cases that failed |
|---|---|
| skip the sha512 check (`… | sha512sum -c - && npm install` → `&& npm install`) | home-diff, review-pin |
| write the receipt before the download | review-pin |
| `adv_verified` ignores the receipt | review-pin |
| drop the post-install `adv_verified` check | review-pin |
| `same_family: false` | dry-run-ok, review-field |
| `--apply` runs `cux add --no-alias` | cux-line |
| the register line c text changed | cux-line |
| npm installs the registry spec instead of the checked file | home-diff, review-pin, cux-line |
| npm missing no longer blocks the step | review-pin |

### 3.4 Live: `tests/live/test_join_live.sh` (real npm registry, real sha512sum)

`test_join_live.sh` part B runs `git clone "$REPO_ROOT"`, so it tests HEAD, not the working tree.
The first run therefore exercised the committed (pre-T15) join and failed on every new check. It was
run again from a throwaway worktree (`~/.cache/tb4-live-wt`, branch `tb4-live-tmp`, commit `b4f7e55`,
never pushed). That commit's changed files are byte-identical to the `Ticket: T15` commit's; the
blob ids were compared before the worktree and branch were removed.

```
test_join_live
  part A: dry run in ~/.cache/tb4-live-wt
    INFO slots 8, heavy_gates true, suite {"ran":true,"seconds":95,"exit":0,"timed_out":false,"timeout_seconds":600}
    INFO plan: … dcg 0.15.3 installed; cux 0.4.1 installed; adversarial-review 2.11.1 missing; claude-code 2.1.280 installed
  part B: --apply against a fixture origin with a scratch FACTORY_HOME
    ok   the plan installs exactly dcg, cux, the reviewer and the npx cache
    ok   adversarial-review's npm tarball passed the pinned sha512 before npm installed it
    ok   adversarial-review 2.11.1 under $FACTORY_HOME, with the receipt of the pinned integrity
    ok   the receipt's integrity is npm's own for 2.11.1
    ok   the installed reviewer runs (--help exits 0)
    ok   the manifest records it, same family on this claude-only box
    ok   the register step carries the cux line for the owner
    ok   env puts $FACTORY_HOME/bin first            (dcg, cux, adversarial-review)
    ok   a second --apply with the env sourced exits 0
    ok   and installs nothing
    |   $ rm -f …/fh/receipts/adversarial-review@2.11.1 && d=$(mktemp -d …/fh/tmp/adversarial-review.XXXXXX) && trap … && npm pack … | sha512sum -c - && npm install -g --prefix …/fh … "$d/adversarial-review-2.11.1.tgz" && … receipt
    | …/fh/tmp/adversarial-review.4kalDU/adversarial-review-2.11.1.tgz: OK
  part C: --apply with a wrong ADV_SHA512 in a scratch copy of the wizard
    ok   the copy's pin differs from the real one in one digit
    ok   --apply exits 1
    ok   the real sha512sum refused the real tarball
    ok   the wizard names the failed install step
    ok   nothing installed or recorded: no package, no bin link, no receipt, no temp dir
    ok   no manifest pushed
PASS test_join_live          (48 ok, 0 FAIL)
```

The part A dry run on this box's real `~/.factory` reports `adversarial-review 2.11.1 missing`, which
is correct: dev-box's own `~/.factory` has never had the reviewer installed by join. The only warning
is the existing vetto `~/.aws` symlink warning.

### 3.5 Not run here

`tests/live/test_smoke_live.sh` was edited but not run. It starts a real claude worker, and AC4's
`make live` belongs to TB5 Part A, which runs the smoke with the shim. For this row, AC4's grep half
holds: `grep -c 'npm install' tests/live/test_smoke_live.sh` → `0`. `make lint` covers the smoke's
shellcheck.

## 4. Desk change to T15 (`Ticket: scaffold`, `595e933`)

`tests/live/test_smoke_live.sh` was not in T15's scope, but deliverable 4 and AC4 edit it. The body's
reason for the cux line named fleet, and the real reader is the governor (§2.3). The body also now says
the smoke runs the line join printed.

```
$ a ticket show T15 --json → ticketHash 3dcfea7ce0d8…a8a8
$ a ticket update T15 --input t15.json --expect 3dcfea7ce0d8…a8a8 --json
{"ok":false,"kind":"policy","code":"AUTHORIZATION_REQUIRED","message":"update requires authorization: scope-widening"}   exit=2
$ a ticket update T15 … --authorize --json          → changedFields [body, scope], sensitive [scope-widening], validation valid, dryRun true
$ a ticket update T15 … --authorize --write --json  → applied true, ticketHash 367b5e41dba0…e577
$ a ticket doctor                    → All checks passed.   exit=0
$ a coldstart --all --offline --json → ok true, gaps []
$ a merge-forecast --json            → gateFailures [], waves [[T12,T13],[T15,T14],[T16]]   exit=0
```

## 5. Left as is

- `release_cmd` (dcg, cux) still leaves its temp dir behind when a sha256 check fails. That predates
  this row. The reviewer's command uses an EXIT trap instead.
- `same_family` cannot be false on any box today. Only claude-code has a measured auth check, so no
  second adapter can be usable. Build-order step 4 makes it reachable. The schema and the jq
  expression already handle it, but no offline case produces two usable adapters.
- The reviewer's provider is not pinned here. fleet calls `adversarial-review` without `--provider`
  unless configured, and prosecution.json's `providersPreferred` is prose. That is step 4's
  cross-family work.
