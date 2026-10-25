#!/usr/bin/env bash
# apply-branch-protection — make GitHub's rules for `main` equal factory/policy/branch-protection.json.
#
#   apply-branch-protection.sh [--json] [--repo owner/name] [--policy FILE]     plan (dry run)
#   apply-branch-protection.sh --apply [--json] [--repo owner/name] [--policy FILE]
#
# Reads the current state (GET branch protection, GET each repository ruleset), compares it with
# the policy, and prints one `gh api` call per write it would make: PUT the branch protection (or
# DELETE it when the policy's `protection` is null and GitHub still has one), POST a ruleset that
# does not exist yet, PUT one whose fields differ. A call whose target already matches is printed
# as a noop and never sent, so a second --apply sends nothing. Only the fields the policy names
# are compared and owned; rulesets on GitHub that the policy does not name are reported as
# unmanaged and left alone (never deleted). The policy's `unexpressed` rules are printed on every
# run. Needs repo admin for --apply; the plan needs read access.
#
# Step-2 ruling Q2: every rule on `main` lives in a ruleset, and classic protection keeps nothing
# a policy ruleset covers (refused otherwise). A policy ruleset names no bypass actor (refused
# otherwise): FACTORY_APP_ID (the factory GitHub App's numeric App ID; step-1 ruling Q6) makes the
# App the only one, {actor_id, actor_type: "Integration", bypass_mode: "always"} on every policy
# ruleset, so post-merge can push its completion commit on the App token. The dry run prints it,
# --apply sends it, and it is compared like any other field. Unset or empty: no bypass actor and
# the output is unchanged. A ruleset bypass does not lift classic protection, so FACTORY_APP_ID
# with a policy that keeps classic protection is refused.
#
# Exit 0: planned, or applied every call. 1: a read or a write failed. 2: the policy has a field
# that is not a real GitHub REST field, or breaks the rules above (refused before any call).
set -euo pipefail
PROG="apply-branch-protection"
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

apply=0 json=0 repo="" policy="$FACTORY_ROOT/factory/policy/branch-protection.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --json) json=1 ;;
    --repo) repo="${2:-}"; shift ;;
    --policy) policy="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need gh jq
[ -f "$policy" ] || die "policy not found: $policy"
jq -e 'type == "object"' "$policy" >/dev/null 2>&1 || die "policy is not a JSON object: $policy"

