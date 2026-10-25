# TB5 — Chassis ADR (ticket T5) and close-out

Session date 2026-10-24. Box as in TB0. `a` = `npx -y @adlc/cli@1.12.0`, run under `bash -c` after
`source ~/.nvm/nvm.sh`. Nothing was pushed (SPEC I1). No prep existed for this row
(`specs/factory-step1-v1/prep/` is absent).

## Part A — ADR-0003 accepted (commit `2651523`, `Ticket: T5`)

### What was read (read-only `gh api`, 2026-10-24)

```
$ for r in openai/symphony normahq/norma fabro-sh/fabro Untrivial-ai/agent-orchestrator voodootikigod/adlc; do gh api repos/$r --jq '[.full_name,.default_branch,.stargazers_count,.pushed_at,.archived,.language]|@tsv'; done
openai/symphony                     main    27806  2026-09-15T22:14:59Z false Elixir
normahq/norma                       master  4      2026-09-02T18:08:40Z false Go
fabro-sh/fabro                      main    1737   2026-10-24T09:34:30Z false Rust
OrchestratorInc/agent-orchestrator  main    13586  2026-10-25T00:18:06Z false Go
voodootikigod/adlc                  main    52     2026-10-24T18:30:02Z false JavaScript
```
`Untrivial-ai/agent-orchestrator` (the name SPEC-v0.2 uses) now redirects to
`OrchestratorInc/agent-orchestrator`. Pinned heads (`gh api repos/$r/commits/<branch> --jq .sha`):

| repo | sha | files read (`gh api repos/$r/contents/<path>?ref=<sha>` raw) |
|---|---|---|
| voodootikigod/adlc | `455524c411ff3699e8e63fb05ced260e2fa5a892` | `packages/fleet/README.md` (293 lines) |
| openai/symphony | `be10a1b79df723d6d7612b5651c8522704dafb2e` | `SPEC.md` (2312), `README.md` |
| normahq/norma | `de11cc49bcf0cf87e758298ed5fceb60135e6f4a` | `docs/pdca-agent.md` (393), `README.md` |
| fabro-sh/fabro | `1906d7c9ea4912103f78f0cff8b8d2feef139643` | `.fabro/workflows/{implement-issue,implement-plan}/workflow.fabro`, `test/docs/tutorials/plan-implement/plan-implement.fabro`, `test/docs/examples/definition-of-done/spec-dod.fabro`, `docs/public/core-concepts/{agents,models}.mdx`, `docs/public/execution/outcomes.mdx`, `docs/public/administration/sandboxing.mdx`, `README.md` |
| OrchestratorInc/agent-orchestrator | `2782e4d7f6914457daa9696cd8bccd249ec5603e` | `README.md` (the "Supported agents" table), `docs/architecture.md`, `docs/cli/README.md` |

Counts derived from those files:
- agent-orchestrator adapters: `grep -o '<b>[^<]*</b>' README.md | wc -l` → **36** (the table rows,
  L130-195). `backend/internal/adapters/agent/` holds more entries, but they include infra
  (`agentbase`, `registry`, `fake`, …). The ADR uses the README count.
- fleet adapters: README L99-100 lists **6**.
- norma: `docs/pdca-agent.md` L235-236 lists **5** ACP aliases + `generic_acp`.

### Decision and acceptance greps

