#!/usr/bin/env bash
# commit-check — every commit a PR brings carries its trailer paragraph (specs/factory-step3-v1 TB4,
# ticket T23; factory/RULES.md rule 1 and "Commit-check exemption"). CI runs the BASE's copy of this
# script from ./.base against the PR head's checkout (I16); lib/gate-context.sh resolves BASE, HEAD,
# the PR, its ticket and its class, and refuses a ticket PR whose body or trailers name another ticket
# before this body runs.
#
#   commit-check.sh [--ticket <id> --base <sha> --head <sha>]   (the flags are the node's form)
#
# The commits checked are the ones the head brings: BASE..HEAD (the head side of BASE...HEAD; the
# other side is main's own history, never the PR's). Trailers are read with git's own trailer parser,
# so only the message's last paragraph counts. For each commit:
#   ticket class        Signed-off-by and Assisted-by present; at least one `Ticket:` and every one
#                       equal to the branch's id; at least one `Node:` and every one equal to the
#                       branch's handle (the node's form has no handle and skips that line)
#   desk, halt, human   Signed-off-by present (the DCO only)
#   any class           a commit that says `Ticket: post-merge` passes only in post-merge's exact
#                       shape (factory/bin/post-merge.sh, RULES.md): the four trailers `Through:
#                       <sha>`, `Assisted-by: none`, `Ticket: post-merge`, `Node: github-actions` and
#                       nothing else, author and committer both $CC_PM_IDENT, one parent, a diff
#                       that touches only .adlc/ and factory/ledger/. In that shape it needs no
#                       Signed-off-by; in any other it fails, signed or not.
# Skipped: on the first-party serial queue (event `queue`, specs/factory-step3-v1 TB9), the queue commit
# enqueue.sh builds: parents exactly [base, PR head (GET pulls/<N> .head.sha)], author and committer
# both $CC_PM_IDENT, subject `Merge pull request #<N> from `. Any other shape is checked like every
# commit. Skipped too: on merge_group only, GitHub's own queue merge commit, which carries no trailers. Measured
# on 2026-10-26 (records/TB4.md §1: Homebrew/brew, rust-lang/cargo and rust-lang/rust-analyzer queue
# groups, read-only `gh api`): the group's head commit, committed by `GitHub <noreply@github.com>`
# and authored by whoever enqueued it (so the author is not the mark), with exactly two parents, the
# first the group's base_sha and the second the PR's head sha (GET pulls/<N> .head.sha). Any other
# shape is checked like every commit, so it fails. A squash-method queue commit has one parent and
# is never skipped: the queue merges with the merge method (TB9).
#
# Exit 0 pass, 2 a commit fails (each one named on stderr) or the PR is refused, 1 an operational
# error.
set -euo pipefail
PROG=commit-check
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/gate-context.sh
. "$(dirname "$0")/lib/gate-context.sh"
gate_begin "$@"

# post-merge.sh commits as this identity on every path (its CC_PM_IDENT twin there; a test holds the two
# equal). GitHub's own queue commits are committed as CC_GH_IDENT.
CC_PM_IDENT='github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'
CC_GH_IDENT='GitHub <noreply@github.com>'

# cc_trailer <commit> <key>: the key's values in the last paragraph, one per line (git's parser).
cc_trailer() { git log -1 --format="%(trailers:key=$2,valueonly,unfold,separator=%x0a)" "$1" | sed 's/[[:space:]]*$//; /^$/d'; }

# cc_queue_commit: the head when it is a queue merge commit (GitHub's on merge_group, enqueue.sh's on
# queue), else nothing.
cc_queue_commit() {
  local -a p
  read -r -a p <<<"$(git rev-list --parents -n1 "$GC_HEAD")"
  [ "${#p[@]}" = 3 ] && [ "${p[1]}" = "$GC_BASE" ] || return 0
  case "$GC_EVENT" in
    merge_group) [ "$(git log -1 --format='%cn <%ce>' "$GC_HEAD")" = "$CC_GH_IDENT" ] || return 0 ;;
    queue) [ "$(git log -1 --format='%an <%ae>|%cn <%ce>' "$GC_HEAD")" = "$CC_PM_IDENT|$CC_PM_IDENT" ] &&
             [[ "$(git log -1 --format=%s "$GC_HEAD")" == "Merge pull request #$GC_PR from "* ]] || return 0 ;;
    *) return 0 ;;
  esac
  local prhead
  prhead="$(gh api "repos/$GC_REPO/pulls/$GC_PR" --jq '.head.sha')" ||
    die "cannot read PR #$GC_PR of $GC_REPO (GH_TOKEN with pull-requests: read)"
  [ "${p[2]}" != "$prhead" ] || printf '%s\n' "$GC_HEAD"
}

