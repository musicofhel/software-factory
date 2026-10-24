#!/usr/bin/env bash
# release — give up this node's lock on an Issue (SPEC-v0.2 "Claim protocol", step 5).
#
#   release.sh <n> [--apply] [--json] --handle H [--repo owner/name] [--manifest FILE]
#
# Deletes refs/locks/issue-<n> only when its commit names this node's handle. Another node's lock
# is refused with exit 2: no node ever deletes a lock it does not hold (stale locks are the
# janitor's). No lock at all is exit 0, nothing to do. Labels and comments are not touched; the
# run loop reports results and the janitor tidies labels.
set -euo pipefail
PROG=release
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/lock.sh
. "$(dirname "$0")/lib/lock.sh"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

n="" apply=0 json=0 repo="" manifest="" handle=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --json) json=1 ;;
    --repo) repo="${2:-}"; shift ;;
    --manifest) manifest="${2:-}"; shift ;;
    --handle) handle="${2:-}"; shift ;;
    -h|--help) usage ;;
    -*) warn "unknown argument: $1"; usage ;;
    *) [ -z "$n" ] || usage; n="$1" ;;
  esac
  shift
done
valid_issue "$n" || { warn "need an issue number"; usage; }
need gh jq
REPO="$(resolve_repo "$repo")"
load_node "$manifest" "$handle" ""
[ -n "$NODE_HANDLE" ] || die "need --handle (or --manifest / FACTORY_HANDLE)"
ref="$(lock_ref "$n")"
mode="$([ "$apply" = 1 ] && echo apply || echo dry-run)"

report() {  # report <result> <sha|''>
  local out
  out="$(jq -cn --arg mode "$mode" --argjson n "$n" --arg ref "$ref" --arg r "$1" --arg sha "$2" \
    '{mode: $mode, issue: $n, ref: $ref, result: $r, sha: (if $sha == "" then null else $sha end)}')"
  if [ "$json" = 1 ]; then printf '%s\n' "$out"; else
    jq -r '{absent: "no lock on \(.ref); nothing to release",
            "would-release": "would delete \(.ref) (\(.sha[0:12])); --apply to release",
            released: "released \(.ref) (\(.sha[0:12]))"}[.result]' <<<"$out"
  fi
}

LOCK_ABSENT_OK=1 lock_owned "$n"
if [ -z "$LOCK_SHA" ]; then report absent ""; exit 0; fi
if [ "$apply" = 0 ]; then report would-release "$LOCK_SHA"; exit 0; fi
gh api -X DELETE "repos/$REPO/git/$ref" >/dev/null || die "could not delete $ref"
report released "$LOCK_SHA"
