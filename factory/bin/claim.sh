#!/usr/bin/env bash
# claim — take the oldest claimable Issue through the git-ref lock (SPEC-v0.2 "Claim protocol").
#
#   claim.sh [--json] [--capacity light|heavy]                 list what this node could claim (dry run)
#   claim.sh --apply [--json] --handle H --slots N [--run-id ID] [--capacity light|heavy]
#                                                               claim the first unlocked one
#   claim.sh --check <n> [--json]                               report a lock: absent, fresh or stale
#   common: [--repo owner/name] [--manifest nodes/<handle>.json]
#
# Claimable = open, labeled `ready` and exactly one known `w:<weight>` with weight <= capacity,
# oldest first, and no refs/locks/issue-<n>. On --apply it POSTs the lock ref; on 422 or any other
# error it moves to the next Issue, never retrying the same one. On success it assigns @me, adds
# `in-progress` and writes the one claim comment. One claim per run (one run loop per slot).
# Nothing claimable, or losing every race, is not an error: exit 0 with "claimed": null. Exit 1
# when every attempt failed for a reason other than 422 (GitHub unreachable, nodes branch missing).
#
# Capacity defaults to light (never over-claim); the run loop passes --capacity.
set -euo pipefail
PROG=claim
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/lock.sh
. "$(dirname "$0")/lib/lock.sh"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

apply=0 json=0 check="" capacity="${FACTORY_CAPACITY:-light}" repo="" manifest="" handle="" slots=""
run_id="${FACTORY_RUN_ID:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --json) json=1 ;;
    --check) check="${2:-}"; shift ;;
    --capacity) capacity="${2:-}"; shift ;;
    --repo) repo="${2:-}"; shift ;;
    --manifest) manifest="${2:-}"; shift ;;
    --handle) handle="${2:-}"; shift ;;
    --slots) slots="${2:-}"; shift ;;
    --run-id) run_id="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need gh jq
REPO="$(resolve_repo "$repo")"
NOW="$(now_epoch)"

if [ -n "$check" ]; then
  valid_issue "$check" || die "--check needs an issue number, got '$check'"
  [ "$apply" = 0 ] || die "--check is a reader; it takes no --apply"
  st="$(lock_state "$check" "$NOW")"
  if [ "$json" = 1 ]; then printf '%s\n' "$st"; else
    jq -r '"issue #\(.issue): \(.state)"
           + (if .state == "absent" then "" else
              " (held by \(.handle // "?"), run \(.run_id // "?"), commit \(.sha[0:12]) \(.age_seconds)s old; stale after \(.stale_after_hours) h)" end)' <<<"$st"
  fi
  exit 0
fi

case "$capacity" in light) cap=1 ;; heavy) cap=2 ;; *) die "--capacity must be light or heavy, got '$capacity'" ;; esac
load_node "$manifest" "$handle" "$slots"
if [ "$apply" = 1 ]; then
  [ -n "$NODE_HANDLE" ] || die "--apply needs --handle (or --manifest / FACTORY_HANDLE)"
  [ -n "$NODE_SLOTS" ] || die "--apply needs --slots (or --manifest / FACTORY_SLOTS)"
  run_id="${run_id:-$NODE_HANDLE-$NOW-$$}"
fi

# gh issue list returns newest first and 30 by default; ask for enough and sort ourselves.
issues="$(gh issue list --repo "$REPO" --state open --label ready --limit 1000 \
            --json number,title,createdAt,labels)" || die "cannot list ready Issues"
locks="$(lock_index)" || die "cannot list lock refs"

plan="$(jq -c --argjson locks "$locks" --argjson cap "$cap" '
  def rank: {"light": 1, "heavy": 2}[.];
  [ .[] | . + {weights: [.labels[].name | select(startswith("w:")) | ltrimstr("w:")]} ]
  | sort_by(.createdAt, .number)
  | ($locks | map(.issue)) as $held
  | { locked:     [ .[] | select(.number | IN($held[])) | .number ],
      candidates: [ .[] | select((.number | IN($held[])) | not)
                        | select((.weights | length) == 1 and (.weights[0] | rank) != null
                                 and (.weights[0] | rank) <= $cap)
                        | {number, title, weight: .weights[0], created_at: .createdAt} ] }' <<<"$issues")"

