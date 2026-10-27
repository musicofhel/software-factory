#!/usr/bin/env bash
# halt-guard — the kill switch's asymmetry: zero approvals to add factory/HALT, two to remove it
# (SPEC-v0.2 "Kill switch"; docs/adr/0004-halt-two-person-rule.md options C and D; specs/factory-step3-v1
# TB10, ticket T29; ci:G11, merge:G17).
#
#   halt-guard.sh                        CI's `halt-guard` job, run from ./.base (I16), on pull_request
#                                        and the queue path (I18)
#   halt-guard.sh --add --actor <login> [--reason <text>] [--repo <owner/name>] [--apply | --dry-run]
#                                        halt.yml: commit factory/HALT onto main directly, on the App
#                                        token (the ruleset's only bypass actor), never through a PR
#                                        or the queue
#
# The gate: a PR whose BASE...HEAD deletes factory/HALT passes only with two distinct approvals by
# the owners of factory/HALT in the base's CODEOWNERS, given on the PR's current head
# (owners-check.sh --only factory/HALT counts them). A PR that adds or edits it, or does not touch
# it, passes: adding a halt never waits on a review. reviews.yml re-runs this job on every review.
#
# --add: the actor (the dispatcher of halt.yml, or whoever put the `factory:halt` label on an Issue
# or a PR) must have write access (GET collaborators/<login>/permission: admin or write; maintain
# reads as write). Then the commit: main's tree plus factory/HALT ("halted by @<actor> at <time>:
# <reason>"), parent origin/main, author and committer github-actions[bot] (the identity post-merge
# and the queue commit with), subject `halt: stop the line (@<actor>)`, no `Ticket:` trailer; it is
# pushed to main without force, re-built on a moved main up to three times. A HALT already on main
# is a no-op. --dry-run (the default) prints the plan and pushes nothing. The push on the App token
# starts the push workflows, so the summoner's halt notice fires on it.
#
# stdout: one JSON line: the gate {pr, class, halt: none|add|edit|remove, result} (the count
# included for a removal); --add {actor, result: halted|already-halted|dry-run, sha, main}.
# Exit 0 pass / done, 2 a removal short of approvals, an actor without write access, or the PR refused
# by lib/gate-context.sh, 1 operational error.
set -euo pipefail
PROG=halt-guard
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
B="$(cd "$(dirname "$0")" && pwd)"
HG_PATH=factory/HALT
HG_IDENT_NAME='github-actions[bot]'
HG_IDENT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'

