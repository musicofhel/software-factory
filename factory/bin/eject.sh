#!/usr/bin/env bash
# eject — a ticket PR leaves the queue (specs/factory-step3-v1 TB9, ticket T28; ci:G21, merge:G7).
#
#   eject.sh --pr <n> --reason conflict|red-queue-run [--base <sha>] [--head <sha>] [--queue <branch>]
#            [--repo <owner/name>] [--apply | --dry-run]
#   eject.sh --dequeued [--repo <owner/name>] [--apply | --dry-run]
#
# The first form is enqueue.sh's: the serial queue could not merge PR <n> onto main (conflict) or the
# gates on the queue commit failed (red-queue-run). The second is the native queue's: GitHub removed
# the PR from its merge queue (pull_request_target `dequeued`, GITHUB_EVENT_PATH). GitHub types that
# event's `reason` as a bare String and documents no values (records/TB9.md §1), so only the reasons
# below eject; any other (a person dequeued it, it merged) is reported `ignored` and changes nothing:
#   MERGE_CONFLICT → conflict        CI_FAILURE, CI_TIMEOUT → red-queue-run
# (compared, and recorded as dequeued_reason, in upper case).
#
# Reads, from a checkout of the repo with an `origin` remote (enqueue.yml's, of main): PR <n> (GET
# pulls/<n>: open, from this repo, head ticket/<id>/<handle>; a PR whose head moved past --head was
# re-pushed and is left alone), the open Issue whose body carries `Ticket: <id>` (mirror.sh), and
# origin/main:factory/ledger/ejections.jsonl (a malformed line is skipped). The strike is 1 + the earlier
# lines of that ticket there.
#
# Writes (--apply; the default is a dry run that prints the plan and writes nothing), in this order,
# each one only once the one before it succeeded:
#   1. one line {at, pr, ticket, handle, issue, head, base, queue, reason, strike} appended to
#      factory/ledger/ejections.jsonl on main by git plumbing (a temporary index, commit-tree on
#      origin/main, a push that never forces; a moved main is fetched and retried, 3 tries), committed
#      by github-actions[bot] with the trailers `Ejected: #<n>`, `Assisted-by: none`, `Node:
#      github-actions` and no `Ticket:` (post-merge would report any other id `foreign`). A line for
#      the same PR and head already on main is not written twice.
#   2. the PR: label `autorebase` (created when the repo lacks it), then closed with a comment of ids
#      and codes only (I8). claim.sh skips a ticket with any open ticket PR, so the PR must close.
#   3. the Issue: `ready` and `rebase-strike` added, `in-review` removed. mirror.sh never touches
#      `rebase-strike`; run.sh reads it on the next claim and rebases the ejected commit onto main
#      (a rebase strike never counts toward fleet's --max-strikes).
#
# stdout: one JSON line {result: ejected | would-eject | ignored | not-open | stale, ...}.
# Exit 0 done (also: nothing to eject), 1 operational error, 2 refused (not a ticket PR of this repo).
set -euo pipefail
PROG=eject
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/gate-context.sh
. "$(dirname "$0")/lib/gate-context.sh"
usage() { sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

EJ_IDENT_NAME='github-actions[bot]'
EJ_IDENT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
EJ_LEDGER=factory/ledger/ejections.jsonl

pr="" reason="" base="" head="" queue="" repo="" apply=0 dequeued=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr="${2:-}"; shift ;;
    --reason) reason="${2:-}"; shift ;;
    --base) base="${2:-}"; shift ;;
    --head) head="${2:-}"; shift ;;
    --queue) queue="${2:-}"; shift ;;
    --repo) repo="${2:-}"; shift ;;
    --dequeued) dequeued=1 ;;
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need git jq gh
REPO="$(resolve_repo "$repo")"
native_reason=""

if [ "$dequeued" = 1 ]; then
  [ -z "$pr$reason$base$head$queue" ] || die "--dequeued reads the event; it takes no --pr, --reason, --base, --head or --queue"
  [ -r "${GITHUB_EVENT_PATH:-}" ] || die "--dequeued needs GITHUB_EVENT_PATH (a pull_request_target dequeued event)"
  jq -e '.action == "dequeued" and (.pull_request.number | type) == "number"' "$GITHUB_EVENT_PATH" >/dev/null ||
    die "the event is not a pull_request dequeued event"
  pr="$(jq -r .pull_request.number "$GITHUB_EVENT_PATH")"
  valid_issue "$pr" || die "the event's pull_request.number '$pr' is not a PR number"
  native_reason="$(jq -r '.reason // "" | tostring | ascii_upcase' "$GITHUB_EVENT_PATH")"
  case "$native_reason" in
    MERGE_CONFLICT) reason=conflict ;;
    CI_FAILURE|CI_TIMEOUT) reason=red-queue-run ;;
    *) jq -cn --argjson pr "$pr" --arg r "$native_reason" \
         '{result: "ignored", pr: $pr, dequeued_reason: $r, detail: "not a reason that ejects (MERGE_CONFLICT, CI_FAILURE, CI_TIMEOUT)"}'
       exit 0 ;;
  esac
