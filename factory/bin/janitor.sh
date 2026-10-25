#!/usr/bin/env bash
# janitor — the clock: every TTL, heartbeat, stale and scheduled transition (SPEC-v0.2 "Clock and
# janitor"). One hourly Action runs it in a checkout of main; it never runs on a node.
#
#   janitor.sh [--dry-run | --apply] [--remote NAME] [--repo owner/name]
#
# One fetch reads the remote's nodes branch, refs/locks/issue-* and refs/heads/ticket/**; gh reads
# the Issues and the open PRs. Then, for every duty:
#
#   ready    the open ticket set differs from janitor/state.json on the nodes branch: `adlc
#            merge-forecast --json`, then `mirror.sh --apply --forecast FILE` recomputes the ready
#            labels. The set is saved only after the mirror succeeds. Open = not completed: `adlc
#            ticket list --json` lists completed tickets too, so each id's `ticket show --json` is
#            read (as the mirror does) and a completed one is left out; a completion is a change.
#   previews a deploy record previews/<name>.json on the nodes branch past its expires_at, or whose
#            pr is no longer open, is torn down ($JANITOR_PREVIEW_HOOK teardown <name> <record-file>)
#            and the record removed.
#   nodes    nodes/<h>.json whose last_seen is older than node.staleAfterHours becomes "stale";
#            older than node.retireAfterDays becomes "retired": the token is revoked
#            ($JANITOR_REVOKE_HOOK <handle> <owner>; the hook is a command line split on blanks, so
#            janitor.yml sets `./factory/bin/revoke-collaborator.sh --apply`), the claims released,
#            a halt notice sent if it
#            held any (summon.sh --kind halt), and the manifest moved to archive/nodes/<h>.json.
#   claims   a lock is released (ref deleted, a comment on the Issue, in-progress removed) when its
#            commit is older than claim.staleAfterHours, when its node is stale or retired, or when
#            its node holds more locks than its slots (newest first). A lock whose ticket/<id>/*
#            branch has a commit newer than claim.staleAfterHours is never released, except one
#            that is stale, has no open PR for that branch and is older than
#            claim.unpushedBranchReleaseAfterHours: released, and the branch kept.
#   branches ticket/<id>/* is deleted when its Issue is closed, or when it had no lock at the start
#            of the run and no commit for claim.unclaimedBranchDeleteAfterDays. A branch with an
#            open PR is never deleted (that would close the PR).
#
# --dry-run (the default) writes nothing anywhere: no ref, no commit, no comment, no hook, no
# mirror. Both modes print one JSON line per action on stdout:
#   {"mode", "action", <target fields>, "reason", "result": planned|done|failed|skipped|unconfigured|kept}
# An Issue's ticket id is its body's `Ticket: <id>` line (the mirror writes it), else its number;
# branch ticket/<id>/<handle> belongs to the Issue with that id.
# Writes go only to refs/locks/issue-*, refs/heads/ticket/** and refs/heads/nodes, each a
# compare-and-swap: deletes carry --force-with-lease, the nodes commit is a fast-forward push
# (retried on a moved tip). Never main. TTLs come from factory/policy/budget.json.
# --apply refuses (exit 2) unless RUNNER_ENVIRONMENT=github-hosted. Exit 0 done or planned; 1 a
# read failed, or an action failed or had no hook (the other actions still ran); 2 refused.
#
# Environment: FACTORY_NOW, FACTORY_REPO; FACTORY_ADLC (default `npx -y @adlc/cli@1.12.0`);
# FACTORY_MIRROR (default factory/bin/mirror.sh); JANITOR_REVOKE_HOOK; JANITOR_PREVIEW_HOOK;
# DISCORD_WEBHOOK (for summon.sh).
set -euo pipefail
PROG=janitor
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

apply=0 remote=origin repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --json) ;;                      # the output is always JSON lines
    --remote) remote="${2:-}"; shift ;;
    --repo) repo="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need git gh jq
