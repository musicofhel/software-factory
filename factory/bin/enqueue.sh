#!/usr/bin/env bash
# enqueue — the merge queue (specs/factory-step3-v1 TB9, ticket T28; merge:G1 G4 G7 G13, ci:G19 G21;
# docs/adr/0007-merge-queue.md). enqueue.yml runs it with the factory App token, from a checkout of
# main (fetch-depth 0) whose `origin` is the repo.
#
#   enqueue.sh pick [--repo <owner/name>] [--apply | --dry-run]
#   enqueue.sh land --pr <n> --base <sha> --queue factory-queue/pr-<n> --head <sha>
#                   --result success|failure|cancelled|skipped [--repo <owner/name>] [--apply | --dry-run]
#
# pick: nothing while factory/HALT is on origin/main. The mode is read, never guessed: GraphQL
# repository.mergeQueue(branch: "main") is an object when GitHub's merge queue is on (native), null
# when it is not (serial; a user-owned repo has none, records/TB0.md (a) `native-queue: no`), and an
# error stops the run (exit 1). The candidates are `tier-order.sh --order` at origin/main: open,
# approved ticket PRs whose latest `gates` run is green, by tier, then first green, then number. A
# row is taken only when its run's own `tier-order` job is green too (--order leaves it out of
# green), the PR targets main, is no draft, carries no `autorebase` label and its head is still the
# row's. Only
# the first such row is acted on:
#   native   the queue is empty → enqueuePullRequest(pullRequestId, expectedHeadOid); else nothing
#            (queue-busy): GitHub's queue with build and merge group size 1 does the rest, and
#            eject.sh --dequeued handles what it removes
#   serial   (every factory-queue/* branch is deleted first, before the candidates are read: a run
#            that never landed) the PR head is
#            fetched from refs/pull/<n>/head, and its merge onto main is built with `git merge-tree
#            --write-tree`. A conflict → eject.sh --reason conflict, nothing built. Otherwise the
#            merge commit S (parents [main, PR head], tree of the merge, subject `Merge pull request
#            #<n> from <owner>/<head ref>` as post-merge.sh parses it, author and committer
#            github-actions[bot]) is pushed to factory-queue/pr-<n>, and GITHUB_OUTPUT gets queue,
#            pr, base (main) and head (S) for enqueue.yml's `gates` job (gates.yml, workflow_call)
#
# land (serial only; enqueue.yml's `land` job, after the gates on S):
#   failure              eject.sh --reason red-queue-run --head S^2 (S must be readable: an unknown
#                        PR head ejects nothing, exit 1); the queue branch is deleted; nothing while
#                        HALT is on main
#   cancelled | skipped  nothing (the next run rebuilds)
#   success              re-checked first: no HALT, the queue branch is still S, S is the queue
#                        commit (parents [base, PR head], the identity, the subject), the PR is open
#                        at that head with no `autorebase`, and main is still <base> (else
#                        main-moved: nothing lands, the next run rebuilds onto the new main, merge:G13).
#                        Then `git push origin S:main`, never forced, so a main that moved meanwhile
#                        refuses it; the App is the ruleset's only bypass actor. The queue branch is
#                        deleted and PR <n> read back: GitHub marks a PR merged when its head becomes
#                        reachable from the base outside the PR, and post-merge needs merged == true
#                        with merge_commit_sha == S. The PR is not closed here: closing it first could
#                        keep GitHub from marking it merged (ADR-0007).
#
# stdout: one JSON line {mode, result, ...}. Exit 0 done (also: nothing to do), 1 operational error.
# Environment: GITHUB_OUTPUT (pick's outputs, when set), GH_TOKEN.
set -euo pipefail
PROG=enqueue
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
usage() { sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

EQ_IDENT_NAME='github-actions[bot]'
EQ_IDENT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
EQ_OK='["success", "skipped", "neutral"]'
B="$(cd "$(dirname "$0")" && pwd)"

cmd="${1:-}"; [ $# -eq 0 ] || shift
case "$cmd" in pick|land) ;; -h|--help|"") usage ;; *) warn "unknown command: $cmd"; usage ;; esac
pr="" base="" queue="" head="" result="" repo="" apply=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr="${2:-}"; shift ;;
    --base) base="${2:-}"; shift ;;
    --queue) queue="${2:-}"; shift ;;
    --head) head="${2:-}"; shift ;;
    --result) result="${2:-}"; shift ;;
    --repo) repo="${2:-}"; shift ;;
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need git jq gh
REPO="$(resolve_repo "$repo")"
MODE_FLAG=--dry-run; [ "$apply" = 0 ] || MODE_FLAG=--apply