# cc_post_merge_shape <commit>: return 0 when the commit is exactly post-merge's, else print why not.
cc_post_merge_shape() {
  local c="$1" all n f
  all="$(git log -1 --format='%(trailers:only,unfold)' "$c" | sed '/^$/d')"
  [ "$(printf '%s\n' "$all" | grep -c .)" = 4 ] || { echo "its trailer paragraph is not exactly the four post-merge trailers"; return 1; }
  [[ "$(cc_trailer "$c" Through)" =~ ^[0-9a-f]{40}$ ]] && [ "$(cc_trailer "$c" Assisted-by)" = none ] &&
    [ "$(cc_trailer "$c" Ticket)" = post-merge ] && [ "$(cc_trailer "$c" Node)" = github-actions ] ||
    { echo "its trailers are not Through: <sha>, Assisted-by: none, Ticket: post-merge, Node: github-actions"; return 1; }
  [ "$(git log -1 --format='%an <%ae>' "$c")" = "$CC_PM_IDENT" ] && [ "$(git log -1 --format='%cn <%ce>' "$c")" = "$CC_PM_IDENT" ] ||
    { echo "it is not authored and committed by $CC_PM_IDENT"; return 1; }
  n="$(git rev-list --parents -n1 "$c" | wc -w | tr -d ' ')"
  [ "$n" = 2 ] || { echo "it has $((n - 1)) parents, not one"; return 1; }
  f="$(git diff --no-renames --name-only "$c^" "$c")" || die "git diff $c^ $c failed"
  [ -n "$f" ] || { echo "it changes nothing"; return 1; }
  f="$(grep -v -e '^\.adlc/' -e '^factory/ledger/' <<<"$f" | head -n1 || true)"
  [ -z "$f" ] || { echo "it touches $f, outside .adlc/ and factory/ledger/"; return 1; }
}

# cc_check <commit>: print why the commit fails, or nothing.
cc_check() {
  local c="$1" v why
  if cc_trailer "$c" Ticket | grep -qxF post-merge; then
    why="$(cc_post_merge_shape "$c")" && return 0
    echo "says 'Ticket: post-merge' but is not post-merge's commit: $why"; return 0
  fi
  [ -n "$(cc_trailer "$c" Signed-off-by)" ] || { echo "no Signed-off-by trailer (the DCO)"; return 0; }
  [ "$GC_CLASS" = ticket ] || return 0
  [ -n "$(cc_trailer "$c" Assisted-by)" ] || { echo "no Assisted-by trailer"; return 0; }
  v="$(cc_trailer "$c" Ticket)"
  [ -n "$v" ] || { echo "no Ticket: trailer (the branch's is $GC_TICKET)"; return 0; }
  v="$(grep -vxF -- "$GC_TICKET" <<<"$v" | head -n1 || true)"
  [ -z "$v" ] || { echo "'Ticket: $v', not the branch's $GC_TICKET"; return 0; }
  [ -n "$GC_HANDLE" ] || return 0
  v="$(cc_trailer "$c" Node)"
  [ -n "$v" ] || { echo "no Node: trailer (the branch's handle is $GC_HANDLE)"; return 0; }
  v="$(grep -vxF -- "$GC_HANDLE" <<<"$v" | head -n1 || true)"
  [ -z "$v" ] || { echo "'Node: $v', not the branch's $GC_HANDLE"; return 0; }
}

skip="$(cc_queue_commit)"
commits="$(git rev-list --reverse "$GC_BASE..$GC_HEAD")" || die "git rev-list $GC_BASE..$GC_HEAD failed (is the head fetched with history?)"
n=0 bad=0
while IFS= read -r c; do
  [ -n "$c" ] || continue
  if [ "$c" = "$skip" ]; then
    echo "commit-check: ${c:0:12} skipped: $([ "$GC_EVENT" = queue ] && echo "the serial queue's" || echo "GitHub's queue") merge commit of PR #$GC_PR (parents base, PR head)" >&2; continue
  fi
  n=$((n + 1))
  why="$(cc_check "$c")"
  if [ -z "$why" ]; then echo "commit-check: ${c:0:12} ok" >&2
  else bad=$((bad + 1)); echo "commit-check: FAIL: ${c:0:12} $(git log -1 --format=%s "$c" | cut -c1-72): $why" >&2
  fi
done <<<"$commits"
if [ "$bad" != 0 ]; then
  echo "commit-check: FAIL: $bad of $n commit(s) in ${GC_BASE:0:12}..${GC_HEAD:0:12} fail the $GC_CLASS rule" >&2; exit 2
fi
echo "commit-check: pass: $n commit(s) in ${GC_BASE:0:12}..${GC_HEAD:0:12} carry the $GC_CLASS trailers" >&2
