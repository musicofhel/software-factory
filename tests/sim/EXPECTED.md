# EXPECTED — the stage results of `make sim` (tests/sim/sim.sh)

Every stage judges the **desired** behavior of the pipeline (specs/factory-step3-v1/SPEC.md): `pass`
means the pipeline did the right thing, `red: <gap id>` that it does not yet, with the gap of
`specs/factory-step3-v1/records/sim/*.md` that explains it and the row that fixes it. After a red
stage the sim plays a labeled stand-in (`stand-in:` in sim.log: the records TB7 will write, fleet
without its config preflight, GitHub's queue, the merge) so the later stages stay observable. `tests/sim/lib/compare.sh` compares this table with the results in both
directions: a stage that goes green before its line here says `pass` fails the sim as much as a
regression does. The row that fixes a gap flips its lines in the same commit. A stage only GitHub
itself can prove is `red: kit: <line>` (TB12), never `pass`.

Stage names: `world.*`, `desk.*`, `push.*`, `janitor.*` are the setup; `P.*` is T-sim-parent's path
and `C.*` T-sim-child's (`.pr.<job>` = the job on pull_request, `.mg.<job>` = on merge_group, one
line per job the driver ran from the YAML; `.identity` = the `context` job resolved this PR's number,
ticket, class, base and head, on merge_group from the queue ref; `.node-tamper`, `.node-rails`,
`.node-scope` = the node's three diff gates on the commit it pushes, from run.sh's ledger line;
`.i17-argv` = the node's `diff-gates:` trace lines and tamperguard argv equal those of the PR's
`rails-proof`, `scope` and `tamper` jobs on the same base...head); `S.*` are the failure scenarios
(lib/scenarios.sh), each judged on the gate that should stop it naming its own reason, and `S.class-*`
on the class the `context` job gave the PR; `gh.forms` = no script called a `gh` form the fake gh does
not model.

