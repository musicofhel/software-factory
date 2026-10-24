# House rules (printed by the join wizard)

1. Agents sign every commit and PR with `handle`, ticket id, `Assisted-by:` and
   `Signed-off-by:` trailers.
2. One ticket, one branch, one PR. Out-of-scope fixes become new desk requests, not
   drive-bys.
3. Claims expire. Do not re-claim a ticket you just lost without reading its comments.
4. Post your spend. The PR body carries strikes used and tokens if the adapter reports
   them. The number is for the group to see where quota goes, not a leaderboard.
5. Bots do not open discussions, mention humans, or comment on each other's PRs. Humans
   talk; agents report.
6. Taking your box offline for more than a day: run `/factory:release` first.
7. Provider terms are each contributor's own responsibility; `CONTRIBUTING.md` says so and
   nothing in the factory depends on a particular reading of them.

The kill switch is `factory/HALT` on `main`. Present means every loop sleeps 30 minutes
and checks again. Anyone with write access adds it with a one-line PR that needs no
review; removing it needs two approvals.
