#!/usr/bin/env bash
# labeler — the trusted labeler and the re-evaluation of held PRs (specs/factory-step3-v1 TB8, ticket
# T27; intake:I3, node:G8, merge:G5).
#
#   labeler.sh [--apply] [--json] [--repo <owner/name>]
#
# Run by .github/workflows/labeler.yml from a checkout of main (never pull_request_target, never a PR
# head's code), on every push to main, after post-merge (workflow_run) and on a schedule. For every
# open ticket PR (head ticket/<id>/<handle>, from this repo, its ticket open in main's store):
#   1. the label `tier:<n>` from the store's body header, and no other `tier:` label (a node never
#      labels; SPEC-v0.2 L506). A missing repo label is created first.
#   2. the PR body's display block, from a line `<!-- factory:display -->` or starting
#      `<!-- factory:display: ` to the line `<!-- /factory:display -->`, rewritten when it differs: `Tier:`, one `Depends-on:` line per
#      parent (the store's edges, with the parent's state on main), `Prosecuting adapter:` and
#      `Assisted-by:` (the head commit's trailer, in a code span: never a link or a mention). The
#      node's own lines above it are kept (a start line with no end line after it, and what follows
#      it, are the node's text, kept too). Labels are compared as GitHub does, case-insensitively.
#      No gate reads the block: depends-check.sh reads the store, and the body's `Ticket:` line stays
#      the node's (lib/gate-context.sh gate_identity).
#   3. the re-evaluation: when the latest gates run on the PR's head has a `depends-on` or `tier-order`
#      job whose conclusion differs from what depends-check.sh / tier-order.sh answer now against main
#      (a parent merged, a lower-tier PR merged or turned green), that job is re-run
#      (POST actions/jobs/<id>/rerun). A re-run replays the PR's event and the two scripts read main's
#      tip (lib/gate-context.sh gc_store_sha). This run asks them the same way: a pull_request event
#      built from the PR object (GET pulls/<n>) with base = main, the PR's head read from this
#      checkout's remote refs (fetch-depth 0), so the PR's identity and class are checked as the job
#      checks them. A script that refuses rather than answers (no JSON verdict: a body naming another
#      ticket, a head commit not fetched) re-runs nothing. GITHUB_TOKEN events
#      start no workflow except dispatch (records/TB0.md (d)); a re-run is no event, and the workflow
#      uses the App token when one exists.
#
# Dry run by default: prints what it would change. stdout: one JSON line per ticket PR {pr, ticket,
# tier (a number), label: {add, remove}, body: same|changed, reruns: [{job, was, now}], applied, and
# error when its runs could not be read}; --json is accepted for the readers' convention (the output
# is always JSON lines). Exit 0 done (also when nothing changed), 1 operational error: the PR list or
# store unreadable, a write refused, or a PR whose runs could not be read (that PR is still labeled,
# nothing of it is re-run, and every other PR is still handled).
set -euo pipefail
PROG="labeler"
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/gate-context.sh
. "$(dirname "$0")/lib/gate-context.sh"
BIN="$(cd "$(dirname "$0")" && pwd)"

APPLY=0 repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --dry-run|--json) ;;
    --repo) repo="${2:-}"; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
need git jq gh
REPO="$(resolve_repo "$repo")"
export FACTORY_REPO="$REPO"   # depends-check.sh and tier-order.sh, run below, resolve the same repo
HEAD_SHA="$(git rev-parse --verify -q 'HEAD^{commit}')" || die "run from a checkout of main"
# The store depends-check.sh and tier-order.sh read too: origin/main when it is ahead of the checkout.
MAIN="$(gc_store_sha "$HEAD_SHA" main)"
STORE="$(gc_store "$MAIN")"
MARK_A='<!-- factory:display: written by factory/bin/labeler.sh from main'"'"'s store; for people, no gate reads it -->'
MARK_Z='<!-- /factory:display -->'

prs="$(gh pr list --repo "$REPO" --state open --limit 200 --json number,headRefName,headRefOid,isCrossRepository,labels,body)" ||
  die "cannot list the open PRs of $REPO"
known="$(gh label list --repo "$REPO" --limit 200 --json name)" || die "cannot list the labels of $REPO"

