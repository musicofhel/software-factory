# TB0 — Register, tickets T20–T31, and the measurements the rows depend on

Session date 2026-10-26. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2. Measured at `8768a4a`
(= `origin/main` = local `main`, the SPEC commit on top of `4ea237c`). `git diff --name-only 4ea237c 8768a4a`
touches only `specs/factory-step3-v1/`, so the code tree is byte-identical to the one the pre-spec
simulation (`records/sim/`) ran against. Nothing was pushed (I1). Every GitHub call below is a read
(`gh api` GET, GraphQL query, `gh run list/view`). Docs pages were fetched with `curl` into
`~/.cache/step3-tb0/docs/` (node-local). `a` = `npx -y @adlc/cli@1.12.0`.

**State: done.** Register re-measured (§1), measurements (a)–(d) taken (§2), all 75 gap ids re-checked
(§3: 0 closed, 0 wrong; 74 open, where ci:G3/merge:G1 are now settled by the docs and ci:G21 is open on
the repo side; 1, merge:G13, is GitHub runtime behavior not observable with 0 PRs), T20–T31 drafted, proven in a scratch clone and written to main's store (§4).

## 1. The register, re-measured

| key | SPEC §0 said | measured now | cmd |
|---|---|---|---|
| repo | public, User-owned; no rulesets, no protection, no secrets, no variables, 0 runners; auto-merge off; gates.yml never ran | **same.** `owner_type: User`, `private: false`, `allow_auto_merge: false`; rulesets `[]`; `branches/main/protection` 404 "Branch not protected"; secrets 0, variables 0, environments 0, runners 0; `gh run list --workflow gates.yml` → 0 runs; branches `["main"]` | §1.1 |
| merge queue | believed org-only; docs did not state it | **measured: org-only.** Docs quote in §2(a). `native-queue: no` | §2(a) |
| check-run names | bare job id | **same.** main's check runs at `8768a4a`: `mirror`, `complete` (post-merge.yml's job ids), app `github-actions` id **15368**; janitor's are `janitor`. `tests/test_halt_rules.sh:94` still asserts `gates / <job>` | §2(b) |
| tamper job | `gates.yml:50` passes `--base`, rc 2 | **same.** `gates.yml:50` `pipx run tamperguard==0.2.0 --base origin/main`; `tamperguard --base HEAD` → `unrecognized arguments: --base`, rc=2; `--help` (uv tool v0.2.0) lists `--range`, `--json`, `--no-color`, `--fail-on {tamper,review,never}`, "Exit code: 0 = ok/review, 2 = tamper" | §1.2 |
| stubs | six scripts exit 2 | **same.** rails-proof, scope-check, commit-check, attest-verify, skills-scan (5 lines each), digest (6 lines): rc=2 | §1.2 |
| node commits | fleet's two commits carry no trailers | **same.** `@adlc/fleet/lib/worktrees.mjs:178` `add -A -- ':!.claude' ':!.adlc'`, `:179` `commit -q -m feat(${ticketId}): fleet worker build`, `:200` `merge --no-ff --no-edit` | §1.3 |
| PR body | `Ticket:`, `Issue:`, `Node:` only | **same.** `factory/bin/lib/run.sh:124-137` `run_pr_body`; `run.sh:416-417` `gh pr create` has no `--label` | §1.3 |
| claim across a PR | kept lock never heartbeated; janitor releases at 24 h; counts toward slots | **same.** `run.sh:424` `act keep-lock`; `janitor.sh:205-207` (stale-lock → release when `fresh_branch == null`, before `open_pr` at :208); `janitor.sh:211-218` over-slots cut | §1.3 |
| `ready` records | nothing writes spec-lint/coldstart/merge-forecast records | **same.** `mirror.sh:187-202`; manifest gates before this row's writes: 19 `ticket-complete`, 4 `ticket-update`, 2 `ticket-mutation` | §1.3 |
| Depends-on | no hold anywhere | **same.** `grep -rn -i 'depends-on' factory .github` → only `mirror.sh:17,258` (Issue body) | §1.3 |
| fleet block | none in main's config | **same.** `.adlc/config.json` = `{version, securityMode: "unsigned-fallback", harnesses}`; `@adlc/fleet/lib/preflight.mjs:63-64` refuses without `gate.build`/`gate.test` | §1.3 |
| post-merge | completes every `Ticket:` trailer; push needs the App | **same.** `post-merge.sh:114-117` collects every trailer in the brought range; no App vars/secrets | §1.3 |
| janitor | red hourly, `refs/heads/nodes` missing | **same.** run 40419415270 (2026-10-26T23:23Z): `fatal: couldn't find remote ref refs/heads/nodes` / `janitor: cannot fetch origin (nodes, ticket/**, refs/locks/*)`; the last 30 janitor runs: 29 failure, 1 cancelled | §1.4 |