[ -n "$remote" ] || die "--remote needs a value"
MODE="$([ "$apply" = 1 ] && echo apply || echo dry-run)"
if [ "$apply" = 1 ] && [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then
  refuse "--apply runs only on a GitHub-hosted runner (RUNNER_ENVIRONMENT=${RUNNER_ENVIRONMENT:-unset}); the janitor never runs on a node"
fi
git rev-parse --git-dir >/dev/null 2>&1 || die "run in a checkout of the factory repo"
REPO="$(resolve_repo "$repo")"
NOW="$(now_epoch)"

hours() { local v; v="$(budget "$1")"; [[ "$v" =~ ^[1-9][0-9]*$ ]] || die "budget.json $1 must be a positive integer, got '$v'"; printf '%s\n' "$v"; }
STALE_H="$(hours .claim.staleAfterHours)"
NOPR_H="$(hours .claim.unpushedBranchReleaseAfterHours)"
BRANCH_D="$(hours .claim.unclaimedBranchDeleteAfterDays)"
NODE_STALE_H="$(hours .node.staleAfterHours)"
RETIRE_D="$(hours .node.retireAfterDays)"
TTL_ARGS=(--argjson now "$NOW" --argjson stale_s "$((STALE_H * 3600))" --argjson nopr_s "$((NOPR_H * 3600))"
          --argjson branch_s "$((BRANCH_D * 86400))" --argjson node_stale_s "$((NODE_STALE_H * 3600))"
          --argjson retire_s "$((RETIRE_D * 86400))")
JQ_DEFS='def iso: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;'

read -r -a ADLC <<<"${FACTORY_ADLC:-npx -y @adlc/cli@1.12.0}"
MIRROR="${FACTORY_MIRROR:-$FACTORY_ROOT/factory/bin/mirror.sh}"
SUMMON="$(cd "$(dirname "$0")" && pwd)/summon.sh"
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-factory-janitor}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-janitor@factory.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

