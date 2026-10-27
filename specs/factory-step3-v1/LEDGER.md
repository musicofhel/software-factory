STATUS: IN_PROGRESS

# LEDGER — factory-step3-v1

- [x] TB0: Register, tickets T20–T31, and the measurements the rows depend on — register re-measured, every line holds; (a) `native-queue: no` (docs: org-owned repos only; the repo is User-owned); (b) check runs are named by the bare job id, Actions app id 15368; (c) ubs's license rider excludes Anthropic → no bugscan; aislop 0.18.1 MIT, attest 1.0.0 MIT (linux binary), flaky-test-detective has no release, bomdrift 0.9.9 Apache-2.0; (d) GITHUB_TOKEN events start no workflow (dispatch excepted); 75 gap ids re-checked: 0 closed, 0 wrong; T20–T31 written with `--allow-unsigned` (manifest seq 26–37), chain edges, doctor ok, coldstart gaps empty, forecast exit 0 (12 serial waves), make test 16 PASS, lint 0, tickets 0 (records/TB0.md) — COMMIT
- [ ] TB1: `make sim`: the end-to-end pipeline simulation, today's stop points recorded (ticket T20)
- [ ] TB2: Gate context and ticket identity (ticket T21)
- [ ] TB3: The three diff gates: rails-proof, scope, tamper, one helper for node and CI (ticket T22)
- [ ] TB4: One trailered commit per ticket and the commit check (ticket T23)
- [ ] TB5: main's `fleet` block and the build-test gate from the base config (ticket T24)
- [ ] TB6: The claim across an open PR, and the `blocked` label (ticket T25)
- [ ] TB7: The desk gates: records `ready` needs, contract lint, the manifest chain (ticket T26)
- [ ] TB8: The `Depends-on:` hold and tier order (ticket T27)
- [ ] TB9: The queue: native merge queue or the first-party serial queue, and ejection (ticket T28)
- [ ] TB10: Branch protection as code, approvals, the halt-guard, the App's reach (ticket T29)
- [ ] TB11: The remaining CI gates: attest, bug scan, flaky, skills (ticket T30)
- [ ] TB12: The full walk green, live smoke to `pr-ready`, close-out (ticket T31)
