#!/usr/bin/env bash
# tier-order — foundation first: tier 0 before tier 1 before tier 2 (SPEC-v0.2 Merge; specs/factory-step3-v1
# TB8, ticket T27; merge:G5, ci:G10).
#
#   tier-order.sh                                  CI's `tier-order` job, run from ./.base (I16), on
#                                                  pull_request and merge_group (I18)
#   tier-order.sh --ticket <id> [--base <sha>]     the same answer outside a PR (labeler.sh's re-run)
#   tier-order.sh --order [--base <sha>]           the merge order: one JSON line per approved, green,
#                                                  open ticket PR, by tier, then first green, then
#                                                  number (first-done-first; the queue keeps it, TB9)
#
# A tier-n ticket PR waits while an open ticket PR of a lower tier is approved and green: exit 2,
# naming each blocking PR. Within a tier nothing waits here; the order is first-done-first by the
# PR's first green `gates` time, which --order prints and the queue keeps.
#
#   ticket PR  an open PR from this repo (never a fork) whose head is ticket/<id>/<handle> and whose
#              ticket is open in the base store; its tier is the body header `tier: <n>` there
#   approved   the latest decisive review (APPROVED, CHANGES_REQUESTED or DISMISSED) of each reviewer:
#              at least one APPROVED and no CHANGES_REQUESTED
#   green      the latest `gates` run (.github/workflows/gates.yml, event pull_request) on the PR's head
#              has a completed job concluded success, skipped or neutral for every job id of the base's
#              gates.yml except tier-order (its own check would make two PRs wait on each other); the
#              Actions API names a job by its `name:`, which no gates.yml job sets (so the id)
#   first green  the latest completed_at of those jobs: when the run turned green
#
# Tiers and the gates job list come from one commit, the base (lib/gate-context.sh gc_store_sha), PR
# state from the GitHub API with the job's token: `gh pr list` and the Actions runs and jobs of each
# head. A lower-tier PR whose state cannot be read fails closed (exit 1), never a silent pass. Any
# APPROVED review counts here; who may approve is branch protection's (TB10).
#
# Exit 0 pass (also: a desk, halt or human PR), 2 wait (or the PR refused by lib/gate-context.sh),
# 1 operational error.
set -euo pipefail
PROG=tier-order
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/gate-context.sh
. "$(dirname "$0")/lib/gate-context.sh"
case "${1:-}" in -h|--help) sed -n '2,32p' "$0" | sed '/^set -euo/,$d'; exit 0 ;; esac
need git jq gh

# to_jobs <sha>: the job ids of gates.yml at <sha>, one per line (two-space keys under `jobs:`, bare
# or quoted).
to_jobs() {
  git show "$1:.github/workflows/gates.yml" |
    awk '/^jobs:/ {in_j = 1; next} in_j && /^[^ #]/ {in_j = 0} in_j && /^  ["'"'"']?[A-Za-z0-9_-]+["'"'"']?:/ {sub(/^  ["'"'"']?/, ""); sub(/["'"'"']?:.*/, ""); print}'
}

# to_green <head>: {run, green, first_green, missing: [job], red: ["job=conclusion"]} of the latest
# gates run on <head>, judged against $JOBS.
to_green() {
  local head="$1" runs rid jobs
  runs="$(gh api "repos/$REPO/actions/runs?head_sha=$head&event=pull_request&per_page=100")" ||
    die "cannot read the Actions runs of $head"
  rid="$(jq -r '[.workflow_runs[]? | select(.path == ".github/workflows/gates.yml")] | max_by(.id) | .id // empty' <<<"$runs")" ||
    die "the Actions runs of $head are not JSON"
  if [ -z "$rid" ]; then
    jq -cn --argjson want "$JOBS" '{run: null, green: false, first_green: null, missing: $want, red: []}'; return
  fi
  jobs="$(gh api "repos/$REPO/actions/runs/$rid/jobs?filter=latest&per_page=100")" || die "cannot read the jobs of run $rid"
  jq -c --argjson want "$JOBS" --argjson rid "$rid" '
    [.jobs[]? | select(.name | IN($want[]))] | group_by(.name) | map(max_by(.id)) as $have
    | [$have[] | select(.status == "completed" and (.conclusion | IN("success", "skipped", "neutral")))] as $ok
    | {run: $rid, missing: [$want[] | select(IN($have[].name) | not)],
       red: [$have[] | select(IN($ok[]) | not) | "\(.name)=\(.conclusion // .status)"]}
    | .green = ((.missing | length) == 0 and (.red | length) == 0)
    | .first_green = (if .green then ([$ok[].completed_at] | max) else null end)' <<<"$jobs" ||
    die "the jobs of run $rid are not JSON"
}

ORDER=0 args=()
for a in "$@"; do if [ "$a" = --order ]; then ORDER=1; else args+=("$a"); fi; done

if [ "$ORDER" = 1 ]; then
  base="" repo=""; set -- "${args[@]+"${args[@]}"}"
  while [ $# -gt 0 ]; do
    case "$1" in --base) base="${2:-}"; shift ;; --repo) repo="${2:-}"; shift ;; *) die "--order takes only --base and --repo" ;; esac
    shift
  done
  GC_BASE="$(git rev-parse --verify -q "${base:-HEAD}^{commit}")" || die "base ${base:-HEAD} is not a commit here"
  GC_TICKET="" GC_CLASS=order GC_BASE_BRANCH=main GC_PR=""
  REPO="$(resolve_repo "$repo")"
