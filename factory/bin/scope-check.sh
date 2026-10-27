#!/usr/bin/env bash
# scope-check — every path of BASE...HEAD matches a scope glob of the ticket (fleet's own
# glob semantics), scope read from the base's store; a ticket never touches `.adlc/**` (specs/factory-step3-v1 TB3, ticket T22). One implementation for the node and CI:
# lib/diff-gates.sh (I17). CI runs the BASE's copy of this script from ./.base against the PR head's
# checkout (I16); the node (run.sh) runs it in the ticket's worktree with
# `--ticket <id> --base <merge-base with origin/main> --head <the sha it pushes>`.
#
# Exit 0 pass, 2 gate fail (or the PR is refused by lib/gate-context.sh), 1 operational error.
# Only a `ticket` PR has a scope; a desk, halt or human PR passes here (approvals gate those, TB10).
set -euo pipefail
PROG=scope-check
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/gate-context.sh
. "$(dirname "$0")/lib/gate-context.sh"
# shellcheck source=factory/bin/lib/diff-gates.sh
. "$(dirname "$0")/lib/diff-gates.sh"
gate_begin "$@"
if [ "$GC_CLASS" != ticket ]; then
  echo "scope-check: class $GC_CLASS: no ticket scope (approvals gate it, TB10)" >&2; exit 0
fi
rc=0; out="$(dg_scope "$GC_TICKET" "$GC_BASE" "$GC_HEAD")" || rc=$?
case "$rc" in
  0) echo "scope-check: pass: every path of $GC_BASE...$GC_HEAD is in the scope of $GC_TICKET" >&2 ;;
  2) [ -z "$out" ] || { echo "scope-check: FAIL: outside the scope of $GC_TICKET (or under .adlc/):" >&2
                        sed 's/^/  /' <<<"$out" >&2; }
     exit 2 ;;
  *) exit 1 ;;
esac
