# factory/ledger

`findings.jsonl`: one line per verifier-confirmed prosecution finding, appended by the
post-merge CI job. Input to the weekly distill (`lesson-foundry`). Never prompts, file
contents or session text: ticket id, PR, adapter that prosecuted, finding category,
severity, confidence, reproduction locator, fix ticket id, strikes, token counts.

`ejections.jsonl`: one line per ticket PR the merge queue ejected (`factory/bin/eject.sh`,
specs/factory-step3-v1 TB9, docs/adr/0007-merge-queue.md), appended on main by the queue's
App-token commit (trailers `Ejected: #<pr>`, `Assisted-by: none`, `Node: github-actions`, no
`Ticket:`): `{at, pr, ticket, handle, issue, head, base, queue, reason, strike}` plus
`dequeued_reason` when GitHub's native queue removed the PR. `reason` is `conflict` (the PR does
not merge onto main) or `red-queue-run` (a gate failed on the queue commit); `strike` is 1 + the
ticket's earlier lines. run.sh reads the ticket's last line on the next claim (the Issue's
`rebase-strike` label) to rebase the ejected commit; the digest reads the file later (step 4).
Ids, codes and shas only.
