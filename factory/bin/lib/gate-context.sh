#!/usr/bin/env bash
# shellcheck shell=bash
# gate-context — the facts every gate needs, resolved one way for CI and the node (specs/factory-step3-v1
# TB2, ticket T21; invariants I16 and I17).
#
# Sourced by the gate scripts (after lib/common.sh), or run on its own:
#
#   gate-context.sh [--ticket <id>] [--base <sha>] [--head <sha>] [--repo <owner/name>]
#       Prints the context as one JSON object and exits 0; exit 2 when the PR is refused (no class,
#       a malformed ticket ref, an identity mismatch); exit 1 on an operational error.
#
# What it resolves (gate_context sets the GC_* variables):
#   GC_EVENT    pull_request | merge_group | node
#   GC_BASE     pull_request.base.sha | merge_group.base_sha | --base, else the merge-base of
#               refs/remotes/origin/main and the head (the node; never a lapsed tip)
#   GC_HEAD     pull_request.head.sha | merge_group.head_sha | --head, else HEAD
#   GC_PR       the PR number: the event's, or on merge_group N of gh-readonly-queue/<base>/pr-<N>-<sha>;
#               empty on the node
#   GC_HEAD_REF the PR's head branch: the event's, or on merge_group PR N's, read through
#               `gh api repos/<repo>/pulls/<N>` with the job's read-only token (GH_TOKEN)
#   GC_TICKET, GC_HANDLE  from a head ref ticket/<id>/<handle> (on the node: --ticket)
#   GC_CLASS    ticket | desk | halt | human:
#                 ticket  the head ref is ticket/<id>/<handle>, on the base repo (never a fork)
#                 halt    otherwise, by a collaborator: the diff only adds or only removes factory/HALT
#                 desk    otherwise, by a collaborator: every changed path is under $GC_DESK_PATHS
#                 human   otherwise, by a collaborator (author_association OWNER, MEMBER, COLLABORATOR)
#               Anything else (a ticket ref that does not parse, a fork's ticket ref, a stranger's PR)
#               is refused: exit 2, never a class a gate could wave through.
#   GC_AUTHOR, GC_ASSOC, GC_BODY, GC_HEAD_REPO  the PR's author login, author_association, body and
#               head repository (empty on the node)
#
# The diff is always three-dot from the merge-base (`BASE...HEAD`), read in the current directory:
# CI runs the BASE's copy of this file (./.base/factory/bin/...) inside the PR head's checkout, so the
# head is data and never code (I16).
#
# gate_identity: on a `ticket` PR, every `Ticket:` line of the PR body and every `Ticket:` trailer of
# BASE..HEAD must name GC_TICKET, and the body must carry one (run.sh writes it). A mismatch is
# refused, naming the other id. Missing trailers are commit-check's (TB4), not this check's.
#
# Environment: GITHUB_EVENT_NAME, GITHUB_EVENT_PATH, GITHUB_REPOSITORY (as a runner sets them), GH_TOKEN
# for the merge_group lookup.

# Paths a desk PR may touch: the ticket store and the desk's ADRs (SPEC-v0.2 L408-410: the contract
# desk owns the store; L471: desk disagreements are ADRs in docs/adr/).
GC_DESK_PATHS=('.adlc/' 'docs/adr/')
GC_HALT_PATH=factory/HALT