# The ticket PRs, with what the store says about them.
rows="$(jq -c --argjson T "$STORE" "$GC_STORE_JQ"'
  ($T | map({key: .id, value: .}) | from_entries) as $by
  | .[] | select(.isCrossRepository != true)
  | (.headRefName | capture("^ticket/(?<id>[A-Za-z0-9][A-Za-z0-9._:#-]{0,127})/(?<h>[A-Za-z0-9][A-Za-z0-9-]{0,38})$")?) as $r
  | select($r != null)
  | ($by[$r.id]) as $t
  | {pr: .number, ticket: $r.id, head: .headRefOid, body: (.body // ""), labels: [.labels[]?.name],
     open: ($t != null and $t.completed != true), tier: ($t | if . == null then null else gc_tier end),
     parents: [$T | gc_parents($r.id)[] as $p | {id: $p, completed: ($by[$p].completed == true)}]}' <<<"$prs")" ||
  die "the open PRs are not JSON"

# display_block <row> <assisted-by>
display_block() {
  jq -r --arg a "$MARK_A" --arg z "$MARK_Z" --arg ab "$2" '
    [$a, "Tier: \(.tier)"]
    + (if (.parents | length) == 0 then ["Depends-on: none"]
       else [.parents[] | "Depends-on: \(.id) (\(if .completed then "completed" else "open" end) on main)"] end)
    + ["Prosecuting adapter: not recorded by the node (prosecution is build order 4; SPEC-v0.2 Prosecution)",
       "Assisted-by: \($ab)", $z] | join("\n")' <<<"$1"
}
# assisted_by <head>: the head commit's Assisted-by trailer, as display-safe text.
assisted_by() {
  local msg v
  msg="$(gh api "repos/$REPO/git/commits/$1" --jq .message 2>/dev/null)" || { echo "unknown (the head commit could not be read)"; return; }
  v="$(git interpret-trailers --parse <<<"$msg" | sed -n 's/^Assisted-by:[[:space:]]*//p' | head -n1)"
  if [ -z "$v" ]; then echo "none on the head commit"
  elif [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._@/+:-]{0,79}$ ]]; then printf '`%s`\n' "$v"
  else echo "unrecognized"; fi
}
# new_body <old body> <block>: the old body without any display block, then the block. A start line
# with no end line after it, or followed by another start line, is kept as written.
new_body() {
  local kept
  kept="$(awk -v a="<!-- factory:display: " -v b="<!-- factory:display -->" -v z="$MARK_Z" '
      function start(s) { return index(s, a) == 1 || s == b }
      skip && start($0) {printf "%s\n", held; held = $0; next}
      !skip && start($0) {skip = 1; held = $0; next}
      skip && $0 == z {skip = 0; held = ""; next}
      skip {held = held "\n" $0; next}
      {print}
      END {if (skip) printf "%s\n", held}' <<<"$1" |
          sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
  if [ -n "$kept" ]; then printf '%s\n\n%s\n' "$kept" "$2"; else printf '%s\n' "$2"; fi
}
# evaluate <script> <pr>: success | failure, the job's conclusion if it ran now on the PR's event with
# base = main; empty when the script cannot answer (an error, or a refusal: exit 2 with no JSON verdict
# on stdout).
evaluate() {
  local rc=0 verdict
  if [ ! -s "$WORK/event-$2.json" ]; then
    gh api "repos/$REPO/pulls/$2" | jq -c --arg b "$MAIN" '{action: "synchronize", number: .number, pull_request: (.base.sha = $b)}' \
      >"$WORK/event-$2.json" || { warn "PR #$2: cannot read the PR to evaluate it"; rm -f "$WORK/event-$2.json"; return 0; }
  fi
  GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$WORK/event-$2.json" GITHUB_REPOSITORY="$REPO" \
    "$BIN/$1" >"$WORK/eval.out" 2>"$WORK/eval.err" || rc=$?
  verdict="$(tail -n1 "$WORK/eval.out" | jq -r '.result // empty' 2>/dev/null || true)"
  case "$rc:$verdict" in
    0:pass) echo success ;;
    2:held|2:wait) echo failure ;;
    *) warn "PR #$2: $1 gave no verdict (exit $rc): $(tail -n1 "$WORK/eval.err")" ;;
  esac
}
ERRORS=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

