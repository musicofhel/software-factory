---
name: run
description: Start the factory run loops on this node (one loop per slot). The loop is a shell script, factory/bin/run.sh, not an agent; this skill only starts it and explains its outcomes and reason codes. Use when a member says "start my node", "run the factory", or runs /factory:run.
---

# /factory:run

**Status: built (build order step 2, ticket T9). The loop is `factory/bin/run.sh`; never do its
steps by hand.** It codes to the real CLIs as `docs/adr/0005-run-loop-cli-reality.md` records them,
not to SPEC-v0.2's run-loop sketch.

```
. ~/.factory/env                                   # join.sh --apply wrote it: PATH, FACTORY_MANIFEST
factory/bin/run.sh --slot 1                        # dry run: governor verdict + what it would claim; writes nothing
factory/bin/run.sh --slot 1 --apply --once         # one iteration, then exit
factory/bin/run.sh --slot 1 --apply                # the loop, forever
```

Run it from the root of your clone. One loop per slot (`slots` in your manifest):

```
. ~/.factory/env
slots="$(jq -r .slots "$FACTORY_MANIFEST")"
for s in $(seq 1 "$slots"); do
  nohup factory/bin/run.sh --slot "$s" --apply >>"$HOME/.factory/run/slot-$s.out" 2>&1 &
done
```

A second loop on a slot that already has one is refused (exit 2). A slot beyond the manifest's
`slots` is refused. Stop a loop with `kill <pid>` (its pid is in `~/.factory/run/slot-N.mutex/pid`);
a paused claim survives the restart (see "Paused" below). Before taking the box offline for more
than a day, run `/factory:release`.

Flags: `--apply` (without it nothing is written), `--once`, `--max-iterations K`, `--json` (one JSON
line per iteration on stdout). Exit 0 done (`--once`, `--max-iterations`); 2 the governor refused,
or the slot stopped at a gate; 1 an operational error or a fleet failure that needs a human.

## One iteration

1. **Governor** (`governor.sh --json --apply`, one at a time per node): version and adapter pins,
   the hourly `nodes` heartbeat, `factory/HALT`, quiet hours, quota (`cux usage show`).
   `refuse` stops the loop (exit 2); `sleep` naps; `claim` goes on.
2. **Claim** (`claim.sh --apply`, the git-ref lock protocol). Nothing claimable → nap 10 min. The
   Issue's `Ticket: <id>` line names the ticket.
3. **Fetch** `origin main` and `origin ticket/<id>/*`.
4. **Worktree** `.worktrees/<id>`, detached: at the newest lapsed `ticket/<id>/*` branch if one
   exists (its outcome trailers, commits and files go to fleet as `--dead-end-file`), else at
   `origin/main`. `agent.lock` is rendered from the ticket's `rails` (`lib/ralon-lock.sh`).
5. **Build**:
   ```
   ralon run -C <worktree> -- npx -y @adlc/cli@1.12.0 fleet run --tickets <id> --concurrency 1 \
     --no-pr --no-complete --base <sha> --adapter <adapter> --max-strikes <n> --wall-clock-minutes <m> \
     --pre-strike-argv '["<abs>/factory/bin/quota-gate.sh"]' --pre-strike-env <json> \
     --model-plane-egress allowlist [--dead-end-file <wt>/.factory-run/dead-end.md] --json
   ```
   Strikes and minutes come from `factory/policy/budget.json` by the ticket's weight (light 2 / 45,
   heavy 3 / 120). fleet sandboxes its own build/test steps (bwrap) and model turns (egress
   allowlist); vetto cannot wrap fleet (ADR-0005), so vetto + `build.toml` wraps the loop's own
   tamperguard step instead.
6. **Case on fleet's reason**, then remove the worktree (except while paused):

| fleet says | outcome | what the loop does |
|---|---|---|
| success (`exitCode 0`, `reason null`, `merged ≥ 1`) | `built` | tamperguard (under vetto) and `scope-check.sh` on the ticket's range; both pass → push `ticket/<id>/<handle>` ending in a record commit, open the PR, comment on the Issue. The lock stays until merge |
| success, scope-check is still step 3's stub | `held`, reason `scope-check-not-built` | no push (no false green); the work stays on a **local** `ticket/<id>/<handle>` branch; release, comment; **the slot stops (exit 2)** |
| success, tamperguard says tamper / a real scope failure | `desk`, reason `tamper` / `scope-fail` | label `needs-desk`, comment, release, nothing pushed |
| success, tamperguard or scope-check fails to run | `released`, reason `tamperguard-error` / `scope-check-error` | release, comment, the slot stops (exit 1) |
| `quota-paused`, `wall-clock` | `paused` | push the partial branch, heartbeat the lock, keep the worktree; the next iteration re-runs the identical fleet argv there (fleet resumes). Nap 10 min after quota, none after wall-clock. The 4th pause of one claim is handled as strikes-exhausted |
| `strikes-exhausted`, `flail` | `desk` | push the branch, label `needs-desk`, comment, release |
| `review-unavailable` | `released` | release, no comment, nap 30 min |
| `lock-held`, `ticket-blocked`, `mirror-fetch-failed` | `released` | release, comment the reason, nap 10 min |
| anything else (`preflight`, `quarantined`, `dispatch-refused`, …, unreadable output, no merge) | `released` | release, comment the reason, **the slot stops (exit 1)**: re-claiming would repeat it |

A paused claim's lock is heartbeated whenever `claim.heartbeatMinutes` have passed; if the janitor
took it meanwhile, the outcome is `lock-lost` and the loop cleans up without re-claiming. A nap is
at most one hour (`governor.nodeHeartbeatMinutes`); then the governor is asked again.

## Where things live

- `~/.factory/run/ledger.jsonl`: one JSON line per iteration (slot, iteration, outcome, reason,
  ticket, Issue, base, fleet run id and strikes, gate verdicts, actions, sleep).
- `~/.factory/run/logs/<run_id>.*`: fleet's own JSON and stderr, tamperguard's findings, git and gh
  errors. **These stay on this box.**
- `~/.factory/run/slot-N.json`: a paused claim (Issue, ticket, worktree, the saved fleet argv). Remove
  it only after releasing the lock yourself.

## Transcripts never leave the node (I8)

Everything the loop sends out (commit messages, PR bodies, Issue comments, the ledger) is rendered
from ids, reason codes, strike counts, adapter names, shas and gate-manifest hashes only. fleet's
free-text reasons and warnings, tamperguard's findings and every transcript stay in
`~/.factory/run/logs/`. A fleet reason that is not a plain code is sent as `unrecognized`. Token
counts are `null`: fleet 1.12.0 does not report them.
