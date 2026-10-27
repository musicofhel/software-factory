# TB4 — One trailered commit per ticket and the commit check (ticket T23)

Session 9, 2026-10-26. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2. Base: `68808fd` (TB3 +
ledger). Nothing was pushed and nothing was written to GitHub, the repo's own store or `~/.factory`
(I1, I19). The only network use was read-only `gh api` GETs on public repos (§1). Every world is a temp
dir. No prep exists for this spec.

**State: done.** Fixes node:G2, node:G15, ci:G8, merge:G11 and ci:G6 (the commit-check stub; only
attest-verify, TB11, is left of the six stubs).

## 1. Measured this row: GitHub's queue merge commit and `merge_commit_sha`

The spec asks for the queue merge commit to be "identified by its author and parent shape, measured".
This repo is user-owned and has no queue (TB0 (a)), so the measurement was taken from public repos
that run GitHub's native merge queue. The method is read-only:

- `gh api repos/<r>/actions/runs?event=merge_group&per_page=1` gives `head_branch` and `head_sha`;
- `gh api repos/<r>/commits/<head_sha>`;
- `gh api repos/<r>/pulls/<N>`.

| repo | queue head | parents | author | committer | p1 = ref's base | p2 = PR head.sha |
|---|---|---|---|---|---|---|
| Homebrew/brew pr-24355 | `c6069d2a943b` | 2 | Mike McQuaid (a human) | GitHub `noreply@github.com` (login web-flow) | `8d799352d3ff` yes | `40d40f5505c6` yes |
| rust-lang/cargo pr-17644 | `749d85d9fc53` | 2 | Weihang Lo | GitHub | `a4590e45f7d5` yes | `a2530ed8f2d0` yes |
| rust-lang/rust-analyzer pr-23534 | `6ee6a51fd402` | 2 | Shoyu Vanilla | GitHub | `0c4d74686b21` yes | `aafbaf7b4c16` yes |
| github/docs pr-46488 (squash queue) | `b1cce113b64b` | **1** | North Dunne | GitHub | — | — |
| bevyengine/bevy pr-25336 (squash queue) | `dda322277c07` | **1** | Saratii | GitHub | — | — |

Further merge-method queues seen with 2 parents: Homebrew/homebrew-core, nixos/nixpkgs,
rust-lang/rust-clippy. Further squash-method queues seen with 1 parent: flutter/flutter,
zed-industries/zed. Every one of these commits is GitHub-signed (`verification.verified: true`).

**Findings:**

- The **author is the human who enqueued**, never GitHub. The mark is therefore the **committer**
  `GitHub <noreply@github.com>` plus the parent shape `[merge_group.base_sha, PR head.sha]`.
  commit-check uses exactly that.
- `pulls/<N>.merge_commit_sha` of a queue-merged PR **is** the group's head commit:
  - Homebrew/brew #24355 → `c6069d2a943b`;
  - rust-lang/cargo #17644 → `749d85d9fc53`;
  - github/docs #46488 → `b1cce113b64b`.

  post-merge relies on this to tie a first-parent commit on main to its PR.
- A **squash-method** queue commit has one parent and replaces the PR's commits, so commit-check cannot
  tell it apart from any other commit. It is never skipped, and it is checked like any commit. The
  queue must merge with the **merge** method (TB9/TB10 apply it).

## 2. What was built