# --- validate: every key must be a field the REST API takes (a made-up field is a false rule) ---
# RULE_PARAMS: each ruleset rule type and its parameters, {type: [required, optional]}, from
# GitHub's REST schema (components/schemas/repository-rule-*, the oneOf of repository-rule; docs:
# https://docs.github.com/rest/repos/rules#create-a-repository-ruleset; read 2026-10-25).
RULE_PARAMS='{
  "creation": [[], []], "deletion": [[], []], "non_fast_forward": [[], []], "required_linear_history": [[], []],
  "required_signatures": [[], []], "license_compliance_scanning": [[], []],
  "update": [["update_allows_fetch_and_merge"], []],
  "merge_queue": [["check_response_timeout_minutes", "grouping_strategy", "max_entries_to_build", "max_entries_to_merge",
                   "merge_method", "min_entries_to_merge", "min_entries_to_merge_wait_minutes"], []],
  "required_deployments": [["required_deployment_environments"], []],
  "pull_request": [["dismiss_stale_reviews_on_push", "require_code_owner_review", "require_last_push_approval",
                    "required_approving_review_count", "required_review_thread_resolution"],
                   ["allowed_merge_methods", "dismissal_restriction", "required_reviewers"]],
  "required_status_checks": [["required_status_checks", "strict_required_status_checks_policy"], ["do_not_enforce_on_create"]],
  "commit_message_pattern": [["operator", "pattern"], ["name", "negate"]],
  "commit_author_email_pattern": [["operator", "pattern"], ["name", "negate"]],
  "committer_email_pattern": [["operator", "pattern"], ["name", "negate"]],
  "branch_name_pattern": [["operator", "pattern"], ["name", "negate"]],
  "tag_name_pattern": [["operator", "pattern"], ["name", "negate"]],
  "workflows": [["workflows"], ["do_not_enforce_on_create"]],
  "code_scanning": [["code_scanning_tools"], []], "code_quality": [["severity"], []],
  "code_coverage": [[], ["max_coverage_drop", "minimum_coverage"]],
  "copilot_code_review": [[], ["review_draft_pull_requests", "review_on_push"]],
  "file_path_restriction": [["restricted_file_paths"], []], "max_file_path_length": [["max_file_path_length"], []],
  "file_extension_restriction": [["restricted_file_extensions"], []], "max_file_size": [["max_file_size"], []]
}'
bad="$(jq -r --argjson params "$RULE_PARAMS" '
  def known($ks): to_entries[] | select(.key | startswith("_") | not) | select(.key | IN($ks[]) | not) | .key;
  def lacks($ks): $ks[] as $k | select(has($k) | not) | $k;
  ( known(["branch", "protection", "rulesets", "unexpressed"]) | "top-level key \(.)" ),
  ( select(has("protection") | not) | "top-level key protection is missing (null: no classic protection)" ),
  ( .protection | select(. != null and type != "object") | "protection must be an object or null" ),
  ( .protection | objects | known(["required_status_checks", "enforce_admins", "required_pull_request_reviews",
      "restrictions", "required_linear_history", "allow_force_pushes", "allow_deletions", "block_creations",
      "required_conversation_resolution", "lock_branch", "allow_fork_syncing"]) | "protection.\(.)" ),
  ( .protection | objects | lacks(["required_status_checks", "enforce_admins", "required_pull_request_reviews", "restrictions"])
      | "protection.\(.) is required by PUT branch protection" ),
  ( (.rulesets // [])[] | .name as $n
    | ( known(["name", "target", "enforcement", "bypass_actors", "conditions", "rules"]) | "ruleset \($n): key \(.)" ),
      ( select((.name | type) != "string" or .name == "") | "a ruleset has no name" ),
      ( select((.bypass_actors // []) != []) | "ruleset \($n): bypass_actors must be empty (the only bypass actor is the App, from FACTORY_APP_ID)" ),
      ( .conditions // {} | ( known(["ref_name"]) | "ruleset \($n): conditions.\(.)" ),
                            ( .ref_name // {} | known(["include", "exclude"]) | "ruleset \($n): conditions.ref_name.\(.)" ) ),
      ( (.rules // [])[] | .type as $t
        | if ($params | has($t) | not) then "ruleset \($n): rule type \($t)"
          else ( known(["type", "parameters"]) | "ruleset \($n): rule \($t): key \(.)" ),
               ( .parameters // {} | ( known($params[$t][0] + $params[$t][1]) | "ruleset \($n): rule \($t): parameter \(.)" ),
                                     ( lacks($params[$t][0]) | "ruleset \($n): rule \($t): parameter \(.) is required" ) ),
               ( select($t == "required_status_checks") | .parameters.required_status_checks // [] | .[]
                 | ( known(["context", "integration_id"]) | "ruleset \($n): required status check key \(.)" ),
                   ( select((.context | type) != "string") | "ruleset \($n): a required status check has no context" ) )
          end ) ),
  ( [(.rulesets // [])[].name] | group_by(.)[] | select(length > 1) | "ruleset name \(.[0]) appears twice" ),
  # Ruling Q2: classic protection keeps nothing an active policy ruleset covers.
  ( (.protection | objects) as $p
    | [(.rulesets // [])[] | select((.enforcement // "active") == "active") | (.rules // [])[].type] as $types
    | ( {pull_request: ($p.required_pull_request_reviews != null), required_status_checks: ($p.required_status_checks != null),
         non_fast_forward: (($p.allow_force_pushes // false) == false), deletion: (($p.allow_deletions // false) == false)}
        | to_entries[] | select(.value and (.key | IN($types[]))) | .key )
    | "protection duplicates ruleset rule \(.): classic protection keeps nothing a ruleset covers (step-2 ruling Q2)" ),
  ( (.unexpressed // [])[] | select((.rule | type) != "string" or (.why | type) != "string") | "an unexpressed entry needs rule and why" )
' "$policy")"
[ -z "$bad" ] || refuse "policy $policy is not GitHub REST: $(paste -sd ';' <<<"$bad")"

APP_ID="${FACTORY_APP_ID:-}"
[ -z "$APP_ID" ] || [[ "$APP_ID" =~ ^[1-9][0-9]{0,18}$ ]] || refuse "FACTORY_APP_ID must be the App's numeric ID, got '$APP_ID'"
[ -z "$APP_ID" ] || jq -e '.protection == null' "$policy" >/dev/null ||
  refuse "FACTORY_APP_ID is set but $policy keeps classic protection, which a ruleset bypass does not lift; move it into a ruleset (step-2 ruling Q2)"
REPO="$(resolve_repo "$repo")"
BRANCH="$(jq -r '.branch // "main"' "$policy")"
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] || die "bad branch name '$BRANCH'"

# Compare only what the policy names: project the current state onto the desired shape.
JQ_LIB='
  def strip: walk(if type == "object" then with_entries(select(.key | startswith("_") | not)) else . end);
  def canon: walk(if type == "array"
                  then sort_by(if type == "object" then [(.type // ""), (.actor_id // 0), (.name // ""), (.context // "")] else . end)
                  else . end);
  def shape($w):
    if ($w | type) == "object" then
      (if type == "object" then . else {} end) as $c
      | reduce ($w | keys[]) as $k ({}; .[$k] = ($c[$k] | shape($w[$k])))
    elif ($w | type) == "array" then
      (if type == "array" then . else [] end) as $c
      | if ($c | length) != ($w | length) then $c else [range(0; $w | length) as $i | $c[$i] | shape($w[$i])] end
    else . end;
  def same($want): (canon | shape($want | canon)) == ($want | canon);
  def actors: if . == null then null
              else {users: [(.users // [])[].login], teams: [(.teams // [])[].slug], apps: [(.apps // [])[].slug]} end;
  # GET branch protection answers {enabled: bool} objects and urls; PUT takes plain values.
  def protection_as_put:
    { required_status_checks: (.required_status_checks | if . == null then null else {strict, contexts} end),
      enforce_admins: (.enforce_admins.enabled // false),
      required_pull_request_reviews: (.required_pull_request_reviews | if . == null then null else
        (del(.url)
         | if has("dismissal_restrictions") then .dismissal_restrictions |= actors else . end
         | if has("bypass_pull_request_allowances") then .bypass_pull_request_allowances |= actors else . end) end),
      restrictions: (.restrictions | actors),
      required_linear_history: (.required_linear_history.enabled // false),
      allow_force_pushes: (.allow_force_pushes.enabled // false),
      allow_deletions: (.allow_deletions.enabled // false),
      block_creations: (.block_creations.enabled // false),
      required_conversation_resolution: (.required_conversation_resolution.enabled // false),
      lock_branch: (.lock_branch.enabled // false),
      allow_fork_syncing: (.allow_fork_syncing.enabled // false) };
'

# --- read the current state ---
prot_path="repos/$REPO/branches/$BRANCH/protection"
errf="$(mktemp)"; trap 'rm -f "$errf"' EXIT
if current_prot="$(gh api "$prot_path" 2>"$errf")"; then
  current_prot="$(jq -c "$JQ_LIB protection_as_put" <<<"$current_prot")"
else
  # An unprotected branch is a 404 with this message; any other failure is not "absent".
  grep -q 'Branch not protected (HTTP 404)' "$errf" || die "cannot read $prot_path: $(tail -n1 "$errf")"
  current_prot=null
fi
existing="$(gh api --paginate "repos/$REPO/rulesets?includes_parents=false")" || die "cannot list rulesets of $REPO"
existing="$(jq -c '[.[] | select((.source_type // "Repository") == "Repository") | {id, name}]' <<<"$existing")"

# --- plan: one entry per write, noops included so the reader sees every rule was checked ---
plan='[]'
add_call() {  # add_call <action> <method> <path> <body-json> <what>
  plan="$(jq -c --arg a "$1" --arg m "$2" --arg p "$3" --argjson b "$4" --arg w "$5" \
    '. + [{action: $a, method: $m, path: $p, what: $w, body: $b}]' <<<"$plan")"
}

want="$(jq -c "$JQ_LIB .protection | strip" "$policy")"
if [ "$want" = null ]; then
  # The policy keeps no classic protection: one on GitHub is removed (its rules are a ruleset's).
  if [ "$current_prot" = null ]; then action=noop; else action=delete; fi
  add_call "$action" DELETE "$prot_path" null "no classic branch protection on $BRANCH"
else
  if [ "$current_prot" = null ]; then action=create
  elif jq -e --argjson w "$want" "$JQ_LIB same(\$w)" <<<"$current_prot" >/dev/null; then action=noop
  else action=update; fi
  add_call "$action" PUT "$prot_path" "$want" "branch protection for $BRANCH"
fi

while IFS= read -r rs; do
  [ -n "$rs" ] || continue
  name="$(jq -r .name <<<"$rs")"
  id="$(jq -r --arg n "$name" '[.[] | select(.name == $n) | .id][0] // empty' <<<"$existing")"
  if [ -z "$id" ]; then
    add_call create POST "repos/$REPO/rulesets" "$rs" "ruleset $name"; continue
  fi
  cur="$(gh api "repos/$REPO/rulesets/$id")" || die "cannot read ruleset $name (id $id)"
  cur="$(jq -c '{name, target, enforcement, bypass_actors: (.bypass_actors // []), conditions, rules}' <<<"$cur")"
  if jq -e --argjson w "$rs" "$JQ_LIB same(\$w)" <<<"$cur" >/dev/null; then action=noop; else action=update; fi
  add_call "$action" PUT "repos/$REPO/rulesets/$id" "$rs" "ruleset $name"
done < <(jq -c --arg app "$APP_ID" "$JQ_LIB (.rulesets // [])[] | strip
  | .bypass_actors = (if \$app == \"\" then []
                      else [{actor_id: (\$app | tonumber), actor_type: \"Integration\", bypass_mode: \"always\"}] end)" "$policy")

unmanaged="$(jq -c --argjson want "$(jq -c '[(.rulesets // [])[].name]' "$policy")" \
  '[.[] | select(.name | IN($want[]) | not) | .name]' <<<"$existing")"
unexpressed="$(jq -c '[(.unexpressed // [])[] | {rule, why, adr}]' "$policy")"

# --- apply ---
results='[]'
if [ "$apply" = 1 ]; then
  while IFS= read -r call; do
    m="$(jq -r .method <<<"$call")"; p="$(jq -r .path <<<"$call")"
    if [ "$m" = DELETE ]; then send() { gh api -X DELETE "$p"; }; else send() { jq -c .body <<<"$call" | gh api -X "$m" "$p" --input -; }; fi
    if out="$(send 2>&1 >/dev/null)"; then r=ok; out=""
    else r=failed; warn "$m $p failed: $(tail -n1 <<<"$out")"; fi
    results="$(jq -c --arg p "$p" --arg m "$m" --arg r "$r" --arg e "$(tail -n1 <<<"$out")" \
      '. + [{method: $m, path: $p, result: $r} + (if $e == "" then {} else {error: $e} end)]' <<<"$results")"
  done < <(jq -c '.[] | select(.action != "noop")' <<<"$plan")
fi

out="$(jq -cn --arg mode "$([ "$apply" = 1 ] && echo apply || echo dry-run)" --arg repo "$REPO" \
  --arg branch "$BRANCH" --argjson calls "$plan" --argjson results "$results" \
  --argjson unmanaged "$unmanaged" --argjson unexpressed "$unexpressed" \
  --arg app "$APP_ID" --argjson rulesets "$(jq -c '[(.rulesets // [])[].name]' "$policy")" \
  '{mode: $mode, repo: $repo, branch: $branch, calls: $calls, results: $results,
    unmanaged_rulesets: $unmanaged, unexpressed: $unexpressed}
   + (if $app == "" then {} else {app_bypass: {actor_id: ($app | tonumber), actor_type: "Integration",
        bypass_mode: "always", rulesets: $rulesets}} end)')"
if [ "$json" = 1 ]; then printf '%s\n' "$out"; else
  jq -r '
    (.calls[] | "# \(.action): \(.what)" + (if .action == "noop" then " (already matches; not sent)" else "" end),
                (if .action == "noop" then empty
                 elif .method == "DELETE" then "gh api -X DELETE \(.path)"
                 else "gh api -X \(.method) \(.path) --input - <<< \(.body | tojson | @sh)" end)),
    (.results[] | "# \(.result): \(.method) \(.path)" + (if .error then " (\(.error))" else "" end)),
    (.unmanaged_rulesets[] | "# unmanaged ruleset on GitHub, not in the policy (left alone): \(.)"),
    (.unexpressed[] | "# NOT EXPRESSIBLE on GitHub, not enforced: \(.rule). \(.why) See \(.adr // "the policy").") ,
    (.app_bypass // empty | "# bypass actor: GitHub App \(.actor_id) (\(.actor_type), \(.bypass_mode)), the only one, on ruleset(s) \(.rulesets | join(", ")) (FACTORY_APP_ID)"),
    (if .mode == "dry-run" then
       "# dry run: \([.calls[] | select(.action != "noop")] | length) write(s) planned, none sent; --apply to send"
     else "# applied \([.results[] | select(.result == "ok")] | length) of \(.results | length) write(s)" end)
  ' <<<"$out"
fi
if jq -e '[.results[] | select(.result != "ok")] | length > 0' <<<"$out" >/dev/null; then exit 1; fi
