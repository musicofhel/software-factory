# TB2 — Gate context and ticket identity (ticket T21)

Sessions 5–6, 2026-10-26. Box: WSL2, Linux 6.18.33.2-microsoft-standard-WSL2. Base: `39d0518` (TB1 +
ledger). Nothing was pushed, and nothing touched GitHub, the repo's own store, `~/.factory` or the
network (I1, I19). Every world is a temp dir.

**State: done.** Fixes ci:G4, ci:G5, ci:G7, merge:G10 and node:G4 (the identity half).
`factory/bin/lib/gate-context.sh` resolves base, head, PR, ticket and PR class for every gate, on
`pull_request`, on `merge_group` and on the node. gates.yml runs every gate script from the **base**
checkout in `./.base`, against the PR head's checkout (I16). The sim's identity stages are green, and
`tests/sim/EXPECTED.md` is now 105 stages: 40 pass and 65 red.

## 1. What was built

| file | what |
|---|---|
| `factory/bin/lib/gate-context.sh` | New, executable. It can be sourced (`gate_context`, `gate_identity`, `gate_context_json`, `gate_begin`) or run, in which case it prints the context JSON. Exit 0 = resolved, 2 = refused, 1 = operational error. |
| `factory/bin/lib/common.sh` | `valid_ticket_id` refuses `/`, because the id is one segment of `ticket/<id>/<handle>` (ci:G7). |
| `factory/bin/{rails-proof,scope-check,commit-check,attest-verify}.sh` | Each still a stub (TB3, TB4, TB11). Each now sources gate-context and calls `gate_begin "$@"` first, then exits 2 `not built`. run.sh's node call (`--ticket --base --head`) keeps its `not built` contract. |
| `.github/workflows/gates.yml` | A workflow `env` with `GATE_BASE`/`GATE_HEAD` from the event (`pull_request.base/head.sha` or `merge_group.base_sha/head_sha`). A new `context` job. Each script job checks out the head (`ref: GATE_HEAD`, fetch-depth 0), then the base into `.base`, then runs `./.base/factory/bin/…` with `GH_TOKEN: github.token` (read-only: `contents: read`, `pull-requests: read`). The `--base origin/main` arguments are gone (ci:G4). |
| `tests/test_gate_context.sh` | New: 11 cases, 100 checks (§5). |
| `tests/fixtures/events/` | GitHub's own example payloads, byte for byte: `pull_request` opened and synchronize, and `merge_group` checks_requested. They come from octokit/webhooks `aa80c24`, which is what docs.github.com's webhook pages render. A README gives the source URLs and sha256 values, and the suite checks the hashes. |
| `tests/fakes/gh` | `api GET pulls/<n>`, the REST pull-request object. `author_association` comes from `.collaborators` (OWNER for the repo owner, NONE otherwise), and `head.repo.full_name` comes from `headRepository` for a fork. The form is listed in `__forms`. |
| `tests/sim/sim.sh` | `pr_event` builds `.pull_request` from the fake's GET pulls/<n>, the object GitHub's event carries. `ctx_of`/`ctx_is` read the `context` job's JSON. New stages: `X.pr.identity` and `X.mg.identity`. |
| `tests/sim/lib/driver.sh` | The `actions/checkout` emulation empties a non-repo target dir before it checks out there, as v4 does (§3). |
| `tests/sim/lib/world.sh` | The fake gh state lists the collaborators (`dev-box-owner`, `node-b-owner`, `desk`). |
| `tests/sim/lib/scenarios.sh` | New scenarios: `S.base-script`, `S.head-plants-base`, `S.foreign-body`, `S.ticket-ref-malformed`, `S.fork-ticket-ref`, `S.class-human`, `S.stranger-refused`, `S.class-desk`, `S.foreign-trailer-refused`, `S.class-halt-add`, `S.class-halt-remove`. |
| `tests/sim/EXPECTED.md` | +19 stages, all `pass`. `S.head-edits-gate` is relabeled (§4). |

Every file is inside T21's scope globs.

## 2. Decisions

1. **A `context` job.** gates.yml runs the base's `gate-context.sh` on both events and prints the
   JSON, and the sim's `X.pr.identity`/`X.mg.identity` stages judge that output. The job reports on
   `pull_request` and on `merge_group` and has no `if:`, so under I18 it will be a required check.
   TB10 owns the branch-protection policy, and adding it there is a desk note (I15: `factory/policy/**`).
