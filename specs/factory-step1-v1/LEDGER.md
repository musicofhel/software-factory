STATUS: IN_PROGRESS

- [x] TB0: Register — measure the scaffold, prove the toolchain, fix what the scaffold got wrong — `6f25e1d`: all register outputs in records/TB0.md; merge-forecast gate fixed (exit 2→0, edges T1→T2→T3→T4), T5 title fixed, `make lint` now fails closed + runs actionlint; fleet sandbox NOT met (bwrap missing, unshare rejected), dry-run exit 0
- [x] TB1: Claim protocol (ticket T1) — `6730c62`: claim/heartbeat/release + lib/{common,lock}.sh + git-backed fake gh; tests/test_claim.sh 6 cases PASS (5 T1 + fake-gh-semantics), make test/lint exit 0, T1 stubs gone, 7 mutations each caught (records/TB1.md)
- [ ] TB2: Kill switch (ticket T2)
- [ ] TB3: Clock and janitor (ticket T3)
- [ ] TB4: Mirror and post-merge (ticket T4)
- [ ] TB5: Chassis ADR (ticket T5) and close-out