fi
valid_issue "$pr" || die "--pr must be a PR number, got '$pr'"
case "$reason" in conflict|red-queue-run) ;; *) die "--reason must be conflict or red-queue-run, got '$reason'" ;; esac
for s in "$base" "$head"; do [ -z "$s" ] || [[ "$s" =~ ^[0-9a-f]{40}$ ]] || die "--base and --head are full shas, got '$s'"; done
[ -z "$queue" ] || [[ "$queue" =~ ^factory-queue/pr-[1-9][0-9]*$ ]] || die "--queue must be factory-queue/pr-<n>, got '$queue'"

# ------------------------------------------------------------------ reads
pull="$(gh api "repos/$REPO/pulls/$pr")" || die "cannot read PR #$pr of $REPO"
[ "$(jq -r '.number // empty' <<<"$pull")" = "$pr" ] || die "repos/$REPO/pulls/$pr answered another PR"
if [ "$(jq -r .state <<<"$pull")" != open ]; then
  jq -cn --argjson pr "$pr" --arg s "$(jq -r .state <<<"$pull")" --argjson m "$(jq '.merged == true' <<<"$pull")" \
    '{result: "not-open", pr: $pr, state: $s, merged: $m}'
  exit 0
fi
[ "$(jq -r '.head.repo.full_name // empty' <<<"$pull")" = "$REPO" ] || refuse "PR #$pr is from another repo (never a ticket PR)"
pr_head="$(jq -r '.head.sha // empty' <<<"$pull")"
[[ "$pr_head" =~ ^[0-9a-f]{40}$ ]] || die "PR #$pr has no head sha in GitHub's answer"
tr_rc=0; tr="$(gc_ticket_ref "$(jq -r '.head.ref // empty' <<<"$pull")")" || tr_rc=$?
[ "$tr_rc" = 0 ] || refuse "PR #$pr: head ref $(jq -r '.head.ref // empty' <<<"$pull") is not ticket/<id>/<handle>"
ticket="${tr% *}" handle="${tr#* }"
if [ -n "$head" ] && [ "$head" != "$pr_head" ]; then
  jq -cn --argjson pr "$pr" --arg h "$head" --arg now "$pr_head" \
    '{result: "stale", pr: $pr, head: $h, pr_head: $now, detail: "the PR was pushed again since; its new head is gated anew"}'
  exit 0
fi
head="$pr_head"

issues="$(gh issue list --repo "$REPO" --state open --limit 1000 --json number,body,labels)" || die "cannot list the open Issues of $REPO"
issue="$(jq -r --arg t "$ticket" '[.[] | select([.body // "" | split("\n")[] | capture("^Ticket: (?<id>[^[:space:]]+)[[:space:]]*$") | .id] | first == $t)
  | .number] | first // empty' <<<"$issues")" || die "the open Issues are not JSON"
[ -n "$issue" ] || warn "no open Issue carries 'Ticket: $ticket'; the PR is ejected, no Issue is relabeled"

fetch_main() { git fetch -q origin "+refs/heads/main:refs/remotes/origin/main" || die "git fetch origin main failed"; }
# ledger_at <sha>: the ejection ledger at <sha>, or nothing.
ledger_at() { git show "$1:$EJ_LEDGER" 2>/dev/null || true; }
# recorded_at <sha>: the last line of the ledger at <sha> for this PR and head, or nothing.
recorded_at() {
  ledger_at "$1" | jq -cR --argjson pr "$pr" --arg h "$head" 'fromjson? | select(type == "object" and .pr == $pr and .head == $h)' 2>/dev/null |
    tail -n1 || true
}
# record_at <sha>: the record line on top of the ledger at <sha>; empty when this PR and head are
# already recorded there.
record_at() {
  local l; l="$(ledger_at "$1")"
  [ -z "$(recorded_at "$1")" ] || return 0
  jq -cn --arg at "$(epoch_to_iso "$(now_epoch)")" --argjson pr "$pr" --arg t "$ticket" --arg h "$handle" --arg i "$issue" \
    --arg head "$head" --arg b "$base" --arg q "$queue" --arg r "$reason" --arg nr "$native_reason" \
    --argjson k "$(( $(jq -cR --arg t "$ticket" 'fromjson? | select(type == "object" and .ticket == $t)' <<<"$l" 2>/dev/null | grep -c . || true) + 1 ))" \
    '{at: $at, pr: $pr, ticket: $t, handle: $h, issue: ($i | tonumber? // null), head: $head,
      base: (if $b == "" then null else $b end), queue: (if $q == "" then null else $q end), reason: $r, strike: $k}
     + (if $nr == "" then {} else {dequeued_reason: $nr} end)'
}

