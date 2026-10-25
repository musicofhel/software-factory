#!/usr/bin/env bash
# T2 acceptance 2 and T13 (step-2 ruling Q2): apply-branch-protection.sh against the fake gh,
# offline. Dry run prints every gh api call built from factory/policy/branch-protection.json and
# sends no write; --apply sends them; a second --apply sends nothing. Every rule on main is a rule
# of ruleset `main`; classic protection is empty, and one found on GitHub is deleted. Plus the
# fake's own protection/ruleset semantics.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

POLICY="$REPO_ROOT/factory/policy/branch-protection.json"
WRITES='.[0] == "api" and (index("PUT") or index("POST") or index("PATCH") or index("DELETE"))'
abp() {  # abp <args>: sets RC, OUT, ERR
  RC=0
  OUT="$("$BIN/apply-branch-protection.sh" "$@" 2>"$WORLD/err")" || RC=$?
  # shellcheck disable=SC2034  # ERR is read inside the eval strings passed to check
  ERR="$(command cat "$WORLD/err")"
}

# ---------------------------------------------------------------------------------------------
case_fake_gh_settings() {
  fakegh_setup
  local rc out
  rc=0; gh api repos/test/repo/branches/main/protection >/dev/null 2>"$WORLD/err" || rc=$?
  check "unprotected branch: 404 Branch not protected" eq "$rc:$(command cat "$WORLD/err")" "1:gh: Branch not protected (HTTP 404)"
  rc=0; gh api repos/test/repo/branches/nope/protection >/dev/null 2>"$WORLD/err" || rc=$?
  check "missing branch: 404 Branch not found" eq "$rc:$(command cat "$WORLD/err")" "1:gh: Branch not found (HTTP 404)"
  rc=0; echo '{"enforce_admins":true}' | gh api -X PUT repos/test/repo/branches/main/protection --input - >/dev/null 2>&1 || rc=$?
  check "PUT protection without the four required keys is 422 and stores nothing" \
    eq "$rc:$(jq -c .protection "$FAKE_GH_SETTINGS")" "1:{}"
  echo '{"required_status_checks":{"strict":true,"contexts":["a"]},"enforce_admins":true,"required_pull_request_reviews":null,"restrictions":null,"allow_deletions":false}' |
    gh api -X PUT repos/test/repo/branches/main/protection --input - >/dev/null
  out="$(gh api repos/test/repo/branches/main/protection)"
  check "GET protection answers GitHub's shape: wrapped booleans, checks[], absent nulls" \
    eq "$(jq -c '[.enforce_admins.enabled, .allow_deletions.enabled, .lock_branch.enabled, .required_status_checks.checks[0].context,
                  has("required_pull_request_reviews"), has("restrictions")]' <<<"$out")" '[true,false,false,"a",false,false]'
  rc=0; out="$(gh api -X DELETE repos/test/repo/branches/main/protection 2>&1)" || rc=$?
  check "DELETE protection: 204, no output, gone from the store" eq "$rc:$out:$(jq -c .protection "$FAKE_GH_SETTINGS")" "0::{}"
  rc=0; gh api -X DELETE repos/test/repo/branches/main/protection >/dev/null 2>"$WORLD/err" || rc=$?
  check "DELETE protection of an unprotected branch: 404 Branch not protected" \
    eq "$rc:$(command cat "$WORLD/err")" "1:gh: Branch not protected (HTTP 404)"

  check "no rulesets yet" eq "$(gh api 'repos/test/repo/rulesets?includes_parents=false')" "[]"
  out="$(echo '{"name":"r1","target":"branch","enforcement":"active","rules":[{"type":"pull_request","parameters":{"required_approving_review_count":1}}]}' |
         gh api -X POST repos/test/repo/rulesets --input -)"
  check "POST ruleset returns an id and server defaults" \
    eq "$(jq -c '[.id, .source_type, .bypass_actors, .rules[0].parameters.allowed_merge_methods]' <<<"$out")" \
       '[1,"Repository",[],["merge","squash","rebase"]]'
  rc=0; echo '{"name":"r1","rules":[]}' | gh api -X POST repos/test/repo/rulesets --input - >/dev/null 2>"$WORLD/err" || rc=$?
  check "POST of a duplicate name is 422" eq "$rc:$(command cat "$WORLD/err")" "1:gh: Validation Failed: Name must be unique (HTTP 422)"
  rc=0; echo '{"name":"r2","rules":[{"type":"halt_on_deletion"}]}' | gh api -X POST repos/test/repo/rulesets --input - >/dev/null 2>&1 || rc=$?
  check "POST of an unknown rule type is 422" eq "$rc:$(jq '.rulesets | length' "$FAKE_GH_SETTINGS")" "1:1"
  check "the list has summaries without rules (callers GET by id)" \
    eq "$(gh api repos/test/repo/rulesets | jq -c '[.[0].id, .[0].name, (.[0] | has("rules"))]')" '[1,"r1",false]'
  echo '{"enforcement":"disabled"}' | gh api -X PUT repos/test/repo/rulesets/1 --input - >/dev/null
  check "PUT ruleset updates the named fields only" \
    eq "$(gh api repos/test/repo/rulesets/1 | jq -c '[.enforcement, .name, (.rules | length)]')" '["disabled","r1",1]'
  rc=0; gh api repos/test/repo/rulesets/9 >/dev/null 2>&1 || rc=$?
  check "GET of a missing ruleset is 404" eq "$rc" 1
}