# gc_queue_pr <merge_group head_ref>: N of (refs/heads/)gh-readonly-queue/<base>/pr-<N>-<40 hex>, or
# return 1.
gc_queue_pr() {
  local r="${1#refs/heads/}"
  [[ "$r" =~ ^gh-readonly-queue/.+/pr-([1-9][0-9]*)-[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# gc_ticket_ref <head ref>: prints "<id> <handle>" for ticket/<id>/<handle>; return 1 when the ref is
# not under ticket/, 2 when it is but does not parse (an extra `/`, a bad id or handle).
gc_ticket_ref() {
  local r="${1#refs/heads/}"
  case "$r" in ticket/*) ;; *) return 1 ;; esac
  [[ "$r" =~ ^ticket/([^/]+)/([^/]+)$ ]] || return 2
  local id="${BASH_REMATCH[1]}" h="${BASH_REMATCH[2]}"   # the validators' own =~ overwrite BASH_REMATCH
  valid_ticket_id "$id" && valid_handle "$h" || return 2
  printf '%s %s\n' "$id" "$h"
}

# gc_collaborator <author_association>: the associations that mean write access to the repo.
gc_collaborator() { case "$1" in OWNER|MEMBER|COLLABORATOR) return 0 ;; *) return 1 ;; esac; }

# gc_files_class <base> <head>: halt, desk or human for a non-ticket diff (BASE...HEAD).
gc_files_class() {
  local ns path p desk=1 n=0
  ns="$(git diff --no-renames --name-status "$1...$2")" || die "git diff $1...$2 failed (is the head fetched with history?)"
  case "$ns" in "A"$'\t'"$GC_HALT_PATH"|"D"$'\t'"$GC_HALT_PATH") echo halt; return ;; esac
  while IFS=$'\t' read -r _ path; do
    [ -n "$path" ] || continue
    n=$((n + 1))
    local hit=0
    for p in "${GC_DESK_PATHS[@]}"; do case "$path" in "$p"*) hit=1 ;; esac; done
    [ "$hit" = 1 ] || desk=0
  done <<<"$ns"
  if [ "$n" -gt 0 ] && [ "$desk" = 1 ]; then echo desk; else echo human; fi
}

# gc_pull <json>: GC_HEAD_REF, GC_AUTHOR, GC_ASSOC, GC_BODY, GC_HEAD_REPO from a REST pull-request object
# (the shape of the pull_request event's .pull_request and of GET repos/<repo>/pulls/<n>).
gc_pull() {
  GC_HEAD_REF="$(jq -r '.head.ref // empty' <<<"$1")"
  GC_HEAD_REPO="$(jq -r '.head.repo.full_name // empty' <<<"$1")"
  GC_AUTHOR="$(jq -r '.user.login // empty' <<<"$1")"
  GC_ASSOC="$(jq -r '.author_association // empty' <<<"$1")"
  GC_BODY="$(jq -r '.body // ""' <<<"$1")"
}

gate_context() {
  local ticket="" base="" head="" repo="" ev pull
  while [ $# -gt 0 ]; do
    case "$1" in
      --ticket) ticket="${2:-}"; shift ;;
      --base) base="${2:-}"; shift ;;
      --head) head="${2:-}"; shift ;;
      --repo) repo="${2:-}"; shift ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
  GC_EVENT="" GC_BASE="" GC_HEAD="" GC_PR="" GC_HEAD_REF="" GC_TICKET="" GC_HANDLE="" GC_CLASS=""
  GC_AUTHOR="" GC_ASSOC="" GC_BODY="" GC_HEAD_REPO="" GC_REPO=""
  # Explicit flags are the node's call (run.sh: --ticket --base --head); a runner's event otherwise.
  if [ -n "$ticket$base$head" ] || [ -z "${GITHUB_EVENT_NAME:-}" ]; then
    GC_EVENT=node
    [ -n "$ticket" ] || die "the node passes --ticket (no GITHUB_EVENT_NAME to read one from)"
    valid_ticket_id "$ticket" || refuse "bad ticket id '$ticket'"
    GC_HEAD="$(git rev-parse --verify -q "${head:-HEAD}^{commit}")" || die "head ${head:-HEAD} is not a commit here"
    if [ -n "$base" ]; then GC_BASE="$(git rev-parse --verify -q "$base^{commit}")" || die "base $base is not a commit here"
    else GC_BASE="$(git merge-base refs/remotes/origin/main "$GC_HEAD")" || die "no merge-base of origin/main and $GC_HEAD"
    fi
    GC_TICKET="$ticket" GC_CLASS=ticket
    return 0
  fi
  [ -r "${GITHUB_EVENT_PATH:-}" ] || die "GITHUB_EVENT_PATH is not a readable event file"
  ev="$(jq -c . "$GITHUB_EVENT_PATH")" || die "the event file is not JSON"
  GC_REPO="$(resolve_repo "${repo:-${GITHUB_REPOSITORY:-}}")"
  case "$GITHUB_EVENT_NAME" in
    pull_request|pull_request_review)
      GC_EVENT=pull_request
      pull="$(jq -c '.pull_request // empty' <<<"$ev")"
      [ -n "$pull" ] || die "a $GITHUB_EVENT_NAME event without .pull_request"
      GC_BASE="$(jq -r '.base.sha // empty' <<<"$pull")"; GC_HEAD="$(jq -r '.head.sha // empty' <<<"$pull")"
      GC_PR="$(jq -r '.number // empty' <<<"$pull")"
      gc_pull "$pull" ;;
    merge_group)
      GC_EVENT=merge_group
      GC_BASE="$(jq -r '.merge_group.base_sha // empty' <<<"$ev")"; GC_HEAD="$(jq -r '.merge_group.head_sha // empty' <<<"$ev")"
      local qref; qref="$(jq -r '.merge_group.head_ref // empty' <<<"$ev")"
      GC_PR="$(gc_queue_pr "$qref")" || refuse "merge_group head_ref '$qref' is not gh-readonly-queue/<base>/pr-<N>-<sha>"
      pull="$(gh api "repos/$GC_REPO/pulls/$GC_PR")" || die "cannot read PR #$GC_PR of $GC_REPO (GH_TOKEN with pull-requests: read)"
      [ "$(jq -r '.number // empty' <<<"$pull")" = "$GC_PR" ] || die "repos/$GC_REPO/pulls/$GC_PR answered another PR"
      gc_pull "$pull" ;;
    *) die "event $GITHUB_EVENT_NAME has no gate context (pull_request or merge_group)" ;;
  esac
  [[ "$GC_BASE" =~ ^[0-9a-f]{40}$ && "$GC_HEAD" =~ ^[0-9a-f]{40}$ ]] || die "the event has no base and head sha"
  valid_issue "$GC_PR" || die "the event has no PR number"
  git cat-file -e "$GC_BASE^{commit}" 2>/dev/null && git cat-file -e "$GC_HEAD^{commit}" 2>/dev/null ||
    die "base $GC_BASE or head $GC_HEAD is not in this checkout (fetch-depth: 0)"
  local tr rc=0
  tr="$(gc_ticket_ref "$GC_HEAD_REF")" || rc=$?
  case "$rc" in
    0) [ "$GC_HEAD_REPO" = "$GC_REPO" ] ||
         refuse "PR #$GC_PR: ticket ref $GC_HEAD_REF from ${GC_HEAD_REPO:-an unknown repo}, not $GC_REPO (a fork is never a ticket PR)"
       GC_TICKET="${tr% *}" GC_HANDLE="${tr#* }" GC_CLASS=ticket ;;
    2) refuse "PR #$GC_PR: head ref '$GC_HEAD_REF' is under ticket/ but is not ticket/<id>/<handle> (an id has no '/')" ;;
    *) gc_collaborator "$GC_ASSOC" ||
         refuse "PR #$GC_PR by ${GC_AUTHOR:-unknown} (${GC_ASSOC:-no association}): not a ticket branch and not a collaborator's PR"
       GC_CLASS="$(gc_files_class "$GC_BASE" "$GC_HEAD")" ;;
  esac
}

# gate_identity: refuse a `ticket` PR whose body or trailers name another ticket (run after
# gate_context; a no-op for the other classes).
gate_identity() {
  [ "$GC_CLASS" = ticket ] || return 0
  local named other
  if [ "$GC_EVENT" != node ]; then
    named="$(tr -d '\r' <<<"$GC_BODY" | sed -n 's/^Ticket:[[:space:]]*//p' | sed 's/[[:space:]]*$//')"
    [ -n "$named" ] || refuse "PR #$GC_PR: ticket branch for $GC_TICKET, but the body has no 'Ticket:' line"
    other="$(grep -vxF -- "$GC_TICKET" <<<"$named" | head -n1 || true)"
    [ -z "$other" ] || refuse "PR #$GC_PR: ticket branch for $GC_TICKET, but the body says 'Ticket: $other'"
  fi
  named="$(git log --format='%H %(trailers:key=Ticket,valueonly,separator=%x2C)' "$GC_BASE..$GC_HEAD")" ||
    die "git log $GC_BASE..$GC_HEAD failed"
  other="$(awk -v t="$GC_TICKET" '{ n = split($2, v, ","); for (i = 1; i <= n; i++) { gsub(/^ +| +$/, "", v[i]); if (v[i] != "" && v[i] != t) { print substr($1, 1, 12) " " v[i]; exit } } }' <<<"$named")"
  [ -z "$other" ] || refuse "${GC_PR:+PR #$GC_PR: }ticket branch for $GC_TICKET, but commit ${other% *} has the trailer 'Ticket: ${other#* }'"
}

gate_context_json() {
  jq -cn --arg event "$GC_EVENT" --arg base "$GC_BASE" --arg head "$GC_HEAD" --arg pr "$GC_PR" --arg ref "$GC_HEAD_REF" \
    --arg ticket "$GC_TICKET" --arg handle "$GC_HANDLE" --arg class "$GC_CLASS" --arg author "$GC_AUTHOR" --arg assoc "$GC_ASSOC" \
    '{event: $event, base: $base, head: $head, pr: (if $pr == "" then null else ($pr | tonumber) end), head_ref: $ref,
      ticket: $ticket, handle: $handle, class: $class, author: $author, author_association: $assoc}
     | with_entries(select(.value != ""))'
}

# gate_begin [flags]: what every gate script calls first: resolve, check identity, say on stderr which
# copy of the gate runs against what (the job log shows the base's script ran, I16).
gate_begin() {
  gate_context "$@"
  gate_identity
  printf '%s: %s gate from %s on %s\n' "${PROG:-gate}" "$GC_CLASS" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" "$(gate_context_json)" >&2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  PROG=gate-context
  # shellcheck source=factory/bin/lib/common.sh
  . "$(dirname "$0")/common.sh"
  gate_context "$@"
  gate_identity
  gate_context_json
fi
