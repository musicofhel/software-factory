#!/usr/bin/env bash
# post-merge — ticket completion, only from main. SPEC-v0.2 "Merge": completion (`adlc ticket
# complete --write`) happens in a post-merge CI job, never on a node, so the ticket store is only
# written from main.
#
#   post-merge.sh [--dry-run | --apply] [--remote NAME] [--json]
#
# Refuses (exit 2) unless `git symbolic-ref --short HEAD` is main. Then:
#
#   range     the commits merged since the last run: <through>..HEAD, where <through> is the commit
#             factory/ledger/post-merge.json names (all of history when the file is absent), walked
#             along main's first parent. A merge commit brings the commits of the side it merged
#             (its PR, numbered from "Merge pull request #N"); any other commit brings itself.
#   tickets   per merged PR, only the ticket its head branch names (merge:G11, ticket T23): the PR
#             numbered by the subject ("Merge pull request #N", "… (#N)") is read with `gh api
#             repos/<repo>/pulls/<N>` (GH_TOKEN; <repo> is GITHUB_REPOSITORY, FACTORY_REPO or the
#             origin remote) and counts only when it is merged, its merge_commit_sha is this
#             first-parent commit and its head is ticket/<id>/<handle> on <repo>. Then <id> is
#             completed, in merge order. Every `Ticket:` trailer (git's own trailer parser) the
#             commit brings that names another id, and every trailer of a commit no such PR
#             merged, is reported `foreign` and never completed: a commit cannot complete a
#             ticket by naming it. An id the store does not hold and a ticket already complete are
#             reported and skipped. `Ticket: post-merge` names this job's own commit, not a ticket:
#             it is passed over without a line.
#   complete  `adlc ticket complete <id> --write --authorize --allow-unsigned` for each. Once any
#             ticket declares a rail the store is a frozen trust root (adlc 1.12.0) and a write
#             without ADLC_MANIFEST_KEY refuses (MANIFEST_KEY_REQUIRED) unless it is passed; no key
#             exists, so the completion is recorded unsigned (factory-run-calls-v1 ruling Q1,
#             `.adlc/config.json` securityMode unsigned-fallback). An unfrozen store ignores it.
#   ledger    one line per verified finding of that ticket appended to factory/ledger/findings.jsonl:
#             its p5-finding-verified gate records (`adlc gate-manifest show --ticket <id>`), less
#             any finding a later p5-finding-killed record kills. A line keeps ids, category,
#             severity, confidence and the file/line locator; never the claim, evidence or
#             recommendation text (factory/ledger/README.md).
#   land      factory/ledger/post-merge.json becomes {"through": HEAD} and .adlc/ plus
#             factory/ledger/ are committed once and pushed to <remote> main as a fast-forward. The
#             commit's one trailer paragraph is `Through: <head>`, `Assisted-by: none`, `Ticket:
#             post-merge`, `Node: github-actions` (no Signed-off-by: no human wrote it), authored
#             and committed as github-actions[bot] whatever the environment says, the one
#             identity commit-check.sh exempts in this shape (factory/RULES.md). With
#             nothing completed there is no commit; the next run rescans the same range, which is
#             safe because a completed ticket is skipped. After a failed completion the commit keeps
#             the old marker, so the next run retries the rest.
#
# Every read happens before the first write. --dry-run (the default) changes nothing: no adlc
# write, no file, no commit, no push. Both modes print one JSON line per ticket:
#   {"mode", "action": "complete", "ticket", "commit", "pr", "findings",
#    "result": planned|done|failed|unknown|already|invalid|foreign}
# and, in apply mode, one {"action": "land", "commit", "through", "result"} line.
# --apply refuses (exit 2) unless RUNNER_ENVIRONMENT=github-hosted.
# Exit 0 done or planned; 1 a read, a completion or the push failed; 2 refused.
#
# Environment: FACTORY_ADLC (default `npx -y @adlc/cli@1.12.0`); FACTORY_NOW; GH_TOKEN and
# GITHUB_REPOSITORY (or FACTORY_REPO) for the PR reads.
set -euo pipefail
PROG=post-merge
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

