#!/usr/bin/env bash
# depends-check — the Depends-on hold (specs/factory-step3-v1 TB8, ticket T27; merge:G3, ci:G9).
#
#   depends-check.sh                                  CI's `depends-on` job, run from ./.base (I16), on
#                                                     pull_request and merge_group (I18)
#   depends-check.sh --ticket <id> [--base <sha>]     the same answer outside a PR (labeler.sh asks it
#                                                     before it re-runs a held job)
#
# The parents of a ticket are the tickets of the base store with an edge to it (`edges[].to == <id>`,
# the rule mirror.sh writes an Issue's `Depends-on:` lines from). A ticket PR passes only when every
# parent is completed in that store, and completed means merged to main (I20: post-merge completes a
# ticket on main). The PR body is never read: it is the node's text, so a body that drops or invents a
# `Depends-on:` line changes nothing, and a parent completed only on another branch still holds.
#
# The store is read at lib/gate-context.sh gc_store_sha: the event's base, or the base branch's tip
# when it descends from it, because GitHub re-runs a job with its original event and labeler.sh
# re-runs a held job once its parent merged. A parent on an edge cycle (a desk error) is held, and the
# cycle is named. adlc lets a child complete while its parent is open (merge:G3); the forecast's serial
# order makes this a backstop, never the only order (TB6 ruling).
#
# stdout: one JSON line {ticket, store, base, parents: [{id, completed}], waiting: [ids], cycle, result}
# (result pass | held); {class, result: "pass"} for a desk, halt or human PR; nothing on a refusal.
# Exit 0 pass (also: a desk, halt or human PR, and a ticket with no parents), 2 held (each open
# parent named) or the PR refused by lib/gate-context.sh, 1 operational error (an unreadable store
# fails closed).
set -euo pipefail
PROG=depends-check
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/gate-context.sh
. "$(dirname "$0")/lib/gate-context.sh"
case "${1:-}" in -h|--help) sed -n '2,25p' "$0"; exit 0 ;; esac
need git jq
gate_begin "$@"
if [ "$GC_CLASS" != ticket ]; then
  echo "depends-check: pass: class $GC_CLASS: no ticket, nothing to hold" >&2
  jq -cn --arg c "$GC_CLASS" '{class: $c, result: "pass"}'
  exit 0
fi

STORE_SHA="$(gc_store_sha "$GC_BASE" "$GC_BASE_BRANCH")"
[ "$STORE_SHA" = "$GC_BASE" ] ||
  echo "depends-check: the base branch moved: reading the store at origin/$GC_BASE_BRANCH ${STORE_SHA:0:12}, a descendant of base ${GC_BASE:0:12}" >&2
STORE="$(gc_store "$STORE_SHA")"

out="$(jq -c --arg id "$GC_TICKET" --arg s "$STORE_SHA" --arg b "$GC_BASE" "$GC_STORE_JQ"'
  . as $T
  | ([$T[] | select(.id == $id)] | first) as $me
  | (map({key: .id, value: (.completed == true)}) | from_entries) as $done
  # Every ancestor, breadth first; a cycle is an ancestor path that comes back to $id.
  | {seen: [], todo: ($T | gc_parents($id))}
  | until((.todo | length) == 0;
      .seen as $s | (.todo | map(select(IN($s[]) | not)) | unique) as $new
      | .seen += $new | .todo = [$new[] as $p | $T | gc_parents($p) | .[]])
  | .seen as $anc
  | ($T | gc_parents($id)) as $parents
  | {ticket: $id, store: $s, base: $b, known: ($me != null), completed: ($me.completed == true),
     parents: [$parents[] | {id: ., completed: $done[.]}],
     waiting: [$parents[] | select($done[.] | not)],
     cycle: any($anc[]; . == $id)}
  | .result = (if (.waiting | length) == 0 and (.cycle | not) then "pass" else "held" end)' <<<"$STORE")" ||
  die "cannot evaluate the store at ${STORE_SHA:0:12}"

[ "$(jq -r .known <<<"$out")" = true ] || refuse "ticket $GC_TICKET is not in the store at ${STORE_SHA:0:12}"
[ "$(jq -r .completed <<<"$out")" != true ] || refuse "ticket $GC_TICKET is completed in the store at ${STORE_SHA:0:12}: nothing to merge"
out="$(jq -c 'del(.known, .completed)' <<<"$out")"
printf '%s\n' "$out"
if [ "$(jq -r .result <<<"$out")" = pass ]; then
  jq -r '"depends-check: pass: \(.ticket) " + (if (.parents | length) == 0 then "has no parents"
         else "waits on nothing: every parent is completed (\([.parents[].id] | join(", ")))" end)
         + " in the store at \(.store[0:12])"' <<<"$out" >&2
  exit 0
fi
jq -r '(.waiting[] | "depends-check: HELD: \($ticket) waits on parent \(.) (open in the store at \($s[0:12]))"),
       (if .cycle then "depends-check: HELD: \($ticket) is on an edge cycle (a desk error: an ancestor of \($ticket) depends on it)" else empty end)' \
  --arg ticket "$GC_TICKET" --arg s "$STORE_SHA" <<<"$out" >&2
exit 2
