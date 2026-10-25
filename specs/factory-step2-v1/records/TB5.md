# TB5 — Step-1 rulings and follow-ups in code (ticket T10)

Session 9, 2026-10-25. No prep existed for this row (`specs/factory-step2-v1/prep/` is absent).

Files (all inside T10's scope globs, `jq -c .scope .adlc/tickets/t10--*.json`):
`factory/bin/revoke-collaborator.sh` (new), `factory/bin/janitor.sh`, `factory/bin/post-merge.sh`,
`factory/bin/apply-branch-protection.sh`, `factory/RULES.md`, `.github/workflows/janitor.yml`,
`.github/workflows/post-merge.yml`, `tests/test_revoke.sh` (new), `tests/test_janitor.sh`,
`tests/test_halt_rules.sh`, `tests/test_post_merge.sh`. `tests/fakes/gh` is **not** in T10's scope, so
the collaborators API is a shim inside `tests/test_revoke.sh` (and a 3-line one in the janitor case),
as TB4 did for `pr create`. An earlier draft that extended the fake was reverted before commit.

## 1. Acceptance criteria → code → cases

| AC | code | cases (all PASS) |
|---|---|---|
| 1 revoke: dry run calls nothing and prints the call; `--apply` exactly one DELETE; CODEOWNERS owner → exit 2 | `revoke-collaborator.sh` | test_revoke.sh `dry-run` (0 gh calls; the printed line, piped to bash, is the removal), `apply-one-delete` (log = `[["api","-X","DELETE","repos/test/repo/collaborators/bob"]]`), `refusals` (code owner, case-blind `DAVE-x` vs `@dave-x`, repo owner, non-login, bad handle → 2 with 0 calls; no CODEOWNERS → 1; usage → 1; the repo's own CODEOWNERS refuses `musicofhel`), `apply-failure-and-token` (HTTP 500 → exit 1 `failed`; `REVOKE_GH_TOKEN` is the token the DELETE runs on), `shim-collaborators` |
| 1 wiring: janitor.yml `JANITOR_REVOKE_HOOK` | janitor.yml; janitor.sh splits the hook on blanks | test_janitor.sh `revoke-hook-wired`: reads the value out of janitor.yml (`./factory/bin/revoke-collaborator.sh --apply`), runs the janitor with it: r1 (owner bob) `done`, r2 (owner musicofhel, a code owner) `failed`, exit 1, exactly one DELETE (bob) |
| 2 apply-branch-protection with `FACTORY_APP_ID`: dry run prints the bypass actor, `--apply` sends it, unset → output unchanged | apply-branch-protection.sh | test_halt_rules.sh `app-bypass-actor` (16 checks): empty/unset output byte-identical (plain and `--json`); dry run prints `# bypass actor: GitHub App 987654 (Integration, always) on ruleset(s) main-merge-queue (FACTORY_APP_ID)` and the POST body carries `{"actor_id":987654,"actor_type":"Integration","bypass_mode":"always"}`; `--apply` lands it; second `--apply` sends nothing; non-numeric / 0 → exit 2 before any call; an App already in the policy is not listed twice |
| 3 post-merge's commit: three trailers, parseable by `git interpret-trailers --parse` | post-merge.sh | test_post_merge.sh `trailers`: `--parse` = `Through: <head>` / `Assisted-by: none` / `Ticket: post-merge` / `Node: github-actions`; no Signed-off-by; the next run reads its own commit, reports only T3, never asks the store about `post-merge` |
| 4 ready duty compares open ids only | janitor.sh `ready_pass` | test_janitor.sh `ready-open-only` (8 checks): a completed T3 in `ticket list` is not in the set (no recompute); every id read with `ticket show --json`; completing T2 → recompute, `removed: ["T2"]`, saved `["T1"]`; next run no-op; a failed `ticket show` → `failed`, exit 1, set kept. `ready-recompute` updated for the extra `ticket show` calls |
| 5 actionlint clean; App-token action pinned by 40-hex sha (grep case) | both workflows | `make lint` (actionlint via uvx) exit 0; test_post_merge.sh `workflow` (14 checks): every `create-github-app-token@` use in post-merge.yml and janitor.yml matches `@[0-9a-f]{40} # vX.Y.Z`, same sha in both, App step gated on `FACTORY_APP_ID` + `HAS_APP_KEY`, checkout token `steps.app.outputs.token \|\| github.token`, fallback summary line, `permission-contents: write` only |
| 6 shellcheck -S warning clean | all | `make lint` exit 0 |

Follow-up 2's second half: `factory/RULES.md` gains "Commit-check exemption (for build order step 3)":
exempt exactly the four-trailer shape, the post-merge identity, and a diff limited to `.adlc/` and
`factory/ledger/`.

## 2. Gates

```
$ make test     → 14 files PASS (test_revoke.sh new), exit 0
$ make lint     → exit 0 (shellcheck -S warning over factory/ + tests/, actionlint over .github/workflows)
```

Mutations (each applied alone, the named test run, then restored):

| mutation | caught by |
|---|---|
| janitor counts every listed id (open filter removed) | `ready-open-only` |
| janitor calls the hook as one word (no split) | `revoke-hook-wired` |
| CODEOWNERS refusal removed | `refusals` |
| case-sensitive owner match | `refusals` |
| dry run makes a gh read | `dry-run`, `apply-one-delete` |
| comments not stripped from CODEOWNERS | `dry-run`, `apply-one-delete`, `apply-failure-and-token` |
| repo-owner refusal removed | `refusals` |
| `REVOKE_GH_TOKEN` ignored | `apply-failure-and-token` |
| bypass actor not added | `app-bypass-actor` |
| post-merge trailers dropped | `trailers` |
| post-merge self-skip removed | `range-since-marker`, `completion-failure`, `trailers` |
| action pinned by tag `@v3` | `workflow` |
| checkout always on `github.token` | `workflow` |

## 3. The pin (read-only `gh api`, allowed by I1)

```
$ gh api repos/actions/create-github-app-token/releases/latest --jq '{tag: .tag_name, published: .published_at, prerelease, draft}'
{"draft":false,"prerelease":false,"published":"2026-10-12T23:42:23Z","tag":"v3.3.0"}
$ gh api repos/actions/create-github-app-token/git/ref/tags/v3.3.0 --jq .object
{"sha":"64ab729a6294000f5aa4a4bc0b73d1f32bc45510","type":"commit",...}      (lightweight tag → commit)
$ gh api repos/actions/create-github-app-token/commits/64ab729a… --jq '{sha, date: .commit.committer.date, msg: …}'
{"date":"2026-10-12T23:42:07Z","msg":"chore(main): release 3.3.0 (#402)","sha":"64ab729a6294000f5aa4a4bc0b73d1f32bc45510"}
$ gh api 'repos/actions/create-github-app-token/contents/action.yml?ref=64ab729a…' --jq .content | base64 -d
  inputs: client-id; app-id (deprecationMessage: "Use 'client-id' instead."); private-key (required);
  permission-<name> per permission (permission-administration: "… collaborators creation"); outputs: token,
  installation-id, app-slug; runs: node24
$ … contents/main.js?ref=64ab729a… | grep -n 'app-id'
  21:  const clientId = core.getInput("client-id") || core.getInput("app-id");
```

The workflows pass `app-id: ${{ vars.FACTORY_APP_ID }}`. That input is deprecated at v3.3.0 but still
read (main.js:21), and the spec names `FACTORY_APP_ID`. A numeric App ID is also what the ruleset
bypass actor takes. The run prints a deprecation annotation. Moving to `client-id` would need a
second variable (the App's Client ID), which the kit does not have.

## 4. Docs read (WebFetch, docs.github.com, 2026-10-25)

- REST "Create a repository ruleset": `bypass_actors[]` = `{actor_id, actor_type ∈ Integration |
  OrganizationAdmin | RepositoryRole | Team | DeployKey | User, bypass_mode ∈ always | pull_request |
  exempt}`; "When the actor_type is Integration, the actor_id is required and must contain the specific
  ID of that integration instance." The first real `--apply` proves the App ID is accepted (due at first
  join, with the 422 measurement already listed in step 1).
- REST "Remove a repository collaborator": 204 on removal; "the authenticated user must either be an
  administrator of the repository or target themselves"; it also "Cancels any outstanding
  invitations". 403 and 422 are listed. The shim answers 204 for a non-collaborator because the docs
  do not say what GitHub returns.
- "About protected branches": classic protection's restrictions "do not apply to people with admin
  permissions" unless "Do not allow bypassing" (`enforce_admins`) is set. Commits must pass the required
  checks before they reach the branch.

## 5. Decisions

1. **The hook is a command line.** janitor.sh now splits `JANITOR_REVOKE_HOOK` on blanks (the
   `FACTORY_ADLC` idiom), so janitor.yml can say `./factory/bin/revoke-collaborator.sh --apply`. The
   janitor calls hooks only in `--apply` mode, so the script's `--apply` is safe there.
2. **Revoke runs on the App token.** Removing a collaborator needs repo admin (Administration: write
   for an App). GITHUB_TOKEN never has it. janitor.yml mints the App token with
   `permission-administration: write`, but only to the hook (`REVOKE_GH_TOKEN`). The janitor's own gh
   calls stay on GITHUB_TOKEN, so comments keep their `github-actions[bot]` author. With no App, the
   step summary says so and the revoke line fails ("revoke by hand"), which is honest.
3. **post-merge passes over its own commit silently.** The trailer `Ticket: post-merge` lands in the
   next run's range. Reporting it every run would be noise, and asking adlc about it would waste a
   call. It is dropped when the trailers are read.
4. **A configured App whose mint fails fails the job.** The GITHUB_TOKEN fallback runs only when the
   App step was skipped (`steps.app.outcome == 'skipped'`). A broken key must stay visible.
5. **The App token in post-merge asks for `contents: write` only.** post-merge.sh makes no gh call.
   The mirror job keeps `github.token`.
6. **CODEOWNERS refusal fails closed.** No CODEOWNERS file at all is exit 1. Teams are not expanded
   (a user-owned repo has none, and a dry run must not read). The repo's own owner is refused too.

## 6. Found here: the ruling Q6 bypass does not cover classic protection (carried to TB6 as a Q)

`factory/policy/branch-protection.json` puts required reviews, required status checks and
`enforce_admins: true` in **classic** branch protection, and only the merge queue in a ruleset. A
ruleset bypass actor bypasses rulesets only. Once `apply-branch-protection.sh --apply` runs,
post-merge's direct push on the App token is still refused by classic protection: the commit has no
review and has not passed the required checks. Today nothing is protected (register), so post-merge
works. The script now prints this as a `# NOTE:` (and `app_bypass.not_covered` in `--json`) on every
run with the App set. Fixing it means moving the classic rules into the ruleset as `pull_request`,
`required_status_checks`, `non_fast_forward` and `deletion` rules, where the bypass list applies. That
departs from step 1's TB2 policy design, so it is Aaron's call; TB6 puts it in a `### Q` block.

## 7. Due at first join (none can happen before; I1)

- The App ID accepted as a ruleset `bypass_actors` Integration id (first real `apply-branch-protection.sh --apply`).
- The App needs **Administration: write** besides contents/pull requests/issues write for the revoke hook
  (TB6 kit line).
- `create-github-app-token` minting on the hosted runner (first post-merge run after the kit).
- GitHub's answer to DELETE of a login that is not a collaborator (204 or 422; docs silent).
