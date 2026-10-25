# TB2 — Protection rules into the ruleset (ticket T13; ruling Q2)

Session 5, 2026-10-25. No prep existed for this row (`specs/factory-step2-followups-v1/prep/` is
absent). Nothing was pushed and nothing was written to GitHub (I1): the only `gh` calls against the
real repo were GETs (the read-only checks in §2 and a dry run in §5).

Commits: `e936374` (`Ticket: scaffold`: T13's scope gains `tests/fakes/gh`, §4) and the `Ticket: T13`
commit that carries this file.

## 1. What was built

Step-2 ruling Q2: "Move the classic rules into the ruleset, where the App bypass applies; post-merge
keeps its direct push" (`specs/factory-step2-v1/RULINGS.md`).

- `factory/policy/branch-protection.json`
  - One ruleset, renamed `main-merge-queue` → **`main`**, holds every rule on `main`: `deletion`,
    `non_fast_forward`, `pull_request` (1 approval, `require_code_owner_review`, `dismiss_stale_reviews_on_push`,
    no last-push approval, no thread resolution, matching what classic protection held), `required_status_checks`
    (the seven `gates / *` contexts, `strict_required_status_checks_policy: true`) and the unchanged `merge_queue`.
    `bypass_actors: []`.
  - `"protection": null`: classic protection keeps nothing. Mapping (in the policy's `_protection` note):
    `required_pull_request_reviews` → `pull_request`; `required_status_checks` → `required_status_checks`;
    `allow_force_pushes: false` → `non_fast_forward`; `allow_deletions: false` → `deletion`;
    `enforce_admins: true` → a ruleset's default (only `bypass_actors` bypass; there are none);
    `restrictions: null`, `required_linear_history: false`, `lock_branch: false` held nothing.
  - ADR-0004's HALT interim is restated in the ruleset's `_halt` note and in the `unexpressed` entry
    (one code-owner approval to add, one to remove, until `gates / halt-guard` at build order 3).
- `factory/bin/apply-branch-protection.sh`
  - `protection: null` plans `DELETE repos/{r}/branches/{branch}/protection` when GitHub has classic
    protection (action `delete`) and a noop `no classic branch protection on main` when it has none.
    The DELETE is printed and sent without a body.
  - Validation (exit 2, before any call) now covers the ruleset's insides, from GitHub's REST schema
    (§2): every rule type's parameters (unknown parameter, missing required parameter, parameters on a
    type that takes none), keys beside `type`/`parameters`, status-check entries (`context`,
    `integration_id`), `conditions` (`ref_name.include/exclude`), a missing top-level `protection` key.
  - A policy ruleset must name no bypass actor; the App from `FACTORY_APP_ID` is set as the **only**
    one (the body's `bypass_actors` is `[]` or `[App]`, so a hand-added admin bypass on GitHub is drift).
  - "Classic protection keeps nothing the ruleset covers" is checked: a `protection` object that
    duplicates an active policy ruleset's `pull_request`, `required_status_checks`, `non_fast_forward`
    or `deletion` is refused. `FACTORY_APP_ID` with any classic protection in the policy is refused,
    because a ruleset bypass does not lift it.
  - The `# NOTE: not covered by the bypass: classic branch protection …` line and the JSON
    `app_bypass.not_covered` field are gone: the case cannot exist any more.
  - `canon` also sorts by `context`, so GitHub listing status checks in another order is not drift.
- `tests/fakes/gh`: `DELETE branches/<b>/protection` (204, no output; 404 `Branch not protected`).
- `tests/test_halt_rules.sh`: 8 cases, 98 checks (was 7 cases). New case `classic-protection-removed`;
  `refuses-made-up-fields` gained 10 refusal cases, each asserting exit 2, no gh call, and the message.
- `docs/adr/0004-halt-two-person-rule.md`: an "Update (2026-10-25, step-2 ruling Q2, ticket T13)"
  section. The interim stands; new fact recorded: the App, as the only bypass actor, can push
  `factory/HALT` without review (only post-merge holds its token).

## 2. Schema source (field names only from GitHub's REST ruleset schema)

- Docs page read: https://docs.github.com/en/rest/repos/rules?apiVersion=2022-11-28#create-a-repository-ruleset
  (body: `name`, `target`, `enforcement`, `bypass_actors`, `conditions`, `rules`; `pull_request`,
  `required_status_checks`, `merge_queue` parameters; `non_fast_forward`/`deletion` take none).
- Machine-readable: `github/rest-api-description` main `755ee33b4a81` (`git ls-remote`, 2026-10-25),
  `descriptions/api.github.com/api.github.com.json` (info.version 1.1.4, sha256 prefix `3177ad6a86ca04c5`):
  `components.schemas["repository-rule"].oneOf` and each `repository-rule-*` schema's
  `parameters.required`/`properties` became the script's `RULE_PARAMS` table verbatim (25 types);
  `repository-rule-params-status-check-configuration` = `{context (required), integration_id}`;
  `repos/create-repo-ruleset` body keys `bypass_actors, conditions, enforcement, name, rules, target`;
  `repos/delete-branch-protection` (DELETE …/branches/{branch}/protection) answers 204.

```
$ jq -c '.components.schemas["repository-rule-pull-request"].properties.parameters.required' api.github.com.json
["dismiss_stale_reviews_on_push","require_code_owner_review","require_last_push_approval","required_approving_review_count","required_review_thread_resolution"]
$ jq -c '.components.schemas["repository-rule-required-status-checks"].properties.parameters.required' api.github.com.json
["required_status_checks","strict_required_status_checks_policy"]
```

Real-repo state, read only (why renaming the ruleset is safe — nothing was ever applied):

```
$ gh api repos/musicofhel/software-factory/rulesets                      → []
$ gh api repos/musicofhel/software-factory/branches/main/protection      → gh: Branch not protected (HTTP 404)
$ gh api repos/musicofhel/software-factory --jq .owner.type              → User
```

## 3. Acceptance (T13)

| # | criterion | evidence |
|---|---|---|
| 1 | dry run prints every call, the ruleset carrying the moved rules | `dry-run-prints-calls`: one POST, rule types `[deletion, non_fast_forward, pull_request, required_status_checks, merge_queue]`, parameters checked; the printed commands run through `bash` produce the same state as `--apply`; `classic-protection-removed`: the DELETE is printed |
| 2 | second `--apply` makes no write | `dry-run-prints-calls`, `classic-protection-removed`, `app-bypass-actor`: `fakegh_calls WRITES` = 0 |
| 3 | unknown field in the ruleset → exit 2 | `refuses-made-up-fields`: `path_filter`, `halt_on_deletion`, `require_code_owner_reviews` (the classic name inside `pull_request`), missing `require_last_push_approval`, parameters on `deletion`, `{contexts}` status check, `on` beside `type`, `conditions.path`, a policy bypass actor, no `protection` key, the old classic body beside the ruleset |
| 4 | App the only bypass actor, no NOTE line | `app-bypass-actor`: body `bypass_actors` = exactly the App; `grep -c '^# NOTE'` = 0; `app_bypass` has no `not_covered`; a hand-added RepositoryRole bypass is planned away |
| 5 | shellcheck clean | `make lint` exit 0 |

Mutation checks (each reverted): dropping `context` from `canon`'s sort key fails
`drift-is-corrected`; disabling the overlap check fails the "old policy" refusal; disabling the
bypass-actor check fails "a bypass actor written into the policy".

## 4. Desk change to T13 (`Ticket: scaffold`, `e936374`)

Removing classic protection needs `DELETE …/protection`, which the fake gh did not answer, and
`tests/fakes/gh` was not in T13's scope. The body also gained the DELETE in its deliverables.

```
$ a ticket show T13 --json → ticketHash 5b60e17ab336…6207
$ a ticket update T13 --input t13-new.json --expect 5b60e17ab336…6207 --json
{"ok":false,"kind":"policy","code":"AUTHORIZATION_REQUIRED","message":"update requires authorization: scope-widening"}   exit=2
$ a ticket update T13 … --authorize --json          → changedFields [body, scope], sensitive [scope-widening], validation valid, dryRun true
$ a ticket update T13 … --authorize --write --json  → applied true, ticketHash 0ffcd6cb349f…a684
$ a ticket doctor                    → All checks passed.   exit=0
$ a coldstart --all --offline --json → ok true; T12–T16 ok, gaps []
$ a merge-forecast --json            → {"gateFailures":[],"waves":[["T12","T13"],["T15","T14"],["T16"]]}   exit=0
```

## 5. Gates

- `make test`: 15 files PASS (`tests/test_halt_rules.sh` 8 cases, 98 checks).
- `make lint`: exit 0.
- `make live`: not run; no live file touches branch protection (`grep -l apply-branch-protection tests/live/*` → none).
- Dry run against the real repo (GETs only):

```
$ factory/bin/apply-branch-protection.sh --repo musicofhel/software-factory --json | jq -c '[.mode, [.calls[] | [.action, .method, .path]], .unmanaged_rulesets]'
["dry-run",[["noop","DELETE","repos/musicofhel/software-factory/branches/main/protection"],["create","POST","repos/musicofhel/software-factory/rulesets"]],[]]
$ FACTORY_APP_ID=987654 … --json   → POST body bypass_actors [{"actor_id":987654,"actor_type":"Integration","bypass_mode":"always"}]; app_bypass.rulesets ["main"]; no NOTE
```

## 6. For Aaron's kit (unchanged ask, new shape)

`factory/bin/apply-branch-protection.sh --apply` with `FACTORY_APP_ID` set is still Aaron's (out of
scope here, I1). It now sends one POST (ruleset `main`) and no classic protection call. ADR-0004's
open question stands: the merge queue may need an organization-owned repo; the POST either succeeds
or answers 422, and on 422 the whole ruleset (reviews and checks included) is refused, so drop the
`merge_queue` rule and re-run rather than leave `main` unprotected.