The chassis is **fleet**. Why: it is the only candidate with a closed `--json` reason set (the run
loop's `case reason:` keys on it) and the only one with a fail-closed OS sandbox. Its weakness is
adapter count (6 vs 36). Multi-machine over a public repo is supplied by this spec's claim protocol
for every candidate, fleet included. The full SAME/DIFFERENT lines and per-claim permalinks are in
`docs/adr/0003-chassis.md`.

```
$ grep -c -e SAME -e DIFFERENT docs/adr/0003-chassis.md
24                      (criterion 1: >= 5)
$ grep -c 'https://' docs/adr/0003-chassis.md
44                      (criterion 2: >= 5)
$ grep -q 'only the run loop' docs/adr/0003-chassis.md; echo $?
0                       (criterion 3)
$ git log -1 --format='%h %(trailers:key=Ticket,valueonly)' 2651523
2651523 T5
```
Every external link pins the sha above with `?plain=1#Lx-Ly`. The SPEC-v0.2 links pin `origin/main`
`20371e2`; `git diff --quiet origin/main HEAD -- docs/spec/SPEC-v0.2.txt` exits 0, so the line numbers
hold on the pushed copy. Bernstein is in the ADR's context but not among T5's five, so it was not read.

## Part B — close-out gates (at `2651523`, run concurrently)

```
$ make test; echo rc=$?
PASS tests/test_claim.sh
PASS tests/test_halt_rules.sh
PASS tests/test_halt.sh
PASS tests/test_janitor.sh
PASS tests/test_layout.sh
PASS tests/test_mirror.sh
PASS tests/test_post_merge.sh
PASS tests/test_summon.sh
PASS tests/test_version_check.sh
rc=0
$ make lint; echo rc=$?          # shellcheck -S warning + actionlint (via uvx); silent = clean
rc=0
$ a ticket doctor; echo rc=$?
  ok config-valid · tickets-load · store:active-store · store:transactions · store:writer-lock ·
  store:current-ticket · store:storehash-manifest-bind · store:manifest-forest · store:archive · schema-drift
All checks passed.
rc=0
$ a coldstart --all --offline --json; echo rc=$?
{"ok":true,"results":[{"id":"T1","pass":true,"gaps":[],"cached":false,"offline":true},
 {"id":"T2","pass":true,"gaps":[],"cached":false,"offline":true},{"id":"T3","pass":true,"gaps":[],"cached":false,"offline":true},
 {"id":"T4","pass":true,"gaps":[],"cached":false,"offline":true},{"id":"T5","pass":true,"gaps":[],"cached":false,"offline":true}]}
rc=0                            # gap list empty for T1–T5
$ a merge-forecast --json | jq -c '{waves,mergeOrder,gateFailures}'; echo rc=$?
{"waves":[["T1","T5"],["T2"],["T3"],["T4"]],"mergeOrder":["T1","T5","T2","T3","T4"],"gateFailures":[]}
rc=0
$ a fleet run --dry-run --json | jq -c '{baseSha,readyNow,firstBatch,waitingOnDeps,completedExcluded}'; echo rc=$?
{"baseSha":"265152340244b953ff5d75fa632d3c88e358cd1e","readyNow":["T1","T5"],"firstBatch":["T1","T5"],"waitingOnDeps":["T2","T3","T4"],"completedExcluded":0}
rc=0
$ git worktree list             # the dry run created none
/home/musicofhel/software-factory  2651523 [main]
```
No ticket is `completed` in the store yet (`completedExcluded: 0`). Completion is post-merge's job,
and post-merge runs on main after the push.

README "Build order and status" row 1 now reads **built locally, awaiting first push**.

## Follow-ups (none blocks build order 1; each needs a desk ticket or Aaron's call)

1. **Janitor ready-duty defect** (T3 code; records/TB4.md §6.2). It compares `[.[].id]` from
   `ticket list`, which includes completed tickets, so a completion never triggers a recompute.
   post-merge.yml's mirror job covers it in the meantime.
2. **post-merge's commit carries no I5 trailers** (records/TB4.md §6.4). The step-3 commit-check must
   exempt the post-merge identity, or post-merge must add trailers. This goes with Q5.
3. **The first mirror run labels T1–T5 `needs-desk`** until spec-lint/coldstart/merge-forecast gate
   records exist (records/TB4.md §6.5, Q6).
4. **TB3 commits lack a parseable `Ticket: T3`** (Q7). This row did **not** add `Ticket: T3` to its
   commits: that would complete T3 on post-merge's first run, and the choice is Aaron's.
5. **Fine-grained token scopes.** SPEC-v0.2 "Join" step 3 wants a token with "contents: write on
   ticket/**, nodes/** and refs/locks/** only". Whether a fine-grained PAT can be branch-scoped was
   not measured here. The proof is due when the first node joins (build order 2).
6. **Node needs `bwrap`** for a live fleet run (records/TB0.md §2; ADR-0003 Consequences). The join
   wizard must probe for it.

## Live proofs due at first push (none can happen before; SPEC I9)

- The real `POST git/refs` 422 CAS (claim.sh against GitHub).
- The janitor's first scheduled dry run (step summary shows the JSON lines).
- The mirror's first Issue. Its author login must match `MIRROR_AUTHORS` =
  `app/github-actions,github-actions[bot]`.
- The `in-progress` label existing on the repo.
- Node token scopes (follow-up 5).
- post-merge's push to protected main (Q5).
- `apply-branch-protection.sh --apply`: the rulesets either accept or return 422 (records/TB2.md §5).