### 1.1 Repo (GitHub, read-only)

```
$ gh api repos/musicofhel/software-factory --jq '{owner_type:.owner.type, private, visibility, allow_auto_merge, default_branch}'
{"allow_auto_merge":false,"default_branch":"main","owner_type":"User","private":false,"visibility":"public"}
$ gh api repos/$R/rulesets                       → []
$ gh api repos/$R/branches/main/protection       → {"message":"Branch not protected",…,"status":"404"}
$ gh api repos/$R/actions/secrets --jq .total_count       → 0
$ gh api repos/$R/actions/variables --jq .total_count     → 0
$ gh api repos/$R/environments --jq .total_count          → 0
$ gh api repos/$R/actions/runners --jq .total_count       → 0
$ gh run list -R $R --workflow gates.yml --json databaseId --jq length → 0
$ gh api repos/$R/branches --jq '[.[].name]'     → ["main"]
$ gh api repos/$R/labels --paginate --jq '[.[].name]'
["accessibility","bug","documentation","duplicate","enhancement","good first issue","help wanted","invalid","needs-desk","question","tier:0","tier:1","tier:2","w:heavy","w:light","wontfix"]
```

No `ready`, `blocked`, `in-review`, `autorebase` or `factory:halt` label exists yet (the mirror creates
owned labels on first use, `mirror.sh:294-297`).

### 1.2 Tamper and the stubs

```
$ uv tool list | grep -A1 tamperguard        → tamperguard v0.2.0
$ (cd /tmp && tamperguard --base HEAD; echo rc=$?)
tamperguard: error: unrecognized arguments: --base
rc=2
$ for f in rails-proof scope-check commit-check attest-verify skills-scan digest; do ./factory/bin/$f.sh; echo rc=$?; done
rails-proof: rc=2 5 lines · scope-check: rc=2 5 lines · commit-check: rc=2 5 lines
attest-verify: rc=2 5 lines · skills-scan: rc=2 5 lines · digest: rc=2 6 lines
```

### 1.3 Node, PR, claim, records, Depends-on, fleet, post-merge

Read in place; the re-check agents in §3 ran the same lines (file:line in the table above). The run.sh
scope call is `run.sh:392` (`"$SCOPE_CHECK" --ticket "$TICKET" --base "$BASE" --head "$tip"`) and the
stub hold is `run.sh:394-399` (`REASON=scope-check-not-built; outcome held`).

### 1.4 Janitor

```
$ gh run view 40419415270 -R musicofhel/software-factory --log-failed | grep -m2 -i nodes
janitor	janitor sweep	2026-10-26T23:23:29.7229990Z fatal: couldn't find remote ref refs/heads/nodes
janitor	janitor sweep	2026-10-26T23:23:29.7232727Z janitor: cannot fetch origin (nodes, ticket/**, refs/locks/*)
```

## 2. The measurements

### (a) Merge-queue availability → **`native-queue: no`**

Both merge-queue pages carry the same "Who can use this feature?" line (it sits in the page's product
callout, not in the article body, which is why the 2026-10-26 pre-spec fetch of the body API missed it):

```
$ curl -sSL https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue
  … Who can use this feature? People with admin permissions can manage merge queues for pull requests targeting
  selected branches of a repository. Pull request merge queues are available in any public repository owned by
  an organization, or in private repositories owned by organizations using GitHub Enterprise Cloud. See GitHub's plans.
$ curl -sSL https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/merging-a-pull-request-with-a-merge-queue
  … Who can use this feature? Pull request merge queues are available in any public repository owned by an
  organization, or in private repositories owned by organizations using GitHub Enterprise Cloud. See GitHub's plans.
$ gh api graphql -f query='query{repository(owner:"musicofhel",name:"software-factory"){mergeQueue(branch:"main"){id url}}}'
{"data":{"repository":{"mergeQueue":null}}}
```

