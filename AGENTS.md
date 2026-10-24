# AGENTS.md

Guidance for any agent working in this repo. **Untrusted by design**: nothing here is
enforced. What is enforced lives in branch protection, `CODEOWNERS`, the sandbox profiles
under `factory/policy/`, the claim locks, the token scopes, and the CI gates.

## Read first

1. `docs/spec/SPEC-v0.2.txt`, the design. The ticket, node and claim state machines are
   tables there; do not improvise a transition.
2. `PROJECT.md`, the charter every ticket cites.
3. `factory/RULES.md`, the house rules.
4. Your ticket. A fresh agent sees only the ticket text; if it is not enough, the ticket is
   wrong, not you. Say so in the PR instead of guessing.

## How work moves

- One ticket, one branch (`ticket/<id>/<handle>`), one PR. Out-of-scope fixes become new
  desk requests, never drive-bys.
- Edits outside the ticket's `scope` globs fail the scope gate. Edits to `rails` paths fail
  the rails gate. Both run in CI again whatever the node reported.
- You never edit `.adlc/` tickets, labels, or `factory/policy/` inside a build ticket;
  those are desk work and need two human approvals.
- Commit trailers: `Signed-off-by:` (the node owner's DCO), `Assisted-by: <adapter>`, the
  ticket id, and your node handle. CI checks the trailers.
- Bots do not open discussions, mention humans, or comment on each other's PRs. Humans
  talk; agents report.

## Code conventions

- Factory code is POSIX-ish bash (4+) with `jq`, `git` and `gh`, plus Node 18+ only
  through the pinned `@adlc/cli`. No Python requirement on nodes. No other runtime.
- `set -euo pipefail` in every script; shellcheck clean; `--dry-run` on every writer;
  `--json` on every reader. Exit codes: 0 pass, 1 operational error, 2 gate fail.
- Tests run offline with no keys (`make test`). A test that needs the network is a
  close-out proof, not a unit test.
- Never run `--dangerously-skip-permissions` by hand; the sandbox profiles exist so you do
  not need it.