emit() {  # emit <claimed|null> <attempts-json> <extra-json>
  local out
  out="$(jq -c --arg mode "$([ "$apply" = 1 ] && echo apply || echo dry-run)" --arg repo "$REPO" \
           --arg handle "$NODE_HANDLE" --arg cap "$capacity" --argjson claimed "$1" \
           --argjson attempts "$2" --argjson extra "$3" \
    '{mode: $mode, repo: $repo, handle: (if $handle == "" then null else $handle end),
      capacity: $cap} + . + {claimed: $claimed, attempts: $attempts} + $extra' <<<"$plan")"
  if [ "$json" = 1 ]; then printf '%s\n' "$out"; else
    jq -r '"\(.mode) as \(.handle // "(no handle)"), capacity \(.capacity), repo \(.repo)",
           (.locked[] | "  locked     #\(.)"),
           (.candidates[] | "  claimable  #\(.number) w:\(.weight) \(.created_at) \(.title)"),
           (.attempts[] | "  attempt    #\(.issue): \(.result)\(if .detail then " (\(.detail))" else "" end)"),
           (if .mode == "dry-run" then
              (if (.candidates | length) > 0 then "would claim #\(.candidates[0].number) (first unlocked; --apply to claim)"
               else "nothing claimable" end)
            elif .claimed then "claimed #\(.claimed): \(.ref) -> \(.sha), expected finish \(.expected_finish)"
                 + (if .announced then "" else " (assign/label/comment FAILED; lock held)" end)
            else "nothing claimed" end)' <<<"$out"
  fi
}

if [ "$apply" = 0 ]; then emit null '[]' '{}'; exit 0; fi

attempts='[]'
add_attempt() { attempts="$(jq -c --argjson n "$1" --arg r "$2" --arg d "$3" \
  '. + [{issue: $n, result: $r} + (if $d == "" then {} else {detail: $d} end)]' <<<"$attempts")"; }

while read -r n weight <&3; do
  [ -n "$n" ] || continue
  claimed_at="$(epoch_to_iso "$NOW")"
  payload="$(lock_payload "$NODE_HANDLE" "$run_id" "$NODE_SLOTS" "$claimed_at")"
  if ! sha="$(lock_commit "$n" "$payload")"; then
    add_attempt "$n" error "could not create the lock commit"; continue
  fi
  ref="$(lock_ref "$n")"
  if ! err="$(gh api -X POST "repos/$REPO/git/refs" -f ref="$ref" -f sha="$sha" 2>&1 >/dev/null)"; then
    if grep -q 'HTTP 422' <<<"$err"; then add_attempt "$n" conflict "ref exists (HTTP 422)"
    else add_attempt "$n" error "$(tail -n1 <<<"$err")"; fi
    continue                      # no retry on the same Issue
  fi
  add_attempt "$n" claimed ""
  minutes="$(budget ".weights.\"$weight\".wallClockMinutes")"
  finish="$(epoch_to_iso "$((NOW + minutes * 60))")"
  body="Claimed by node \`$NODE_HANDLE\`: fleet run \`$run_id\`, $NODE_SLOTS slot(s), expected finish $finish (w:$weight, ${minutes} min wall clock). Lock \`$ref\` at \`$sha\`."
  announced=true
  gh issue edit "$n" --repo "$REPO" --add-assignee @me --add-label in-progress >/dev/null ||
    { warn "claimed #$n but could not assign/label it"; announced=false; }
  gh issue comment "$n" --repo "$REPO" --body "$body" >/dev/null ||
    { warn "claimed #$n but could not comment on it"; announced=false; }
  emit "$n" "$attempts" "$(jq -cn --arg ref "$ref" --arg sha "$sha" --arg run "$run_id" \
         --argjson slots "$NODE_SLOTS" --arg at "$claimed_at" --arg fin "$finish" --argjson ann "$announced" \
         '{ref: $ref, sha: $sha, run_id: $run, slots: $slots, claimed_at: $at, expected_finish: $fin, announced: $ann}')"
  exit 0
done 3< <(jq -r '.candidates[] | "\(.number) \(.weight)"' <<<"$plan")

emit null "$attempts" '{}'
# Losing every race is a normal outcome; failing to talk to GitHub at all is not.
if jq -e 'length > 0 and all(.result == "error")' <<<"$attempts" >/dev/null; then exit 1; fi
