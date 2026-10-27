#!/usr/bin/env bash
# tamper-check — tamperguard over BASE...HEAD, the verdict parsed from its JSON (specs/factory-step3-v1 TB3, ticket T22). One implementation for the node and CI:
# lib/diff-gates.sh (I17). CI runs the BASE's copy of this script from ./.base against the PR head's
# checkout (I16); the node (run.sh) runs it in the ticket's worktree with
# `--ticket <id> --base <merge-base with origin/main> --head <the sha it pushes>`.
#
# Exit 0 pass, 2 gate fail (or the PR is refused by lib/gate-context.sh), 1 operational error.
# Every class is checked. tamperguard 0.2.0 ($DG_TAMPERGUARD_PIN) is on PATH (the node: uv tool; CI:
# pipx on Python $DG_TAMPERGUARD_PYTHON). Its JSON goes to stdout (the job log). rc 0 with `ok` or
# `review` passes; rc 2 with a parsed `tamper` verdict fails (exit 2); anything else is tamper-error,
# a failure too (exit 1), never a pass.
set -euo pipefail
PROG=tamper-check
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/gate-context.sh
. "$(dirname "$0")/lib/gate-context.sh"
# shellcheck source=factory/bin/lib/diff-gates.sh
. "$(dirname "$0")/lib/diff-gates.sh"
gate_begin "$@"
need tamperguard
argv=(); while IFS= read -r a; do argv+=("$a"); done < <(dg_tamper_argv "$GC_BASE" "$GC_HEAD")
rc=0; out="$(tamperguard "${argv[@]}")" || rc=$?
[ -z "$out" ] || printf '%s\n' "$out"
case "$(dg_tamper_judge "$rc" "$out")" in
  0:ok|0:review) echo "tamper-check: pass (rc $rc, $(jq -r .verdict <<<"$out"))" >&2 ;;
  2:tamper) echo "tamper-check: FAIL: tamperguard's verdict is tamper" >&2; exit 2 ;;
  *) echo "tamper-check: tamper-error: tamperguard exited $rc without a verdict this gate reads" >&2; exit 1 ;;
esac
