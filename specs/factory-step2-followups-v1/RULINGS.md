# factory-step2-followups-v1 rulings

Aaron submitted the decision page "Four Run Calls" on 2026-10-25 20:26Z
(https://claude.ai/artifact/MA92pyWPpMDCZHzCoSCSb6, store doc `rulings/four-run-calls-20261025`).
He picked the preselected recommendation on all four and left no notes. The questions are in full in
this spec's HANDOFF (`### Q1`–`### Q4`) and on the page.

| Q | Call | Ruling | Where it lands |
|---|---|---|---|
| Q1 | tamperguard under vetto + build.toml | **Rendered per-run policy**: run.sh renders a per-claim copy of build.toml with absolute `allow_read` roots (the clone's git dir, FACTORY_HOME's tool and interpreter dirs); build.toml is the template; ADR-0005 decision 8 is amended; tamperguard stays sandboxed with no network | factory-run-calls-v1 TB1 (T17) |
| Q2 | Tickets with `rails: []` | **Default rail `factory/policy/**` + a check** that refuses an empty rails list; the desk's ticket convention gains the rail | factory-run-calls-v1 TB2 (T18) |
| Q3 | main's `.adlc/config.json` `fleet` block | **Written with step 3's gates**: one repo-wide block, gate commands plus a desk-written allowedCommands list | step 3 spec (not before) |
| Q4 | Upstream issue: strikes spent on a rails-guard config error | **Filed** 2026-10-25 as drafted (records/TB5.md §5): https://github.com/voodootikigod/adlc/issues/1272 | done |
