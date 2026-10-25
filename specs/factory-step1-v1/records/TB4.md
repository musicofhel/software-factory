# TB4: Mirror and post-merge (ticket T4)

Session date 2026-10-24. There were two sessions: the first stopped at a SOFT GATE after WIP commit `84374d5`, and the
second finished the row. Box: WSL2. Commits: `84374d5` (WIP: mirror.sh, post-merge.sh, fakes, workflows,
test_mirror at 9/12) and the TB4 commit that carries this record. Nothing was pushed (SPEC I1). No write
reached the real GitHub. In the tests, every `gh` is `tests/fakes/gh`, every `adlc` is `tests/fakes/adlc`
(or the real CLI against a throwaway clone, §4), and every origin is a local bare repo. No prep existed for
this row (`specs/factory-step1-v1/prep/` is absent).

## 1. What was built

| file | role |
|---|---|
| `factory/bin/mirror.sh` | Turns the store into Issues. It reads `ticket list`, `ticket show` per id, `gate-manifest show`, the forecast and every Issue/label before it writes anything. A pure jq plan follows, then the writes. Labels: `w:<weight>`, `tier:<n>`, and `ready` (header valid, latest spec-lint verified, latest coldstart gap-free on the current ticketHash, a merge-forecast record that is not a failure, and live wave-1 certification) or else `needs-desk` with the reasons in the body. The body carries `Ticket: <id>` and the `Depends-on:` lines. It closes the Issues of completed tickets, reopens wrongly closed ones, and reports duplicates, impostors and orphans. Dry-run is the default. `--apply` needs a GitHub-hosted runner and a checkout of main. |
| `factory/bin/post-merge.sh` | Refuses off main (exit 2). Range: `<through>..HEAD` along the first parent. A merge brings `C^1..C`, with the PR number taken from "Merge pull request #N". Ticket ids come from git's own `Ticket:` trailer parser. Unknown and already-complete tickets are skipped. It runs `adlc ticket complete <id> --write --authorize --json` (applied only when the last JSON doc has `.applied == true`) and appends one ledger line per verified finding (p5 records replayed: verified sets, killed clears, needs-human ignored; never claim/evidence/recommendation). Then it makes one commit (store + manifest + ledger + marker) and does one fast-forward push. After a failed completion the marker does not advance. |
| `factory/bin/lib/common.sh` | `valid_ticket_id`. |
| `tests/fakes/gh` | `issue create/close/reopen`, `issue edit --title/--body/--body-file`, `label list/create`, Issue `author` (`FAKE_GH_BOT`). |
| `tests/fakes/adlc` | `ticket show` (unknown id: exit 2, TICKET_NOT_FOUND **on stderr**, as the real CLI), `ticket complete` (`FAKE_ADLC_STORE`; `--write` without `--authorize` is exit 2), `gate-manifest show [--ticket]` (`FAKE_ADLC_SKIPPED`). |
| `tests/test_mirror.sh` | 12 cases, 142 assertions: **creates, updates-idempotent, ready-only-when-gated, depends-on-lines** (the T4 named cases), plus dry-run-inert, closes-completed, stranger-issues, forecast-file, read-failures-write-nothing, refuses-apply, workflow, fake-semantics. |
| `tests/test_post_merge.sh` | 9 cases, 81 assertions: **completes, refuses-off-main** (the T4 named cases), plus dry-run-inert, findings-ledger, range-since-marker, completion-failure, push-refused, refuses-apply-off-hosted, workflow. |
| `.github/workflows/mirror.yml` | Applies by default (`MIRROR_DRY_RUN=true` or a dispatch input narrows it), checks out `ref: main`, concurrency group `mirror`. |
| `.github/workflows/post-merge.yml` | Job `complete` runs `post-merge.sh --apply` on `ref: main, fetch-depth: 0`. Job `mirror` (`needs: complete`, group `mirror`) re-mirrors, because a push made with the Actions token triggers no other workflow. |

Stubs gone: `grep -n "not built" factory/bin/mirror.sh factory/bin/post-merge.sh` prints nothing.

## 2. Design decisions made in this session (and why)

