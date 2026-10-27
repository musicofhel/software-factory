# EXPECTED — the stage results of `make sim` (tests/sim/sim.sh)

Every stage judges the **desired** behavior of the pipeline (specs/factory-step3-v1/SPEC.md): `pass`
means the pipeline did the right thing, `red: <gap id>` that it does not yet, with the gap of
`specs/factory-step3-v1/records/sim/*.md` that explains it and the row that fixes it. After a red
stage the sim plays a labeled stand-in (`stand-in:` in sim.log) so the later stages stay observable.
The queue's stand-ins: GitHub's view of the `attest-verify` stub as green (SIM_STANDIN_GREEN, the
walk and the queue scenarios only, so a PR can reach the queue; jobs.jsonl keeps its real failure),
a repo admin's merge for the scenario merges that are no queue's, and GitHub's own native merge
queue (the group, its merge_group run, its merge and its dequeue) in the native scenarios.
`tests/sim/lib/compare.sh` compares this table with the results in both directions: a stage that
goes green before its line here says `pass` fails the sim as much as a regression does. The row that
fixes a gap flips its lines in the same commit. A stage only GitHub
itself can prove is `red: kit: <line>` (TB12), never `pass`.

Stage names: `world.*`, `desk.*`, `push.*`, `janitor.*` are the setup; `P.*` is T-sim-parent's path
and `C.*` T-sim-child's (`.pr.<job>` = the job on pull_request, `.q.<job>` = on the first-party serial
queue's commit (enqueue.yml calls gates.yml), one line per job the driver ran from the YAML;
`.identity` = the `context` job resolved this PR's number, ticket, class, base and head, on the queue
from the caller's inputs; `.enqueue` = enqueue.yml's `pick` built the queue commit, `.merge` = `land`
pushed it to main; `.node-tamper`, `.node-rails`,
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
| P.mirror-ready | pass |
| C.mirror-blocked | pass |
| C.depends-link | pass |
| P.claim | pass |
| P.fleet-preflight | pass |
| P.node-tamper | pass |
| P.node-rails | pass |
| P.node-scope | pass |
| P.commit-shape | pass |
| P.pr-open | pass |
| P.claim-released | pass |
| P.tier-label | pass |
| P.pr.context | pass |
| P.pr.identity | pass |
| P.i17-argv | pass |
| P.pr.build-test | pass |
| P.pr.rails-proof | pass |
| P.pr.scope | pass |
| P.pr.tamper | pass |
| P.pr.dependencies | pass |
| P.pr.commit-check | pass |
| P.pr.depends-on | pass |
| P.pr.tier-order | pass |
| P.pr.desk | pass |
| P.pr.attest-verify | red: ci:G6 — attest-verify.sh is a stub, `attest-verify: not built` (TB11) |
| P.pr.required-checks | red: ci:G1 — the policy requires `gates / <job>`; check runs are named by the bare job id (TB10) |
| P.hold | pass |
| P.tier-order | pass |
| P.enqueue | pass |
| P.q.context | pass |
| P.q.build-test | pass |
| P.q.rails-proof | pass |
| P.q.scope | pass |
| P.q.tamper | pass |
| P.q.dependencies | red: ci:G1 — `if: pull_request` skips it on the queue path (a called workflow sees the caller's event), so a required check never runs there (I18, TB10) |
| P.q.commit-check | pass |
| P.q.depends-on | pass |
| P.q.tier-order | pass |
| P.q.desk | pass |
| P.q.attest-verify | red: ci:G6 — attest-verify.sh is a stub, `attest-verify: not built`; GitHub's view of it is the sim's labeled stand-in (TB11) |
| P.q.identity | pass |
| P.merge | pass |
| P.merged-mark | red: kit: GitHub marks the PR merged once its head is reachable from main, but its merge_commit_sha then is undocumented; post-merge needs it equal to the queue commit (TB12) |
| P.complete | pass |
| P.issue-closed | pass |
| P.lock-released | pass |
| C.mirror-ready | pass |
| C.claim | pass |
| C.fleet-preflight | pass |
| C.node-tamper | pass |
| C.node-rails | pass |
| C.node-scope | pass |
| C.commit-shape | pass |
| C.pr-open | pass |
| C.claim-released | pass |
| C.tier-label | pass |
| C.pr.context | pass |
| C.pr.identity | pass |
| C.i17-argv | pass |
| C.pr.build-test | pass |
| C.pr.rails-proof | pass |
| C.pr.scope | pass |
| C.pr.tamper | pass |
| C.pr.dependencies | pass |
| C.pr.commit-check | pass |
| C.pr.depends-on | pass |
| C.pr.tier-order | pass |
| C.pr.desk | pass |
| C.pr.attest-verify | red: ci:G6 — attest-verify.sh is a stub, `attest-verify: not built` (TB11) |
| C.pr.required-checks | red: ci:G1 — the policy requires `gates / <job>`; check runs are named by the bare job id (TB10) |
| C.hold | pass |
| C.tier-order | pass |
| C.enqueue | pass |
| C.q.context | pass |
| C.q.build-test | pass |
| C.q.rails-proof | pass |
| C.q.scope | pass |
| C.q.tamper | pass |
| C.q.dependencies | red: ci:G1 — `if: pull_request` skips it on the queue path (a called workflow sees the caller's event), so a required check never runs there (I18, TB10) |
| C.q.commit-check | pass |
| C.q.depends-on | pass |
| C.q.tier-order | pass |
| C.q.desk | pass |
| C.q.attest-verify | red: ci:G6 — attest-verify.sh is a stub, `attest-verify: not built`; GitHub's view of it is the sim's labeled stand-in (TB11) |
| C.q.identity | pass |
| C.merge | pass |
| C.merged-mark | red: kit: GitHub marks the PR merged once its head is reachable from main, but its merge_commit_sha then is undocumented; post-merge needs it equal to the queue commit (TB12) |
| C.complete | pass |
| C.issue-closed | pass |
| C.lock-released | pass |
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
| S.head-edits-gate-config | pass |
| S.desk-pr | pass |
| S.class-desk | pass |
| S.desk-chain-race | pass |
| S.desk-stale-base | pass |
| S.desk-no-records | pass |
| S.child-before-parent | pass |
| S.tier-jump | red: ci:G6 — attest-verify.sh is a stub, so no PR is ever green and tier-order has nothing to wait for (TB11; the scenario's PR_A then also needs its attest note) |
| S.queue-conflict | pass |
| S.rebase-strike | pass |
| S.queue-red | pass |
| S.native-enqueue | pass |
| S.native-merge | red: ci:G1 — the policy requires `gates / <job>`; check runs are named by the bare job id, so the merge group never reports green (TB10) |
| S.native-dequeue | pass |
| S.foreign-trailer | pass |
| S.foreign-trailer-refused | pass |
| S.held-24h | pass |
| S.child-released | pass |
| S.built-plus-claim | pass |
| S.class-halt-add | pass |
| S.halt-add | red: merge:G17 — adding HALT waits on `gates / <job>` contexts and one approval (TB10) |
| S.class-halt-remove | pass |
| S.halt-remove | red: ci:G11 — no `halt-guard` job; one approval would do (TB10) |
| gh.forms | pass |