The rulesets "Available rules" page (`…/managing-rulesets/available-rules-for-rulesets`) has no
availability line of its own for "Require merge queue". The GraphQL `null` alone would not decide it (an
org repo with no queue configured also answers null); the docs line does: this repo is owned by a
**User**, so GitHub's merge queue is not available. TB9 builds the first-party serial queue as the live
mode; the native mode stays coded and simulated (SPEC TB9), and TB12 asks **Q: the merge queue**.

### (b) Check-run names → **the bare job id, on both events**

- Docs: `jobs.<job_id>.name` "set[s] a name for the job, which is displayed in the GitHub UI"
  (`actions/reference/workflows-and-actions/workflow-syntax`). No job in `.github/workflows/*.yml` sets
  `name:` (grep of `^    name:` → none), so each check run is named by its job id.
- Measured on this repo: `gh api repos/$R/commits/main/check-runs --jq '.check_runs[] | {name, app:.app.slug, app_id:.app.id}'`
  → `{"name":"mirror","app":"github-actions","app_id":15368}`, `{"name":"complete",…,15368}`. No
  `<workflow> / <job>` prefix. `integration_id` for a required check pinned to Actions is **15368**.
- merge_group: this repo has never had a merge_group run (0 PRs), so it is not measured here. The docs
  say a required check must be reported by a workflow that also runs on `merge_group`
  ("You **must** use the `merge_group` event to trigger your GitHub Actions workflow when a pull request
  is added to a merge queue … Otherwise … The merge will fail as the required status check will not be
  reported", managing-a-merge-queue). The same job id reports under the same name on either event. With
  `native-queue: no` this matters only for the native mode.
- Two docs facts the later rows need (`pull-requests/reference/status-checks`;
  `pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks`):
  "A job that is skipped will report its status as "Success". It will not prevent a pull request from
  merging, even if it is a required check." and "A job depends on a failed job → The dependent job is
  skipped and may not block merging. Use `always()` with `needs` for required checks that depend on
  other jobs." So `dependencies` (`if: pull_request`) passes in the queue, and `attest-verify`
  (`needs: [...]`) is skipped (= green) when a gate it needs fails. TB10/TB11 must not rely on either.

### (c) Tools: pinned, installable releases, with license

| tool | where (SPEC-v0.2 L1405–1417) | newest pinned release | license | verdict for TB11 |
|---|---|---|---|---|
| ubs | Dicklesworthstone/ultimate_bug_scanner | v5.5.3 (2026-10-15; release assets `ubs`, `SHA256SUMS`, `.minisig`; tags go to v5.5.13 without releases) | **"MIT License (with OpenAI/Anthropic Rider)"**: "no rights are granted to any Restricted Party" (Anthropic, PBC, its affiliates, and "any person or entity acting directly or indirectly on behalf of, for the benefit of, or under the direction of" them); "use" includes "executing … or incorporating the Software … into any … pipeline for machine learning or other automated systems" | **not license-compatible**: this factory's builders are Claude Code agents (`Assisted-by: claude-code@…`). Not downloaded, not run. No `bugscan` job; TB11's `### Q` |
| aislop | scanaislop/aislop; npm `aislop` | 0.18.1 (npm latest; GitHub release v0.18.1, 2026-10-06, no assets) | MIT | installable (`npx -y aislop@0.18.1`). The SPEC wants ubs **and** aislop for the job, so aislop alone does not add it |
| attest | CorvidLabs/attest | 1.0.0 (2026-07-07; `attest-linux-x86_64` 85 MB + `.sha256`) | MIT | exists as a pinned linux release; README: "records signed attestations … keyed to git commit SHAs and stored in **git notes**". TB11 uses it if it fits the note format, citing it; else first-party in ADR-0007 |
| flaky-test-detective | ahmedhashmu/flaky-test-detective | **none**: 0 releases, 0 tags; PyPI `flaky-test-detective` and `flaky_test_detective` → 404. npm `flaky-test-detective@0.1.0` is a **different project** (`repository: mvpamansingh/Flaky-cli`) | MIT (pyproject) | no pinned release → the JUnit classifier is step 4; TB11 builds only the quarantine expiry reader |
| bomdrift | Metbcy/bomdrift; crates.io `bomdrift` | v0.9.9 (2026-05-01; x86_64-unknown-linux-gnu tarball + `.sha256` + `.sig` + `.pem`) | Apache-2.0 | exists; not in any step-3 row (SPEC L572–576 is a supply-chain addition the rows do not ask for) |

```
$ gh api repos/Dicklesworthstone/ultimate_bug_scanner/license --jq .license.spdx_id   → NOASSERTION
$ gh api repos/Dicklesworthstone/ultimate_bug_scanner/contents/LICENSE --jq .content | base64 -d | sed -n '1,3p;12,30p'   (quoted above)
$ npm view aislop name version license dist-tags --json → {"name":"aislop","version":"0.18.1","license":"MIT","dist-tags":{"latest":"0.18.1"}}
$ gh api repos/CorvidLabs/attest/releases/latest --jq '{tag_name,published_at}' → {"published_at":"2026-07-07T21:34:20Z","tag_name":"1.0.0"}
$ gh api repos/CorvidLabs/attest/license --jq .license.spdx_id → MIT
$ gh api 'repos/ahmedhashmu/flaky-test-detective/releases?per_page=3' → []; …/tags → []
$ curl -s -o /dev/null -w '%{http_code}' https://pypi.org/pypi/flaky-test-detective/json → 404
$ npm view flaky-test-detective repository.url → git+https://github.com/mvpamansingh/Flaky-cli.git
$ curl -s https://crates.io/api/v1/crates/bomdrift | jq -c '{v:.crate.max_stable_version, lic:.versions[0].license}' → {"v":"0.9.9","lic":"Apache-2.0"}
```

### (d) `GITHUB_TOKEN` events → **they start no workflow** (with three named exceptions)

`actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow`, "Triggering a workflow
from a workflow":

> When you use the repository's `GITHUB_TOKEN` to perform tasks, events triggered by the `GITHUB_TOKEN`
> will not create a new workflow run, with the following exceptions:
> * `workflow_dispatch` and `repository_dispatch` events always create workflow runs.
> * `pull_request` events with the `opened`, `synchronize`, or `reopened` activity types: when a workflow
>   using `GITHUB_TOKEN` creates or updates a pull request, the resulting `pull_request` event creates
>   workflow runs in an **approval-required** state. … Other `pull_request` activity types (such as
>   `labeled`, `edited`, or `closed`) do not create workflow runs.
>
> For all other events … if a workflow run pushes code using the repository's `GITHUB_TOKEN`, a new
> workflow will not run even when the repository contains a workflow configured to run when `push`
> events occur. … If you do want to trigger a workflow from within a workflow run, you can use a GitHub
> App installation access token or a personal access token instead.

Consequences for TB8 (and intake:I8): a label set by the mirror on `github.token` never fires
`summoner.yml`'s `issues: labeled` (the API agrees: 45 label events by `github-actions[bot]` since
summoner.yml landed, 0 summoner runs). A post-merge push on `GITHUB_TOKEN` starts no `push` workflow, so
the labeler and the held-PR re-evaluation also run on `schedule`, and use the App token when it exists.
`workflow_dispatch` is the one GITHUB_TOKEN-safe trigger (TB8/TB9 may use it to chain).