# Classic protection as the step-1 policy held it (before ruling Q2): what a repo that applied it has.
OLD_CLASSIC='{"required_status_checks":{"strict":true,"contexts":["gates / build-test","gates / scope"]},"enforce_admins":true,
  "required_pull_request_reviews":{"dismiss_stale_reviews":true,"require_code_owner_reviews":true,"required_approving_review_count":1},
  "restrictions":null,"allow_force_pushes":false,"allow_deletions":false}'
seed_classic() { jq -c . <<<"$OLD_CLASSIC" | gh api -X PUT repos/test/repo/branches/main/protection --input - >/dev/null; }
body_of() {  # body_of <METHOD path-prefix>: the JSON body of the printed command
  grep "^gh api -X $1" <<<"$OUT" | sed "s/.*<<< '//; s/'\$//"
}

case_dry_run_prints_calls() {
  fakegh_setup
  abp
  check "dry run: exit 0" eq "$RC" 0
  check "dry run sends no write" eq "$(fakegh_calls "$WRITES")" 0
  check "dry run: settings untouched" eq "$(jq -c '[.protection, .rulesets]' "$FAKE_GH_SETTINGS")" '[{},[]]'
  check "no classic protection on GitHub and none in the policy: no protection call printed" \
    eq "$(grep -c '^gh api -X [A-Z]* repos/test/repo/branches/main/protection' <<<"$OUT" || true)" 0
  check "... but the check is reported as a noop" \
    eval 'grep -qx "# noop: no classic branch protection on main (already matches; not sent)" <<<"$OUT"'
  check "prints one POST per policy ruleset" \
    eq "$(grep -c '^gh api -X POST repos/test/repo/rulesets --input - <<< ' <<<"$OUT")" "$(jq '.rulesets | length' "$POLICY")"
  local rs; rs="$(body_of 'POST repos/test/repo/rulesets')"
  check "the POST is ruleset main, on refs/heads/main, active" \
    eq "$(jq -c '[.name, .target, .enforcement, .conditions.ref_name.include]' <<<"$rs")" '["main","branch","active",["refs/heads/main"]]'
  check "it carries the moved rules: deletion, non_fast_forward, pull_request, required_status_checks, and the merge queue" \
    eq "$(jq -c '[.rules[].type]' <<<"$rs")" '["deletion","non_fast_forward","pull_request","required_status_checks","merge_queue"]'
  check "pull_request: one approval, code-owner review, stale reviews dismissed" \
    eq "$(jq -c '.rules[] | select(.type == "pull_request") | .parameters
                 | [.required_approving_review_count, .require_code_owner_review, .dismiss_stale_reviews_on_push]' <<<"$rs")" '[1,true,true]'
  check "required_status_checks: the seven gates, strict" \
    eq "$(jq -c '.rules[] | select(.type == "required_status_checks") | .parameters
                 | [.strict_required_status_checks_policy, [.required_status_checks[].context]]' <<<"$rs")" \
       '[true,["gates / build-test","gates / rails-proof","gates / scope","gates / tamper","gates / dependencies","gates / attest-verify","gates / commit-check"]]'
  check "no bypass actor (admins included)" eq "$(jq -c .bypass_actors <<<"$rs")" '[]'
  check "no _comment or _halt key is sent" eq "$(jq '[.. | objects | keys[] | select(startswith("_"))] | length' <<<"$rs")" 0
  check "names the rule GitHub cannot express, and its ADR" \
    eval 'grep -q "^# NOT EXPRESSIBLE.*factory/HALT.*docs/adr/0004-halt-two-person-rule.md" <<<"$OUT"'
  # The printed lines are the real commands: run them through a shell and the fake ends up equal to
  # what --apply makes.
  grep '^gh api ' <<<"$OUT" | bash >/dev/null
  check "the printed commands, run by hand, leave classic protection empty" eq "$(jq -c '.protection' "$FAKE_GH_SETTINGS")" '{}'
  check "... and create the rulesets (without _ keys)" \
    eq "$(jq -c '[.rulesets[] | del(.id)]' "$FAKE_GH_SETTINGS")" \
       "$(jq -c '[.rulesets[] | walk(if type == "object" then with_entries(select(.key | startswith("_") | not)) else . end)]' "$POLICY")"
  abp
  check "after the printed commands ran, the plan is all noop" eq "$(grep -c '^gh api ' <<<"$OUT" || true)" 0

  fakegh_setup
  abp --json
  check "--json lists every call with action, method, path and body" \
    eq "$(jq -c '[.mode, [.calls[] | [.action, .method, .path]]]' <<<"$OUT")" \
       '["dry-run",[["noop","DELETE","repos/test/repo/branches/main/protection"],["create","POST","repos/test/repo/rulesets"]]]'
  abp --apply --json
  check "--apply: exit 0, every write ok" eq "$RC:$(jq -c '[.results[].result]' <<<"$OUT")" '0:["ok"]'
  check "--apply sent exactly the planned writes" eq "$(fakegh_calls "$WRITES")" 1
  check "GitHub holds no classic protection" eq "$(jq -c '.protection' "$FAKE_GH_SETTINGS")" '{}'
  : >"$FAKE_GH_LOG"
  abp --apply --json
  check "idempotent: a second --apply sends no write" eq "$RC:$(fakegh_calls "$WRITES")" "0:0"
  check "idempotent: every call is a noop" eq "$(jq -c '[.calls[].action] | unique' <<<"$OUT")" '["noop"]'
  abp --apply
  check "plain output says 0 writes on the noop run" eval 'grep -q "^# applied 0 of 0 write(s)" <<<"$OUT"'
}

