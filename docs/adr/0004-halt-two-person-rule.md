# ADR-0004: GitHub cannot express "zero approvals to add factory/HALT, two to remove it"

- Status: proposed (the interim below is what ships; the options are Aaron's to pick)
- Date: 2026-10-24
- Deciders: @musicofhel

## Context

SPEC-v0.2 "Kill switch": anyone with write access adds `factory/HALT` with a one-line PR that
"needs no review"; removing it needs two approvals, "which the branch rules express as a
required-reviewers rule keyed on deletion". The scaffold's `branch-protection.json` wrote this
as a ruleset with `"path_filter": {"paths": ["factory/HALT"], "on": "deletion"}`.

Measured on 2026-10-24 (the commands are in `specs/factory-step1-v1/records/TB2.md`):

1. No GitHub rule is keyed on file deletion. Ruleset rules (REST "Create a repository
   ruleset") have no `path_filter`. The nearest rules are:
   - `pull_request.parameters.required_reviewers`: `[{file_patterns, minimum_approvals,
     reviewer: {id, type: "Team"}}]`. It keys on changed files, so adding HALT would need the
     same approvals as removing it. Docs: "This rule is not available on user-owned
     repositories as they do not contain teams."
   - `file_path_restriction` is a push-ruleset rule. It blocks every push that changes the
     path, add and delete alike.
2. This repo is user-owned: `gh api repos/musicofhel/software-factory --jq .owner.type` →
   `User`.
3. Classic protection's `required_approving_review_count: 1` with `require_code_owner_reviews`
   applies to every PR into `main`. Adding HALT therefore needs one code-owner approval.
4. Only one human owns the repo (PROJECT.md "Who"). So nobody can satisfy a two-approval rule
   on HALT today, whatever expresses it.

## Decision (interim, shipped by ticket T2)

- `factory/policy/branch-protection.json` holds only real REST fields. `apply-branch-protection.sh`
  refuses any other field with exit 2, so a made-up rule can never look enforced.
- The asymmetry goes into the policy's `unexpressed` list. Every run of the script, dry or
  applied, prints it as `NOT EXPRESSIBLE ... not enforced`.
- Until this ADR is decided, HALT follows the plain CODEOWNERS rule: **one code-owner approval
  to add it, and one to remove it.** The CODEOWNERS line stays, so the code owner remains the
  required reviewer for both.
- None of this changes the halt itself. `halt-check.sh` reads `factory/HALT` from `origin/main`
  however it got there, and the summoner fires on the `factory:halt` label and on a push that
  touches the file.

## Options (for Aaron)

- **A. Keep the interim.** No change. Setting a halt waits for a code-owner approval, so the
  stop is slower than the spec intends. Removing it needs one person, not two.
- **B. Move the repo to an organization with a `factory-owners` team** (at least two members;
  the bus-factor rule already asks for two org owners before the queue opens). Add a ruleset
  `pull_request` rule with `required_reviewers: [{file_patterns: ["factory/HALT"],
  minimum_approvals: 2, reviewer: {type: "Team", id: <team id>}}]`. Removing HALT then needs
  two approvals. Adding it also needs two, so B alone makes halting harder.
- **C. Halt without a PR.** A `halt` workflow (`workflow_dispatch`, so any write-access member
  can run it) commits `factory/HALT` with a GitHub App token. That App is the only bypass
  actor on the PR rule (a ruleset `bypass_actors` entry, or classic protection's
  `bypass_pull_request_allowances.apps`). Adding HALT then needs zero approvals. It needs an
  App, a stored private key, and a workflow that build order 1 does not include.
- **D. A required check `gates / halt-guard`.** It fails a PR that deletes `factory/HALT`
  unless the PR has at least two approvals, and it re-runs on `pull_request_review`. This
  works on a user-owned repo. It is a gate body, so it belongs to build order 3.

The loop recommends **A now and B + C once the organization exists**. B + C is the only
combination that gives the spec's exact asymmetry. D can stand in for B on a user-owned repo.

## Consequences

- The spec's two-person rule for lifting a halt is not enforced on GitHub until B or D lands.
  `slb` was already deferred by the spec, so for now the rule is a policy line and nothing more.
- Related, unverified: GitHub's merge queue may be limited to organization-owned repos. The
  docs fetched on 2026-10-24 did not state its availability. The first `--apply` on the real
  repo settles it: the `main-merge-queue` ruleset POST either succeeds or returns 422.
