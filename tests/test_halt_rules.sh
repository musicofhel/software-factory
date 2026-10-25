#!/usr/bin/env bash
# T2 acceptance 2: apply-branch-protection.sh against the fake gh, offline. Dry run prints every
# gh api call built from factory/policy/branch-protection.json and sends no write; --apply sends
# them; a second --apply sends nothing. Plus the fake's own protection/ruleset semantics.
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

case_dry_run_prints_calls() {
  fakegh_setup
  abp
  check "dry run: exit 0" eq "$RC" 0
  check "dry run sends no write" eq "$(fakegh_calls "$WRITES")" 0
  check "dry run: settings untouched" eq "$(jq -c '[.protection, .rulesets]' "$FAKE_GH_SETTINGS")" '[{},[]]'
  check "prints the PUT of the branch protection, body = policy .protection" \
    eq "$(grep -c '^gh api -X PUT repos/test/repo/branches/main/protection --input - <<< ' <<<"$OUT")" 1
  check "prints one POST per policy ruleset" \
    eq "$(grep -c '^gh api -X POST repos/test/repo/rulesets --input - <<< ' <<<"$OUT")" "$(jq '.rulesets | length' "$POLICY")"
  check "names the rule GitHub cannot express, and its ADR" \
    eval 'grep -q "^# NOT EXPRESSIBLE.*factory/HALT.*docs/adr/0004-halt-two-person-rule.md" <<<"$OUT"'
  # The printed lines are the real commands: run them through a shell and the fake ends up equal to
  # what --apply makes.
  grep '^gh api ' <<<"$OUT" | bash >/dev/null
  check "the printed commands, run by hand, set the protection the policy names" \
    eq "$(jq -c '.protection.main' "$FAKE_GH_SETTINGS")" "$(jq -c '.protection' "$POLICY")"
  check "... and the rulesets (without _comment keys)" \
    eq "$(jq -c '[.rulesets[] | del(.id)]' "$FAKE_GH_SETTINGS")" \
       "$(jq -c '[.rulesets[] | with_entries(select(.key | startswith("_") | not))]' "$POLICY")"
  abp
  check "after the printed commands ran, the plan is all noop" eq "$(grep -c '^gh api ' <<<"$OUT" || true)" 0

  fakegh_setup
  abp --json
  check "--json lists every call with action, method, path and body" \
    eq "$(jq -c '[.mode, [.calls[] | [.action, .method, .path]]]' <<<"$OUT")" \
       '["dry-run",[["create","PUT","repos/test/repo/branches/main/protection"],["create","POST","repos/test/repo/rulesets"]]]'
  abp --apply --json
  check "--apply: exit 0, every write ok" eq "$RC:$(jq -c '[.results[].result]' <<<"$OUT")" '0:["ok","ok"]'
  check "--apply sent exactly the planned writes" eq "$(fakegh_calls "$WRITES")" 2
  check "the protection GitHub holds is the policy's" eq "$(jq -c '.protection.main' "$FAKE_GH_SETTINGS")" "$(jq -c '.protection' "$POLICY")"
  : >"$FAKE_GH_LOG"
  abp --apply --json
  check "idempotent: a second --apply sends no write" eq "$RC:$(fakegh_calls "$WRITES")" "0:0"
  check "idempotent: every call is a noop" eq "$(jq -c '[.calls[].action] | unique' <<<"$OUT")" '["noop"]'
  abp --apply
  check "plain output says 0 writes on the noop run" eval 'grep -q "^# applied 0 of 0 write(s)" <<<"$OUT"'
}

