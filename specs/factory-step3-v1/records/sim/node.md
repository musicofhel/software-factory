# Node segment simulation: T20 (tier:1, Depends-on T19, rails ["factory/policy/**"], scope globs)

Repo at origin/main 4ea237c. The sim was read-only: a copy at `sim/node/repo`, `tests/sim_t20.sh` (built from test_run.sh's harness with the fakes on PATH), and its output in `sim/node/sim.out`. Three cases ran: `t20-stub` (today's stub), `t20-pass` (scope-check passing), `t20-lapsed` (another node's lapsed branch). Nothing was written to the real repo, the store, ~/.factory or GitHub. The only GitHub calls were `gh api` GETs (rulesets, check-runs).

## 1. The walk

| # | Step (file:line) | Reads | Writes | Status |
|---|---|---|---|---|
| 1 | governor.sh:98-160 (version-check, nodes heartbeat CAS, halt-check, quiet hours, cux quota) | factory/VERSION, nodes/<h>.json, origin/main tree, manifest, `cux usage show` | nodes branch commit (lib/governor.sh:146-188) | works. It is serialized per node (run.sh:179-185, 496) |
| 2 | halt-check.sh:41-58 | `git fetch origin main`, `ls-tree factory/HALT` | none | works. Exit 3 → sleep, anything else → sleep (fails closed) |
| 3 | claim.sh:71-139 | `gh issue list --label ready` (oldest first, `w:` ≤ capacity), lock index | lock commit on the nodes tip, POST refs/locks/issue-1 (422 → next), assign + `in-progress`, one comment | works (sim). It ignores `tier:1` and `Depends-on:`. The Issue keeps `ready` |
| 4 | run.sh:526-532 ticket resolution | the Issue body's `Ticket: T20`, `Ticket-Hash:` | none | works. The branch name is `ticket/T20/<handle>`, checked by check-ref-format |
| 5 | run.sh:535-540, 292-308 fetch + worktree | origin/main, origin/ticket/T20/* | `.worktrees/T20`, detached at origin/main or at the newest lapsed branch | works. With a lapsed branch, the gate base is wrong (G5) |
| 6 | lib/ralon-lock.sh:59,96 | `adlc ticket show T20` in the worktree | `agent.lock` with `factory/policy/**` and `.worktrees/*/factory/policy/**` | works. Fleet's worker worktree is not covered (ADR-0005 ralon 3) |
| 7 | run.sh:311-343 fleet under ralon (+ bwrap shim) | worktree store, budget.json weights | fleet/t20, fleet/run-*, mirror | works (TB3 live). On the real repo fleet **refuses at preflight**: main's .adlc/config.json has no `fleet.gate` (preflight.mjs:63-64; G10). Per-ticket `budget` is ignored (G14) |
| 8 | pre-strike quota-gate.sh:52-66 | cux | none | works (0 / 1 / 2) |
| 9 | heartbeat.sh:44-65 | lock ref | PATCH lock (force) | works, but only for paused claims. A built claim's kept lock is never heartbeated (G3) |
| 10 | strikes / adversarial review | inside fleet (`review` in the doc) | none node-side | works as fleet does it. `review.provider` is null (TB3). run.sh never checks that adversarial-review is on PATH; fleet fails closed with `review-unavailable` (G16) |
| 11 | tamperguard run.sh:359-389, lib/policy-render.sh:54-109 | render of build.toml; `tamperguard --range BASE..tip --json` | `.factory-run/tamperguard.*`, logs | works (TB3: rc 0, `ok`) |
| 12 | scope-check run.sh:392-406 | `scope-check.sh --ticket T20 --base BASE --head <fleet merge sha>`, cwd = worktree | none | stub today: `scope-check-not-built`, local branch, release, exit 2 (sim t20-stub) |
| 13 | after a pass: push_record run.sh:408, lib/run.sh:55-71 | fleet tip | an empty record commit with trailers, `push --force-with-lease ticket/T20/<h>` | works (sim). **Only the record commit has trailers** (G2) |
| 14 | PR run.sh:411-419, lib/run.sh:124-138 | the facts JSON | `gh pr create --base main --head ticket/T20/dev-box --title "T20: built by dev-box (issue #1)"` | works (sim). No labels, no `Depends-on:`, no `Assisted-by` note, and the gate-manifest hashes always read "none" (G6, G8) |
| 15 | comment + keep-lock run.sh:422-425 | none | Issue comment "built ... PR #2". The lock stays and `ready` stays | the lifecycle is broken (G3). Nothing releases the lock at merge (post-merge.sh has no lock code) |
| 16 | release.sh:49-57 | lock | DELETE the ref | works. It is called only on the failure and desk paths, never after a built PR |

Failure paths (lines in run.sh). They were already covered by test_run.sh, and the sim matched them:
- tamper → desk comment + marker, label `needs-desk` / remove `ready`, release (L385-387).
- tamperguard error or render failure → release, stop the slot with exit 1 (L364-368, 388).
- scope fail (exit 2) → desk (L400-402). Scope error → release, exit 1 (L403-405).
- push failed → release, nap (L408-409).
- pr-open-failed → the branch stays pushed with the lock kept, and nothing retries the PR (L416-419; G12).
- quota-paused / wall-clock → push the partial branch, heartbeat, keep the state. The 4th pause goes to the desk (L434-448).
- strikes-exhausted / flail → push, desk, release (L427-433).
- lock-held / ticket-blocked → release, nap 10 min, re-claimable (L476; ADR-0005 open point 3).

### What the PR looks like (sim t20-pass)

- **Commits in main..tip:** three. `feat(T20): fleet worker build` and `Merge branch 'fleet/t20' into fleet/run-…` have no trailers. `factory: T20 built on dev-box` is empty and carries `Factory-Outcome, Fleet-Run, Fleet-Strikes, Assisted-by, Ticket, Node, Signed-off-by`.
- **Body:** `Ticket: T20`, `Issue: #1`, `Node: dev-box`, the ids table, and `Gate-manifest hashes: none recorded`.
- **Missing:** no `tier:` label, no `Depends-on:` line, no git note (`refs/notes` is empty), no Assisted-by note in the body.

### What CI needs from the node, and what it gets today

| CI gate (gates.yml) | Needs from the node / PR | Gets |
|---|---|---|
| build-test L25-27 | the project's fleet.gate commands | `make test` (the factory's own suite). There is no fleet block on main |
| rails-proof L34 | ticket id → rails from **main's** store | `--base origin/main` only, no ticket |
| scope L41 | ticket id → scope from main's store, the range | `--base origin/main` only. The node passes `--ticket --base --head` (G4) |
| tamper L50 | the same tool, version and flags as the node | `pipx run tamperguard==0.2.0 --base origin/main`. `--base` is not a flag, so argparse exits 2, which reads as tamper (G1) |
| commit-check L63 | trailers on every commit | 2 of 3 commits have none (G2) |
| attest-verify L71 | a signed manifest or note | nothing is produced anywhere. The CI token is `contents: read` (G6) |
| Depends-on hold / tier order (not built) | tier, parents | only on the Issue (body + label), not on the PR (G8) |

### Gates that run on both the node and CI

**tamperguard**
- Node: uv tamperguard 0.2.0 on py3.14 under vetto strict + the rendered policy, `--range BASE..tip --json`, default `--fail-on tamper`.
- CI: pipx 0.2.0 on py3.12, no sandbox, wrong flag.
- Mismatch. They agree on the version only.

**scope**
- Node: the store at BASE (the worktree), range BASE..fleet-merge.
- CI: undefined (no ticket, no head). It must use main's store, and `merge_group` has no `head_ref`.
- fleet already runs its own scope gate (gates.mjs:54-60, `@adlc/core` inScope over startSha..HEAD). That makes three matchers that must agree.

**rails**
- Node: ralon in the loop's worktree, plus fleet's rails-guard.
- CI: rails-proof with no ticket.
- They are different mechanisms. Only CI's is authoritative.

## 2. GAPS

| id | sev | evidence | what's wrong | fix (file, behavior, test) | step |
|---|---|---|---|---|---|
| G1 | blocker | gates.yml:50; `tamperguard --help` (0.2.0) has `--range`, not `--base`; `tamperguard --base HEAD` → "unrecognized arguments", rc 2 | The CI tamper gate fails every PR (rc 2 = tamper), and its flags differ from the node's (run.sh:371 via lib/policy-render.sh:106-108) | **gates.yml:** `tamperguard --range origin/main...HEAD --json`, the same 0.2.0 through uv (or `pipx run --spec tamperguard==0.2.0 tamperguard`; the pipx spec syntax is unverified). Put the node and CI argv in one place (e.g. `factory/bin/lib/tamper-argv`).<br>**Test:** tests/fakes/tamperguard refuses unknown flags; a new tests/test_gates.sh runs each `run:` line of gates.yml against the fakes | 3 |
| G2 | blocker | sim t20-pass: `feat(T20)…` and `Merge branch…` have empty trailers; lib/run.sh:55-63 adds trailers only to the record commit; fleet worktrees.mjs:179,200; ADR-0005 open point 2 | commit-check ("trailers on every commit", gates.yml:63; spec L851; RULES 1) fails every node PR | **run.sh on_success:** after both gates pass, make ONE commit `git commit-tree "$tip^{tree}" -p "$(git merge-base origin/main $tip)"` carrying the trailers, and push it. That is the same tree tamperguard and scope scanned; fleet's history stays local. It also drops a lapsed node's untrailered commits (G5).<br>**Test:** case success asserts `rev-list main..tip` = 1 and all four trailers are present. The alternative is a commit-check rule that "the tip's trailers cover the range"; the desk would have to rule on it | 3 |
| G3 | blocker | run.sh:36,424 (lock kept "released at merge"); post-merge.sh has no lock code; janitor.sh:204-209 (`fresh_branch == null` → release, checked before `open_pr`); janitor.sh:211-217 (over-slots cut, newest without a fresh branch); run.sh never removes `ready` on success | (a) A PR that waits more than 24 h (CI, review, a Depends-on hold) loses its lock. The Issue is still `ready`, so another node re-claims T20 and opens a second PR. (b) Kept locks count toward slots, so the janitor releases the node's in-flight claim (no branch yet). (c) Nothing releases the lock at merge | **run.sh:** release the lock at PR open (the PR + branch hold the ticket).<br>**mirror.sh / claim.sh:** withhold `ready` (or claim.sh skips the ticket) while an open PR from `ticket/<id>/*` exists.<br>**janitor.sh:** an open PR → keep, outside the slot count.<br>**Tests:** test_janitor "open PR, lock older than 24 h, kept"; test_claim "skips a ticket with an open PR"; test_run success asserts `release-lock` | 3 (touches 1, 2) |
| G4 | major | run.sh:392 vs gates.yml:34,41; scope-check.sh, rails-proof.sh are stubs; no `head_ref` in `merge_group`; fleet gates.mjs:54-60 | The scope-check and rails-proof interfaces don't match between node and CI. CI has no ticket id or head. The scope source is unspecified (it must be main's store, never the PR head's `.adlc`) | **scope-check.sh and rails-proof.sh:**<br>• take `--ticket` optionally;<br>• otherwise derive the id from `GITHUB_HEAD_REF` = `ticket/<id>/<h>`, or in merge_group parse `gh-readonly-queue/main/pr-N-…` → `gh api pulls/N` → head ref;<br>• read scope and rails from `origin/main`'s store (`git show origin/main:.adlc/tickets/…` or adlc in a main worktree);<br>• match with `@adlc/core` `inScope`, as fleet does.<br>**Tests:** a glob table; a PR that edits its own ticket's scope cannot widen it; merge_group derivation | 3 |
| G5 | major | sim t20-lapsed: `scope.log --base c9346bd` (the lapsed tip, not main 84ca5e0); the PR diff includes `OUTSIDE_SCOPE`; the PR body says `scope-check pass`; run.sh:295-297,371,392 | On a resumed lapsed claim, node tamperguard and scope scan only the new work. The PR body reports a false green, and the earlier node's commits ride in without trailers | **run.sh:** the gate range base = `git merge-base refs/remotes/origin/main $tip`; keep BASE for fleet `--base` only.<br>**Test:** case lapsed asserts the scope and tamperguard ranges start at origin/main | 3 |
| G6 | major | lib/run.sh:75-88 reads `.adlc/manifest.jsonl` at the tip, but fleet commits `:!.adlc` (worktrees.mjs commitWorker) and runs `--no-complete`, so it is always "none" (sim). No git note anywhere. gates.yml:12-13 `contents: read`. Token ref_patterns exclude refs/notes (join.sh:404). Spec L601-604 names corvidlabs/attest; adlc has `gate-manifest attest/verify` and securityMode unsigned-fallback | Nothing produces the signed gate manifest attest-verify needs. The node's hash list is dead code | **Step-3 spec picks the tool.** CI writes the note or attestation (a job with `contents: write` limited to refs/notes/factory, or a check-run output) from CI's own gate results. The node contributes only ids (fleet run, adapter, review verdict, the sha256 of fleet's doc) in the PR body. Remove or rewire `run_gate_hashes`.<br>**Test:** attest-verify fails on a PR with no note | 3 |
| G7 | major | join.sh:402-404 (Contents + Metadata only); claim.sh:131-134 (issue edit/comment); run.sh:242,246,416; join.sh:496-500 env has no `GH_TOKEN`; nothing reads `$FH/token` | (a) The token join prescribes cannot label, comment or open PRs, so a node on it gets `announced=false` + `pr-open-failed`. (b) The stored token is unused: gh and git run on the owner's ambient credentials, so the spec's node-token boundary (L801) doesn't exist | **join.sh:** ask for Issues write + Pull requests write, and write `GH_TOKEN` from `$FH/token` into env. git pushes through a credential helper on the same token.<br>**Tests:** test_join asserts env exports it; a live probe at join | 2 follow-up, needed for 3 |
| G8 | major | lib/run.sh:124-138; sim PR body; mirror.sh:255-258 puts `Depends-on:` + `tier:` only on the Issue; spec L183, L641-642, L841 | The PR carries no tier, no parents, no prosecutor adapter and no Assisted-by note, so the merge-ordering Action has nothing on the PR | **Hold/tier Action:** derives tier (body header) and parents (edges) from main's store by the branch's ticket id, and labels the PR itself (trusted; the node never sets labels).<br>**run_pr_body:** adds `Depends-on: <id>` lines (display), `Assisted-by: <adapter>@<v>`, and a `review` row (verdict, provider).<br>**Test:** test_run success greps them | 3 (review row: 4) |
| G9 | major (speculative) | branch-protection.json:33-39 contexts are `gates / build-test` …; the live check-runs on main are named by job (`janitor`, `mirror`); live rulesets = `[]` (not applied yet) | Required contexts probably never match the check-run names (job names), so every PR would wait forever once applied | **branch-protection.json:** contexts = job names (`build-test`, …), optionally with `integration_id`.<br>**Test:** apply-branch-protection dry-run cross-checks the gates.yml job ids. Verify on the first apply | 3 |
| G10 | blocker (known, ruled Q3) | .adlc/config.json has no `fleet` block; fleet preflight.mjs:63-64 | A real T20 on main stops at fleet `preflight` and run.sh exits 1 (L477) before any gate | Step 3 writes the repo-wide fleet block (followups RULINGS Q3) | 3 |
| G11 | minor (speculative) | mirror.sh:31-33 (`ready` only in forecast wave 1); fleet `ticket-blocked` → run.sh:476 nap + re-claim | If the forecast puts dependents behind open parents, T20 is never claimable before T19 completes. The merge-queue Depends-on hold then matters only for fix tickets and reverts, and the DAG is fully serialized | The step-3 spec names which mechanism owns ordering (forecast vs hold).<br>**Test:** a forecast with an edge T19→T20 | 3 |
| G12 | minor | run.sh:416-419,424 | `pr-open-failed` leaves the branch pushed and the lock kept, with no retry | Retry next iteration (state file) or in the janitor; else release + desk | 3 |
| G13 | minor | run.sh:408 (no ownership check before push/PR) | If the lock was released mid-run (G3b), the node still pushes and opens a PR | `heartbeat.sh <n>` dry-run (`lock_owned`) before `push_record`; exit 2 → `lock-lost` | 3 |
| G14 | minor | run.sh:524-525; budget.json `_comment`; spec ticket field `budget` | The desk's per-ticket strikes/minutes override is ignored | Read `budget` from `adlc ticket show`, falling back to the weights. Test | 2 follow-up |
| G15 | minor | post-merge.sh:13-15,111-118 completes every id in any `Ticket:` trailer of the merged range | A commit can name another ticket and complete it | commit-check: `Ticket:` == the branch's ticket id (and `Node:` == the branch's handle) | 3 |
| G16 | minor | gates.yml:46-50 py3.12 vs node uv py3.14; spec L644 vs run.sh (no PATH check for adversarial-review) | Interpreter drift; no up-front refusal when the reviewer is missing (fleet → `review-unavailable` nap loop) | Pin the CI python to the node's minor. A run.sh start check on `$FH/bin/adversarial-review` | 3 / 4 |
| G17 | minor | gates.yml header L1-3 vs jobs (all ubuntu-latest); branch-protection.json:21 (1 approval on every PR) | No factory-node push jobs for w:heavy. Every node PR needs a human approval, unlike the spec's two human gates | Step-3 spec: heavy push workflow; approvals only via CODEOWNERS paths | 3 |
