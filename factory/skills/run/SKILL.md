---
name: run
description: Start one factory run loop on this node (one loop per slot). The loop is a shell script, not an agent; this skill only starts it and explains its reason codes. Use when a member says "start my node", "run the factory", or runs /factory:run.
---

# /factory:run

**Status: build order step 2 (not built). `factory/bin/run-loop.sh` does not exist yet.**

One loop per slot: `factory/bin/run-loop.sh --slot <n>`. The loop, top to bottom:

```
version_check      # factory/VERSION and adapter pins; behind → pull, restart, or refuse to claim
heartbeat          # last_seen into nodes/<handle>.json on the nodes branch, push (hourly at most)
kill_switch_check  # factory/HALT present on origin/main → sleep 30m, continue
quiet_hours_check  # inside owner's quiet hours → sleep until they end
quota_check        # cux status; all accounts ≥ quota_cap of window → sleep until reset
claim              # git-ref lock protocol (factory/bin/claim.sh); nothing claimable → sleep 10m
git fetch
worktree           # from the lapsed ticket/<id>/* branch if one exists (dead-end material appended), else origin/main
ralon run --lock .ralon/<id>.lock -- vetto --profile factory/policy/build.toml -- \
  fleet run --tickets <id> --concurrency 1 --no-pr --no-complete \
    --adapter <preferred> --worker-deps <lockfile cache> \
    --max-strikes <budget.strikes> --wall-clock-minutes <budget.minutes> \
    --pre-strike-argv '["cux","status","--json"]' --json
case reason:
  merged into fleet/run-*   → tamperguard + scope check locally; push ticket/<id>/<handle>; open PR; comment on Issue
  quota-paused | wall-clock → keep lock (heartbeat it), push partial branch, sleep, resume
  strikes-exhausted | flail → push branch, label Issue needs-desk, delete lock
  review-unavailable        → delete lock, sleep 30m
  anything else             → delete lock, comment reason, continue
git worktree remove .worktrees/<id>
```

Transcripts never leave the node. The PR body carries gate-manifest hashes, reason codes,
strikes, adapter names and token counts; never prompts, file contents or session text.
