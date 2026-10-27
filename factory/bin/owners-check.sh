#!/usr/bin/env bash
# owners-check — two distinct code-owner approvals on the factory's own paths (specs/factory-step3-v1
# TB10, ticket T29; ci:G12, merge:G6; SPEC-v0.2 trust section: two human approvals on everything that
# defines the factory's quality settings).
#
#   owners-check.sh                      CI's `owners` job, run from ./.base (I16), on pull_request and
#                                        the queue path (I18)
#   owners-check.sh --only <path>        the same count for one path, whatever the PR class and whether
#                                        or not the path is protected (halt-guard.sh asks it for
#                                        factory/HALT)
#   owners-check.sh --rerun              reviews.yml on pull_request_review: re-run the `owners` and
#                                        `halt-guard` jobs of the PR head's latest gates run
#
# GitHub counts one code owner per path (ruleset `pull_request.require_code_owner_review`) and its
# required_reviewers rule needs a Team, which a user-owned repo has none of (ADR-0004). So this gate
# counts: a PR whose BASE...HEAD touches a protected path (factory/**, .adlc/**, .github/**, .claude/**
# and the CODEOWNERS file itself, so a PR cannot add an owner on one approval) passes only with two
# distinct approvals by owners of that path. The owners are the base's CODEOWNERS (.github/, root,
# docs/, GitHub's order), the last matching line, as GitHub reads it; a team or e-mail owner cannot be
# counted from a review and is named. An approval counts when the reviewer's latest decisive review
# (APPROVED, CHANGES_REQUESTED, DISMISSED) is APPROVED and was given on the PR's current head commit,
# so a push after the approval voids it (require_last_push_approval), and the PR's author never counts.
# On the queue path the PR is GATE_QUEUE_PR (or the merge group's), and its head is read from GitHub.
# A `halt` PR passes here: removing factory/HALT is halt-guard.sh's, adding it needs no approval.
# The serial queue lands with the App, which bypasses GitHub's own review rule, so on that path this
# gate is the only review count there is.
#
# GitHub re-runs nothing on a review: --rerun asks for it (POST actions/jobs/<id>/rerun with the
# workflow's token; whether a GITHUB_TOKEN re-run starts the job is a kit line, TB12).
#
# stdout: one JSON line {pr, head, class, protected: [{path, owners, approvals, uncountable}], approvers,
# result} (result pass | short); with nothing to count, {pr, class, result: pass} (+ protected: [] when
# no protected path is touched); --rerun: {pr, head, run, rerun: [job names]}.
# Exit 0 pass, 2 short (each path named with its count) or the PR refused by lib/gate-context.sh,
# 1 operational error (an unreadable CODEOWNERS or review list fails closed).
set -euo pipefail
PROG=owners-check
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/gate-context.sh
. "$(dirname "$0")/lib/gate-context.sh"

OC_MIN=2
OC_PROTECTED_RE='^(factory/|\.adlc/|\.github/|\.claude/|CODEOWNERS$|docs/CODEOWNERS$)'

# CODEOWNERS patterns (gitignore rules GitHub uses) as anchored regexes; a pattern this does not
# handle (`!`, `[`, `\`) stops the gate rather than guess.
OC_JQ='
def pat_re:
  if test("[!\\[\\\\]") then error("CODEOWNERS pattern \(.) uses syntax this gate does not read") else . end
  | (startswith("/") or (rtrimstr("/") | test("/"))) as $anchored
  | ltrimstr("/") as $p
  | ($p | endswith("/")) as $dir
  | ($p | rtrimstr("/")
     | gsub("\\."; "\\.") | gsub("\\*\\*/"; "\u0002") | gsub("/\\*\\*"; "\u0003") | gsub("\\*\\*"; "\u0001")
     | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]")
     | gsub("\u0002"; "(.*/)?") | gsub("\u0003"; "/.*") | gsub("\u0001"; ".*")) as $body
  | (if $anchored then "^" else "^(.*/)?" end) + $body + (if $dir then "/.*$" else "(/.*)?$" end);