else
  gate_begin "${args[@]+"${args[@]}"}"
  if [ "$GC_CLASS" != ticket ]; then
    echo "tier-order: pass: class $GC_CLASS: no ticket, no tier" >&2; exit 0
  fi
  REPO="${GC_REPO:-$(resolve_repo)}"
fi

STORE_SHA="$(gc_store_sha "$GC_BASE" "$GC_BASE_BRANCH")"
STORE="$(gc_store "$STORE_SHA")"
JOBS="$(to_jobs "$STORE_SHA" | jq -Rsc 'split("\n") | map(select(. != "" and . != "tier-order"))')" ||
  die "cannot read .github/workflows/gates.yml at ${STORE_SHA:0:12}"
[ "$JOBS" != '[]' ] || die "gates.yml at ${STORE_SHA:0:12} names no job"

MY_TIER=""
if [ "$ORDER" = 0 ]; then
  MY_TIER="$(jq -r --arg id "$GC_TICKET" "$GC_STORE_JQ"'[.[] | select(.id == $id and (.completed != true))] | first | if . == null then "absent" else (gc_tier // "none") end' <<<"$STORE")"
  case "$MY_TIER" in
    absent) refuse "ticket $GC_TICKET is not open in the store at ${STORE_SHA:0:12}" ;;
    none) refuse "ticket $GC_TICKET has no 'tier: <n>' header in the store at ${STORE_SHA:0:12}" ;;
  esac
fi

prs="$(gh pr list --repo "$REPO" --state open --limit 200 --json number,headRefName,headRefOid,isCrossRepository,reviews)" ||
  die "cannot list the open PRs of $REPO"
# The open ticket PRs with their tier, approval, and (for the ones that can block or be ordered) green.
cands="$(jq -c --argjson T "$STORE" "$GC_STORE_JQ"'
  def approved: [.reviews[]? | select(.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED"))]
    | group_by(.author.login) | map(last | .state) | (index("APPROVED") != null) and (index("CHANGES_REQUESTED") == null);
  ($T | map(select(.completed != true) | {key: .id, value: gc_tier}) | from_entries) as $tier
  | .[] | select(.isCrossRepository != true)
  | (.headRefName | capture("^ticket/(?<id>[A-Za-z0-9][A-Za-z0-9._:#-]{0,127})/(?<h>[A-Za-z0-9][A-Za-z0-9-]{0,38})$")?) as $r
  | select($r != null and $tier[$r.id] != null)
  | {pr: .number, ticket: $r.id, tier: $tier[$r.id], head: .headRefOid, approved: approved}' <<<"$prs")" ||
  die "the open PRs are not JSON"

rows=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  if [ "$ORDER" = 0 ]; then
    # Only an approved PR of a lower tier can make this one wait; this PR's own ticket never does.
    jq -e --argjson t "$MY_TIER" --arg id "$GC_TICKET" '.approved and .tier < $t and .ticket != $id' <<<"$c" >/dev/null || continue
  else
    jq -e .approved <<<"$c" >/dev/null || continue
  fi
  g="$(to_green "$(jq -r .head <<<"$c")")"
  rows+="$(jq -c --argjson g "$g" '. + {green: $g.green, first_green: $g.first_green, run: $g.run, missing: $g.missing, red: $g.red}' <<<"$c")"$'\n'
done <<<"$cands"
rows="$(jq -sc . <<<"$rows")"

if [ "$ORDER" = 1 ]; then
  jq -c '[.[] | select(.green)] | sort_by(.tier, .first_green, .pr) | to_entries[] | .value + {position: (.key + 1)} | del(.missing, .red)' <<<"$rows"
  exit 0
fi

blockers="$(jq -c '[.[] | select(.green)] | sort_by(.pr)' <<<"$rows")"
jq -r --arg id "$GC_TICKET" --argjson t "$MY_TIER" '.[] | select(.green | not)
  | "tier-order: not waiting on #\(.pr) (\(.ticket), tier \(.tier), approved): not green (\((.missing | map("\(.)=absent")) + .red | join(", ")))"' <<<"$rows" >&2
if [ "$blockers" = '[]' ]; then
  echo "tier-order: pass: $GC_TICKET (tier $MY_TIER) waits on no approved, green, open ticket PR of a lower tier" >&2
  jq -cn --arg id "$GC_TICKET" --argjson t "$MY_TIER" --arg pr "$GC_PR" '{ticket: $id, tier: $t, pr: ($pr | tonumber? // null), blocking: [], result: "pass"}'
  exit 0
fi
jq -r --arg id "$GC_TICKET" --argjson t "$MY_TIER" '.[] |
  "tier-order: WAIT: \($id) (tier \($t)) waits on #\(.pr) (\(.ticket), tier \(.tier), approved, green since \(.first_green))"' <<<"$blockers" >&2
jq -cn --arg id "$GC_TICKET" --argjson t "$MY_TIER" --arg pr "$GC_PR" --argjson b "$blockers" \
  '{ticket: $id, tier: $t, pr: ($pr | tonumber? // null), blocking: [$b[].pr], result: "wait"}'
exit 2