case_drift_is_corrected() {
  fakegh_setup
  abp --apply
  # Someone loosens the rules by hand on GitHub: one review dropped, the queue disabled.
  echo '{"required_status_checks":null,"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}' |
    gh api -X PUT repos/test/repo/branches/main/protection --input - >/dev/null
  echo '{"enforcement":"disabled"}' | gh api -X PUT repos/test/repo/rulesets/1 --input - >/dev/null
  : >"$FAKE_GH_LOG"
  abp --json
  check "drift is planned as updates, by id for the ruleset" \
    eq "$(jq -c '[.calls[] | [.action, .method, .path]]' <<<"$OUT")" \
       '[["update","PUT","repos/test/repo/branches/main/protection"],["update","PUT","repos/test/repo/rulesets/1"]]'
  abp --apply --json
  check "--apply restores the policy" \
    eq "$(jq -c '[.protection.main.enforce_admins, .rulesets[0].enforcement]' "$FAKE_GH_SETTINGS")" '[true,"active"]'
  check "no ruleset was created twice" eq "$(jq '.rulesets | length' "$FAKE_GH_SETTINGS")" 1
  # A field GitHub adds, that the policy does not name, is not drift.
  local tmp; tmp="$(mktemp)"
  jq '.protection.main.required_conversation_resolution = false | .rulesets[0].rules[0].parameters.extra = 1' "$FAKE_GH_SETTINGS" >"$tmp"
  mv "$tmp" "$FAKE_GH_SETTINGS"
  abp --json
  check "fields the policy does not name are not owned: noop" eq "$(jq -c '[.calls[].action] | unique' <<<"$OUT")" '["noop"]'
}

case_unmanaged_left_alone() {
  fakegh_setup
  echo '{"name":"someone-elses","target":"branch","enforcement":"active","rules":[{"type":"deletion"}]}' |
    gh api -X POST repos/test/repo/rulesets --input - >/dev/null
  : >"$FAKE_GH_LOG"
  abp --apply --json
  check "a ruleset the policy does not name is reported, not touched" \
    eq "$(jq -c '.unmanaged_rulesets' <<<"$OUT"):$(fakegh_calls "$WRITES and index(\"repos/test/repo/rulesets/1\")")" '["someone-elses"]:0'
  check "and never deleted" eq "$(jq -c '[.rulesets[].name]' "$FAKE_GH_SETTINGS")" '["someone-elses","main-merge-queue"]'
}

case_refuses_made_up_fields() {
  fakegh_setup
  local bad="$WORLD/bad.json"
  # The scaffold's original halt ruleset carried `path_filter`, which GitHub does not have.
  jq '.rulesets[0].path_filter = {paths: ["factory/HALT"], on: "deletion"}' "$POLICY" >"$bad"
  abp --policy "$bad" --apply
  check "a made-up ruleset field: exit 2" eq "$RC" 2
  check "names the field" eval '[[ "$ERR" == *"ruleset main-merge-queue: key path_filter"* ]]'
  check "refused before any call" eq "$(wc -l <"$FAKE_GH_LOG" | tr -d ' ')" 0
  jq '.rulesets[0].rules[0].type = "halt_on_deletion"' "$POLICY" >"$bad"
  abp --policy "$bad"
  check "an unknown rule type: exit 2" eq "$RC" 2
  jq 'del(.protection.restrictions)' "$POLICY" >"$bad"
  abp --policy "$bad"
  check "protection missing a key PUT requires: exit 2" eq "$RC" 2
  jq '.protection.merge_queue = {required: true}' "$POLICY" >"$bad"
  abp --policy "$bad"
  check "merge_queue under protection (not a protection field): exit 2" eq "$RC" 2
  check "the shipped policy itself is accepted" eval '"$BIN/apply-branch-protection.sh" >/dev/null 2>&1'
}

case_read_errors_fail() {
  fakegh_setup
  FAKE_GH_FAIL='branches/main/protection' abp --apply
  check "a 500 on reading the protection is exit 1, not 'unprotected'" eq "$RC" 1
  check "and nothing was written" eq "$(fakegh_calls "$WRITES")" 0
  FAKE_GH_FAIL='-X POST repos/test/repo/rulesets' abp --apply --json
  check "a failed write: exit 1, the other write still sent and reported" \
    eq "$RC:$(jq -c '[.results[].result]' <<<"$OUT")" '1:["ok","failed"]'
}

echo "test_halt_rules"
for c in fake-gh-settings dry-run-prints-calls drift-is-corrected unmanaged-left-alone refuses-made-up-fields read-errors-fail; do
  run_case "$c"
done
exit "$FAILED"