def owners_of($rules; $path): [$rules[] | select(.re as $r | $path | test($r))] | last | .owners // [];
'

oc_codeowners() {  # oc_codeowners <sha>: [{pattern, re, owners}] of the CODEOWNERS GitHub reads at <sha>
  local f body=""
  for f in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    if body="$(git show "$1:$f" 2>/dev/null)"; then break; fi
    body=""
  done
  [ -n "$body" ] || { echo '[]'; return 0; }
  sed -e 's/[[:space:]]#.*$//' -e 's/^#.*$//' <<<"$body" | awk 'NF { print }' |
    jq -Rsc "$OC_JQ"' [split("\n")[] | select(. != "") | [splits("[[:space:]]+")] | {pattern: .[0], re: (.[0] | pat_re), owners: .[1:]}]' ||
    die "cannot read the CODEOWNERS of ${1:0:12}"
}

oc_pr_head() {  # oc_pr_head: the PR's head sha (pull_request: the event's; otherwise GitHub's)
  if [ "$GC_EVENT" = pull_request ]; then printf '%s\n' "$GC_HEAD"; return; fi
  gh api "repos/$GC_REPO/pulls/$GC_PR" --jq .head.sha || die "cannot read PR #$GC_PR"
}

oc_approvers() {  # oc_approvers <head sha>: [logins] whose latest decisive review is APPROVED on <head>
  local reviews
  reviews="$(gh api --paginate "repos/$GC_REPO/pulls/$GC_PR/reviews")" || die "cannot read the reviews of PR #$GC_PR"
  jq -sc --arg h "$1" --arg author "$GC_AUTHOR" '
    [.[] | if type == "array" then .[] else . end | select(.state | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED"))]
    | group_by(.user.login) | map(last) | map(select(.state == "APPROVED" and .commit_id == $h and .user.login != $author))
    | map(.user.login) | unique' <<<"$reviews"
}

oc_rerun() {
  local ev pr head runs run jobs jid name done_=()
  [ -n "${GITHUB_EVENT_PATH:-}" ] && ev="$(jq -c . "$GITHUB_EVENT_PATH" 2>/dev/null)" || die "--rerun needs GITHUB_EVENT_PATH (a pull_request_review payload)"
  pr="$(jq -r '.pull_request.number // empty' <<<"$ev")"; head="$(jq -r '.pull_request.head.sha // empty' <<<"$ev")"
  valid_issue "$pr" && [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "the event carries no pull_request number and head sha"
  REPO="$(resolve_repo "${GITHUB_REPOSITORY:-}")"
  runs="$(gh api "repos/$REPO/actions/runs?head_sha=$head&event=pull_request")" || die "cannot list the runs of $head"
  run="$(jq -r '[.workflow_runs[] | select(.path == ".github/workflows/gates.yml" or (.path | startswith(".github/workflows/gates.yml@")))] | max_by(.id) | .id // empty' <<<"$runs")"
  if [ -z "$run" ]; then
    echo "owners-check: no gates run for #$pr at ${head:0:12} yet: its jobs will read the reviews when they run" >&2
    jq -cn --argjson p "$pr" --arg h "$head" '{pr: $p, head: $h, run: null, rerun: []}'; return 0
  fi
  jobs="$(gh api "repos/$REPO/actions/runs/$run/jobs")" || die "cannot list the jobs of run $run"
  while IFS=$'\t' read -r jid name; do
    [ -n "$jid" ] || continue
    gh api -X POST "repos/$REPO/actions/jobs/$jid/rerun" >/dev/null || die "re-run of $name (job $jid, run $run) was refused"
    done_+=("$name")
    echo "owners-check: re-ran $name (job $jid of gates run $run) for #$pr: a review changed its count" >&2
  done < <(jq -r '.jobs[] | select(.name | IN("owners", "halt-guard")) | [.id, .name] | @tsv' <<<"$jobs")
  jq -cn --argjson p "$pr" --arg h "$head" --argjson r "$run" '{pr: $p, head: $h, run: $r, rerun: $ARGS.positional}' \
    --args "${done_[@]+"${done_[@]}"}"
}

only=""
case "${1:-}" in
  -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
  --rerun) shift; [ $# -eq 0 ] || die "--rerun takes no argument"; need gh jq; oc_rerun; exit 0 ;;
  --only) only="${2:-}"; [ -n "$only" ] || die "--only needs a path"; shift 2 ;;
esac
need git jq gh
gate_begin "$@"
[ -n "$GC_PR" ] || die "owners-check counts a PR's reviews: no PR on a $GC_EVENT event"

if [ -z "$only" ] && [ "$GC_CLASS" = halt ]; then
  echo "owners-check: pass: class halt: adding factory/HALT needs no approval, removing it is halt-guard's" >&2
  jq -cn --argjson p "$GC_PR" '{pr: $p, class: "halt", result: "pass"}'
  exit 0
fi

if [ -n "$only" ]; then paths="$(jq -cn --arg p "$only" '[$p]')"
else
  changed="$(git diff --name-only "$GC_BASE...$GC_HEAD")" || die "cannot diff ${GC_BASE:0:12}...${GC_HEAD:0:12}"
  paths="$(jq -Rsc --arg re "$OC_PROTECTED_RE" 'split("\n") | map(select(. != "" and test($re)))' <<<"$changed")"
fi
if [ "$paths" = '[]' ]; then
  echo "owners-check: pass: #$GC_PR touches no protected path (factory/**, .adlc/**, .github/**, .claude/**, CODEOWNERS)" >&2
  jq -cn --argjson p "$GC_PR" --arg c "$GC_CLASS" '{pr: $p, class: $c, protected: [], result: "pass"}'
  exit 0
fi

RULES="$(oc_codeowners "$GC_BASE")"
HEAD_SHA="$(oc_pr_head)"
APPROVERS="$(oc_approvers "$HEAD_SHA")"
out="$(jq -c --argjson rules "$RULES" --argjson paths "$paths" --argjson ap "$APPROVERS" --argjson pr "$GC_PR" \
  --arg h "$HEAD_SHA" --arg c "$GC_CLASS" --argjson min "$OC_MIN" "$OC_JQ"'
  [$paths[] as $p | owners_of($rules; $p) as $o
   | {path: $p, owners: $o, approvals: [$ap[] | select(("@" + . | ascii_downcase) as $u | $o | map(ascii_downcase) | index($u))],
      uncountable: [$o[] | select(test("^@[^/]+$") | not)]}] as $rows
  | {pr: $pr, head: $h, class: $c, protected: $rows, approvers: $ap,
     result: (if all($rows[]; (.approvals | length) >= $min) then "pass" else "short" end)}' <<<'null')" ||
  die "cannot evaluate the owners of #$GC_PR"
printf '%s\n' "$out"
jq -r '.protected[] | select((.uncountable | length) > 0)
       | "owners-check: \(.path): owner(s) \(.uncountable | join(", ")) cannot be counted from a review (a team or an e-mail)"' <<<"$out" >&2
if [ "$(jq -r .result <<<"$out")" = pass ]; then
  jq -r '"owners-check: pass: #\(.pr): every protected path has \($min) or more distinct code-owner approvals on \(.head[0:12]) (\(.approvers | join(", ")))"' \
    --argjson min "$OC_MIN" <<<"$out" >&2
  exit 0
fi
jq -r '.protected[] | select((.approvals | length) < $min)
       | "owners-check: SHORT: \(.path) needs \($min) distinct approvals by its code owners (\(if (.owners | length) == 0 then "none in CODEOWNERS" else .owners | join(" ") end)) on the PR head \($h[0:12]); it has \(.approvals | length)\(if (.approvals | length) > 0 then " (" + (.approvals | join(", ")) + ")" else "" end)"' \
  --argjson min "$OC_MIN" --arg h "$HEAD_SHA" <<<"$out" >&2
exit 2
