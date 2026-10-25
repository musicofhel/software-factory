# factory-step2-v1 rulings

Aaron submitted the decision page "Five Node Calls" on 2026-10-25 12:24Z
(https://claude.ai/artifact/5WLA4B5QzrwCgx7Yniahkt, store doc `rulings/five-node-calls-20261025`).
He picked the preselected recommendation on all five and left no notes. The questions are in full in
this spec's HANDOFF (end of TB6) and on the page.

| Q | Call | Ruling | Where it lands |
|---|---|---|---|
| Q1 | Getting past fleet 1.12.0's preflight canary | **Report upstream + a temporary bwrap shim behind an ADR.** Upstream issue FILED 2026-10-25: https://github.com/voodootikigod/adlc/issues/1266 (body = records/upstream-fleet-canary-issue.md). The shim adds read-only system roots only, and retires when a fixed fleet is pinned | factory-step2-followups-v1 TB1 (ADR-0006) |
| Q2 | Post-merge vs classic protection | **Move the classic rules into the ruleset**, where the App bypass applies; post-merge keeps its direct push | followups TB2 |
| Q3 | Who sets needs-desk | **The node labels; mirror.sh preserves a node-added needs-desk**; the claim protocol text gains the exception | followups TB3 |
| Q4 | fleet's reviewer | **Pin adversarial-review 2.11.1 by npm integrity in join's plan; same-family review accepted until step 4** | followups TB4 |
| Q5 | cux account | **join.sh prints the `cux add` line** in the register step; it handles no credential | followups TB4 |