# Ruling Q2 on a repo that already has classic protection: it is deleted, its rules land in the ruleset.
case_classic_protection_removed() {
  fakegh_setup
  seed_classic
  : >"$FAKE_GH_LOG"
  abp
  check "dry run: prints the DELETE of the classic protection (no body)" \
    eq "$(grep -c '^gh api -X DELETE repos/test/repo/branches/main/protection$' <<<"$OUT")" 1
  check "dry run: and sends nothing" eq "$(fakegh_calls "$WRITES"):$(jq -c '.protection | keys' "$FAKE_GH_SETTINGS")" '0:["main"]'
  abp --apply --json
  check "--apply: DELETE then POST, both ok" \
    eq "$RC:$(jq -c '[.results[] | [.method, .result]]' <<<"$OUT")" '0:[["DELETE","ok"],["POST","ok"]]'
  local rc=0; gh api repos/test/repo/branches/main/protection >/dev/null 2>&1 || rc=$?
  check "GET protection is now 404 Branch not protected" eq "$rc" 1
  : >"$FAKE_GH_LOG"
  abp --apply --json
  check "a second --apply sends nothing" eq "$RC:$(fakegh_calls "$WRITES")" "0:0"
}

case_drift_is_corrected() {
  fakegh_setup
  abp --apply
  # Someone puts classic protection back by hand and disables the ruleset.
  seed_classic
  echo '{"enforcement":"disabled"}' | gh api -X PUT repos/test/repo/rulesets/1 --input - >/dev/null
  : >"$FAKE_GH_LOG"
  abp --json
  check "drift is planned: classic protection deleted, the ruleset updated by id" \
    eq "$(jq -c '[.calls[] | [.action, .method, .path]]' <<<"$OUT")" \
       '[["delete","DELETE","repos/test/repo/branches/main/protection"],["update","PUT","repos/test/repo/rulesets/1"]]'
  abp --apply --json
  check "--apply restores the policy" \
    eq "$(jq -c '[.protection, .rulesets[0].enforcement]' "$FAKE_GH_SETTINGS")" '[{},"active"]'
  check "no ruleset was created twice" eq "$(jq '.rulesets | length' "$FAKE_GH_SETTINGS")" 1
  # Someone drops the code-owner review inside the ruleset.
  local tmp; tmp="$(mktemp)"
  jq '(.rulesets[0].rules[] | select(.type == "pull_request") | .parameters.require_code_owner_review) = false' "$FAKE_GH_SETTINGS" >"$tmp"
  mv "$tmp" "$FAKE_GH_SETTINGS"
  abp --json
  check "a loosened rule parameter is drift" eq "$(jq -c '[.calls[].action]' <<<"$OUT")" '["noop","update"]'
  abp --apply
  # A field GitHub adds, that the policy does not name, is not drift; neither is the order GitHub
  # lists rules and status checks in.
  jq '(.rulesets[0].rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
        |= (reverse | map(. + {integration_id: 15368}))
      | (.rulesets[0].rules[] | select(.type == "pull_request") | .parameters.required_reviewers) = []
      | .rulesets[0].rules |= reverse' "$FAKE_GH_SETTINGS" >"$tmp"
  mv "$tmp" "$FAKE_GH_SETTINGS"
  abp --json
  check "fields the policy does not name, and list order, are not owned: noop" eq "$(jq -c '[.calls[].action] | unique' <<<"$OUT")" '["noop"]'
}

