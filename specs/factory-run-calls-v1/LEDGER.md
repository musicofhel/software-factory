STATUS: IN_PROGRESS

# LEDGER — factory-run-calls-v1

- [x] TB0: Register and tickets T17–T19 — register re-measured; T17–T19 written to main's store (T19 plain, T18/T17 `--allow-unsigned` per ruling Q1; T18 scope + post-merge.sh); doctor ok, coldstart gaps empty, forecast 0, make test 15 PASS, lint 0 (records/TB0.md §2.4) — fbcd3e3
- [x] TB1: The rendered per-run policy (ticket T17; ruling Q1) — run.sh renders $FACTORY_HOME/run/policy/<run id>.build.toml (lib/policy-render.sh: git dir + tool + interpreter install roots, I14, fail-closed); live: rc 0 ok under scratch HOME, real HOME fails closed; make test 15 PASS, lint 0, live render PASS, rails-guard pass (records/TB1.md) — d26e3f7
- [x] TB2: The default rail and the check (ticket T18; ruling Q2) — convention in RULES.md + ADR-0002 (decision 3, amendment T18); mirror: open ticket without rails → needs-desk `rails: none declared`, completed never relabeled; new factory/bin/ticket-check.sh behind `make tickets` (exit 2; main's store exit 0, 16 completed + 3 ok); post-merge passes `--allow-unsigned` (fake refuses a frozen store without it, measured on adlc 1.12.0); make test 16 PASS, lint 0, red proofs fail on old code, rails-guard pass (records/TB2.md) — df7a6dc
- [ ] TB3: The live run to `scope-check-not-built`, and close-out (ticket T19)