hg_add() {
  local actor="" reason="" repo="" apply=0 perm main tree blob commit attempt now msg
  while [ $# -gt 0 ]; do
    case "$1" in
      --actor) actor="${2:-}"; shift ;;
      --reason) reason="${2:-}"; shift ;;
      --repo) repo="${2:-}"; shift ;;
      --apply) apply=1 ;;
      --dry-run) apply=0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
  [[ "$actor" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?$ ]] || die "--actor needs a GitHub login, got '$actor'"
  need git gh jq
  REPO="$(resolve_repo "$repo")"
  perm="$(gh api "repos/$REPO/collaborators/$actor/permission" --jq .permission)" ||
    die "cannot read the permission of @$actor on $REPO"
  case "$perm" in
    admin|maintain|write) ;;
    *) refuse "@$actor has $perm access to $REPO: only a collaborator with write access may halt the factory" ;;
  esac
  reason="$(printf '%s' "${reason:-no reason given}" | tr '\n' ' ' | cut -c1-200)"
  for attempt in 1 2 3; do
    git fetch --quiet --no-tags origin "+refs/heads/main:refs/remotes/origin/main" || die "cannot fetch origin main"
    main="$(git rev-parse refs/remotes/origin/main)"
    if [ -n "$(git ls-tree "$main" "$HG_PATH")" ]; then
      echo "halt-guard: $HG_PATH is already on main (${main:0:12}): nothing to add" >&2
      jq -cn --arg a "$actor" --arg m "$main" '{actor: $a, result: "already-halted", sha: null, main: $m}'; return 0
    fi
    now="$(epoch_to_iso "$(now_epoch)")"
    if [ "$apply" = 0 ]; then
      echo "halt-guard: dry run: would commit $HG_PATH (halted by @$actor at $now: $reason) onto main ${main:0:12} and push it" >&2
      jq -cn --arg a "$actor" --arg m "$main" '{actor: $a, result: "dry-run", sha: null, main: $m}'; return 0
    fi
    blob="$(printf 'halted by @%s at %s: %s\n' "$actor" "$now" "$reason" | git hash-object -w --stdin)"
    local idx; idx="$(git rev-parse --absolute-git-dir)/halt-guard.index"
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git read-tree "$main"
    GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$blob,$HG_PATH"
    tree="$(GIT_INDEX_FILE="$idx" git write-tree)"; rm -f "$idx"
    msg="$(printf 'halt: stop the line (@%s)\n\n%s\n' "$actor" "$reason")"
    commit="$(GIT_AUTHOR_NAME="$HG_IDENT_NAME" GIT_AUTHOR_EMAIL="$HG_IDENT_EMAIL" GIT_COMMITTER_NAME="$HG_IDENT_NAME" \
              GIT_COMMITTER_EMAIL="$HG_IDENT_EMAIL" git commit-tree "$tree" -p "$main" -m "$msg")"
    local perr; perr="$(git rev-parse --absolute-git-dir)/halt-guard.push-err"
    if git push --quiet origin "$commit:refs/heads/main" 2>"$perr"; then
      echo "halt-guard: halted: $HG_PATH committed as ${commit:0:12} on main (by @$actor)" >&2
      jq -cn --arg a "$actor" --arg s "$commit" --arg m "$main" '{actor: $a, result: "halted", sha: $s, main: $m}'; return 0
    fi
    # Only a moved main is retried; any other refusal (auth, a rule) is the answer.
    git fetch --quiet --no-tags origin "+refs/heads/main:refs/remotes/origin/main" || die "cannot fetch origin main"
    [ "$(git rev-parse refs/remotes/origin/main)" != "$main" ] ||
      die "the push of ${commit:0:12} onto main was refused and main did not move: $(tail -n1 "$perr")"
    warn "the push of ${commit:0:12} onto main ${main:0:12} was refused (attempt $attempt of 3): main moved, rebuilding"
  done
  die "main kept moving: $HG_PATH was not pushed after 3 attempts; run halt.yml again"
}

case "${1:-}" in
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  --add) shift; hg_add "$@"; exit 0 ;;
esac

# shellcheck source=factory/bin/lib/gate-context.sh
. "$B/lib/gate-context.sh"
need git jq
gate_begin "$@"
st="$(git diff --name-status --no-renames "$GC_BASE...$GC_HEAD" -- "$HG_PATH")" || die "cannot diff ${GC_BASE:0:12}...${GC_HEAD:0:12}"
case "${st%%$'\t'*}" in
  "") kind=none ;;
  A) kind=add ;;
  D) kind=remove ;;
  *) kind=edit ;;
esac
if [ "$kind" != remove ]; then
  echo "halt-guard: pass: $HG_PATH $([ "$kind" = none ] && echo "is not touched" || echo "${kind}ed: a halt needs no approval")" >&2
  jq -cn --arg pr "$GC_PR" --arg c "$GC_CLASS" --arg k "$kind" '{pr: ($pr | tonumber? // null), class: $c, halt: $k, result: "pass"}'
  exit 0
fi
rc=0
count="$("$B/owners-check.sh" --only "$HG_PATH" "$@")" || rc=$?
case "$rc" in
  0) echo "halt-guard: pass: removing $HG_PATH has two distinct code-owner approvals" >&2 ;;
  2) [ -n "$count" ] || refuse "the PR was refused by lib/gate-context.sh (owners-check.sh says why above)"
     echo "halt-guard: FAIL: removing $HG_PATH needs two distinct approvals by its code owners on the PR head; it has $(jq -r '.protected[0].approvals | length' <<<"$count")" >&2 ;;
  *) die "owners-check.sh failed (exit $rc): the approvals of a HALT removal are unknown" ;;
esac
jq -c --arg c "$GC_CLASS" '{pr, class: $c, halt: "remove", approvals: .protected[0].approvals, owners: .protected[0].owners,
  result: (if .result == "pass" then "pass" else "short" end)}' <<<"$count"
[ "$rc" = 0 ] || exit 2