| stage | expected |
|---|---|
| world.seed | pass |
| janitor.no-nodes | red: ci:G22 — janitor.sh dies on a missing `nodes` branch (the branch itself is kit: merge:G15) |
| desk.write | pass |
| push.mirror | pass |
| P.mirror-ready | red: intake:I1 — nothing writes the spec-lint/coldstart/merge-forecast records mirror.sh needs (TB7) |
| C.mirror-blocked | red: intake:I2 — a child waiting on its parent is `needs-desk`, not `blocked` (TB6) |
| C.depends-link | red: intake:I12 — `Depends-on: <id>` with no `(#<issue>)` link (TB6) |
| P.claim | pass |
| P.fleet-preflight | red: node:G10 — main's .adlc/config.json has no fleet block (TB5) |
| P.node-tamper | pass |
| P.node-rails | pass |
| P.node-scope | pass |
| P.commit-shape | pass |
| P.pr-open | pass |
| P.claim-released | red: node:G3 — the lock is kept across the PR and the Issue stays `ready` (TB6) |
| P.tier-label | red: intake:I3 — the PR carries no tier label (TB8) |
| P.pr.context | pass |
| P.pr.identity | pass |
| P.i17-argv | pass |
| P.pr.build-test | pass |
| P.pr.rails-proof | pass |
| P.pr.scope | pass |
| P.pr.tamper | pass |
| P.pr.dependencies | pass |
| P.pr.commit-check | pass |
| P.pr.attest-verify | red: ci:G6 — attest-verify.sh is a stub, `attest-verify: not built` (TB11) |
| P.pr.required-checks | red: ci:G1 — the policy requires `gates / <job>`; check runs are named by the bare job id (TB10) |
| P.hold | red: merge:G3 — no `depends-on` job (TB8) |
| P.tier-order | red: merge:G5 — no `tier-order` job (TB8) |
| P.enqueue | red: merge:G4 — nothing enqueues a green PR (TB9) |
| P.mg.context | pass |
| P.mg.identity | pass |
| P.mg.build-test | pass |
| P.mg.rails-proof | pass |
| P.mg.scope | pass |
| P.mg.tamper | pass |
| P.mg.dependencies | red: ci:G1 — `if: pull_request` skips it on merge_group, so a required check never runs on the queue path (I18, TB10) |
| P.mg.commit-check | pass |
| P.mg.attest-verify | red: ci:G6 — attest-verify.sh is a stub, `attest-verify: not built` (TB11) |
| P.mg.required-checks | red: ci:G1 — the policy requires `gates / <job>`; check runs are named by the bare job id (TB10) |
| P.merge | red: merge:G1 — no native queue on a user-owned repo, no first-party queue (TB9) |
| P.complete | pass |
| P.issue-closed | pass |
| P.lock-released | red: merge:G8c — nothing releases the lock after the merge (TB6) |
| C.mirror-ready | pass |
| C.claim | pass |
| C.fleet-preflight | red: node:G10 — main's .adlc/config.json has no fleet block (TB5) |
| C.node-tamper | pass |
| C.node-rails | pass |
| C.node-scope | pass |
| C.commit-shape | pass |
| C.pr-open | pass |
| C.claim-released | red: node:G3 — the lock is kept across the PR and the Issue stays `ready` (TB6) |
| C.tier-label | red: intake:I3 — the PR carries no tier label (TB8) |
| C.pr.context | pass |
| C.pr.identity | pass |
| C.i17-argv | pass |
| C.pr.build-test | pass |
| C.pr.rails-proof | pass |
| C.pr.scope | pass |
| C.pr.tamper | pass |
| C.pr.dependencies | pass |
| C.pr.commit-check | pass |
| C.pr.attest-verify | red: ci:G6 — attest-verify.sh is a stub, `attest-verify: not built` (TB11) |
| C.pr.required-checks | red: ci:G1 — the policy requires `gates / <job>`; check runs are named by the bare job id (TB10) |
| C.hold | red: merge:G3 — no `depends-on` job (TB8) |
| C.tier-order | red: merge:G5 — no `tier-order` job (TB8) |
| C.enqueue | red: merge:G4 — nothing enqueues a green PR (TB9) |
| C.mg.context | pass |
| C.mg.identity | pass |
| C.mg.build-test | pass |
| C.mg.rails-proof | pass |
| C.mg.scope | pass |
| C.mg.tamper | pass |
| C.mg.dependencies | red: ci:G1 — `if: pull_request` skips it on merge_group, so a required check never runs on the queue path (I18, TB10) |
| C.mg.commit-check | pass |
| C.mg.attest-verify | red: ci:G6 — attest-verify.sh is a stub, `attest-verify: not built` (TB11) |
| C.mg.required-checks | red: ci:G1 — the policy requires `gates / <job>`; check runs are named by the bare job id (TB10) |
| C.merge | red: merge:G1 — no native queue on a user-owned repo, no first-party queue (TB9) |
| C.complete | pass |
| C.issue-closed | pass |
| C.lock-released | red: merge:G8c — nothing releases the lock after the merge (TB6) |
| S.out-of-scope | pass |
| S.tamper-skip | pass |
| S.rail-edit | pass |
| S.no-trailer | pass |
| S.head-edits-gate | pass |
| S.base-script | pass |
| S.head-plants-base | pass |
| S.foreign-body | pass |
| S.ticket-ref-malformed | pass |
| S.fork-ticket-ref | pass |
| S.class-human | pass |
| S.stranger-refused | pass |
| S.ticket-adlc | pass |
| S.desk-pr | red: intake:I6 — no `desk` job in gates.yml (TB7) |
| S.class-desk | pass |
| S.child-before-parent | red: merge:G3 — no `depends-on` job (TB8) |
| S.tier-jump | red: merge:G5 — no `tier-order` job (TB8) |
| S.queue-conflict | red: merge:G7 — no ejection: no `autorebase` label, no ejections.jsonl (TB9) |
| S.foreign-trailer | pass |
| S.foreign-trailer-refused | pass |
| S.held-24h | red: merge:G8a — the janitor releases the 25 h lock and the Issue stays `ready` for a second build (TB6) |
| S.built-plus-claim | red: merge:G8b — the built PR's lock counts toward the slot; the new claim is cut `over-slots` (TB6) |
| S.class-halt-add | pass |
| S.halt-add | red: merge:G17 — adding HALT waits on `gates / <job>` contexts and one approval (TB10) |
| S.class-halt-remove | pass |
| S.halt-remove | red: ci:G11 — no `halt-guard` job; one approval would do (TB10) |
| gh.forms | pass |
