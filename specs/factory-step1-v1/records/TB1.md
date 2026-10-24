# TB1 — Claim protocol (ticket T1)

Session date 2026-10-24. Box: WSL2. Base `92a2205`. Nothing was pushed; no call reached the real
GitHub (every `gh` in the tests is `tests/fakes/gh`, which refuses any repo but `test/repo` and any
`issue` command without `--repo`).
Blocks are `$ <command>` followed by verbatim output and `exit=<code>`. No prep existed for this row
(`specs/factory-step1-v1/prep/` is absent).

## 1. What was built

| file | role |
|---|---|
| `factory/bin/claim.sh` | list (`--json`, dry run, the default) / claim (`--apply`) / `--check <n>` (absent, fresh, stale) |
| `factory/bin/heartbeat.sh` | `<n> --apply`: own-lock check, new lock commit with fresh `claimed_at`, `PATCH … force=true` |
| `factory/bin/release.sh` | `<n> --apply`: own-lock check, `DELETE`; foreign or unreadable lock exits 2; absent exits 0 |
| `factory/bin/lib/common.sh` | die/refuse (exit 1/2), clock (`FACTORY_NOW`), jq date math (BSD and GNU alike), budget.json reads, repo and node resolution |
| `factory/bin/lib/lock.sh` | lock ref naming, lock commit shape, index/read/create, state (stale = commit older than `claim.staleAfterHours`), ownership |
| `tests/fakes/gh` | fake `gh`: call log, `api` git refs/commits backed by a real bare repo (CAS = `git update-ref <ref> <new> ""`), `issue list/edit/comment` on a flock-guarded JSON store, fault and race injection |
| `tests/fakes/lib.sh` | test world setup (bare origin with `main` + `nodes`), issue/lock seeding, assertions |
| `tests/test_claim.sh` | the five T1 cases plus `fake-gh-semantics` |

Changed paths (`git status --porcelain --untracked-files=all`), all inside T1's scope globs
(`factory/bin/{claim,heartbeat,release}.sh`, `factory/bin/lib/**`, `tests/test_claim*.sh`, `tests/fakes/**`):
```
 M factory/bin/claim.sh
 M factory/bin/heartbeat.sh
 M factory/bin/release.sh
?? factory/bin/lib/common.sh
?? factory/bin/lib/lock.sh
?? tests/fakes/gh
?? tests/fakes/lib.sh
?? tests/test_claim.sh
```