1. **Mirror ownership = trusted author + `Ticket:` line. The marker is not part of the test.** The WIP rule
   needed the marker, so a human who rewrote a mirror Issue's body (and deleted the marker) made the
   mirror create a duplicate Issue on the next run. Now an Issue is the mirror's when its author is in
   `MIRROR_AUTHORS` and its body has a `Ticket: <id>` line. A hand edit that keeps the Ticket line is
   overwritten from the store. A body wiped of its Ticket line can't be matched: a fresh Issue is
   created and the wiped one is reported as an `orphan` (kept). Both behaviours are tested
   (updates-idempotent). Impostor detection still keys on the marker (an untrusted *bot* carrying the
   marker means MIRROR_AUTHORS is wrong). A third-party bot that only mentions `Ticket: T1` therefore
   can't block the mirror.
2. **post-merge checks out `ref: main`, not the pushed sha.** With `cancel-in-progress: false`, a queued run
   on the pushed sha would sit behind the previous run's completion commit, and its push would always be
   non-fast-forward. On the latest main, the marker range covers every merge since the last landing. A
   merge that lands mid-run makes this run's push fail (exit 1, tested in push-refused), and that merge's
   own run picks the range up.
3. **TICKET_NOT_FOUND is read from stderr.** Found by running post-merge against the real CLI (§4): adlc
   1.12.0 prints the error object on stderr with stdout empty. The WIP code and the fake both assumed
   stdout, so the first real run would have died (exit 1) on `Ticket: scaffold`. Fixed in both. The
   script now parses one JSON document per line from stdout+stderr and ignores other text.
4. Test-only fixes: the three WIP failures were `has` checks on `iss … .body`, which is JSON-encoded (it
   holds `\n` escapes, not newlines). They were rewritten with a raw `body()` helper and without `eval`.

## 3. Gates

```
$ make test        # exit 0
PASS tests/test_claim.sh
PASS tests/test_halt_rules.sh
PASS tests/test_halt.sh
PASS tests/test_janitor.sh
PASS tests/test_layout.sh
PASS tests/test_mirror.sh          (12 cases, 142 assertions)
PASS tests/test_post_merge.sh      (9 cases, 81 assertions)
PASS tests/test_summon.sh
PASS tests/test_version_check.sh
$ make lint        # exit 0 (shellcheck -S warning on factory/ + tests/, then actionlint with that shellcheck)
$ uvx --from actionlint-py actionlint .github/workflows/mirror.yml .github/workflows/post-merge.yml; echo rc=$?
rc=0
```

## 4. Real adlc 1.12.0 (measured; re-run with the commands shown)

Measured this session in a throwaway clone (`git clone ~/software-factory /tmp/tb4-adlc2`, at `e159a89`),
`A="npx -y @adlc/cli@1.12.0"`:

| command | result |
|---|---|
| `$A --version` | `1.12.0` |
| `$A ticket list --json \| jq -c '.[0], length'` | `{"id":"T1","title":"…","ticketHash":"882cd7ad…"}`, `5`: only id/title/ticketHash |
| `$A ticket show NOPE --json` (stdout) / (stderr) | stdout empty, exit 2 / stderr `{"ok":false,"kind":"invalid","code":"TICKET_NOT_FOUND","message":"ticket not found: NOPE"}` |
| `$A ticket complete NOPE --json 2>/dev/null` | stdout empty, exit 2 |
| `$A ticket show T1 --json \| jq -c '.ticket\|keys'` | `["body","category","duration","edges","id","scope","title"]`: an open ticket has **no** `completed` key (the mirror reads it as false) |
| `$A gate-manifest show --json \| jq -c '{e:(.entries\|length),s:.skipped}'` | `{"e":1,"s":[]}` |
| `$A merge-forecast --json` | exit 0, `waves [["T1","T5"],["T2"],["T3"],["T4"]]`, `mergeOrder ["T1","T5","T2","T3","T4"]`, `firstWaveWidth 2`, `certifiedWidth 2`, `gateFailures []` |

