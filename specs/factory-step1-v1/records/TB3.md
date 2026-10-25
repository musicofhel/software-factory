# TB3 — Clock and janitor (ticket T3)

Session dates 2026-10-24 (two sessions; the first stopped at a SOFT GATE after WIP commit `4c1198b`).
Box: WSL2. Commits: `4c1198b` (WIP: janitor, version-check, fixture, fakes, tests) and `6f9aec6`
(lint fix, janitor.yml, new test cases, the mutation pass). Nothing was pushed. No write reached the
real GitHub: every `gh` in the tests is `tests/fakes/gh`, every `adlc`/mirror/`curl` a fake, and
every origin a local bare repo built by `tests/fixtures/make-repo.sh`. No prep existed for this row
(`specs/factory-step1-v1/prep/` is absent).

## 1. What was built

| file | role |
|---|---|
| `factory/bin/janitor.sh` | The six duties of SPEC-v0.2 "Clock and janitor": ready recompute, preview teardown, node stale/retire (with token revoke + halt notice), claim release (stale lock, stale/retired node, over slots, no PR after 48 h), branch sweep (Issue closed, unclaimed 7 d). `--dry-run` default; one JSON line per action; `--apply` refused (exit 2) off a GitHub-hosted runner. Header documents every rule. |
| `factory/bin/version-check.sh` | factory/VERSION vs origin/main (numeric x.y.z), manifest adapter pins vs `factory/policy/adapters.json` on main (absent today, see Q4), installed-CLI drift. Exit 0 current/ahead, 2 behind/drift, 1 unknown. |
| `tests/fixtures/make-repo.sh` | Bare origin with `main`, `nodes` (manifests with chosen `last_seen`, previews, janitor state), `flaky-history`, lock refs and `ticket/**` branches with chosen commit dates (`GIT_COMMITTER_DATE`). |
| `tests/fakes/adlc`, `tests/fakes/mirror` | New fakes: `ticket list --json`, `merge-forecast --json` (with `FAKE_ADLC_FORECAST_EXIT`, `FAKE_ADLC_FAIL`); mirror records argv + forecast, `FAKE_MIRROR_FAIL`. |
| `tests/fakes/gh`, `tests/fakes/lib.sh` | `pr list`; `issue list` answers OPEN/CLOSED and `""` bodies as real gh does; `fakegh_close`, `fakegh_pr`, body arg on `fakegh_issue`. |
| `tests/test_janitor.sh` | 15 cases: the ten named T3 cases (stale-lock, stale-node, over-slots, fresh-branch-kept, no-pr-48h, branch-sweep, node-lifecycle, preview-ttl, ready-recompute, dry-run-inert) + refuses-off-hosted, lease-race, nodes-race, hooks-unconfigured, fake-semantics. |
| `tests/test_version_check.sh` | 6 cases: current, version-behind, numeric-compare, adapter-pin-behind, installed-drift, unknown. Runs on a closed PATH so the box's real `claude` cannot leak in. |
| `.github/workflows/janitor.yml` | Reviewed against the script's flags and rewritten (§4). |

## 2. Gates

```
$ make test        # exit 0
PASS tests/test_claim.sh
PASS tests/test_halt_rules.sh
PASS tests/test_halt.sh
PASS tests/test_janitor.sh        (15 cases, 146 assertions)
PASS tests/test_layout.sh
PASS tests/test_summon.sh
PASS tests/test_version_check.sh  (6 cases, 27 assertions)
$ make lint        # exit 0 (shellcheck -S warning on factory/ + tests/, then actionlint 1.7.12 with that shellcheck)
$ uvx --from actionlint-py actionlint .github/workflows/janitor.yml; echo rc=$?
rc=0
$ npx -y @adlc/cli@1.12.0 coldstart T3 --offline --json
{"ok":true,"results":[{"id":"T3","pass":true,"gaps":[],"cached":false,"offline":true}]}
$ grep -l 'not built' factory/bin/*.sh    # janitor.sh and version-check.sh are not listed: T3 stubs gone
```

The first `make lint` of this session failed with ten SC1010 warnings (`emit "$line" done`: the bare
word `done` reads as a keyword). Fixed by quoting `"done"`; no behaviour change.