while IFS= read -r row; do
  [ -n "$row" ] || continue
  pr="$(jq -r .pr <<<"$row")" t="$(jq -r .ticket <<<"$row")" head="$(jq -r .head <<<"$row")"
  if [ "$(jq -r '.open and .tier != null' <<<"$row")" != true ]; then
    warn "PR #$pr: ticket $t is not open with a tier in main's store: nothing to label"
    jq -c '{pr, ticket, skipped: "not open with a tier in main'"'"'s store"}' <<<"$row"; continue
  fi
  want="tier:$(jq -r .tier <<<"$row")"
  add="$(jq -c --arg w "$want" 'if any(.labels[]; ascii_downcase == $w) then [] else [$w] end' <<<"$row")"
  remove="$(jq -c --arg w "$want" '[.labels[] | select(ascii_downcase | startswith("tier:") and . != $w)]' <<<"$row")"
  block="$(display_block "$row" "$(assisted_by "$head")")"
  # GitHub's web editor stores CRLF; the comparison and the rewrite are on LF lines.
  old="$(jq -r '.body | gsub("\r"; "")' <<<"$row")"; body="$(new_body "$old" "$block")"
  bstate=same; [ "$body" = "$old" ] || [ "$body" = "$old"$'\n' ] || bstate=changed

  # The re-evaluation: the latest gates run on this head, its two order jobs, and today's answer.
  reruns='[]' err="" rid="" jobs=""
  if ! runs="$(gh api "repos/$REPO/actions/runs?head_sha=$head&event=pull_request&per_page=100")" ||
     ! rid="$(jq -r '[.workflow_runs[]? | select(.path == ".github/workflows/gates.yml")] | max_by(.id) | .id // empty' <<<"$runs")"; then
    err="cannot read the Actions runs of $head"; rid=""
  elif [ -n "$rid" ] && ! jobs="$(gh api "repos/$REPO/actions/runs/$rid/jobs?filter=latest&per_page=100")"; then
    err="cannot read the jobs of run $rid"; rid=""
  fi
  if [ -n "$err" ]; then warn "PR #$pr: $err: nothing of it is re-run"; ERRORS=$((ERRORS + 1)); fi
  if [ -n "$rid" ]; then
    for j in depends-on:depends-check.sh tier-order:tier-order.sh; do
      job="${j%%:*}" script="${j#*:}"
      cur="$(jq -c --arg n "$job" '[.jobs[]? | select(.name == $n)] | max_by(.id) // empty' <<<"$jobs")"
      [ -n "$cur" ] && [ "$(jq -r .status <<<"$cur")" = completed ] || continue
      was="$(jq -r .conclusion <<<"$cur")"
      case "$was" in success|failure) ;; *) continue ;; esac
      now="$(evaluate "$script" "$pr")"
      [ -n "$now" ] && [ "$now" != "$was" ] || continue
      reruns="$(jq -c --arg j "$job" --argjson id "$(jq .id <<<"$cur")" --arg w "$was" --arg n "$now" '. + [{job: $j, id: $id, was: $w, now: $n}]' <<<"$reruns")"
    done
  fi

  if [ "$APPLY" = 1 ]; then
    for l in $(jq -r '.[]' <<<"$add"); do
      # GitHub label names are case-insensitive: `Tier:1` is the label `tier:1`.
      jq -e --arg l "$l" 'any(.[]; (.name | ascii_downcase) == ($l | ascii_downcase))' <<<"$known" >/dev/null && continue
      gh label create "$l" --repo "$REPO" --color 1d76db --description "set by the factory labeler" >/dev/null ||
        die "cannot create label $l"
      known="$(jq -c --arg l "$l" '. + [{name: $l}]' <<<"$known")"
    done
    edit=()
    for l in $(jq -r '.[]' <<<"$add"); do edit+=(--add-label "$l"); done
    for l in $(jq -r '.[]' <<<"$remove"); do edit+=(--remove-label "$l"); done
    if [ "$bstate" != same ]; then printf '%s\n' "$body" >"$WORK/body"; edit+=(--body-file "$WORK/body"); fi
    [ "${#edit[@]}" = 0 ] || gh pr edit "$pr" --repo "$REPO" "${edit[@]}" >/dev/null || die "cannot edit PR #$pr"
    for id in $(jq -r '.[].id' <<<"$reruns"); do
      gh api -X POST "repos/$REPO/actions/jobs/$id/rerun" >/dev/null || die "cannot re-run job $id of PR #$pr"
    done
  fi
  jq -cn --argjson pr "$pr" --arg t "$t" --argjson tier "${want#tier:}" --argjson add "$add" --argjson rm "$remove" --arg b "$bstate" \
    --argjson r "$reruns" --argjson ap "$APPLY" --arg err "$err" \
    '{pr: $pr, ticket: $t, tier: $tier, label: {add: $add, remove: $rm}, body: $b, reruns: [$r[] | del(.id)], applied: ($ap == 1)}
     + (if $err == "" then {} else {error: $err} end)'
done <<<"$rows"
[ "$ERRORS" = 0 ] || die "$ERRORS PR(s) whose runs could not be read (each named above); every other PR was handled"
