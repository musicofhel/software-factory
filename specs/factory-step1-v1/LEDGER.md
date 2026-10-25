STATUS: IN_PROGRESS

- [x] TB0: Register — measure the scaffold, prove the toolchain, fix what the scaffold got wrong — `6f25e1d`: all register outputs in records/TB0.md; merge-forecast gate fixed (exit 2→0, edges T1→T2→T3→T4), T5 title fixed, `make lint` now fails closed + runs actionlint; fleet sandbox NOT met (bwrap missing, unshare rejected), dry-run exit 0
- [x] TB1: Claim protocol (ticket T1) — `6730c62`: claim/heartbeat/release + lib/{common,lock}.sh + git-backed fake gh; tests/test_claim.sh 6 cases PASS (5 T1 + fake-gh-semantics), make test/lint exit 0, T1 stubs gone, 7 mutations each caught (records/TB1.md)
- [x] TB2: Kill switch (ticket T2) — `2a4cb49`: halt-check (origin/main ls-tree, 0/3/1 fail-closed), apply-branch-protection (dry-run prints calls, --apply, 2nd run no-op, refuses fake fields), summon (3 kinds, 1 POST, else exit 2) + summoner.yml fixed; test_halt/test_halt_rules/test_summon 19 cases PASS, make test/lint exit 0, 26/26 mutations caught; HALT 0-to-add/2-to-remove NOT expressible on GitHub → ADR-0004 proposed (records/TB2.md)
- [ ] TB3: Clock and janitor (ticket T3) — PARTIAL (WIP `4c1198b`): janitor.sh, version-check.sh, make-repo.sh, fake adlc/mirror/gh pr list, test_janitor (14 cases) + test_version_check (6) pass by hand; REMAINING: janitor.yml, make test/lint, mutation pass, records/TB3.md, final commit
- [ ] TB4: Mirror and post-merge (ticket T4)
- [ ] TB5: Chassis ADR (ticket T5) and close-out