2. **The classes.** The rules are checked in this order:
   - `ticket`: the head ref is `ticket/<id>/<handle>` and the head repo is the base repo. A fork's
     ticket-named ref is refused (exit 2).
   - Every other PR must have `author_association` OWNER, MEMBER or COLLABORATOR, or it is refused.
     That keeps the spec's four classes exactly, and a stranger gets no class a gate could wave
     through.
   - `halt`: the BASE...HEAD name-status is exactly `A` or exactly `D` of `factory/HALT`. An edit
     (`M`) is `human`.
   - `desk`: every changed path is under `.adlc/` or `docs/adr/`. SPEC-v0.2 L408–410 says the
     contract desk owns the store, and L471 says desk disagreements are ADRs in `docs/adr/`. An empty
     diff is `human`.
   - `human`: any other collaborator PR.
   - A ref under `ticket/` that does not parse (an extra `/`, a bad id or handle) is refused and is
     never read as `human`.
3. **Identity.** A `ticket` PR's body must carry a `Ticket:` line. Every such line, and every
   `Ticket:` trailer in BASE..HEAD, must equal the branch's id; the first id that differs is named
   and the PR is refused. A missing trailer is commit-check's job (TB4), not this check's. The node
   mode checks the trailers only, because there is no body yet. Node mode is chosen by the flags
   `--ticket/--base/--head`, which win over the GITHUB_* variables. Without `--base`, node mode uses
   `merge-base(origin/main, HEAD)`, never a lapsed tip (node:G5's rule; TB3 wires run.sh to it).
4. **merge_group.** The PR number comes from `gh-readonly-queue/<base>/pr-<N>-<40 hex>`, with or
   without `refs/heads/`. The PR object comes from `gh api repos/$REPO/pulls/$N`, a GET on the job's
   read-only token, and its `.number` must echo N. A group holding several PRs would carry their
   trailers too, so the queue must keep the group size at 1. TB9 already plans this (first-party
   serial queue, or native build and merge size 1).
5. **Head and base checkouts.** A gate job checks out the PR head (`GATE_HEAD`), not
   `refs/pull/N/merge`, so BASE...HEAD never contains GitHub's synthetic merge commit (ci:G4, merge:G10).
6. **Left to later rows.** These are recorded here so nobody reads them as an I16 hole that this row
   left open:
   - `build-test` still runs the head's `make test`. TB5 makes it run the base config's gate
     commands.
   - `tamper` still runs `pipx run tamperguard==0.2.0 --base origin/main` (ci:G2). TB3 moves it onto
     `diff-gates.sh` from `.base`.
   - Neither job runs a `factory/bin` script today. The unit suite asserts that no gate step runs the
     head's `factory/bin`.
7. **`S.head-edits-gate` stays red, relabeled** from `ci:G5 (TB2)` to
   `ci:G6 … (TB3)`. The base's scope-check now runs, which is I16 holding, but it is a stub and
   cannot yet name `docs/outside.md`. `S.base-script` judges the I16 rule itself on the same PR: the
   scope job's log shows the gate ran from `…/.base`, and the job failed.

## 3. Measured this row

- **actions/checkout v4 empties a non-repo target dir before it checks out there.** Source: commit
  `11d5960`, `src/git-directory-helper.ts:26-31,116-124`. This means that a PR head which commits its
  own `.base/factory/bin/scope-check.sh` (`exit 0`) has it deleted before the base lands in `.base`.
  The sim driver now does the same, and `S.head-plants-base` is the scenario. Red proof C (§5) shows
  that without the wipe the planted `exit 0` runs and the scope job goes green.
- **GitHub's payload shapes** (the fixtures): `pull_request` carries
  `.pull_request.{number, base.sha, head.sha, head.ref, head.repo.full_name, user.login,
  author_association, body}`. `merge_group` carries `.merge_group.{base_sha, head_sha, head_ref}` and
  no PR object. Its `head_ref` is `refs/heads/gh-readonly-queue/main/pr-<N>-<sha>`, with the
  `refs/heads/` prefix.
- **The `BASH_REMATCH` footgun.** `valid_ticket_id`'s own `=~` overwrites the caller's capture
  groups, so `gc_ticket_ref` copies them into locals first. The bug was real, it was found while
  writing this row, and the `classes` case covers it.

## 4. Stage table delta (tests/sim/EXPECTED.md)

The table goes from 86 stages (21 pass, 65 red) to **105 stages (40 pass, 65 red)**.
- **New, all `pass` (19):**
  - `P/C.pr.context`, `P/C.mg.context`, `P/C.pr.identity`, `P/C.mg.identity` (8)
  - `S.base-script`, `S.head-plants-base`, `S.foreign-body`, `S.ticket-ref-malformed`,
    `S.fork-ticket-ref`, `S.class-human`, `S.stranger-refused`, `S.class-desk`,
    `S.foreign-trailer-refused`, `S.class-halt-add`, `S.class-halt-remove` (11)
- **Relabeled, still red:** `S.head-edits-gate`, `ci:G5 (TB2)` → `ci:G6 (TB3)` (§2.7).
  - `S.foreign-trailer` stays `red: merge:G11 (TB4)`. It judges post-merge, which still completes
    the foreign id once the stand-in merges the PR.
  - Its new sibling `S.foreign-trailer-refused` proves that the ticket gates now refuse that PR on
    `pull_request`.
- No other red line changed. The `ci:G6` stub lines stay red: the stubs resolve the context and then
  exit 2.

## 5. Tests and red proofs

`tests/test_gate_context.sh` has 11 cases and 100 checks, all PASS:
- `fixtures-are-githubs`: the sha256 values match the fixture README.
- `pull-request-ticket`: the opened and synchronize payloads.
- `merge-group`: PR N from the queue ref, ticket and class from PR N's head ref with exactly one
  read (`gh api repos/<repo>/pulls/N`), a body naming another ticket, a head_ref outside
  `gh-readonly-queue` (exit 2), and an unreadable PR (exit 1, never a pass).
- `queue-ref-parse`: with and without `refs/heads/`, a base with a `/` (`release/v1`), `pr-0`, a
  short sha, no sha, a non-numeric N, a ticket ref, `main`.
- `classes`: desk (`.adlc/` alone, and with an ADR), halt add, halt remove, a HALT edit (human),
  HALT plus another file (human), a docs PR (human), a desk path plus `factory/bin` (human), an
  empty diff (human), OWNER and MEMBER desk PRs.
- `refusals`: a stranger (NONE) and a CONTRIBUTOR on non-ticket refs, a fork's ticket ref (a
  stranger's and a collaborator's), and five malformed `ticket/` refs (an extra segment, no handle,
  an empty id, a flag-like id, a bad handle).