apply=0 remote=origin
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --json) ;;                      # the output is always JSON lines
    --remote) remote="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need git jq
branch="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
[ "$branch" = main ] ||
  refuse "runs only in a checkout of main (HEAD is ${branch:-detached or not a repo}); the ticket store is written only from main"
[ -n "$remote" ] || die "--remote needs a value"
MODE="$([ "$apply" = 1 ] && echo apply || echo dry-run)"
if [ "$apply" = 1 ] && [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then
  refuse "--apply runs only on a GitHub-hosted runner (RUNNER_ENVIRONMENT=${RUNNER_ENVIRONMENT:-unset}); completion never runs on a node"
fi
cd "$(git rev-parse --show-toplevel)"
read -r -a ADLC <<<"${FACTORY_ADLC:-npx -y @adlc/cli@1.12.0}"
# One identity on every path, the runner's (commit-check.sh CC_PM_IDENT exempts exactly it): the env
# and git config cannot change it, so the exemption keys on one fixed author and committer.
export GIT_AUTHOR_NAME='github-actions[bot]' GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
MARK=factory/ledger/post-merge.json
LEDGER=factory/ledger/findings.jsonl
NOW_ISO="$(epoch_to_iso "$(now_epoch)")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/post-merge.XXXXXX")"
# shellcheck disable=SC2317  # invoked by the trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
FAILED=0

emit() {  # emit <json-object> <result> [detail]
  jq -c --arg mode "$MODE" --arg r "$2" --arg d "${3:-}" \
    '{mode: $mode} + . + {result: $r} + (if $d == "" then {} else {detail: $d} end)' <<<"$1"
}

# ------------------------------------------------------------------------------------- range
HEAD_SHA="$(git rev-parse HEAD)"
through=""
if [ -f "$MARK" ]; then
  through="$(jq -r '.through // empty' "$MARK" 2>/dev/null)" || die "$MARK is not JSON"
  [[ "$through" =~ ^[0-9a-f]{40}$ ]] || die "$MARK names no commit (through='$through')"
  git merge-base --is-ancestor "$through" HEAD 2>/dev/null ||
    die "$MARK names $through, which is not in main's history; refusing to guess the range"
fi
range=(HEAD); [ -z "$through" ] || range=("$through..HEAD")
merged="$(git rev-list --first-parent --reverse "${range[@]}")" || die "git rev-list ${range[*]} failed"

# pr_ticket <pr> <commit>: the ticket id of merged PR <pr> when GitHub says it landed as <commit> from a
# ticket/<id>/<handle> branch of this repo; nothing otherwise.
REPO=""
pr_ticket() {
  local pull ref
  [ -n "$REPO" ] || REPO="$(resolve_repo "${GITHUB_REPOSITORY:-}")"
  pull="$(gh api "repos/$REPO/pulls/$1")" || die "cannot read PR #$1 of $REPO (GH_TOKEN with pull-requests: read)"
  jq -e --argjson n "$1" --arg c "$2" --arg r "$REPO" \
    '.number == $n and .merged == true and .merge_commit_sha == $c and .head.repo.full_name == $r' <<<"$pull" >/dev/null || return 0
  ref="$(jq -r '.head.ref // empty' <<<"$pull")"
  [[ "$ref" =~ ^ticket/([^/]+)/([^/]+)$ ]] || return 0
  ref="${BASH_REMATCH[1]}"; valid_handle "${BASH_REMATCH[2]}" && valid_ticket_id "$ref" && printf '%s\n' "$ref"
  return 0
}