`dry-run-inert` compares `snapshot()` (origin `git for-each-ref`, `git ls-tree -r` of every ref, and
the ci checkout's refs) plus the fake Issue store before and after both a no-flag run and a
`--dry-run` run, with every duty firing at once; then `--apply` must take exactly the planned actions.

## 3. The tests can fail (mutation check)

Harness: `/tmp/tb3-mut/run.sh` copies the repo per mutation, applies one literal substitution with
perl (`\Q…\E`; a substitution count of 0 is reported NOAPPLY, none were), runs only the relevant
test file, and records the failing case names. First pass: 36 mutations, 4 survived (m12, m20, m21,
m27). Tests were added for each (§3.1), then the full list (40) was re-run.

| # | mutation (janitor.sh unless noted) | caught by |
|---|---|---|
| m01 | stale-lock TTL `>` → `>=` | stale-lock |
| m02 | stale-lock TTL doubled | stale-lock, fresh-branch-kept, dry-run-inert, lease-race |
| m03 | fresh-branch window `<=` → `<` | fresh-branch-kept |
| m04 | drop the fresh-branch guard | stale-node, fresh-branch-kept, no-pr-48h, dry-run-inert |
| m05 | no-PR release at the 24 h TTL, not 48 h | fresh-branch-kept, no-pr-48h, dry-run-inert |
| m06 | no-PR release ignores an open PR | no-pr-48h |
| m07 | drop `--force-with-lease` | lease-race |
| m08 | lost lease reported failed, not skipped | lease-race |
| m09 | drop the RUNNER_ENVIRONMENT refusal | refuses-off-hosted |
| m10 | state saved even when the mirror fails | ready-recompute |
| m11 | ready recompute every run | stale-lock, node-lifecycle, ready-recompute |
| m12 | merge-forecast exit 2 rejected | ready-recompute (after fix) |
| m13 | over-slots cuts oldest first (`sort_by(-.at)` → `sort_by(.at)`) | over-slots |
| m14 | over-slots ignores the fresh-branch guard | over-slots |
| m15 | over-slots disabled | over-slots |
| m16 | drop the open-PR branch guard | branch-sweep |
| m17 | closed-Issue branch not deleted | branch-sweep |
| m18 | unclaimed sweep ignores locks | branch-sweep |
| m19 | unclaimed sweep at 24 h, not 7 d | stale-lock, branch-sweep |
| m20 | drop the NODES_OK transition reset | nodes-race (after fix) |
| m21 | nodes commit not retried | nodes-race (after fix) |
| m22 | node never retires | node-lifecycle, dry-run-inert, hooks-unconfigured |
| m23 | node stale at the retire TTL | stale-node, node-lifecycle, dry-run-inert, nodes-race |
| m24 | retired manifest left in nodes/ | node-lifecycle |
| m25 | stale node's locks not released | stale-node, nodes-race |
| m26 | retired node: no halt summon | node-lifecycle |
| m27 | revoke hook unset is green | hooks-unconfigured (after fix) |
| m28 | preview TTL `>=` → `>` | preview-ttl |
| m29 | preview whose PR closed is kept | preview-ttl |
| m30 | release posts no comment | stale-lock, stale-node, over-slots, no-pr-48h, node-lifecycle |
| m31 | release keeps `in-progress` | stale-lock |
| m32 | dry-run deletes branches | dry-run-inert |
| m33 | `Ticket:` line ignored (id = Issue number) | fresh-branch-kept, node-lifecycle |
| m34 | version-check: string compare (version-check.sh) | numeric-compare |
| m35 | version-check: ahead counted as behind | version-behind |
| m36 | version-check: no x.y.z guard on pins | unknown |
| m37 | preview hook unset is green | hooks-unconfigured |
| m38 | nodes retry does not re-plan | nodes-race |
| m39 | nodes retry does not re-fetch | nodes-race |
| m40 | `push_ref` allow-list accepts any ref | **SURVIVED — unreachable** |

39 of 40 caught. m40 is an equivalent mutant: every caller passes either `refs/heads/nodes`, a
`refs/heads/ticket/*` name read from `refs/heads/ticket/*`, or `refs/locks/issue-<n>` with `n`
validated by `valid_issue`, so no input reaches the guard with another ref. It stays as defence in
depth; no test can drive it through the CLI.

### 3.1 Tests added for the survivors

- **m12** — fake adlc gained `FAKE_ADLC_FORECAST_EXIT` (prints the forecast, then exits with it; the
  real CLI exits 2 when a gate fails). ready-recompute now runs a changed set with exit 2 and expects
  exit 0, `forecast_exit: 2`, result `done`, set saved. fake-semantics checks the new knob.
- **m20, m21** — new case `nodes-race`. A `reference-transaction` hook in the ci checkout fires when
  the janitor's fetch writes `refs/janitor/nodes` and moves the origin's `nodes` first. *once*: a
  prebuilt heartbeat for `beta` lands; the janitor's push is rejected, it re-fetches and re-plans, so
  `beta` stays active and keeps lock 5, `gamma` goes stale and lock 6 is released, and the janitor's
  commit's parent is the heartbeat. *always*: every fetch is followed by a new commit; after three
  attempts the nodes commit fails, `node-stale` lines say failed, exit 1, and both locks are kept
  with no comment (nothing acts on a transition that did not land).
- **m27** (and m37) — hooks-unconfigured used to unset both hooks at once, so either one alone kept
  the run red. It now unsets each alone in its own world and expects exit 1 with the other hook's
  action `done`.

## 4. janitor.yml review

Against `janitor.sh --dry-run | --apply`, `halt-check.sh` (0/3/1) and `summon.sh`:

| before | problem | after |
|---|---|---|
| `DRY_RUN: ${{ inputs.dry_run != false && vars.JANITOR_DRY_RUN != 'false' }}` | On `schedule`, `inputs.dry_run` is null and Actions' loose `null != false` is **false**, so every scheduled run computed DRY_RUN=false and passed no flag. It was inert only because the script defaults to dry-run. | `APPLY: ${{ vars.JANITOR_DRY_RUN == 'false' && (github.event_name != 'workflow_dispatch' \|\| inputs.dry_run == false) }}`; the shell passes `--apply` iff `$APPLY = true`, else `--dry-run` explicitly. Unset/any other variable value = dry run; a dispatch can only narrow to dry run. |
| `run: ./factory/bin/halt-check.sh` | Exit 3 (halted) made the job red every hour of a halt. | `set +e`, then 0 → `halted=false`; 3 → `halted=true` + `::notice::`, sweep skipped, job green; anything else (unknown) → red. |
| `concurrency.group: janitor` | Spec: the janitor must not overlap itself *or the mirror*. | `group: mirror` (groups are repo-wide; mirror.yml already uses it). Cost: a pending run in a group is replaced by a newer pending one, so a janitor run queued behind a mirror run can be dropped; the next hour covers it. |
| no Node | `adlc` runs via `npx`. | `actions/setup-node@v4`, node 22. |
| default shell | `sh -e` has no pipefail; the tee would hide the janitor's exit. | `defaults.run.shell: bash`; `rc=${PIPESTATUS[0]}`. |
| no git identity, no webhook | The nodes commit needs an identity; retire-with-claims calls `summon.sh --kind halt --apply`. | `github-actions[bot]` identity; `DISCORD_WEBHOOK: secrets.SUMMONER_WEBHOOK`, `SUMMONER_TO: vars.SUMMONER_TO`. |
| output in the log only | Q2: dry-run output is the human's view. | JSON lines teed into `$GITHUB_STEP_SUMMARY` in a json block. |

`RUNNER_ENVIRONMENT=github-hosted` is set by GitHub on hosted runners, which is what `--apply` checks.
`JANITOR_REVOKE_HOOK`/`JANITOR_PREVIEW_HOOK` are deliberately not set (Q3; previews are step 5): an
`--apply` that needs one goes red with result `unconfigured`. Until TB4 builds `mirror.sh`, an
`--apply` with a changed open set fails red at the mirror stub (exit 2), which is correct.
Live proof (the first scheduled dry run) is due at first push (TB5 kit).

## 5. Decisions

1. **Git-native reads and writes.** One fetch into a private `refs/janitor/*` namespace, dropped on
   exit. Deletes are `git push --force-with-lease=<ref>:<sha> origin :<ref>` (a true CAS; the REST
   DELETE is not). A lost lease is result `skipped`, not an error. The nodes commit is a
   fast-forward push, retried 3× with a re-read and re-plan. `push_ref` refuses any ref other than
   lock refs, `ticket/**` and `nodes`; main is never written. gh only for Issues, PRs, comments.
2. **Ticket id mapping.** An Issue's id is its body's `Ticket: <id>` line, else its number; branch
   `ticket/<id>/*` maps through it.
3. **Fresh-branch guard on every release** (stale, node-stale, node-retired, over-slots). The only
   exception is `no-pr-48h`: lock age > `unpushedBranchReleaseAfterHours` with no open PR for the
   branch → released, branch kept. Lock age = committer date of the lock commit (heartbeats
   refresh it).
4. **Over-slots**: slots from the manifest, else the max payload slots; newest locks cut first (commit
   date, then issue number), skipping fresh-branch locks.
5. **Branches**: a branch with an open PR is never deleted, even with its Issue closed (deleting the
   head closes the PR). "Unclaimed for 7 d" = no lock at run start and tip older than 7 d.
6. **Nodes**: retired → `archive/nodes/<h>.json` (status retired), removed from `nodes/`. A failed
   nodes commit resets every planned transition, so nothing acts on a state that did not land.
7. **Hooks (new interface)**: `JANITOR_REVOKE_HOOK <handle> <owner>`, `JANITOR_PREVIEW_HOOK teardown
   <name> <record-file>`. Unset under `--apply` → `unconfigured`, exit 1; the node is still archived
   (one red run, not hourly); the preview record is kept (retries).
8. **Deploy record (spec silent)**: `previews/<name>.json` on `nodes`, `{branch, pr, node, address,
   deployed_at, expires_at}`; torn down at `now >= expires_at` or when `pr` is not open. Build order
   5 may revise it.
9. **Ready**: the sorted open id set vs `janitor/state.json` on `nodes`; on a change,
   `merge-forecast --json` (exit 0 or 2) then `$FACTORY_MIRROR --apply --forecast FILE`; state saved
   only after the mirror succeeds. **TB4 contract: `mirror.sh --apply --forecast FILE`.**
10. **Dry-run writes nothing anywhere**, Issue comments included (Q2).
11. **janitor.yml shares the `mirror` concurrency group** (§4).

## 6. Questions raised (carried to TB5's close-out list in HANDOFF.md)

Q2 (dry-run comments), Q3 (token revocation on a user-owned repo), Q4 (where adapter pins live).
Q1 (HALT two-person rule) came from TB2.