case_unmanaged_left_alone() {
  fakegh_setup
  echo '{"name":"main-merge-queue","target":"branch","enforcement":"active","rules":[{"type":"deletion"}]}' |
    gh api -X POST repos/test/repo/rulesets --input - >/dev/null
  : >"$FAKE_GH_LOG"
  abp --apply --json
  check "a ruleset the policy does not name (the old main-merge-queue) is reported, not touched" \
    eq "$(jq -c '.unmanaged_rulesets' <<<"$OUT"):$(fakegh_calls "$WRITES and index(\"repos/test/repo/rulesets/1\")")" '["main-merge-queue"]:0'
  check "and never deleted" eq "$(jq -c '[.rulesets[].name]' "$FAKE_GH_SETTINGS")" '["main-merge-queue","main"]'
}

case_refuses_made_up_fields() {
  fakegh_setup
  local bad="$WORLD/bad.json"
  refused() {  # refused <name> <jq edit> <message fragment>: the edited policy is exit 2, named, before any call
    # shellcheck disable=SC2034  # want is read inside the eval string passed to check
    local want="$3"
    jq "$2" "$POLICY" >"$bad"
    : >"$FAKE_GH_LOG"
    abp --policy "$bad" --apply
    check "$1: exit 2, before any call" eq "$RC:$(wc -l <"$FAKE_GH_LOG" | tr -d ' ')" "2:0"
    check "$1: names it" eval '[[ "$ERR" == *"$want"* ]]'
  }
  # The scaffold's original halt ruleset carried `path_filter`, which GitHub does not have.
  refused "a made-up ruleset field" '.rulesets[0].path_filter = {paths: ["factory/HALT"], on: "deletion"}' "ruleset main: key path_filter"
  refused "an unknown rule type" '.rulesets[0].rules[0].type = "halt_on_deletion"' "rule type halt_on_deletion"
  refused "a classic field name inside the ruleset's pull_request rule" \
    '(.rulesets[0].rules[] | select(.type == "pull_request") | .parameters.require_code_owner_reviews) = true' \
    "rule pull_request: parameter require_code_owner_reviews"
  refused "a parameter GitHub requires is missing" \
    '(.rulesets[0].rules[] | select(.type == "pull_request") | .parameters) |= del(.require_last_push_approval)' \
    "parameter require_last_push_approval is required"
  refused "parameters on a rule that takes none" '.rulesets[0].rules[0].parameters = {paths: ["factory/HALT"]}' "rule deletion: parameter paths"
  refused "a status check written the classic way" \
    '(.rulesets[0].rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) = [{contexts: "gates / scope"}]' \
    "required status check key contexts"
  refused "an unknown key beside type in a rule" '.rulesets[0].rules[1].on = "deletion"' "rule non_fast_forward: key on"
  refused "an unknown condition" '.rulesets[0].conditions.path = ["factory/HALT"]' "conditions.path"
  refused "a bypass actor written into the policy" \
    '.rulesets[0].bypass_actors = [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]' "bypass_actors must be empty"
  refused "no protection key" 'del(.protection)' "protection is missing"
  refused "merge_queue under protection (not a protection field)" '.protection = {merge_queue: {required: true}}' "protection.merge_queue"
  refused "classic protection beside the ruleset that covers it (the old policy)" ".protection = $OLD_CLASSIC" \
    "protection duplicates ruleset rule pull_request"
  refused "classic protection missing a key PUT requires" '.protection = {enforce_admins: true, allow_force_pushes: true, allow_deletions: true}' \
    "protection.restrictions is required"
  # Classic protection that covers nothing the ruleset covers is allowed and planned as a PUT...
  fakegh_setup; bad="$WORLD/bad.json"
  jq '.protection = {required_status_checks: null, enforce_admins: true, required_pull_request_reviews: null, restrictions: null,
                     required_linear_history: true, allow_force_pushes: true, allow_deletions: true}' "$POLICY" >"$bad"
  abp --policy "$bad" --json
  check "classic protection that duplicates no ruleset rule: accepted, planned as a PUT" \
    eq "$RC:$(jq -c '[.calls[0] | .action, .method]' <<<"$OUT")" '0:["create","PUT"]'
  # ... but not with the App: a ruleset bypass does not lift it, so the App's push would be refused.
  FACTORY_APP_ID=987654 abp --policy "$bad"
  check "... and refused with FACTORY_APP_ID set (exit 2)" eq "$RC" 2
  check "... naming why" eval '[[ "$ERR" == *"keeps classic protection, which a ruleset bypass does not lift"* ]]'
  check "the shipped policy itself is accepted" eval '"$BIN/apply-branch-protection.sh" >/dev/null 2>&1'
}