Measured in the first session, in a throwaway copy (`/tmp/tb4-adlc`, since deleted) and not re-run in this one:
`ticket list` includes completed tickets, and only `ticket show` has `.ticket.completed`. `ticket complete T5
--write --authorize --json` prints the plan JSON, then `{"applied":true,…}`. Re-completing is a no-op
(`changedFields: []`) but appends another manifest entry, which is why post-merge skips completed tickets.
`merge-forecast` drops completed tickets. `certifiedWidth` is a deprecated alias of `firstWaveWidth`.
spec-lint `--record` writes `{gate:"spec-lint", data:{verified:true}}` only on a pass. coldstart writes
`data.cache {ticketHash, model, gaps}`. Nothing writes `merge-forecast` gate records by itself (ADLC's own P2
rule is presence-only, runner/lib/assertions.mjs). prosecute writes `type: p5-finding-verified|killed|needs-human`
with `finding {id, category, file, line_start, line_end, severity, confidence, claim, evidence,
recommendation}`. `gh issue list --json author` on an Actions-created Issue gives
`{"is_bot":true,"login":"app/github-actions"}` (genlayerlabs/genlayer-docs#743, read-only).

**Integration smoke (real adlc, fake gh, in /tmp/tb4-adlc2):**
- `mirror.sh --dry-run` → exit 0. It plans 5 creates, all `needs-desk`: every ticket has `spec-lint: no
  record`, `coldstart: no record` and `merge-forecast: no record`, and T2/T3/T4 are also `in wave 2/3/4,
  not wave 1`. This is fail-closed by design until the desk records the gates.
- `post-merge.sh` (dry run, on main, no marker = all history) → exit 0 after fix 3. Its lines are
  `T1 planned`, `T2 planned`, `T4 planned`, `scaffold unknown`.
  **T3 is missing.** Commits `4c1198b` and `6f9aec6` put `Ticket: T3` in a paragraph *above* a blank line,
  followed by the Co-Authored-By/Signed-off-by block, so git's trailer parser (`git log
  --format='%(trailers:key=Ticket)'`) does not see it. The commit-check gate of step 3 will read trailers
  the same way. This is a defect in the TB3 commit messages, not in post-merge, and is carried to TB5 (§6).

## 5. The tests can fail (mutation check)

Harness: `/tmp/tb4-mut/run.sh` copies `factory/`, `tests/` and `.github/workflows/` per mutation. It applies one
literal substitution with perl (`\Q…\E`; a count other than 1 is NOAPPLY) and runs only that script's test
file. First pass: 64 mutations, 3 survived (m33, m34, p28). A test was added for each:
- T11 has a failing merge-forecast record.
- A CRLF/trailing-newline copy of the same body (a web-UI save) must be `unchanged`.
- A PR merge in range-since-marker must bring only its own commits.

Fix 3 changed one line, so p08 was re-pointed at it and p29 added. Final: **65/65 caught.**

| # | mutation (mirror.sh) | caught by |
|---|---|---|
| m01 | adopt every author's Issue | stranger-issues |
| m02 | spec-lint always passes | ready-only-when-gated |
| m03 | coldstart staleness ignored | ready-only-when-gated |
| m04 | one gap tolerated | ready-only-when-gated |
| m05 | earliest record counts, not latest | ready-only-when-gated |
| m06 | missing merge-forecast record tolerated | ready-only-when-gated |
| m07 | SEQUENCE/hardVeto pairs ignored | ready-only-when-gated |
| m08 | last wave read as wave 1 | ready-only-when-gated, forecast-file |
| m09 | forecast gateFailures ignored | ready-only-when-gated |
| m10 | Depends-on from own edges (direction flipped) | depends-on-lines |
| m11 | always update (not idempotent) | updates-idempotent, depends-on-lines, stranger-issues |
| m12 | remove labels the mirror does not own | updates-idempotent, ready-only-when-gated |
| m13 | completed ticket's Issue not closed | dry-run-inert, closes-completed |
| m14 | closed Issue of an open ticket not reopened | closes-completed |
| m15 | impostor does not suppress create | stranger-issues |
| m16 | duplicates not reported | stranger-issues |
| m17 | highest number kept | stranger-issues |
| m18 | RUNNER_ENVIRONMENT refusal dropped | refuses-apply |
| m19 | main refusal dropped | refuses-apply |
| m20 | dry run writes | dry-run-inert, refuses-apply |
| m21 | unreadable manifest entries tolerated | read-failures-write-nothing |
| m22 | truncated Issue list tolerated | read-failures-write-nothing |
| m23 | conflict exits 0 | stranger-issues |
| m24 | missing labels never created | creates, dry-run-inert |
| m25 | weight `medium` accepted | ready-only-when-gated |
| m26 | tier `7` accepted | ready-only-when-gated |
| m27 | forecast exit 2 rejected | ready-only-when-gated |
| m28 | `--forecast FILE` ignored | forecast-file |
| m29 | `ready` kept on close | closes-completed |
| m30 | no `Ticket:` line in the body | 7 cases |
| m31 | always ready | ready-only-when-gated, forecast-file |
| m32 | every forecast ticket certified | ready-only-when-gated, forecast-file |
| m33 | failed merge-forecast record tolerated | ready-only-when-gated (after fix) |
| m34 | body compared without CRLF/trailing normalisation | updates-idempotent (after fix) |
| m35 | completed flag ignored | creates, dry-run-inert, closes-completed |
| m36 | coldstart always a reason | 6 cases |

| # | mutation (post-merge.sh) | caught by |
|---|---|---|
| p01 | main refusal dropped | refuses-off-main |
| p02 | hosted refusal dropped | refuses-apply-off-hosted |
| p03 | marker ignored (always all history) | range-since-marker, completion-failure |
| p04 | not first-parent | 5 cases |
| p05 | a merge brings only itself | 5 cases |
| p06 | PR number dropped | completes, range-since-marker |
| p07 | completed tickets re-completed | range-since-marker, completion-failure |
| p08 | TICKET_NOT_FOUND not skipped | 6 cases |
| p09 | killed findings kept | findings-ledger |
| p10 | re-verified finding duplicated | findings-ledger |
| p11 | needs-human counted as verified | findings-ledger |
| p12 | claim text in the ledger | findings-ledger |
| p13 | `--authorize` dropped | 5 cases |
| p14 | `applied` not checked | completion-failure |
| p15 | marker advanced after a failure | completion-failure |
| p16 | dry run writes the ledger | dry-run-inert |
| p17 | dry run completes | dry-run-inert |
| p18 | commit with nothing completed | range-since-marker, completion-failure |
| p19 | force push | push-refused |
| p20 | non-ancestor marker accepted | range-since-marker |
| p21 | unreadable manifest entries tolerated | completion-failure |
| p22 | marker names the wrong commit | completes, range-since-marker, completion-failure |
| p23 | `git add -A` (commits stray files) | completes |
| p24 | a ticket named twice completed twice | range-since-marker |
| p25 | wrong trailer key | 6 cases |
| p26 | dry run lands | dry-run-inert |
| p27 | ledger never appended | completes, findings-ledger, completion-failure |
| p28 | a merge brings all of `C^2`'s history | range-since-marker (after fix) |
| p29 | TICKET_NOT_FOUND read from stdout only | 6 cases |

## 6. Follow-ups carried to TB5 (none blocks TB4)

1. **TB3 commits lack a parseable `Ticket: T3` trailer** (§4). On the first post-merge run T3 is not completed
   from history. Options for TB5/Aaron: complete T3 by hand from main, or add a `Ticket: T3` trailer to a
   later commit before the first push. Rewriting the local, unpushed history would also work, but that
   rewrites signed DCO commits.
2. **Janitor defect (T3 code, outside T4 scope):** janitor's ready duty compares the open set with
   `[.[].id]` from `ticket list`. That list includes completed tickets, so a completion never triggers
   a recompute. post-merge.yml's mirror job covers this. It needs a desk ticket.
3. **post-merge's push to protected main** will likely be refused, because branch-protection.json requires
   PRs and `enforce_admins`. This is Q5 in HANDOFF.
4. **post-merge's own commit carries no I5 trailers** (no DCO, Ticket or Node; it has `Through:`). The step-3
   commit-check must exempt the post-merge identity, or post-merge must add trailers. Decide this with Q5.
5. Due at first push: the mirror's first Issue (its author login must match `MIRROR_AUTHORS`), and the first
   real run labels T1–T5 `needs-desk` until the gate records exist.