## 3. Every gap id, re-checked

Method: three read-only agents re-opened every file:line cited in `records/sim/{ci,merge,intake,node}.md`
against `8768a4a`, re-ran the cited commands (`gh api` GETs, `tamperguard --base`, the S1 adlc scenario in
throwaway `/tmp` clones), and classified each row. **None is closed and none is wrong.** A few
citations are a few lines off with the same content (corrected below); the conclusions stand.

| segment | ids | verdict |
|---|---|---|
| ci | G1 G2 G4 G5 G6 G7 G8 G9 G10 G11 G12 G13 G14 G15 G16 G17 G18 G19 G20 G22 | open |
| ci | G3 | **settled by (a)**: merge queue is org-only, the repo is User-owned → open, as the SPEC's Q |
| ci | G21 | open on the repo side (no `dequeued` handler: `grep -rln dequeued .github factory/bin` → none). The event type exists: events-that-trigger-workflows lists `pull_request` activity types `enqueued`, `dequeued` (L448, L698 of the fetched body). Native mode only |
| merge | G2 G3 G4 G5 G6 G7 G8a G8b G8c G9 G10 G11 G12 G14 G15 G16 G17 G18 G19 G20 | open |
| merge | G1 | **settled by (a)** → open (Aaron's kit / TB12 Q) |
| merge | G13 | GitHub runtime behavior (an App push to main rebuilding a queued merge_group); not observable with 0 PRs. Native mode only; with the first-party serial queue (one PR at a time) it does not arise |
| intake | I1–I14 | open (I8 is step 4; I9 is Aaron's kit, the `nodes` branch) |
| node | G1–G17 | open (G9's repo half confirmed; GitHub's matching follows from (b)) |

Evidence highlights (one command per class; the agents' full tables were not kept beyond this summary):

```
$ sed -n 33,39p factory/policy/branch-protection.json  → { "context": "gates / build-test" } … "gates / commit-check"   (ci:G1, merge:G2, node:G9)
$ sed -n 51p factory/bin/lib/common.sh                 → valid_ticket_id … ^[A-Za-z0-9][A-Za-z0-9._:/#-]{0,127}$ (allows /)   (ci:G7)
$ (scratch /tmp clone) a ticket complete T20 --write --authorize --allow-unsigned → T20 completed=true, T21 (its parent) completed=null   (merge:G3)
$ (scratch) a merge-forecast --json | jq -c '{waves}'  → {"waves":[["T21"],["T20"]]}   (merge:G9, intake:I2, node:G11)
$ jq '{fleet}' .adlc/config.json                       → {"fleet": null}   (node:G10, merge:G19)
$ ~/.local/share/uv/tools/tamperguard/bin/python --version → Python 3.14.3; gates.yml:48 python-version "3.12"   (node:G16)
$ grep -n adversarial-review factory/bin/run.sh        → none   (node:G16)
$ jq '.permissions, .ref_patterns' (join.sh:403-404)   → contents + metadata only; ticket/**, nodes/**, refs/locks/**   (node:G7, ci:G16)
$ gh api repos/$R/actions/permissions                  → "sha_pinning_required": false   (ci:G17)
$ grep -c . factory/RULES.md                           → 52 lines; the post-merge exemption is L44-52   (intake:I6)
```

Line corrections (content unchanged): merge:G7 `run.sh:425` → `:424`; merge:G8b over-slots
`janitor.sh:211-218`; merge:G20 the release-completion row is SPEC-v0.2 L195–196; intake:I2 the
dead-letter text is SPEC-v0.2 L750; intake:I3 `lib/run.sh:124-137`; intake:I6 RULES.md L44–52;
node:G3 janitor L204–218; node:G16 SPEC-v0.2 L643; ci SPEC-v0.2 anchors: L557→558, L683–686→685–686,
L800–802→801–802, L808–812→809–813; ci:G11 ADR-0004 L68–69; ci:G17 post-merge.yml pins only
`create-github-app-token` by sha (its checkout/setup-node use tags). ci:G20: `factory/policy/README.md:16`
marks `tamperguard.toml` as "build order 3" (planned), not as existing; still a gap, since tamperguard
0.2.0 reads no config file.

## 4. Tickets T20–T31

### 4.1 The drafts

`records/tickets/gen.py` writes `records/tickets/T20.json` … `T31.json` (the exact input documents).
Each body opens with the ADR-0002 header block, names its SPEC row and the gap ids it closes, lists
deliverables, gives acceptance criteria that each end in `Verify: <command>` (plus the two common ones:
`make lint`; `make test` and `make sim`), names its **new paths** (so TB7's "scope glob resolves to a path
or a declared new path" has something to read), and an out-of-scope line with I1 and I15. Every ticket
declares `rails: ["factory/policy/**"]`; no scope names `factory/policy/**` or `.adlc/**`.

| id | row | header (weight/tier/charter) | title (short) | edges |
|---|---|---|---|---|
| T20 | TB1 | light / 0 / C6 | `make sim` harness | T21 |
| T21 | TB2 | light / 0 / C6 | gate context and identity | T22 |
| T22 | TB3 | light / 0 / C6 | the three diff gates | T23 |
| T23 | TB4 | light / 0 / C6 | one trailered commit, commit check | T24 |
| T24 | TB5 | heavy / 0 / C5 | fleet block, build-test from base config | T25 |
| T25 | TB6 | light / 1 / C2 | claim across an open PR, `blocked` | T26 |
| T26 | TB7 | light / 1 / C6 | desk gates | T27 |
| T27 | TB8 | light / 1 / C8 | Depends-on hold and tier order | T28 |
| T28 | TB9 | light / 1 / C8 | the queue and ejection | T29 |
| T29 | TB10 | light / 1 / C6 | branch protection as code, halt-guard | T30 |
| T30 | TB11 | light / 1 / C6 | attest, flaky, skills | T31 |
| T31 | TB12 | heavy / 2 / C8 | the full walk, live smoke, close-out | — |

Choices: edges are a chain in row order (prerequisite → dependent, `T<n> → T<n+1>`), so the forecast
gives twelve serial waves and no co-change pair can run concurrently. Tiers never decrease along an edge
(TB7's inversion rule: a parent's tier ≤ its child's): 0 for the node-to-PR foundation (TB1–TB5), 1 for
the ordering, desk and policy rows (TB6–TB11), 2 for the close-out. Weights: heavy where the DoD runs
`make live` (T24, T31), as T19 was. Charters from PROJECT.md: C6 CI gates, C5 run loop, C2 claim
protocol, C8 merge queue.

### 4.2 Proven in a scratch clone (`~/.cache/step3-tb0/scratch`, a clone of `8768a4a`)

Reverse dependency order (an edge to an unwritten ticket fails validation). The store has been frozen
since T19 (factory-run-calls-v1 ruling Q1, unsigned), so every write passes `--allow-unsigned`:

```
$ for n in 31 30 … 20; do a ticket create --input $D/T$n.json --json; a ticket create --input $D/T$n.json --write --allow-unsigned --json; done
T31 dry=0 write=0 {"applied":true,"h":"385470790665"} warning: --allow-unsigned with no ADLC_MANIFEST_KEY — …
T30 … "3d46784c45e2" · T29 "edf7c8493af1" · T28 "740c14aa43e5" · T27 "be8c4a5523cd" · T26 "45d402ebe782"
T25 "9a367fffb9e4" · T24 "fc8323244b95" · T23 "7da51df4cfbc" · T22 "32c28d384fd1" · T21 "ac77328eac3c" · T20 "562374349922"
$ a ticket doctor                    → All checks passed. doctor=0
$ a coldstart --all --offline --json → cs=0, ok true; T20…T31 each {"pass":true,"gaps":[]}
$ a merge-forecast --json            → mf=0 {"gateFailures":[],"waves":[["T20"],["T21"],…,["T31"]],"warnings":[]}
$ ./factory/bin/ticket-check.sh      → tc=0
```

### 4.3 The write on main

Same loop in the main checkout at `8768a4a` (outputs in `~/.cache/step3-tb0/main-write/`). Every hash
matches the scratch:

```
$ git fetch -q origin; git rev-parse origin/main HEAD → 8768a4ae922d… (both)
T31 dry=0 write=0 385470790665 · T30 3d46784c45e2 · T29 edf7c8493af1 · T28 740c14aa43e5 · T27 be8c4a5523cd · T26 45d402ebe782
T25 9a367fffb9e4 · T24 fc8323244b95 · T23 7da51df4cfbc · T22 32c28d384fd1 · T21 ac77328eac3c · T20 562374349922
$ a ticket doctor | tail -1                → All checks passed.  doctor=0
$ a coldstart --all --offline --json       → cs=0; ok true; T20…T31 pass, 0 gaps each
$ a merge-forecast --json                  → mf=0 {"gateFailures":[],"waves":[["T20"],["T21"],["T22"],["T23"],["T24"],["T25"],["T26"],["T27"],["T28"],["T29"],["T30"],["T31"]]}
$ make tickets                             → exit 0
$ tail -12 .adlc/manifest.jsonl | jq -c '{seq,gate,ticket,bypass:.data.bypass,sig}' (first, last)
{"seq":26,"gate":"ticket-mutation","ticket":"T31","bypass":true,"sig":null}
{"seq":37,"gate":"ticket-mutation","ticket":"T20","bypass":true,"sig":null}
$ a ticket show T20|T25|T31 --json → [id, hash, edges, rails, header]
T20	562374349922	T21	factory/policy/**	weight: light tier: 0 charter: C6
T25	9a367fffb9e4	T26	factory/policy/**	weight: light tier: 1 charter: C2
T31	385470790665		factory/policy/**	weight: heavy tier: 2 charter: C8
$ make lint → exit 0
$ make test → see §4.4
```

### 4.4 make test

Run concurrently with the store checks, after the write:

```
$ time make test   # every file's line
PASS tests/test_bwrap_shim.sh · test_claim · test_governor · test_halt_rules · test_halt · test_janitor · test_join
PASS test_layout · test_mirror · test_policy · test_post_merge · test_revoke · test_run · test_summon
PASS test_ticket_check · test_version_check
make test  94.58s user 24.04s system 110% cpu 1:47.03 total
exit=0
```

16 files PASS. `make sim` does not exist yet (TB1 builds it).

## 5. Gotchas for the next rows

1. **`native-queue: no`** (§2(a)). The first-party serial queue is the live mode for TB9; the native
   mode is coded and simulated only. TB10 writes merge-queue settings only under `yes`.
2. **I15 vs TB10/TB11.** `branch-protection.json` and `quarantine.json` live under `factory/policy/`,
   which every ticket rails and no ticket edits (I15). TB10's "branch-protection.json requires the bare
   job ids" therefore cannot be a ticket commit: T29's body says its new contents are a desk note in
   HANDOFF, and its code and tests read whatever main holds. TB10 must decide how the I18 test stays
   green while main's file still says `gates / <job>` (for example: the test asserts against the desk
   note's JSON, or the desk applies the note first). The same holds for `factory/policy/README.md`'s
   `tamperguard.toml` row (ci:G20).
3. **`.adlc/config.json` vs TB3's scope rule.** A ticket PR touching `.adlc/**` fails scope (TB3), so
   T24's scope does not include main's config; T24's body says the fleet block is desk-written (the
   loop writes it as a desk commit in TB5, ruling Q3 of factory-step2-followups-v1) and T24 makes CI and
   the node run exactly its commands.
4. **Skipped = green** (§2(b)). A required job skipped by `if:` or by a failed `needs:` reports success.
   `dependencies` is skipped on merge_group today; `attest-verify`'s `needs:` would turn a red gate into a
   green attest. Required jobs must run unconditionally and report their own verdict.
5. **ubs is out** (§2(c)): its license rider excludes Anthropic and anyone acting for it. Nobody on this
   loop should download or run it. TB11 adds no `bugscan` job and writes the `### Q`.
6. **flaky-test-detective has no release**, and the npm package of that name is someone else's.
7. **GITHUB_TOKEN events start nothing** except dispatch and (approval-gated) PR open/sync (§2(d)).
8. The store is frozen (since factory-run-calls TB0): every desk write passes `--allow-unsigned`
   (ruling Q1). This row added 12 unsigned `ticket-mutation` entries (seq 26–37).
9. In this box's zsh, `cat` is aliased to a missing `ccat` and `grep` is ugrep (regex complexity
   limits): use `/bin/cat` and `/usr/bin/grep` in commands.

## 6. Result

Done. Register re-measured: every line holds; the merge-queue line is now measured (`native-queue: no`).
(a)–(d) measured with docs quotes and registry reads. All 75 gap ids (ci 22, merge 22, intake 14, node 17) re-checked: 0 closed, 0 wrong.
T20–T31 are in main's store with `rails: ["factory/policy/**"]`, ADR-0002 headers, verify-ended
criteria, and chain edges T20→…→T31. Doctor ok, coldstart gaps empty T20–T31, merge-forecast exit 0
(twelve serial waves), `make tickets` 0, `make lint` 0, `make test` 16 files PASS. Commit
`Ticket: scaffold`, local only (I1).
