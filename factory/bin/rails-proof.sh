#!/usr/bin/env bash
# rails-proof — no path of BASE...HEAD touches a rail of the ticket, rails read from the
# base's store (specs/factory-step3-v1 TB3, ticket T22). One implementation for the node and CI:
# lib/diff-gates.sh (I17). CI runs the BASE's copy of this script from ./.base against the PR head's
# checkout (I16); the node (run.sh) runs it in the ticket's worktree with
# `--ticket <id> --base <merge-base with origin/main> --head <the sha it pushes>`.
#
# Exit 0 pass, 2 gate fail (or the PR is refused by lib/gate-context.sh), 1 operational error.
# Only a `ticket` PR has rails; a desk, halt or human PR passes here (approvals gate those, TB10). A
# ticket that declares no rails is refused. The spec's text says exit 1 for a rails failure; exit 2 is
# the gate-fail code of every factory script (AGENTS.md, ticket T22), so a rails failure is 2.
set -euo pipefail
PROG=rails-proof
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/gate-context.sh
. "$(dirname "$0")/lib/gate-context.sh"
# shellcheck source=factory/bin/lib/diff-gates.sh
. "$(dirname "$0")/lib/diff-gates.sh"
gate_begin "$@"
if [ "$GC_CLASS" != ticket ]; then
  echo "rails-proof: class $GC_CLASS: no ticket rails (approvals gate it, TB10)" >&2; exit 0
fi
rc=0; hits="$(dg_rails "$GC_TICKET" "$GC_BASE" "$GC_HEAD")" || rc=$?
case "$rc" in
  0) echo "rails-proof: pass: $GC_BASE...$GC_HEAD touches no rail of $GC_TICKET" >&2 ;;
  2) [ -z "$hits" ] || { echo "rails-proof: FAIL: $GC_TICKET edits its rails (the base's store freezes these):" >&2
                         sed 's/^/  /' <<<"$hits" >&2; }
     exit 2 ;;
  *) exit 1 ;;
esac