- `identity`: a CRLF body plus trailers naming the id (pass), two body lines naming it (pass), a
  body naming T21, a second body line naming T21, a body with no `Ticket:` line, a trailer naming
  another id (the commit is named), no trailer at all (pass: TB4's), and a desk PR with ticket
  trailers (class desk, pass).
- `node`: the default base = merge-base with origin/main, explicit `--base/--head` win (a lapsed
  base), flags win over `GITHUB_EVENT_NAME`, no `--ticket` and no event (exit 1), an id with `/`
  (exit 2), and a foreign trailer (exit 2).
- `id-validator`: `T20/x` and the old `gh:owner/repo#12` are refused.
- `gate-stubs`: all four stubs resolve the context first, refuse a body naming T21 before the gate
  body runs, and keep run.sh's `not built` contract.
- `gates-yml-base-scripts`: no step runs the head's `factory/bin`. Each script job checks out the
  head and then the base into `.base`, has no `if:`, and uses the event's base and head shas.

**Red proofs.** Outputs are in `specs/factory-step3-v1/.spec-loop/tb2/`, which is gitignored and
node-local.
- **A, the old code with the new tests** (`tb2-redA-*.out`): the unit suite fails 10 of 11 cases.
  Only `fixtures-are-githubs` passes, because it reads no code. The sim regresses every new stage,
  and there is no `*.context` job.
- **B, the new code with only gates.yml reverted to `39d0518`** (`tb2-redB-*.out`, and
  `s6-redB-plant.out` re-run after `S.head-plants-base` was added):
  - The unit suite fails only `gates-yml-base-scripts`.
  - The sim exits 2, and 15 stages regress: all four identity stages, `S.base-script`,
    `S.head-plants-base`, and every `S.class-*`/refusal scenario.
  - `S.base-script` reads `scope: success`, so the head's `exit 0` copy ran. The `.base` checkout is
    what makes I16 hold.
- **C, the new code with only the driver's checkout wipe removed** (`s6-redC-nowipe.out`): the sim
  exits 2 with exactly one regression, `S.head-plants-base is red (scope: success …)`. The planted
  `.base/factory/bin/scope-check.sh` ran. The scenario depends on actions/checkout's wipe, which is
  measured in §3.

## 6. Timings (this box, with five jobs running at once)

| run | wall |
|---|---|
| `tests/test_gate_context.sh` | 1.9 s |
| `sim.sh --adlc fake` | 1 min 46 s (alongside `make test`, the real sim and two red-proof sims) |
| `sim.sh --adlc real` | 4 min 3 s (alongside the others) |
| `make test` (18 suites) | 3 min 41 s (alongside the sims; 17 suites + test_gate_context.sh) |
| `make lint` | 12 s |

## 7. Gates

All from session 6, against the final tree (`s6-*.out`):
- `make lint` exit 0.
- `make test` exit 0, with 18 suites PASS, including `tests/test_gate_context.sh` and
  `tests/test_sim.sh`.
- `sim.sh --adlc real` (real `@adlc/cli` 1.12.0) exit 0.
- `sim.sh --adlc fake` exit 0.
- Both sim modes match EXPECTED.md: 105 stages, 40 pass and 65 red.