# One "<ticket>\t<first-parent commit>\t<branch|foreign>\t<pr|''>" line per id (pr last: tab is IFS
# whitespace, so an empty middle field would collapse), in merge order: the merged
# PR's branch ticket, then each other id a `Ticket:` trailer of that commit's range names.
: >"$WORK/named"
while IFS= read -r c; do
  [ -n "$c" ] || continue
  read -r -a parents <<<"$(git rev-list --parents -n1 "$c")"
  if [ "${#parents[@]}" -gt 2 ]; then brought=("$c^1..$c"); else brought=(-1 "$c"); fi
  subject="$(git log -1 --format=%s "$c")"; pr="" owner=""
  if [[ "$subject" =~ ^Merge\ pull\ request\ \#([0-9]+)([^0-9]|$) ]] || [[ "$subject" =~ \(\#([0-9]+)\)$ ]]; then
    pr="${BASH_REMATCH[1]}"
  fi
  [ -z "$pr" ] || owner="$(pr_ticket "$pr" "$c")"
  [ -z "$owner" ] || printf '%s\t%s\tbranch\t%s\n' "$owner" "$c" "$pr" >>"$WORK/named"
  git log --reverse --format='%(trailers:key=Ticket,valueonly,unfold,separator=%x1f)' "${brought[@]}" |
    tr '\037' '\n' | while IFS= read -r t; do
      t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
      [ -z "$t" ] || [ "$t" = post-merge ] || [ "$t" = "$owner" ] || printf '%s\t%s\tforeign\t%s\n' "$t" "$c" "$pr"
    done | awk '!seen[$0]++' >>"$WORK/named"
done <<<"$merged"

# ------------------------------------------------------------------------------------- plan (reads)
# Findings still verified after replaying the ticket's p5 records in order: verified sets, killed
# clears (the identity is adlc prosecute's: id, file, lines, category, claim, evidence).
FINDINGS_JQ='
  [.entries[] | select(.ticket == $id and (.finding | type) == "object")]
  | reduce .[] as $e ([];
      ($e.type // $e.gate) as $t
      | ($e.finding | {id, file, line_start, line_end, category, claim, evidence} | tojson) as $k
      | if $t == "p5-finding-verified" then map(select(.k != $k)) + [{k: $k, e: $e}]
        elif $t == "p5-finding-killed" then map(select(.k != $k))
        else . end)
  | map(.e as $e | $e.finding as $f
        | {ticket: $id, pr: $pr, merge_commit: $commit, revision: ($e.revision // null), lens: ($e.lens // null),
           adapter: ($e.adapter // null), finding_id: ($f.id // null), category: ($f.category // null),
           severity: ($f.severity // null), confidence: ($f.confidence // null), file: ($f.file // null),
           line_start: ($f.line_start // null), line_end: ($f.line_end // null),
           fix_ticket: ($f.fix_ticket // null), verified_at: ($e.ts // null), completed_at: $now})'
: >"$WORK/plan"
seen=" "
while IFS=$'\t' read -r id commit kind pr; do
  [ -n "$id" ] || continue
  line="$(jq -cn --arg t "$id" --arg c "$commit" --arg pr "$pr" \
    '{action: "complete", ticket: $t, commit: $c, pr: (if $pr == "" then null else ($pr | tonumber) end)}')"
  skip() { jq -c --arg r "$1" --arg d "$2" '. + {skip: $r, detail: $d}' <<<"$line" >>"$WORK/plan"; }
  if [ "$kind" = foreign ]; then
    if [ -n "$pr" ]; then skip foreign "a Ticket: trailer of the commits PR #$pr merged; the PR's head branch does not name it (never completed)"
    else skip foreign "a Ticket: trailer of a commit no merged ticket PR landed (never completed)"; fi
    continue
  fi
  case "$seen" in *" $id "*) continue ;; esac
  seen="$seen$id "
  if ! valid_ticket_id "$id"; then skip invalid "not a ticket id"; continue; fi
  rc=0
  "${ADLC[@]}" ticket show "$id" --json >"$WORK/show.json" 2>"$WORK/show.err" || rc=$?
  # adlc 1.12.0 prints the TICKET_NOT_FOUND error object on stderr (stdout is empty); read both,
  # one JSON document per line, ignoring any other text (npx notices).
  if [ "$rc" = 2 ] && command cat "$WORK/show.json" "$WORK/show.err" |
       jq -Rne '[inputs | fromjson? | objects | .code] | index("TICKET_NOT_FOUND") != null' >/dev/null 2>&1; then
    skip unknown "the ticket store has no ticket $id"; continue
  fi
  [ "$rc" = 0 ] || die "adlc ticket show $id failed (exit $rc): $(tail -n1 "$WORK/show.err")"
  completed="$(jq -r --arg id "$id" 'select(.ticket.id == $id) | .ticket.completed == true' "$WORK/show.json" 2>/dev/null)" || true
  [ -n "$completed" ] || die "adlc ticket show $id: not the ticket asked for"
  if [ "$completed" = true ]; then skip already "the ticket is already complete"; continue; fi
  "${ADLC[@]}" gate-manifest show --ticket "$id" --json >"$WORK/gm.json" || die "adlc gate-manifest show --ticket $id failed"
  [ "$(jq '.skipped // [] | length' "$WORK/gm.json" 2>/dev/null)" = 0 ] ||
    die "the gate manifest has unreadable entries; refusing to complete $id from a partial record"
  findings="$(jq -c --arg id "$id" --arg commit "$commit" --argjson pr "$(jq '.pr' <<<"$line")" --arg now "$NOW_ISO" \
    "$FINDINGS_JQ" "$WORK/gm.json")" || die "adlc gate-manifest show --ticket $id: unreadable entries"
  jq -c --argjson f "$findings" '. + {findings: ($f | length), lines: $f}' <<<"$line" >>"$WORK/plan"
done <"$WORK/named"

# ------------------------------------------------------------------------------------- complete
completed_ids=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  line="$(jq -c 'del(.lines, .skip, .detail)' <<<"$p")"
  if [ "$(jq -r '.skip // empty' <<<"$p")" != "" ]; then emit "$line" "$(jq -r .skip <<<"$p")" "$(jq -r .detail <<<"$p")"; continue; fi
  if [ "$apply" = 0 ]; then emit "$line" planned; continue; fi
  id="$(jq -r .ticket <<<"$p")"
  rc=0
  "${ADLC[@]}" ticket complete "$id" --write --authorize --allow-unsigned --json >"$WORK/complete.json" 2>"$WORK/complete.err" || rc=$?
  if [ "$rc" = 0 ] && jq -se 'last | .applied == true' "$WORK/complete.json" >/dev/null 2>&1; then
    jq -c '.lines[]' <<<"$p" >>"$LEDGER"
    completed_ids+=("$id")
    emit "$line" "done"
  else
    FAILED=1
    emit "$line" failed "adlc ticket complete exit $rc: $(tail -n1 "$WORK/complete.err")"
  fi
done <"$WORK/plan"
[ "$apply" = 1 ] || exit 0

# ------------------------------------------------------------------------------------- land
line="$(jq -cn --arg t "$HEAD_SHA" '{action: "land", through: $t}')"
if [ "${#completed_ids[@]}" = 0 ]; then
  emit "$line" skipped "nothing completed; no commit"
  exit "$FAILED"
fi
if [ "$FAILED" = 0 ]; then
  jq -n --arg t "$HEAD_SHA" --arg at "$NOW_ISO" '{through: $t, at: $at}' >"$MARK"
else
  line="$(jq -c --arg t "${through:-}" '.through = (if $t == "" then null else $t end)' <<<"$line")"
fi
git add -A -- .adlc factory/ledger
trailers="$(printf 'Through: %s\nAssisted-by: none\nTicket: post-merge\nNode: github-actions' "$HEAD_SHA")"
git commit -q --no-verify -m "post-merge: complete ${completed_ids[*]}" -m "$trailers" ||
  die "git commit failed"
line="$(jq -c --arg c "$(git rev-parse HEAD)" '. + {commit: $c}' <<<"$line")"
if git push --quiet --no-verify "$remote" "HEAD:refs/heads/main" 2>"$WORK/push.err"; then
  emit "$line" "done"
else
  FAILED=1
  emit "$line" failed "push to $remote main refused: $(tail -n1 "$WORK/push.err")"
fi
exit "$FAILED"
