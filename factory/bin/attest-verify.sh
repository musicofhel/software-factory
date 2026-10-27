#!/usr/bin/env bash
# attest-verify — the node's gate manifest (the attest note) agrees with what CI recomputes
# (specs/factory-step3-v1 TB11, ticket T30; ci:G6, ci:G16, node:G6; the format is ADR-0007 decision 9).
#
#   attest-verify.sh [--ticket <id>] [--base <sha>] [--head <sha>] [--repo <owner/name>]
#
# CI runs the BASE's copy of this script from ./.base against the PR head's checkout (I16); with no
# flags it reads the event (lib/gate-context.sh). On a `ticket` PR it fetches origin's
# refs/notes/factory-attest, reads the note on the commit the node pushed (the PR head; on merge_group
# and the first-party queue, the queue commit's second parent) and recomputes, from the base:
#   - the ticket, node and adapter against the gate context and the commit's own trailers;
#   - base = the merge-base of the base and that commit, head, and its tree;
#   - the gate command list (build-test.sh --list of fleet.gate at that merge-base) and the tests
#     the node says fleet ran (that list when built, none on a rebase strike);
#   - the rails-proof, scope and tamperguard verdicts, through lib/diff-gates.sh (I17), tamperguard
#     0.2.0 on PATH as for tamper-check.sh;
#   - signing: the note is unsigned, which only a base store in securityMode unsigned-fallback
#     accepts (ruling Q1 of factory-run-calls-v1).
# What it cannot recompute (fleet's run id, strikes, the hashes of fleet's document and of the node's
# tamperguard JSON) it carries through for the record. On the node (--ticket, no PR) it reads the
# local note and fetches nothing.
#
# Exit 0 the note agrees (and a desk, halt or human PR passes: no node built it, approvals gate it,
# TB10); 2 a missing note, any mismatch, or a refused PR; 1 an operational error.
set -euo pipefail
PROG=attest-verify
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/gate-context.sh
. "$(dirname "$0")/lib/gate-context.sh"
# shellcheck source=factory/bin/lib/diff-gates.sh
. "$(dirname "$0")/lib/diff-gates.sh"
# shellcheck source=factory/bin/lib/attest.sh
. "$(dirname "$0")/lib/attest.sh"
gate_begin "$@"
if [ "$GC_CLASS" != ticket ]; then
  echo "attest-verify: class $GC_CLASS: no node built it, so no attest note (approvals gate it, TB10)" >&2; exit 0
fi
need jq tamperguard
rc=0; target="$(attest_target)" || rc=$?
case "$rc" in
  0) ;;
  2) refuse "FAIL: the $GC_EVENT commit $GC_HEAD is not [base $GC_BASE, PR #$GC_PR's head]: no commit to read the note from" ;;
  *) die "cannot read PR #$GC_PR's head (gh api repos/$GC_REPO/pulls/$GC_PR)" ;;
esac
if [ "$GC_EVENT" != node ]; then
  rc=0; attest_fetch || rc=$?
  case "$rc" in
    0) ;;
    2) refuse "FAIL: origin has no $ATTEST_REF, so $target carries no attest note" ;;
    *) die "cannot fetch $ATTEST_REF from origin" ;;
  esac
fi
rc=0; note="$(attest_read "$target")" || rc=$?
[ "$rc" = 0 ] || refuse "FAIL: no attest note ($ATTEST_REF) on $target, or it is not one JSON object"
rc=0; out="$(attest_check "$note" "$GC_TICKET" "$GC_HANDLE" "$GC_BASE" "$target")" || rc=$?
case "$rc" in
  0) printf '%s\n' "$note"
     echo "attest-verify: pass: the note on $target agrees with what CI recomputes ($(jq -r '"\(.outcome), rails-proof \(.verdicts["rails-proof"]), scope \(.verdicts.scope), tamperguard \(.verdicts.tamperguard.verdict)"' <<<"$note"))" >&2 ;;
  2) echo "attest-verify: FAIL: the note on $target does not agree with CI:" >&2
     sed 's/^/  /' <<<"$out" >&2
     exit 2 ;;
  *) die "could not recompute the note's verdicts on $target" ;;
esac
