#!/usr/bin/env bash
# heartbeat — refresh this node's lock on an Issue (SPEC-v0.2 "Claim protocol", step 4).
#
#   heartbeat.sh <n> [--apply] [--json] --handle H [--repo owner/name] [--manifest FILE]
#
# Reads refs/locks/issue-<n>, checks that its commit names this node's handle, then (with --apply)
# creates a new lock commit on the nodes tip carrying the same {handle, run_id, slots} and a fresh
# claimed_at, and force-updates the ref to it (PATCH git/refs/locks/issue-<n>, force=true).
# The run loop calls it hourly (budget.json claim.heartbeatMinutes); a lock whose commit is older
# than claim.staleAfterHours is stale and the janitor may take it.
# Exit 2 when the lock is gone (the claim was lost) or held by another node: never refresh a lock
# you do not hold, and never re-create a lost one here (that is a new claim, through claim.sh).
set -euo pipefail
PROG=heartbeat
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/lock.sh
. "$(dirname "$0")/lib/lock.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

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
NOW="$(now_epoch)"

lock_owned "$n"
ref="$(lock_ref "$n")"
payload="$(jq -c --arg at "$(epoch_to_iso "$NOW")" '.payload + {claimed_at: $at}' <<<"$LOCK_INFO")"

report() {  # report <mode> <new-sha|''>
  local out
  out="$(jq -cn --arg mode "$1" --argjson n "$n" --arg ref "$ref" --arg old "$LOCK_SHA" --arg new "$2" \
           --argjson payload "$payload" \
    '{mode: $mode, issue: $n, ref: $ref, old_sha: $old, new_sha: (if $new == "" then null else $new end),
      payload: $payload}')"
  if [ "$json" = 1 ]; then printf '%s\n' "$out"; else
    jq -r 'if .mode == "dry-run"
           then "would heartbeat \(.ref) (\(.old_sha[0:12]) -> new commit, claimed_at \(.payload.claimed_at)); --apply to write"
           else "heartbeat \(.ref): \(.old_sha[0:12]) -> \(.new_sha[0:12]), claimed_at \(.payload.claimed_at)" end' <<<"$out"
  fi
}

if [ "$apply" = 0 ]; then report dry-run ""; exit 0; fi
sha="$(lock_commit "$n" "$payload")" || die "could not create the heartbeat commit"
gh api -X PATCH "repos/$REPO/git/$ref" -f sha="$sha" -F force=true >/dev/null ||
  die "could not update $ref"
report apply "$sha"
