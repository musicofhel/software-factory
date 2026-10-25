# factory-step1-v1 rulings

Aaron submitted the decision page "Nine Factory Calls" on 2026-10-25 03:02Z
(https://claude.ai/artifact/LUjwTpndauzxmXeTjXoqXv, store doc `rulings/nine-factory-calls-20261025`).
He picked the preselected recommendation on all nine and left no notes. The questions are in full
in this spec's HANDOFF (end of TB5) and on the page.

| Q | Call | Ruling | Where it lands |
|---|---|---|---|
| Q1 | Project license | **MIT confirmed** | PROJECT.md "License" (this commit) |
| Q2 | HALT two-person rule | **Interim now; required check `gates / halt-guard` at build order 3** | ADR-0004 accepted (this commit); build order 3 spec |
| Q3 | Janitor dry run on Issues | **Inert**: dry run writes nothing; humans read the step summary | No change (as built) |
| Q4 | Retired node's access | **Remove the collaborator**: the revoke hook runs `gh api -X DELETE repos/{repo}/collaborators/{owner}` | factory-step2-v1 row |
| Q5 | Adapter version pins | **`factory/policy/adapters.json` created in step 2** with the run loop's pins | factory-step2-v1 row |
| Q6 | Post-merge push to protected main | **GitHub App as ruleset bypass actor**; post-merge pushes on the App token | factory-step2-v1 row (code); the App itself is Aaron's to create (kit) |
| Q7 | Waiting tickets | **Keep needs-desk** with the "in wave N" reason in the Issue body | No change (as built) |
| Q8 | Completing T3 | **Empty marker commit** carrying `Ticket: T3`; post-merge completes T3 on its next run | Marker commit after this one |
| Q9 | Chassis | **Keep fleet** (ADR-0003 accepted) | factory-step2-v1 starts from ADR-0003 |