- **`factory/bin/lib/run.sh`**: `run_commit_tree <tree-ish> <parent> <subject> <trailers…>` is the one
  message builder. It writes the trailer paragraph `Assisted-by`, `Ticket`, `Node` and
  `Signed-off-by` (the node's committer identity, as `-s` writes it). Two wrappers use it:
  - `run_record_commit <parent> …` writes the empty record commit, unchanged, for partial branches.
  - `run_ticket_commit <merge-base> <tip> …` writes the ONE pushed commit: fleet's final tree, with
    the merge-base as its only parent.
- **`factory/bin/run.sh` `on_success`**:
  1. `GATE_BASE` = `merge-base origin/main <fleet tip>`.
  2. `GATE_HEAD` = `run_ticket_commit "$GATE_BASE" "$tip" "factory: <id> built on <handle>"
     Factory-Outcome/Fleet-Run/Fleet-Strikes`.
  3. tamperguard, rails-proof and scope-check run on `GATE_BASE...GATE_HEAD`.
  4. `push_sha "$GATE_HEAD"`.

  fleet's worker commit and its `--no-ff` merge are never pushed. They stay reachable in the node's
  clone under `refs/factory/fleet/<run id>`, the transcript record the spec asks for. `wt_remove`
  deletes fleet's branches, so without that ref the commits would be unreachable and gc'd. A lapsed
  branch's untrailered commits are dropped the same way, and its work stays in the tree.
- **`factory/bin/commit-check.sh`** (was a stub) checks the commits the head brings, `BASE..HEAD`,
  reading trailers with git's own parser (last paragraph only). The rules:
  - **every class:** `Signed-off-by`.
  - **`ticket` class, in addition:**
    - `Assisted-by`;
    - `Ticket:` present, and every value equal to the branch id;
    - `Node:` present, and every value equal to the branch handle (on PR events; the node form has
      no handle).
  - **`desk`, `halt` and `human`:** the DCO only.
  - **Post-merge exemption.** Any commit saying `Ticket: post-merge` passes only in post-merge's
    exact shape:
    - exactly the four trailers `Through: <40-hex>`, `Assisted-by: none`, `Ticket: post-merge`,
      `Node: github-actions`;
    - author **and** committer `github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>`;
    - one parent;
    - a non-empty diff touching only `.adlc/` and `factory/ledger/`.

    Any other commit saying it fails, signed or not (RULES.md "Commit-check exemption").
  - **Queue merge commit.** It is skipped only on `merge_group`, only for the head commit, and only
    when it has the measured shape of §1. The PR's head sha comes from `gh api
    repos/<repo>/pulls/<N> --jq .head.sha`.
  - Each failing commit is named on stderr. Exit codes: 2 fail, 1 error, 0 pass.
- **`factory/bin/post-merge.sh`**:
  - **Completion.** It completes only the ticket of the merged PR's head branch (merge:G11). For a
    first-parent commit whose subject names #N, `pr_ticket` reads `gh api repos/<repo>/pulls/<N>`. The
    repo comes from `GITHUB_REPOSITORY`, else `FACTORY_REPO`, else the origin remote. The read counts
    only when all of these hold:
    - `merged`;
    - `merge_commit_sha` == that commit;
    - `head.repo.full_name` == the repo;
    - `head.ref` == `ticket/<id>/<handle>`.
  - **Foreign trailers.** Every other `Ticket:` trailer in the commit's range, and every trailer of a
    commit no verified PR landed (a direct push), gets `"result": "foreign"` and is never completed.
  - **Errors.** A PR read failure dies before any write (exit 1).
  - **Identity.** The completion commit is now always authored and committed as `github-actions[bot]`,
    whatever the env or config says. Before, the script exported `factory-post-merge
    <post-merge@factory.invalid>` whenever the env was unset, which overrode the workflow's `git
    config` of github-actions[bot]. So the real identity on main would have been factory-post-merge,
    which RULES.md does not name. A fixed identity is what an identity-keyed exemption needs.
- **`tests/fakes/gh`**: GET `pulls/<n>` gains `merge_commit_sha`, taken from the state's `.merged`
  `{pr, sha}`, else the entry's `mergeCommitOid`, else null.

## 3. Decisions

1. **The pushed commit is built before the gates, and the gates run on it.** The spec says "after
   every node gate passes, run.sh writes one commit". Instead, the one commit is GATE_HEAD itself:
   - its tree is fleet's final tree, and its parent is the merge-base;
   - so `BASE...GATE_HEAD` is the same diff the gates would have read on fleet's tip;
   - and the node still gates the exact sha it pushes, which is TB3's I17 property, comparable line
     for line with CI.

   A commit written after the gates would be a sha no gate saw.
2. **Squash over "tip trailers cover the range"**, as the spec rules. The pushed commit carries the
   three record trailers too (`Factory-Outcome: built`, `Fleet-Run`, `Fleet-Strikes`), so the built
   branch still names its run without a separate record commit.
3. **The commit range is `BASE..HEAD`.** The spec writes `BASE...HEAD`, but for a list of commits the
   symmetric form would include main's own commits since the branch point, including other PRs and
   post-merge commits. The head side of the merge-base is `BASE..HEAD`, the same range
   gate_identity (TB2) uses.
4. **The `Node:` == branch handle check** comes from node:G15's fix line. The node's own form
   (`--ticket --base --head`) carries no handle, so there the line is skipped.
5. **Signed-off-by is checked for presence, not matched to the author.** The spec asks for presence.
   A DCO-bot-style author match is not required and would refuse desk commits that a human signs as
   committer.
6. **The factory App's own git identity is not exempted.** post-merge commits as github-actions[bot]
   whichever token pushes; the token only authenticates the push. The App's slug does not exist yet
   (no App, TB0 register), so no `<slug>[bot]` identity can be named. See the carries.

## 4. Scope deviation (recorded, not hidden)

`tests/test_gate_context.sh` is outside T23's scope globs. Its TB2 stub loop asserted that
commit-check exits 2 "not built", which is false now that commit-check is built. The loop drops
commit-check and keeps attest-verify. This is the change TB3's HANDOFF announced (carry 1).

A second out-of-scope test edit: `tests/test_diff_gates.sh:265` (T22's) greps run.sh for the
merge-base line. GATE_BASE is now the merge-base of fleet's tip, `"$tip"`, not of `"$GATE_HEAD"`,
because GATE_HEAD is built on it. The grep follows the line, and its intent (the merge-base with
origin/main) is unchanged.

Diff stats:
- `tests/test_gate_context.sh`: 5+/3− (the stub loop keeps attest-verify only, with an SC2043
  disable for the one-item loop, and the header line).
- `tests/test_diff_gates.sh`: 1+/1−.

## 5. Tests and red proofs

**Red proofs.** Each new test was run in `git worktree add --detach /tmp/… 68808fd` (the old
factory/) with the new tests copied in. The worktrees were removed afterwards.

- **`tests/test_commit_check.sh`** (new, T23 acceptance 2): 9 cases. **Red: all 9 fail on the old
  code.** `node-commit` exits rc 127 because `run_ticket_commit` does not exist; the rest fail on the
  stub's exit 2.
  1. **node-commit:** a fleet-shaped branch (a worker commit plus a `--no-ff` merge, untrailered)
     fails, naming both commits. The real `run_ticket_commit` output has one parent (the merge-base),
     fleet's tree and the exact trailer paragraph, and it passes. Gated as another ticket, it fails
     naming the id.
  2. **untrailered:** a missing Signed-off-by fails (node form and PR). Trailers followed by a prose
     paragraph also fail, because git's parser reads only the last paragraph.
  3. **ticket-class:** a missing Assisted-by, Ticket or Node fails, as do `Node: other-box`, a foreign
     `Ticket:` and two Ticket values. With three commits, only the bad one is named.
  4. **desk-halt-human:** DCO only. Signed off without Assisted-by passes; unsigned fails.
  5. **post-merge-exempt:** the commit written by the REAL `post-merge.sh --apply` (fake adlc and fake
     gh) passes inside a human PR. `CC_PM_IDENT` equals post-merge.sh's exported identity.
  6. **post-merge-fakes:** 11 near-misses each fail with their own reason:
     - a human author;
     - a human committer;
     - `github-actions` without `[bot]`;
     - an extra Signed-off-by;
     - a missing Node;
     - `Through: main`;
     - `Assisted-by: claude-code`;
     - a README outside the two directories;
     - an empty diff;
     - two parents;
     - a signed human `Ticket: post-merge`.
  7. **merge-group:** the queue commit is skipped, and the PR's commit is still checked. These variants
     fail: a human committer, a wrong second parent, a wrong first parent, a squash shape, and the
     same shape on pull_request.
  8. **merge-in-branch:** an unsigned merge commit inside a PR fails.
  9. **range:** main's unsigned commits beyond the branch point are never checked.
- **`tests/test_post_merge.sh`** (T23 acceptance 3): 16 cases, and **12 fail on the old code.** The
  world now completes tickets only through merged PRs in the fake gh state: T1 by squash PR #6, T2 by
  merge PR #7, and a direct push naming T3, which comes out `foreign`.
  - **New cases:**
    - `foreign-trailer`: a T2 PR whose commits name T3. T2 is done, T3 is `foreign` and never
      reaches adlc.
    - `pr-not-landed`: `merge_commit_sha` elsewhere, a closed PR, an open PR, a fork PR.
    - `non-ticket-head`: desk/human refs and malformed ticket refs.
    - `branch-ticket-unknown`.
    - `gh-read-fails`: a 404 or a 500 exits 1 before any write, in both apply and dry-run.
  - **Identity:** author and committer are `github-actions[bot]` even with GIT_AUTHOR_* set and a repo
    `user.name` configured.
- **`tests/test_run.sh`** (T23 acceptance 1): 28 cases.
  - **`success`:**
    - exactly one commit over main, with main as its only parent;
    - its tree equals fleet's merge tree;
    - the subject is `factory: T-run built on dev-box`;
    - the trailer order is `Factory-Outcome Fleet-Run Fleet-Strikes Assisted-by Ticket Node
      Signed-off-by`;
    - fleet's worker and merge commits are in the clone, and `refs/factory/fleet/<run id>` is fleet's
      merge;
    - neither commit is on the origin, even as an object.
  - **Resume-in-place and lapsed-range:** one commit on main, with the lapsed work (`half.txt`) in its
    tree and the lapsed commits not in the pushed range.
  - **Red:** the one-commit, only-parent and not-on-origin checks of all three cases fail on the old
    code.
- **Bug found by the tests.** post-merge's work file put the possibly empty `pr` field before `kind`.
  Tab is IFS whitespace, so consecutive tabs collapsed, `pr` read "foreign", and jq crashed (exit 5) on
  any direct commit with a `Ticket:` trailer. Real main has such commits (`a7ee3e5`, `d63c0e5`). The
  fix moves `pr` to the last field.
- **Sim red proof.** The new tests/sim plus fakes were run on 68808fd's factory/ (fake adlc). It exits
  2 with exactly the 8 TB4 stages "regressed", and no other stage differs:
  - P.commit-shape: 3 commits over the merge-base;
  - P.pr.commit-check, P.mg.commit-check, C.pr.commit-check, C.mg.commit-check and S.no-trailer:
    `commit-check: not built`;
  - C.commit-shape;
  - S.foreign-trailer: `T-sim-victim completed: true`.

## 6. Stage table delta (tests/sim/EXPECTED.md)

The table goes from 109 stages = 63 pass + 46 red to **109 stages = 71 pass + 38 red**.

| stage | before | after |
|---|---|---|
| P.commit-shape, C.commit-shape | red: node:G2 | pass (one commit over the merge-base, the four trailers) |
| P.pr.commit-check, P.mg.commit-check, C.pr.commit-check, C.mg.commit-check | red: ci:G6 | pass (on mg, the queue commit is skipped and the ticket commit is ok) |
| S.no-trailer | red: ci:G6 | pass (`FAIL: <sha12> … no Signed-off-by trailer`) |
| S.foreign-trailer | red: merge:G11 | pass (T-sim-victim is not completed, T-sim-t1 is, and post-merge's line for the victim is `"result":"foreign","pr":30`) |
| P/C.pr/mg.attest-verify (4) | red: "skipped behind the red commit-check (TB4)" | still red, now `attest-verify.sh is a stub, attest-verify: not built (TB11)` |

Sim changes:
- `queue_standin`'s merge commit is now authored by the enqueuer `sim-owner` and committed by GitHub
  (§1).
- The scenario commits' `Node:` is now the branch's handle, so each scenario carries only its own
  defect.
- S.foreign-trailer also checks post-merge's `foreign` line.
- No stand-in became unnecessary: the remaining ones belong to TB5, TB7 and TB9.

## 7. Gates

- `make lint`: rc 0 (shellcheck `-S warning` and actionlint).
- `make sim`, fake adlc: rc 0. The real `@adlc/cli` 1.12.0 run is also rc 0.
- `bash tests/test_commit_check.sh`: 9/9 PASS.
- `bash tests/test_post_merge.sh`: 16/16 PASS.
- `bash tests/test_run.sh`: 28/28 PASS.
- `bash tests/test_gate_context.sh`: 11/11 PASS.
- `bash tests/test_diff_gates.sh`: PASS.
- `make test`: 20 suites PASS, rc 0 (the 19 from TB3 plus test_commit_check; test_sim included).

**Dogfood.** `factory/bin/commit-check.sh --ticket T22 --base a7ee3e5~1 --head a7ee3e5` passes (TB3's
commit carries the four trailers). The ledger commit `68808fd` fails it with "no Assisted-by"; a
ledger commit is not a ticket PR's commit.

**Unreachable line.** commit-check's own "'Ticket: X', not the branch's" line cannot be reached on any
event: gate_identity (TB2) refuses a foreign `Ticket:` trailer first, with the same exit 2. It stays as
a backstop. For the same reason, on a ticket PR a `Ticket: post-merge` commit is refused by identity
before the exemption is looked at. A ticket branch has no business carrying post-merge's commit.

## 8. Carries (outside T23's scope; owners named)

1. `.github/workflows/post-merge.yml:2` still says post-merge "completes every ticket a merged commit
   names in a `Ticket:` trailer". It is a comment only, and the file is not in T23's scope. Owner:
   TB9 (T28 touches the queue path) or TB12.
2. **The factory App identity.** If a later row makes post-merge commit as the App (`<slug>[bot]`),
   then commit-check's `CC_PM_IDENT` and post-merge's exported identity change together. Owner: TB10
   (T29, the App's reach).
3. **The queue must use the merge method** (§1: a squash-method queue commit is not exempt). Owner:
   TB9/TB10.
4. Still open from TB3: `tests/live/test_render_live.sh:59` range form (TB12);
   `tests/live/test_smoke_live.sh:231`, `factory/skills/run/SKILL.md:65` and README row 2
   `scope-check-not-built` (TB12); `join.sh:327` `--python 3.14` (TB10).