emit() { jq -c "$@"; }   # emit <jq args> <program>: the verdict line (reads null)
out() {                  # out <key> <value>: a step output for enqueue.yml
  [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
}
fetch_main() { git fetch -q origin "+refs/heads/main:refs/remotes/origin/main" || die "git fetch origin main failed"; }
main_sha() { git rev-parse refs/remotes/origin/main; }
halted() { [ -n "$(git ls-tree --name-only "$(main_sha)" -- factory/HALT)" ]; }
# eject <eject.sh args>: eject.sh's verdict line, in the same mode as this run.
eject() { "$B/eject.sh" "$@" --repo "$REPO" "$MODE_FLAG"; }
del_branch() {  # del_branch <factory-queue/...>: delete it on origin (--apply); a branch already gone is fine
  [ "$apply" = 1 ] || { echo "enqueue: would delete $1" >&2; return 0; }
  if git push -q origin --delete "$1" 2>/dev/null; then echo "enqueue: deleted $1" >&2
  elif [ -n "$(git ls-remote --heads origin "refs/heads/$1")" ]; then die "git push --delete $1 failed"
  fi
}

# queue_mode: native | serial (GitHub's answer; an unreadable answer is an error, never a guess).
# Prints "<mode> <merge-queue entries>" .
queue_mode() {
  local q owner="${REPO%/*}" name="${REPO#*/}"
  # shellcheck disable=SC2016  # GraphQL variables, not shell
  q="$(gh api graphql -f owner="$owner" -f name="$name" -f query='query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) { mergeQueue(branch: "main") { id entries(first: 100) { totalCount } } } }')" ||
    die "cannot read the merge queue of $REPO (GraphQL)"
  jq -e '(.errors // []) == [] and (.data.repository | type) == "object"' <<<"$q" >/dev/null ||
    die "the merge queue of $REPO is unreadable: $(jq -c '.errors // .' <<<"$q" | cut -c1-200)"
  jq -r '.data.repository.mergeQueue | if . == null then "serial 0" else "native \(.entries.totalCount // 0)" end' <<<"$q"
}

# eligible <row>: prints the PR object when the row may be acted on, else nothing (why on stderr).
eligible() {
  local row="$1" n run pull jobs why=""
  n="$(jq -r .pr <<<"$row")"; run="$(jq -r '.run // empty' <<<"$row")"
  pull="$(gh api "repos/$REPO/pulls/$n")" || die "cannot read PR #$n of $REPO"
  why="$(jq -r --argjson r "$row" '
    if .state != "open" then "not open"
    elif .base.ref != "main" then "it targets \(.base.ref), not main"
    elif .draft == true then "a draft"
    elif any(.labels[]?; (.name | ascii_downcase) == "autorebase") then "labeled autorebase"
    elif .head.sha != $r.head then "its head moved since its gates run"
    else "" end' <<<"$pull")"
  if [ -z "$why" ]; then
    jobs="$(gh api "repos/$REPO/actions/runs/$run/jobs?filter=latest&per_page=100")" || die "cannot read the jobs of run $run"
    jq -e --argjson ok "$EQ_OK" '[.jobs[]? | select(.name == "tier-order")] | max_by(.id)
      | . != null and .status == "completed" and (.conclusion | IN($ok[]))' <<<"$jobs" >/dev/null ||
      why="its tier-order job (run $run) is not green: it waits on a lower tier"
  fi
  if [ -n "$why" ]; then echo "enqueue: skip #$n: $why" >&2; return 0; fi
  printf '%s\n' "$pull"
}

pick() {
  local mode entries order row pull="" n prhead m tree rc subject s
  fetch_main
  m="$(main_sha)"
  if halted; then emit -n --arg m "$m" '{mode: null, result: "halted", main: $m}'; return; fi
  local qm; qm="$(queue_mode)" || exit 1
  read -r mode entries <<<"$qm"
  # A factory-queue/* branch is a serial run that never landed (the concurrency group runs one at a time).
  if [ "$mode" = serial ]; then
    while IFS= read -r s; do [ -z "$s" ] || del_branch "${s#refs/heads/}"; done \
      < <(git ls-remote --heads origin 'factory-queue/*' | cut -f2)
  fi
  order="$("$B/tier-order.sh" --order --base "$m" --repo "$REPO")" || die "tier-order.sh --order failed"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    pull="$(eligible "$row")" || exit 1
    [ -z "$pull" ] || break
  done <<<"$order"
  if [ -z "$pull" ]; then
    emit -n --arg mode "$mode" --arg m "$m" --argjson c "$(jq -sc 'map(.pr)' <<<"$order")" \
      '{mode: $mode, result: "empty", main: $m, ordered: $c}'
    return
  fi
  n="$(jq -r .number <<<"$pull")"; prhead="$(jq -r .head.sha <<<"$pull")"
  if [ "$mode" = native ]; then
    if [ "$entries" != 0 ]; then
      emit -n --argjson n "$n" --argjson e "$entries" '{mode: "native", result: "queue-busy", pr: $n, entries: $e}'; return
    fi
    if [ "$apply" = 0 ]; then emit -n --argjson n "$n" --arg h "$prhead" '{mode: "native", result: "would-enqueue", pr: $n, head: $h}'; return; fi
    local r
    # shellcheck disable=SC2016  # GraphQL variables, not shell
    r="$(gh api graphql -f id="$(jq -r .node_id <<<"$pull")" -f head="$prhead" -f query='mutation($id: ID!, $head: GitObjectID!) {
      enqueuePullRequest(input: {pullRequestId: $id, expectedHeadOid: $head}) { mergeQueueEntry { position } } }')" ||
      die "enqueuePullRequest #$n failed"
    jq -e '(.errors // []) == []' <<<"$r" >/dev/null || die "enqueuePullRequest #$n: $(jq -c .errors <<<"$r" | cut -c1-200)"
    emit -n --argjson n "$n" --arg h "$prhead" --argjson p "$(jq '.data.enqueuePullRequest.mergeQueueEntry.position // null' <<<"$r")" \
      '{mode: "native", result: "enqueued", pr: $n, head: $h, position: $p}'
    return
  fi
  # serial
  git fetch -q origin "+refs/pull/$n/head:refs/factory-queue/pr-head" || die "git fetch refs/pull/$n/head failed"
  [ "$(git rev-parse refs/factory-queue/pr-head)" = "$prhead" ] ||
    { emit -n --argjson n "$n" '{mode: "serial", result: "head-moved", pr: $n}'; return; }
  rc=0; tree="$(git merge-tree --write-tree "$m" "$prhead" 2>/dev/null)" || rc=$?
  if [ "$rc" = 1 ]; then
    local e; e="$(eject --pr "$n" --reason conflict --base "$m" --head "$prhead")" || die "eject.sh #$n failed"
    emit -n --argjson n "$n" --arg m "$m" --argjson e "$e" '{mode: "serial", result: "conflict", pr: $n, main: $m, eject: $e}'
    return
  fi
  [ "$rc" = 0 ] || die "git merge-tree $m $prhead failed (rc $rc)"
  tree="$(head -n1 <<<"$tree")"
  subject="Merge pull request #$n from ${REPO%/*}/$(jq -r .head.ref <<<"$pull")"
  s="$(printf '%s\n' "$subject" | GIT_AUTHOR_NAME="$EQ_IDENT_NAME" GIT_AUTHOR_EMAIL="$EQ_IDENT_EMAIL" \
        GIT_COMMITTER_NAME="$EQ_IDENT_NAME" GIT_COMMITTER_EMAIL="$EQ_IDENT_EMAIL" git commit-tree "$tree" -p "$m" -p "$prhead")" ||
    die "git commit-tree failed"
  if [ "$apply" = 1 ]; then
    git push -q origin "$s:refs/heads/factory-queue/pr-$n" || die "git push factory-queue/pr-$n failed"
    out queue "factory-queue/pr-$n"; out pr "$n"; out base "$m"; out head "$s"
  fi
  emit -n --argjson n "$n" --arg m "$m" --arg s "$s" --arg h "$prhead" --argjson a "$apply" \
    '{mode: "serial", result: (if $a == 1 then "built" else "would-build" end), pr: $n, queue: "factory-queue/pr-\($n)",
      base: $m, head: $s, pr_head: $h}'
}