fetch_main
tip="$(git rev-parse refs/remotes/origin/main)"
record="$(record_at "$tip")"
comment_body() {  # the strike is the new line's, else the one already on main
  local k; k="$(jq -r '.strike // 0' <<<"${record:-$(recorded_at "$(git rev-parse refs/remotes/origin/main)")}")"
  jq -r --argjson pr "$pr" --arg t "$ticket" --arg r "$reason" --arg h "${head:0:12}" --arg b "${base:0:12}" \
    --argjson k "${k:-0}" '
    "Ejected from the queue: reason `\($r)`" + (if $k > 0 then ", rebase strike \($k)" else "" end)
    + ", head `\($h)`" + (if $b == "" then "" else ", base `\($b)`" end)
    + ". Ticket `\($t)` returns to ready with `rebase-strike`; the next claim rebases its commit onto main."' <<<null
}

if [ "$apply" = 0 ]; then
  jq -cn --arg rec "${record:-$(recorded_at "$tip")}" --argjson new "$([ -n "$record" ] && echo true || echo false)" \
    --argjson pr "$pr" --arg t "$ticket" --arg i "$issue" --arg c "$(comment_body)" '
    {result: "would-eject", pr: $pr, ticket: $t, issue: ($i | tonumber? // null),
     record: (if $rec == "" then null else ($rec | fromjson) end),
     actions: ([if $new then "ledger-append" else "ledger-present" end, "label-autorebase", "close-pr"]
               + (if $i == "" then [] else ["issue-ready-rebase-strike"] end)), comment: $c}'
  exit 0
fi

# ------------------------------------------------------------------ writes
actions='[]'
act() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }
# 1. the ledger line, on main.
if [ -z "$record" ]; then act ledger-present
else
  tries=0 pushed=0
  idx="$(mktemp)"; trap 'rm -f "$idx"' EXIT
  while [ "$tries" -lt 3 ] && [ "$pushed" = 0 ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 1 ]; then fetch_main; tip="$(git rev-parse refs/remotes/origin/main)"; record="$(record_at "$tip")"
      [ -n "$record" ] || { pushed=2; break; }
    fi
    blob="$( { ledger_at "$tip"; printf '%s\n' "$record"; } | git hash-object -w --stdin)" || die "git hash-object failed"
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git read-tree "$tip" || die "git read-tree $tip failed"
    GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$blob,$EJ_LEDGER" || die "git update-index failed"
    tree="$(GIT_INDEX_FILE="$idx" git write-tree)" || die "git write-tree failed"
    commit="$(printf 'factory: eject PR #%s (%s): %s\n\nEjected: #%s\nAssisted-by: none\nNode: github-actions\n' \
                "$pr" "$ticket" "$reason" "$pr" |
              GIT_AUTHOR_NAME="$EJ_IDENT_NAME" GIT_AUTHOR_EMAIL="$EJ_IDENT_EMAIL" \
              GIT_COMMITTER_NAME="$EJ_IDENT_NAME" GIT_COMMITTER_EMAIL="$EJ_IDENT_EMAIL" git commit-tree "$tree" -p "$tip")" ||
      die "git commit-tree failed"
    if git push -q origin "$commit:refs/heads/main" 2>/dev/null; then pushed=1; fi
  done
  case "$pushed" in
    1) act ledger-append ;;
    2) act ledger-present ;;
    *) die "could not append to $EJ_LEDGER on main in 3 tries (main kept moving, or the push is refused)" ;;
  esac
fi
record="${record:-$(recorded_at "$(git rev-parse refs/remotes/origin/main)")}"

# 2. the PR.
labels="$(gh label list --repo "$REPO" --json name --limit 1000)" || die "gh label list failed"
for l in autorebase rebase-strike; do
  jq -e --arg l "$l" 'any(.[]; (.name | ascii_downcase) == $l)' <<<"$labels" >/dev/null && continue
  gh label create "$l" --repo "$REPO" --color "$([ "$l" = autorebase ] && echo d93f0b || echo fbca04)" \
    --description "set by the factory queue (eject.sh)" >/dev/null || die "gh label create $l failed"
  act "label-create $l"
done
gh pr edit "$pr" --repo "$REPO" --add-label autorebase >/dev/null || die "gh pr edit #$pr --add-label autorebase failed"
act label-autorebase
gh pr close "$pr" --repo "$REPO" --comment "$(comment_body)" >/dev/null || die "gh pr close #$pr failed"
act close-pr

# 3. the Issue.
if [ -n "$issue" ]; then
  gh issue edit "$issue" --repo "$REPO" --add-label ready --add-label rebase-strike --remove-label in-review >/dev/null ||
    die "gh issue edit #$issue failed"
  act issue-ready-rebase-strike
fi
jq -cn --argjson pr "$pr" --arg t "$ticket" --arg i "$issue" --arg rec "$record" --argjson a "$actions" \
  '{result: "ejected", pr: $pr, ticket: $t, issue: ($i | tonumber? // null),
    record: (if $rec == "" then null else ($rec | fromjson) end), actions: $a}'