case_read_errors_fail() {
  fakegh_setup
  FAKE_GH_FAIL='branches/main/protection' abp --apply
  check "a 500 on reading the protection is exit 1, not 'unprotected'" eq "$RC" 1
  check "and nothing was written" eq "$(fakegh_calls "$WRITES")" 0
  seed_classic
  FAKE_GH_FAIL='-X POST repos/test/repo/rulesets' abp --apply --json
  check "a failed write: exit 1, the other write still sent and reported" \
    eq "$RC:$(jq -c '[.results[].result]' <<<"$OUT")" '1:["ok","failed"]'
}

# T10 acceptance 2 (step-1 ruling Q6) and T13 acceptance 4 (step-2 ruling Q2): FACTORY_APP_ID makes the
# App the only bypass actor on every policy ruleset, and every rule on main is in one.
case_app_bypass_actor() {
  fakegh_setup
  local plain json app='[{"actor_id":987654,"actor_type":"Integration","bypass_mode":"always"}]'
  abp; plain="$OUT"
  abp --json; json="$OUT"
  FACTORY_APP_ID='' abp
  check "FACTORY_APP_ID empty: the plain output is byte-identical to unset" eq "$OUT" "$plain"
  FACTORY_APP_ID='' abp --json
  check "... and the --json output" eq "$OUT" "$json"
  check "unset: no bypass actor in any planned body" eq "$(jq -c '[.calls[].body.bypass_actors // empty | length] | add' <<<"$json")" 0

  FACTORY_APP_ID=987654 abp
  check "dry run with the App: exit 0, no write sent" eq "$RC:$(fakegh_calls "$WRITES")" "0:0"
  check "prints the App as the only bypass actor" \
    eval 'grep -qx "# bypass actor: GitHub App 987654 (Integration, always), the only one, on ruleset(s) main (FACTORY_APP_ID)" <<<"$OUT"'
  check "the printed POST body carries it, and no other actor" eq "$(body_of 'POST repos/test/repo/rulesets' | jq -c .bypass_actors)" "$app"
  check "no NOTE line: no classic protection is left for the bypass to miss" eq "$(grep -c '^# NOTE' <<<"$OUT" || true)" 0
  check "no classic protection call with the App either" eq "$(grep '^gh api' <<<"$OUT" | grep -c 'branches/main/protection' || true)" 0
  check "every rule of the old classic protection is in the bypassed ruleset" \
    eq "$(body_of 'POST repos/test/repo/rulesets' | jq -c '[.rules[].type | select(IN("pull_request", "required_status_checks", "non_fast_forward", "deletion"))] | length')" 4
  FACTORY_APP_ID=987654 abp --json
  check "--json: app_bypass names the actor and the rulesets, and has no not_covered" \
    eq "$(jq -c '.app_bypass | [.actor_id, .actor_type, .bypass_mode, .rulesets, has("not_covered")]' <<<"$OUT")" '[987654,"Integration","always",["main"],false]'

  FACTORY_APP_ID=987654 abp --apply --json
  check "--apply sends it: GitHub's ruleset holds the App, alone" eq "$RC:$(jq -c '.rulesets[0].bypass_actors' "$FAKE_GH_SETTINGS")" "0:$app"
  : >"$FAKE_GH_LOG"
  FACTORY_APP_ID=987654 abp --apply --json
  check "idempotent with the App: a second --apply sends nothing" eq "$RC:$(fakegh_calls "$WRITES")" "0:0"
  abp --json
  check "the App on GitHub but FACTORY_APP_ID unset: drift, planned as an update to no actor" \
    eq "$(jq -c '[.calls[] | select(.what == "ruleset main") | [.action, .body.bypass_actors]]' <<<"$OUT")" '[["update",[]]]'
  FACTORY_APP_ID=111 abp --json
  check "another App ID: the body is that App only (the old App would be dropped)" \
    eq "$(jq -c '[.calls[] | select(.what == "ruleset main") | [.action, (.body.bypass_actors | map(.actor_id))]]' <<<"$OUT")" '[["update",[111]]]'
  # Someone adds an admin bypass on GitHub by hand: the App stays the only actor.
  local tmp; tmp="$(mktemp)"
  jq '.rulesets[0].bypass_actors += [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]' "$FAKE_GH_SETTINGS" >"$tmp"
  mv "$tmp" "$FAKE_GH_SETTINGS"
  FACTORY_APP_ID=987654 abp --apply --json
  check "a hand-added admin bypass is drift: --apply leaves the App alone on the list" \
    eq "$(jq -c '[.calls[] | select(.what == "ruleset main") | .action]' <<<"$OUT"):$(jq -c '.rulesets[0].bypass_actors' "$FAKE_GH_SETTINGS")" "[\"update\"]:$app"

  : >"$FAKE_GH_LOG"
  FACTORY_APP_ID=12x abp
  check "a non-numeric FACTORY_APP_ID: exit 2 before any call" eq "$RC:$(fakegh_calls "$WRITES")" "2:0"
  FACTORY_APP_ID=0 abp
  check "App ID 0: exit 2" eq "$RC" 2
}

echo "test_halt_rules"
for c in fake-gh-settings dry-run-prints-calls classic-protection-removed drift-is-corrected unmanaged-left-alone \
         refuses-made-up-fields read-errors-fail app-bypass-actor; do
  run_case "$c"
done
exit "$FAILED"