land() {
  valid_issue "$pr" || die "land: --pr must be a PR number, got '$pr'"
  [[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || die "land: --base and --head are full shas"
  [ "$queue" = "factory-queue/pr-$pr" ] || die "land: --queue must be factory-queue/pr-$pr, got '$queue'"
  local v='{mode: "serial", pr: $n, queue: $q, head: $s}' args=(-n --argjson n "$pr" --arg q "$queue" --arg s "$head")
  case "$result" in
    success) ;;
    failure)
      local prhead e
      fetch_main
      if halted; then emit "${args[@]}" "$v + {result: \"halted\", gates: \"failure\"}"; return; fi
      git fetch -q origin "+refs/heads/$queue:refs/factory-queue/land" 2>/dev/null || true
      # The PR head the red run gated; without it a PR pushed since could be ejected for an old head.
      prhead="$(git rev-parse -q --verify "$head^2" 2>/dev/null)" ||
        die "the queue commit $head is not in this checkout: cannot tell which PR head failed; nothing ejected"
      e="$(eject --pr "$pr" --reason red-queue-run --base "$base" --queue "$queue" --head "$prhead")" ||
        die "eject.sh #$pr failed"
      del_branch "$queue"
      emit "${args[@]}" --argjson e "$e" "$v + {result: \"red\", eject: \$e}"; return ;;
    cancelled|skipped) emit "${args[@]}" --arg r "$result" "$v + {result: \"not-landed\", gates: \$r}"; return ;;
    *) die "land: --result must be success, failure, cancelled or skipped, got '$result'" ;;
  esac
  fetch_main
  if halted; then emit "${args[@]}" "$v + {result: \"halted\"}"; return; fi
  git fetch -q origin "+refs/heads/$queue:refs/factory-queue/land" || die "git fetch $queue failed"
  [ "$(git rev-parse refs/factory-queue/land)" = "$head" ] || die "$queue is not $head any more; refusing to land"
  local -a p; read -r -a p <<<"$(git rev-list --parents -n1 "$head")"
  [ "${#p[@]}" = 3 ] && [ "${p[1]}" = "$base" ] || die "$head is not a queue commit on $base (parents ${p[*]:1})"
  [ "$(git log -1 --format='%an <%ae>|%cn <%ce>' "$head")" = "$EQ_IDENT_NAME <$EQ_IDENT_EMAIL>|$EQ_IDENT_NAME <$EQ_IDENT_EMAIL>" ] &&
    [[ "$(git log -1 --format=%s "$head")" == "Merge pull request #$pr from "* ]] || die "$head is not enqueue.sh's merge commit of #$pr"
  local pull why
  pull="$(gh api "repos/$REPO/pulls/$pr")" || die "cannot read PR #$pr of $REPO"
  why="$(jq -r --arg h "${p[2]}" 'if .state != "open" then "the PR is \(.state)"
    elif .head.sha != $h then "the PR was pushed again (head \(.head.sha[0:12]))"
    elif any(.labels[]?; (.name | ascii_downcase) == "autorebase") then "the PR is labeled autorebase"
    else "" end' <<<"$pull")"
  if [ -n "$why" ]; then del_branch "$queue"; emit "${args[@]}" --arg w "$why" "$v + {result: \"pr-changed\", detail: \$w}"; return; fi
  if [ "$(main_sha)" != "$base" ]; then
    del_branch "$queue"; emit "${args[@]}" --arg m "$(main_sha)" "$v + {result: \"main-moved\", main: \$m}"; return
  fi
  if [ "$apply" = 0 ]; then emit "${args[@]}" "$v + {result: \"would-land\"}"; return; fi
  if ! git push -q origin "$head:refs/heads/main"; then
    fetch_main
    if [ "$(main_sha)" != "$base" ]; then
      del_branch "$queue"; emit "${args[@]}" --arg m "$(main_sha)" "$v + {result: \"main-moved\", main: \$m}"; return
    fi
    die "git push $head to main was refused (is the App the ruleset's bypass actor?)"
  fi
  del_branch "$queue"
  pull="$(gh api "repos/$REPO/pulls/$pr" 2>/dev/null || echo '{}')"
  emit "${args[@]}" --argjson pull "$pull" "$v + {result: \"landed\", main: \$s,
    merged_mark: (if (\$pull | has(\"merged\")) | not then null else (\$pull.merged == true and \$pull.merge_commit_sha == \$s) end)}"
}

"$cmd"
