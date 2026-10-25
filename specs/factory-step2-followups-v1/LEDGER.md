STATUS: IN_PROGRESS

# LEDGER — factory-step2-followups-v1

- [x] TB0: Register and tickets T12–T16 — register re-measured, nothing moved, no fixed fleet (TB1 = shim); T12–T16 written, doctor ok, coldstart empty, merge-forecast 0 (abf8e94)
- [x] TB1: The bwrap shim and ADR-0006 (ticket T12; ruling Q1) — shim + ADR-0006 + fixtures from real fleet 1.12.0; live: canary prints __fleet_canary_ok__ through the shim, fails execvp /bin/sh without; make test 15 PASS, lint 0, live shim/join/policy PASS; smoke left to TB5 (7545a15 scaffold, 922af83)
- [x] TB2: Protection rules into the ruleset (ticket T13; ruling Q2) — ruleset `main` holds deletion/non_fast_forward/pull_request/required_status_checks + merge queue, classic protection null (DELETEd if found), App the only bypass actor, NOTE gone, rule params validated from GitHub REST schema; make test 15 PASS, lint 0 (e936374 scaffold, 90b3158)
- [x] TB3: needs-desk survives the mirror (ticket T14; ruling Q3) — marker defined once in factory/bin/lib/desk-marker.sh; run.sh comments it (ticket, Issue's Ticket-Hash, reason, node) then adds needs-desk/removes ready; mirror holds the label until a new ticketHash or a newer trusted claim; RULES.md exception; make test 15 PASS, lint 0, mutation-checked (67a2ff1)
- [x] TB4: The reviewer pin and the cux line in join (ticket T15; rulings Q4, Q5) — join installs adversarial-review 2.11.1 by npm pack + sha512 against the pinned integrity, then npm installs that file, then a receipt; mismatch exits 1 with nothing installed; manifest review {tool, pin, same_family}; register prints `cux add --no-alias` with the governor's reason; smoke uses join's reviewer and printed line (0 `npm install`); make test 15 PASS, lint 0, test_join_live PASS incl. tampered-pin fail-closed; 9/9 mutants killed; smoke run left to TB5 (595e933 scaffold, d41978e)
- [ ] TB5: The live run past preflight, and close-out (ticket T16)