Lock commit shape (the contract T3's janitor reads through git): parent = the `nodes` tip, tree = its
tree, message = `lock issue-<n>: <handle>`, a blank line, then the JSON
`{"handle","run_id","slots","claimed_at"}`. Age = the commit's committer date.

## 2. Gates

```
$ make test
test_claim
  case fake-gh-semantics
    ok   fields without -X are a POST, like gh
    ok   created commit reads back with message and parent
    ok   POST git/refs creates the ref
    ok   duplicate POST git/refs exits 1
    ok   duplicate POST git/refs is HTTP 422 on stderr
    ok   duplicate POST git/refs prints the error body
    ok   duplicate POST leaves the ref alone
    ok   POST git/refs to a missing object is refused
    ok   PATCH without force refuses a non-fast-forward
    ok   PATCH without force takes a fast-forward
    ok   PATCH with force=true changes the sha
    ok   PATCH of a missing ref is refused, not created
    ok   matching-refs is a string prefix, like GitHub (issue-1 matches issue-10)
    ok   matching-refs of nothing is []
    ok   GET git/ref of a missing ref is 404
    ok   DELETE removes the ref
    ok   DELETE of a missing ref is 422
    ok   another repo is 404
    ok   8 concurrent POSTs of one ref: exactly one wins
    ok   issue list defaults to 30, newest first
    ok   issue list --label is AND, --limit honoured
    ok   issue list projects only --json fields
    ok   issue commands without --repo fail (never infer a remote)
    ok   issue edit: @me is FAKE_GH_USER, label added
    ok   issue edit with a label the repo lacks fails
    ok   issue comment appends one comment
    ok   FAKE_GH_FAIL injects an HTTP 500
    ok   every call is in the log, one JSON argv per line
    ok   the log keeps argv intact
  PASS fake-gh-semantics
  case skips-locked
    ok   light node: oldest first, locked and non-claimable skipped
    ok   all 43 claimable light Issues listed despite gh's 30 default
    ok   the locked Issue is reported as locked
    ok   dry run is the default and claims nothing
    ok   heavy node also takes w:heavy, still oldest first
    ok   text mode names the first unlocked Issue
    ok   listing wrote nothing through gh
    ok   listing left every ref as it was
    ok   an unknown capacity is a usage error (exit 1)
  PASS skips-locked
  case cas-422-moves-on
    ok   claim exits 0
    ok   422 on #3 and an error on #5 move on to #7
    ok   claimed #7
    ok   no retry: one POST git/refs per Issue
    ok   the racer keeps #3's lock
    ok   no lock on #5
    ok   #7's lock is alpha's
    ok   the lock commit sits on the nodes tip
    ok   lost Issues get no edit and no comment
    ok   every attempt erroring (not 422) is exit 1, nothing claimed
    ok   four racing nodes: exactly one claimed #1
    ok   the lock names the winner
    ok   losers saw a 422 or the lock, never a second claim
    ok   exactly one comment on the raced Issue
  PASS cas-422-moves-on
  case one-comment
    ok   --apply without slots is a usage error and writes nothing
    ok   claimed #4 with the manifest's handle and slots
    ok   expected finish = claimed_at + the weight's wall clock (budget.json)
    ok   exactly one issue edit, with exactly the spec's arguments
    ok   exactly one comment call
    ok   assigned to @me, in-progress added, no label removed
    ok   comment names the handle
    ok   comment names the fleet run id
    ok   comment names the slot count
    ok   comment names the expected finish
    ok   heartbeat and release add no comment: still exactly one
  PASS one-comment
  case heartbeat-and-stale
    ok   a 25 h old lock is stale
    ok   exactly 24 h is not yet older than 24 h: fresh
    ok   24 h and one second is stale
    ok   no lock reads absent
    ok   --check text mode
    ok   heartbeat without --apply changes nothing
    ok   heartbeat moves the ref to a new commit
    ok   the update is one PATCH with force=true
    ok   the new commit sits on the nodes tip
    ok   payload keeps handle, run_id, slots and freshens claimed_at
    ok   after the heartbeat the lock is fresh
    ok   another node's heartbeat is refused (exit 2) and the ref is untouched
    ok   heartbeat of a lost lock is exit 2 and does not re-create it
  PASS heartbeat-and-stale
  case never-delete-foreign-lock
    ok   releasing beta's (stale) lock as alpha is exit 2
    ok   the refusal names the holder
    ok   beta's lock is still there
    ok   no DELETE was sent
    ok   a lock with no readable holder is refused too
    ok   release without --apply keeps the lock
    ok   release of its own lock deletes it
    ok   exactly one DELETE, for its own ref
    ok   releasing an absent lock is exit 0 and sends nothing
  PASS never-delete-foreign-lock
PASS tests/test_claim.sh
PASS tests/test_layout.sh
exit=0
```

```
$ make lint
exit=0
```
(`make lint` = shellcheck -S warning over every factory/tests shell file including the extensionless
`tests/fakes/gh`, then actionlint via uvx; silent on success.)

```
$ grep -l "not built" factory/bin/{claim,heartbeat,release}.sh
exit=1
```
(exit 1 = no match: the three T1 stubs are gone.)

## 3. The tests can fail (mutation check)

Each row edits one line of the built code, runs `bash tests/test_claim.sh`, and restores the file.
A test suite that stayed green under any of these would be a false green (I4).

| mutation | file | exit | cases that went red |
|---|---|---|---|
| ownership check removed | `factory/bin/lib/lock.sh` | 2 | heartbeat-and-stale, never-delete-foreign-lock |
| no oldest-first sort | `factory/bin/claim.sh` | 2 | skips-locked, cas-422-moves-on |
| locked Issues not skipped | `factory/bin/claim.sh` | 1 | skips-locked |
| heartbeat PATCH without force | `factory/bin/heartbeat.sh` | 1 | heartbeat-and-stale |
| stale at exactly 24 h | `factory/bin/lib/lock.sh` | 1 | heartbeat-and-stale |
| stop at the first 422 | `factory/bin/claim.sh` | 1 | cas-422-moves-on |
| gh's default page of 30 | `factory/bin/claim.sh` | 1 | skips-locked |

Each file was restored from its copy after its run; `make test` re-run afterwards: `make test exit=0`
(all PASS), `git status` lists the same eight paths as §1.

## 4. Decisions inside the row (no ADR needed: each fills a gap the spec leaves, none contradicts it)

1. **Writers are dry-run unless `--apply`.** `--dry-run` is accepted and does nothing (it is the
   default). Readers: `claim.sh` without `--apply` and `claim.sh --check` (both take `--json`).
   T3: `janitor.yml` must pass the writer's `--apply` to leave dry-run mode.
2. **All lock traffic goes through `gh api`.** The lock commit is made with `POST git/commits` (parent =
   `nodes` tip), so a node needs no local `nodes` checkout. Lock presence is read with
   `GET git/matching-refs/locks/issue-<n>` filtered to the exact ref, so absence never rests on parsing
   an error.
3. **Capacity is `--capacity light|heavy` (or `FACTORY_CAPACITY`), default `light`.** The spec says
   "weight ≤ its capacity" but does not map a manifest to a capacity (`heavy_gates` and `quota_tier`
   are both candidates). The run loop (build order 2) owns that mapping; until then a node never
   over-claims. An Issue with no weight label, two of them, or an unknown one is not claimable.
4. **Node identity** comes from `--handle/--slots`, or `--manifest nodes/<handle>.json`, or
   `FACTORY_HANDLE/FACTORY_SLOTS`. `--run-id` defaults to `<handle>-<epoch>-<pid>` until fleet supplies one.
5. **Expected finish** = `claimed_at` + `weights.<w>.wallClockMinutes` from budget.json (45 light,
   120 heavy). budget.json is unchanged.
6. **Exit codes.** claim: 0 for claimed, nothing claimable, or every race lost (422); 1 when every
   attempt failed for a reason other than 422, or on bad usage. heartbeat: 2 when the lock is foreign or
   gone (a lost claim is never re-created by a heartbeat). release: 2 foreign or unreadable, 0 absent.
   A claim whose assign/label/comment calls fail still holds the lock: exit 0, `"announced": false`, warning on stderr.
7. **Staleness** is "older than 24 h", strictly: exactly 24 h is fresh, 24 h + 1 s is stale (tested).

## 5. Found while building; owned elsewhere

- **The heartbeat force-PATCH has a race window** (spec text: "force-updates"). If a node stalls past
  24 h, the janitor deletes its lock and another node claims, then the stalled node's heartbeat runs.
  The ownership read and the forced PATCH are two calls, so the PATCH can overwrite the new holder.
  A true CAS exists: chain the heartbeat commit onto the old lock commit and PATCH with `force=false`
  (GitHub refuses a non-fast-forward). That changes the spec's wording, so it is an ADR for the desk.
  Built as specified here. Noted in HANDOFF.
- **Live proofs due at first push (TB5 kit):** GitHub accepts `POST git/refs` for `refs/locks/issue-<n>`
  (a non-heads/tags namespace) and answers 422 on the second create; `matching-refs/locks/` lists it;
  the `in-progress` label exists on the repo (`gh issue edit --add-label` fails on a missing label, and
  the fake emulates that); the node token can write `refs/locks/**`.
