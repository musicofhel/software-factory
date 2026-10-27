# EXPECTED — the stage results of `make sim` (tests/sim/sim.sh)

Every stage judges the **desired** behavior of the pipeline (specs/factory-step3-v1/SPEC.md): `pass`
means the pipeline did the right thing, `red: <gap id>` that it does not yet, with the gap of
`specs/factory-step3-v1/records/sim/*.md` that explains it and the row that fixes it. After a red
stage the sim plays a labeled stand-in (`stand-in:` in sim.log) so the later stages stay observable.
The queue's stand-ins: a repo admin's merge for the scenario merges that are no queue's, GitHub's
own native merge queue (the group, its merge_group run, its merge and its dequeue) in the native
scenarios, and the App unset for S.tier-jump's two PRs (a real configuration: enqueue runs
`--dry-run`), so the approved, green tier-0 PR is not landed by the queue inside its own event before
the tier-1 PR is judged. Since TB11 (ticket T30) attest-verify is real and no gate has a green
stand-in: every ticket PR the sim opens carries its attest note (the walk's from run.sh, the
scenarios' from lib/scenarios.sh `scn_attest`), and lib/driver.sh's SIM_STANDIN_GREEN is unused.
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
`.attest-note` = origin holds the node's attest note on the PR head, with its ticket, node, base,
head, tests run and passing verdicts (ADR-0007 decision 9); `.i17-argv` = the node's `diff-gates:` trace lines and tamperguard argv equal those of the PR's
`rails-proof`, `scope` and `tamper` jobs on the same base...head); `S.*` are the failure scenarios
(lib/scenarios.sh), each judged on the gate that should stop it naming its own reason, and `S.class-*`
on the class the `context` job gave the PR; `gh.forms` = no script called a `gh` form the fake gh does
not model.

| stage | expected |
|---|---|
| world.seed | pass |
| janitor.no-nodes | pass |
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
| P.attest-note | pass |
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
| P.pr.owners | pass |
| P.pr.halt-guard | pass |
| P.pr.attest-verify | pass |
| P.pr.flaky | pass |
| P.pr.required-checks | pass |
| P.hold | pass |
| P.tier-order | pass |
| P.enqueue | pass |
| P.q.context | pass |
| P.q.build-test | pass |
| P.q.rails-proof | pass |
| P.q.scope | pass |
| P.q.tamper | pass |
| P.q.dependencies | pass |
| P.q.commit-check | pass |
| P.q.depends-on | pass |
| P.q.tier-order | pass |
| P.q.desk | pass |
| P.q.owners | pass |
| P.q.halt-guard | pass |
| P.q.attest-verify | pass |
| P.q.flaky | pass |
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
| C.attest-note | pass |
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
| C.pr.owners | pass |
| C.pr.halt-guard | pass |
| C.pr.attest-verify | pass |
| C.pr.flaky | pass |
| C.pr.required-checks | pass |
| C.hold | pass |
| C.tier-order | pass |
| C.enqueue | pass |
| C.q.context | pass |
| C.q.build-test | pass |
| C.q.rails-proof | pass |
| C.q.scope | pass |
| C.q.tamper | pass |
| C.q.dependencies | pass |
| C.q.commit-check | pass |
| C.q.depends-on | pass |
| C.q.tier-order | pass |
| C.q.desk | pass |
| C.q.owners | pass |
| C.q.halt-guard | pass |
| C.q.attest-verify | pass |
| C.q.flaky | pass |
| C.q.identity | pass |
| C.merge | pass |
| C.merged-mark | red: kit: GitHub marks the PR merged once its head is reachable from main, but its merge_commit_sha then is undocumented; post-merge needs it equal to the queue commit (TB12) |
| C.complete | pass |
| C.issue-closed | pass |
| C.lock-released | pass |
| S.out-of-scope | pass |
| S.tamper-skip | pass |
| S.attest-mismatch | pass |
| S.attest-missing | pass |
| S.rail-edit | pass |
| S.no-trailer | pass |
| S.head-edits-gate | pass |
| S.base-script | pass |
| S.head-plants-base | pass |
| S.foreign-body | pass |
| S.ticket-ref-malformed | pass |
| S.fork-ticket-ref | pass |
| S.class-human | pass |
| S.quarantine-expired | pass |
| S.stranger-refused | pass |
| S.ticket-adlc | pass |
| S.head-edits-gate-config | pass |
| S.desk-pr | pass |
| S.class-desk | pass |
| S.desk-chain-race | pass |
| S.desk-stale-base | pass |
| S.desk-no-records | pass |
| S.child-before-parent | pass |
| S.tier-jump | pass |
| S.queue-conflict | pass |
| S.rebase-strike | pass |
| S.queue-red | pass |
| S.native-enqueue | pass |
| S.native-merge | pass |
| S.native-dequeue | pass |
| S.foreign-trailer | pass |
| S.foreign-trailer-refused | pass |
| S.held-24h | pass |
| S.child-released | pass |
| S.built-plus-claim | pass |
| S.class-halt-add | pass |
| S.halt-add | pass |
| S.class-halt-remove | pass |
| S.halt-remove | pass |
| S.halt-remove-two | pass |
| gh.forms | pass |