NS=refs/janitor                     # private namespace for the fetched remote state
WORK="$(mktemp -d "${TMPDIR:-/tmp}/janitor.XXXXXX")"
drop_ns() { git for-each-ref --format='delete %(refname)' "$NS/" | git update-ref --stdin; }
# shellcheck disable=SC2317  # invoked by the trap
cleanup() { drop_ns 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
FAILED=0
COUNT=0

emit() {  # emit <json-object> <result>
  COUNT=$((COUNT + 1))
  jq -c --arg mode "$MODE" --arg r "$2" '{mode: $mode} + . + {result: $r}' <<<"$1"
}
fail_line() { FAILED=1; emit "$(jq -c --arg d "$2" '. + {detail: $d}' <<<"$1")" failed; }

# Every write is a push through here: a ref outside the janitor's three namespaces is refused.
PUSH_ERR="$WORK/push.err"
push_ref() {  # push_ref <dst-ref> <lease-sha|''> <src-sha|''>: src '' deletes; git's error in PUSH_ERR
  local dst="$1" lease="$2" src="$3"
  [[ "$dst" =~ ^refs/locks/issue-[1-9][0-9]*$ || "$dst" =~ ^refs/heads/ticket/.+ || "$dst" == refs/heads/nodes ]] ||
    refuse "refusing to write $dst: the janitor writes only lock refs, ticket/** branches and nodes"
  local -a lease_arg=()
  [ -z "$lease" ] || lease_arg=("--force-with-lease=$dst:$lease")
  git push --quiet --no-verify "${lease_arg[@]}" "$remote" "$src:$dst" 2>"$PUSH_ERR"
}
lease_lost() { grep -q 'stale info' "$PUSH_ERR"; }
push_detail() { tail -n1 "$PUSH_ERR"; }

# ------------------------------------------------------------------------------------- read
fetch_nodes() {
  git fetch --quiet --no-tags --no-write-fetch-head "$remote" "+refs/heads/nodes:$NS/nodes" ||
    die "cannot fetch $remote nodes (the nodes branch must exist)"
}
fetch_all() {
  drop_ns
  git fetch --quiet --no-tags --no-write-fetch-head "$remote" "+refs/heads/nodes:$NS/nodes" \
      "+refs/heads/ticket/*:$NS/ticket/*" "+refs/locks/*:$NS/locks/*" ||
    die "cannot fetch $remote (nodes, ticket/**, refs/locks/*)"
}

json_files() {  # json_files <dir/>: [{path, name, data}] for the *.json blobs directly in dir/ on nodes
  local _m type obj path
  git ls-tree "$NS/nodes" "$1" | while IFS=$' \t' read -r _m type obj path; do
    [ "$type" = blob ] && [[ "$path" =~ ^$1[^/]+\.json$ ]] || continue
    git cat-file blob "$obj" | jq -c --arg p "$path" '{path: $p, name: ($p | split("/")[-1] | rtrimstr(".json")), data: .}' 2>/dev/null ||
      warn "skipping $path on the nodes branch: not JSON"
  done | jq -sc .
}

read_locks() {
  local ref sha at n
  git for-each-ref --format='%(refname) %(objectname) %(committerdate:unix)' "$NS/locks/" |
  while read -r ref sha at; do
    n="${ref#"$NS/locks/issue-"}"
    valid_issue "$n" || continue
    git log -1 --format=%B "$sha" |
      jq -Rsc --argjson n "$n" --arg sha "$sha" --argjson at "$at" \
        '(split("\n\n") | .[1:] | join("\n\n") | try fromjson catch null) as $p
         | {issue: $n, ref: "refs/locks/issue-\($n)", sha: $sha, at: $at,
            holder: ($p.handle? // null), payload_slots: ($p.slots? // null)}'
  done | jq -sc .
}

read_branches() {
  git for-each-ref --format='%(refname) %(objectname) %(committerdate:unix)' "$NS/ticket/" |
    jq -Rsc --arg ns "$NS/" 'split("\n") | map(select(. != "") | split(" ")
      | {name: ("ticket/" + (.[0] | ltrimstr($ns + "ticket/"))), sha: .[1], at: (.[2] | tonumber)}
      | . + {id: (.name | split("/")[1])})'
}

fetch_all
LOCKS="$(read_locks)"
BRANCHES="$(read_branches)"
MANIFESTS="$(json_files nodes/)"
PREVIEWS="$(json_files previews/)"
STATE="$(git cat-file blob "$NS/nodes:janitor/state.json" 2>/dev/null | jq -c . 2>/dev/null || echo null)"
ISSUES="$(gh issue list --repo "$REPO" --state all --limit 1000 --json number,state,body,labels |
  jq -c '[.[] | .number as $n | {number, state: (.state | ascii_downcase), labels: [.labels[].name],
                 key: ([(.body // "") | splits("\r?\n") | capture("^ticket:[ \t]*(?<id>[A-Za-z0-9._-]+)[ \t]*$"; "i") | .id]
                       | first // ($n | tostring))}]')" || die "cannot list Issues"
PRS="$(gh pr list --repo "$REPO" --state open --limit 1000 --json number,headRefName)" || die "cannot list open PRs"

# ------------------------------------------------------------------------------------- plan
plan_nodes() {  # manifests -> [{handle, owner, path, slots, before, after, age}]
  jq -c "${TTL_ARGS[@]}" "$JQ_DEFS"'
    [ .[] | .data as $m | ($m.last_seen | try iso catch null) as $seen
      | {handle: ($m.handle // .name), owner: ($m.owner // null), path, slots: ($m.slots // null),
         last_seen: $m.last_seen, before: $m.status, age: (if $seen then $now - $seen else null end)}
      | .after = (if .before == "retired" then "retired"
                  elif .age == null then .before
                  elif .age > $retire_s then "retired"
                  elif .age > $node_stale_s and (.before | IN("joining", "active", "paused")) then "stale"
                  else .before end) ]' <<<"$1"
}

plan_claims() {  # uses LOCKS BRANCHES PRS ISSUES and the node plan $1
  jq -nc "${TTL_ARGS[@]}" --argjson locks "$LOCKS" --argjson branches "$BRANCHES" --argjson prs "$PRS" \
        --argjson issues "$ISSUES" --argjson nodes "$1" '
    ($issues | map({key: (.number | tostring), value: .}) | from_entries) as $byn
    | ($prs | map(.headRefName)) as $heads
    | ($nodes | map({key: .handle, value: .}) | from_entries) as $nodeby
    | [ $locks[] | . as $l | $byn[$l.issue | tostring] as $iss
        | ($iss.key // ($l.issue | tostring)) as $id
        | [ $branches[] | select(.id == $id) ] as $bs
        | {issue, ref, sha, at, holder, payload_slots, age: ($now - .at), ticket: $id,
           has_issue: ($iss != null), in_progress: (($iss.labels // []) | index("in-progress") != null),
           fresh_branch: ([$bs[] | select(($now - .at) <= $stale_s) | .name] | first),
           open_pr: any($bs[]; .name | IN($heads[])),
           node: ($nodeby[$l.holder // ""].after // null), node_slots: ($nodeby[$l.holder // ""].slots // null)}
        | .base = (if .node == "retired" then "node-retired" elif .node == "stale" then "node-stale"
                   elif .age > $stale_s then "stale-lock" else null end)
        | if .base == null then . + {verdict: "hold"}
          elif .fresh_branch == null then . + {verdict: "release", reason: .base}
          elif (.open_pr | not) and .age > $nopr_s then
            . + {verdict: "release", reason: "no-pr-48h", branch_kept: .fresh_branch}
          else . + {verdict: "keep", reason: .base} end ]
    | group_by(.holder // "")
    | map(. as $g
        | ($g[0].node_slots // ([$g[].payload_slots | numbers] | max)) as $limit
        | ([$g[] | select(.verdict != "release")] | length) as $live
        | (if $limit == null or ($g[0].holder == null) then 0 else ([$live - $limit, 0] | max) end) as $excess
        | ([$g[] | select(.verdict != "release" and .fresh_branch == null)]
           | sort_by(-.at, -.issue) | .[:$excess] | map(.issue)) as $cut
        | $g[] | if (.issue | IN($cut[])) then . + {verdict: "release", reason: "over-slots", slots: $limit} else . end)
    | sort_by(.issue)'
}

plan_branches() {
  jq -nc "${TTL_ARGS[@]}" --argjson locks "$LOCKS" --argjson branches "$BRANCHES" --argjson prs "$PRS" \
        --argjson issues "$ISSUES" '
    ($issues | group_by(.key) | map({key: .[0].key, value: (sort_by(.state != "open") | .[0])}) | from_entries) as $bykey
    | ($locks | map(.issue)) as $locked
    | ($prs | map(.headRefName)) as $heads
    | [ $branches[] | $bykey[.id] as $iss
        | {branch: .name, sha, ticket: .id, age: ($now - .at), issue: ($iss.number // null),
           issue_state: ($iss.state // null), open_pr: (.name | IN($heads[])),
           locked: (($iss.number // null) as $n | $n != null and ($n | IN($locked[])))}
        | if .open_pr then empty
          elif .issue_state == "closed" then . + {reason: "issue-closed"}
          elif (.locked | not) and .age > $branch_s then . + {reason: "unclaimed-7d"}
          else empty end ]'
}

plan_previews() {
  jq -nc "${TTL_ARGS[@]}" --argjson previews "$PREVIEWS" --argjson prs "$PRS" "$JQ_DEFS"'
    ($prs | map(.number)) as $open
    | [ $previews[] | .data as $r | ($r.expires_at | try iso catch null) as $exp
        | {preview: .name, path, branch: ($r.branch // null), pr: ($r.pr // null), expires_at: ($r.expires_at // null)}
        | if $exp != null and $now >= $exp then . + {reason: "ttl"}
          elif .pr != null and (.pr | IN($open[]) | not) then . + {reason: "pr-closed"}
          else empty end ]'
}

NODES_EDITS="$WORK/edits"           # fixed nodes-branch edits, "put|rm <TAB> path <TAB> file|-" lines
: >"$NODES_EDITS"

# ------------------------------------------------------------------------------------- ready
ready_pass() {
  local line tickets ids id done_ open prev ffile="$WORK/forecast.json" rc=0
  line='{"action": "ready-recompute"}'
  tickets="$("${ADLC[@]}" ticket list --json)" || { fail_line "$line" "adlc ticket list failed"; return 0; }
  ids="$(jq -r 'if type == "array" then .[].id else error("not a list") end' <<<"$tickets" 2>/dev/null)" ||
    { fail_line "$line" "adlc ticket list is not a JSON list"; return 0; }
  open='[]'
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    valid_ticket_id "$id" || { fail_line "$line" "adlc ticket list: bad ticket id"; return 0; }
    done_="$("${ADLC[@]}" ticket show "$id" --json | jq -r --arg id "$id" 'select(.ticket.id == $id) | .ticket.completed == true' 2>/dev/null)" ||
      done_=""
    [ -n "$done_" ] || { fail_line "$line" "adlc ticket show $id failed"; return 0; }
    [ "$done_" = true ] || open="$(jq -c --arg id "$id" '. + [$id]' <<<"$open")"
  done <<<"$ids"
  open="$(jq -c sort <<<"$open")"
  prev="$(jq -c '.open_set // null' <<<"$STATE")"
  [ "$open" != "$prev" ] || return 0
  "${ADLC[@]}" merge-forecast --json >"$ffile" || rc=$?
  if [ "$rc" != 0 ] && [ "$rc" != 2 ] || ! jq -e 'type == "object"' "$ffile" >/dev/null 2>&1; then
    fail_line "$line" "adlc merge-forecast failed (exit $rc)"; return 0
  fi
  line="$(jq -c --argjson open "$open" --argjson prev "$prev" --argjson rc "$rc" \
    '{action: "ready-recompute", open_set: $open, previous: $prev,
      added: ($open - ($prev // [])), removed: (($prev // []) - $open),
      merge_order: .mergeOrder, certified_width: .certifiedWidth, forecast_exit: $rc}' "$ffile")"
  if [ "$apply" = 0 ]; then emit "$line" planned; return 0; fi
  if "$MIRROR" --apply --forecast "$ffile" >&2; then
    emit "$line" "done"
    jq --argjson open "$open" --arg at "$(epoch_to_iso "$NOW")" \
      '{open_set: $open, forecast: {mergeOrder, waves, certifiedWidth}, recomputed_at: $at}' "$ffile" >"$WORK/state.json"
    printf 'put\tjanitor/state.json\t%s\n' "$WORK/state.json" >>"$NODES_EDITS"
  else
    fail_line "$line" "mirror failed; the open set is not saved, so the next run retries"
  fi
}

# ------------------------------------------------------------------------------------- previews
previews_pass() {
  local p line name path plan
  plan="$(plan_previews)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    line="$(jq -c '{action: "preview-teardown"} + .' <<<"$p")"
    name="$(jq -r .preview <<<"$p")"; path="$(jq -r .path <<<"$p")"
    if [ "$apply" = 0 ]; then emit "$line" planned; continue; fi
    if [ -z "${JANITOR_PREVIEW_HOOK:-}" ]; then
      FAILED=1; emit "$(jq -c '. + {detail: "JANITOR_PREVIEW_HOOK is not set; the record is kept"}' <<<"$line")" unconfigured
      continue
    fi
    git cat-file blob "$NS/nodes:$path" >"$WORK/preview-$name.json"
    if "$JANITOR_PREVIEW_HOOK" teardown "$name" "$WORK/preview-$name.json" >&2; then
      emit "$line" "done"
      printf 'rm\t%s\t-\n' "$path" >>"$NODES_EDITS"
    else
      fail_line "$line" "the teardown hook failed; the record is kept"
    fi
  done <<<"$(jq -c '.[]' <<<"$plan")"
}

# ------------------------------------------------------------------------------------- nodes
NODES="$(plan_nodes "$MANIFESTS")"

# nodes_commit: one commit on the nodes branch with the node transitions and the fixed edits.
# Fast-forward only; on a moved tip it re-reads the manifests, re-plans and tries again. Sets
# NODES_OK=0 when nothing could be written. Never called as a condition, so set -e holds inside.
nodes_commit() {
  local attempt tip idx="$WORK/index" tree new op path file msg changed
  NODES_OK=1
  for attempt in 1 2 3; do
    if [ "$attempt" -gt 1 ]; then fetch_nodes; NODES="$(plan_nodes "$(json_files nodes/)")"; fi
    tip="$(git rev-parse "$NS/nodes")"
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git read-tree "$tip"
    node_edits >"$WORK/all-edits"
    command cat "$NODES_EDITS" >>"$WORK/all-edits"
    while IFS=$'\t' read -r op path file; do
      case "$op" in
        put) GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$(git hash-object -w "$file"),$path" ;;
        rm) GIT_INDEX_FILE="$idx" git update-index --force-remove "$path" ;;
        *) die "bad nodes edit: $op $path" ;;
      esac
    done <"$WORK/all-edits"
    tree="$(GIT_INDEX_FILE="$idx" git write-tree)"
    changed="$(git diff-tree -r --name-status "$tip^{tree}" "$tree" | jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {(.[1]): .[0]}) | add // {}')"
    [ "$changed" != '{}' ] || return 0
    msg="$(jq -r --arg at "$(epoch_to_iso "$NOW")" '"janitor: \(keys | length) file(s) at \($at)\n\n" + (to_entries | map("\(.value) \(.key)") | join("\n"))' <<<"$changed")"
    if [ "$apply" = 0 ]; then emit "$(jq -c '{action: "nodes-commit", files: .}' <<<"$changed")" planned; return 0; fi
    new="$(git commit-tree "$tree" -p "$tip" -m "$msg")"
    if push_ref refs/heads/nodes "" "$new"; then
      emit "$(jq -c --arg sha "$new" '{action: "nodes-commit", sha: $sha, files: .}' <<<"$changed")" "done"
      return 0
    fi
    warn "nodes push rejected (attempt $attempt): $(push_detail)"
  done
  fail_line "$(jq -c '{action: "nodes-commit", files: .}' <<<"$changed")" "the nodes branch kept moving; nothing written"
  NODES_OK=0
}

node_edits() {  # the manifest edits the node plan implies, as "op\tpath\tfile" lines
  local n handle path after plan
  plan="$(jq -c '.[] | select(.after != .before or .after == "retired")' <<<"$NODES")"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    handle="$(jq -r .handle <<<"$n")"; path="$(jq -r .path <<<"$n")"; after="$(jq -r .after <<<"$n")"
    git cat-file blob "$NS/nodes:$path" | jq --arg s "$after" '.status = $s' >"$WORK/manifest-$handle.json"
    if [ "$after" = retired ]; then
      printf 'rm\t%s\t-\n' "$path"
      printf 'put\tarchive/nodes/%s.json\t%s\n' "$handle" "$WORK/manifest-$handle.json"
    else
      printf 'put\t%s\t%s\n' "$path" "$WORK/manifest-$handle.json"
    fi
  done <<<"$plan"
}

node_lines() {  # node-stale / node-retire lines for the node plan, with result $1
  local n plan
  plan="$(jq -c '.[] | select(.after != .before or .after == "retired")
                  | {action: (if .after == "retired" then "node-retire" else "node-stale" end),
                     handle, path, status_before: .before, status_after: .after, last_seen,
                     silent_hours: ((.age // 0) / 3600 | floor)}
                  + (if .after == "retired" then {archived_to: "archive/nodes/\(.handle).json"} else {} end)' <<<"$NODES")"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    emit "$n" "$1"
  done <<<"$plan"
}

# ------------------------------------------------------------------------------------- claims
reason_text() {  # reason_text <claim-json>
  jq -r --argjson sh "$STALE_H" --argjson nh "$NOPR_H" --argjson nsh "$NODE_STALE_H" --argjson rd "$RETIRE_D" '
    { "stale-lock": "no heartbeat for more than \($sh) h and no commit on a ticket/\(.ticket)/* branch in the last \($sh) h",
      "node-stale": "node `\(.holder)` is stale (no heartbeat on the nodes branch for more than \($nsh) h)",
      "node-retired": "node `\(.holder)` is retired (silent for more than \($rd) days)",
      "over-slots": "node `\(.holder)` holds more locks than its \(.slots) slot(s); the newest go first",
      "no-pr-48h": "no heartbeat for more than \($nh) h and no open PR for `\(.branch_kept)`" }[.reason]' <<<"$1"
}

claims_pass() {
  local c line n ref sha body plan
  plan="$(plan_claims "$NODES" | jq -c '.[] | select(.verdict != "hold")')"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    n="$(jq -r .issue <<<"$c")"; ref="$(jq -r .ref <<<"$c")"; sha="$(jq -r .sha <<<"$c")"
    line="$(jq -c '{action: (if .verdict == "keep" then "keep-lock" else "release-lock" end), issue, ref, sha, holder,
                    ticket, reason, lock_age_hours: (.age / 3600 | floor)}
                   + (if .verdict == "keep" then {kept_for: .fresh_branch} else {} end)
                   + (if .branch_kept then {branch_kept: .branch_kept} else {} end)' <<<"$c")"
    if jq -e '.verdict == "keep"' <<<"$c" >/dev/null; then emit "$line" kept; continue; fi
    body="janitor: released the claim lock \`$ref\` (held by \`$(jq -r '.holder // "unknown"' <<<"$c")\`, last heartbeat $(epoch_to_iso "$(jq -r .at <<<"$c")")). Reason: $(reason_text "$c"). The Issue is claimable again."
    if jq -e '.branch_kept' <<<"$c" >/dev/null; then body+=" Branch \`$(jq -r .branch_kept <<<"$c")\` is kept for the next claimant."; fi
    local comment remove=""
    comment="$(jq -c --arg b "$body" '{action: "comment", issue, body: $b}' <<<"$c")"
    if jq -e '.in_progress' <<<"$c" >/dev/null; then remove="$(jq -c '{action: "remove-label", issue, label: "in-progress"}' <<<"$c")"; fi
    if [ "$apply" = 0 ]; then
      emit "$line" planned
      if jq -e .has_issue <<<"$c" >/dev/null; then emit "$comment" planned; fi
      if [ -n "$remove" ]; then emit "$remove" planned; fi
      continue
    fi
    if ! push_ref "$ref" "$sha" ""; then
      if lease_lost; then
        emit "$(jq -c '. + {detail: "the lock moved since it was read (a heartbeat); left alone"}' <<<"$line")" skipped
      else fail_line "$line" "$(push_detail)"; fi
      continue
    fi
    emit "$line" "done"
    if jq -e .has_issue <<<"$c" >/dev/null; then
      if gh issue comment "$n" --repo "$REPO" --body "$body" >/dev/null; then emit "$comment" "done"
      else fail_line "$comment" "gh issue comment failed"; fi
    fi
    if [ -n "$remove" ]; then
      if gh issue edit "$n" --repo "$REPO" --remove-label in-progress >/dev/null; then emit "$remove" "done"
      else fail_line "$remove" "gh issue edit failed"; fi
    fi
  done <<<"$plan"
}

retire_pass() {  # token revocation and the halt notice for each node retired in this run
  local n handle owner held line ids first plan hook
  plan="$(jq -c '.[] | select(.after == "retired" and .before != "retired")' <<<"$NODES")"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    handle="$(jq -r .handle <<<"$n")"; owner="$(jq -r '.owner // ""' <<<"$n")"
    line="$(jq -c '{action: "revoke-token", handle, owner}' <<<"$n")"
    if [ "$apply" = 0 ]; then emit "$line" planned
    elif [ -z "${JANITOR_REVOKE_HOOK:-}" ]; then
      FAILED=1; emit "$(jq -c '. + {detail: "JANITOR_REVOKE_HOOK is not set; revoke the node token by hand"}' <<<"$line")" unconfigured
    elif read -r -a hook <<<"$JANITOR_REVOKE_HOOK" && "${hook[@]}" "$handle" "$owner" >&2; then emit "$line" "done"
    else fail_line "$line" "the revoke hook failed; revoke the node token by hand"; fi

    held="$(jq -c --arg h "$handle" '[.[] | select(.holder == $h)] | sort_by(.issue)' <<<"$LOCKS")"
    [ "$(jq length <<<"$held")" -gt 0 ] || continue
    first="$(jq -r '.[0].issue' <<<"$held")"
    ids="$(jq -r 'map("#\(.issue)") | join(", ")' <<<"$held")"
    local ticket reason link
    ticket="$(jq -r --argjson n "$first" '[.[] | select(.number == $n) | .key][0] // "#\($n)"' <<<"$ISSUES")"
    reason="node $handle retired with open claims ($ids)"
    link="https://github.com/$REPO/issues/$first"
    line="$(jq -cn --arg h "$handle" --arg t "$ticket" --arg r "$reason" --arg l "$link" \
      '{action: "summon-halt", handle: $h, ticket: $t, reason: $r, link: $l}')"
    if [ "$apply" = 0 ]; then emit "$line" planned; continue; fi
    if "$SUMMON" --kind halt --apply --ticket "$ticket" --link "$link" --reason "$reason" >&2; then emit "$line" "done"
    else fail_line "$line" "summon.sh failed"; fi
  done <<<"$plan"
}

# ------------------------------------------------------------------------------------- branches
branches_pass() {
  local b line ref sha plan
  plan="$(plan_branches | jq -c '.[]')"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    line="$(jq -c '{action: "delete-branch", branch, sha, ticket, issue, reason, age_days: (.age / 86400 | floor)}' <<<"$b")"
    if [ "$apply" = 0 ]; then emit "$line" planned; continue; fi
    ref="refs/heads/$(jq -r .branch <<<"$b")"; sha="$(jq -r .sha <<<"$b")"
    if push_ref "$ref" "$sha" ""; then emit "$line" "done"
    elif lease_lost; then
      emit "$(jq -c '. + {detail: "the branch moved since it was read; left alone"}' <<<"$line")" skipped
    else fail_line "$line" "$(push_detail)"; fi
  done <<<"$plan"
}

# ------------------------------------------------------------------------------------- run
ready_pass
previews_pass
nodes_commit
if [ "$NODES_OK" = 1 ]; then
  node_lines "$([ "$apply" = 1 ] && echo "done" || echo planned)"
else
  # Nothing landed on the nodes branch: no node changed state, so nothing may act on one.
  node_lines failed
  NODES="$(jq -c 'map(.after = .before)' <<<"$NODES")"
fi
retire_pass
claims_pass
branches_pass
warn "$MODE: $COUNT action line(s)$([ "$FAILED" = 1 ] && echo ', some FAILED' || true)"
exit "$FAILED"
