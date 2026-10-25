#!/usr/bin/env bash
# governor — may this node claim now? (SPEC-v0.2 "Budget governor" and the run-loop sketch; ticket T8)
#
#   governor.sh [--json] [--apply] [--manifest FILE] [--remote NAME] [--branch NAME] [--no-refresh]
#
# Run from the node's clone of the factory repo, at the top of every run-loop iteration. The checks
# run in the spec's order and the first one that says no is the verdict:
#   1 version_check      version-check.sh: exit 2 → refuse (version_behind when factory/VERSION is
#                        behind, else adapter_pins); any other failure → sleep (version_unknown)
#   2 heartbeat          last_seen in nodes/<handle>.json on <remote>/nodes, at most once per
#                        governor.nodeHeartbeatMinutes: skipped while the manifest's last_seen is
#                        younger. With --apply, a compare-and-swap commit (joining|stale → active),
#                        then the manifest's own last_seen. A handle missing from nodes, retired, or
#                        held by another owner → refuse (node_unregistered, node_retired,
#                        handle_taken); a push that fails is a warning and the next run retries it.
#                        Without --apply it only says it would.
#   3 kill_switch_check  halt-check.sh: exit 3 → sleep governor.haltSleepMinutes (halted); any other
#                        failure → sleep (halt_unknown)
#   4 quiet_hours_check  manifest quiet_hours {tz, start, end} in that zone, wrapping midnight →
#                        sleep until the window ends (quiet_hours)
#   5 quota_check        `cux usage refresh` (skipped with --no-refresh) then `cux usage show`
#                        (lib/governor.sh says which windows count) with the manifest's quota_cap:
#                        every account at the cap → sleep until the earliest one frees
#                        (quota_exhausted); a malformed, empty or failed reading → sleep
#                        (quota_unknown), never claim
# Otherwise: claim (reason ok).
#
# Output: one JSON line {"action": "claim"|"sleep"|"refuse", "reason": <code>, "sleep_seconds": <int>}
# with --json, else `<action> <reason> <sleep_seconds>`. Diagnostics go to stderr and never carry a
# cux account key. sleep_seconds is the whole wait; the run loop naps in pieces no longer than the
# heartbeat interval and asks again. Unknown sleeps last governor.unknownStateSleepMinutes.
#
# The manifest is --manifest, else $FACTORY_MANIFEST (join.sh --apply writes it). The clock is
# FACTORY_NOW (epoch seconds or ISO-8601) when set. FACTORY_CUX names the cux binary.
# Exit 0 claim or sleep, 2 refuse, 1 operational error (no manifest, bad budget.json, bad clock).
set -euo pipefail
PROG=governor
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/governor.sh
. "$(dirname "$0")/lib/governor.sh"

usage() { sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

json=0 apply=0 refresh=1 remote=origin branch=main manifest="${FACTORY_MANIFEST:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1 ;;
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --no-refresh) refresh=0 ;;
    --manifest) manifest="${2:-}"; shift ;;
    --remote) remote="${2:-}"; shift ;;
    --branch) branch="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need git jq
[ -n "$remote" ] && [ -n "$branch" ] || die "--remote and --branch need a value"
[ -n "$manifest" ] || die "no manifest: pass --manifest or set FACTORY_MANIFEST (join.sh --apply writes it)"
[ -f "$manifest" ] || die "manifest not found: $manifest"
jq -e 'type == "object"' "$manifest" >/dev/null 2>&1 || die "manifest is not a JSON object: $manifest"

minutes() {  # minutes <governor key>: a positive integer from budget.json, in seconds
  local v; v="$(budget ".governor.$1")"
  [[ "$v" =~ ^[1-9][0-9]*$ ]] || die "budget.json .governor.$1 must be a positive integer, got '$v'"
  echo $((v * 60))
}
HALT_S="$(minutes haltSleepMinutes)"
UNKNOWN_S="$(minutes unknownStateSleepMinutes)"
BEAT_S="$(minutes nodeHeartbeatMinutes)"
STALE_S="$(minutes quotaStaleMinutes)"
NOW="$(gov_now)"
export FACTORY_NOW="$NOW"

handle="$(jq -r '.handle // empty' "$manifest")"
owner="$(jq -r '.owner // empty' "$manifest")"
valid_handle "$handle" || die "manifest handle is missing or bad: '$handle'"
valid_handle "$owner" || die "manifest owner is missing or bad: '$owner'"
cap="$(jq -r '.quota_cap // empty' "$manifest")"
[ -n "$cap" ] || cap="$(budget .governor.quotaCapDefault)"
jq -en --argjson c "$cap" '$c > 0 and $c <= 1' >/dev/null 2>&1 || die "quota_cap must be in (0, 1], got '$cap'"
read -r tz qstart qend < <(jq -r '.quiet_hours // {} | "\(.tz // "-") \(.start // "-") \(.end // "-")"' "$manifest")
[ "$tz" != - ] && [ "$qstart" != - ] && [ "$qend" != - ] || die "manifest quiet_hours needs tz, start and end"

verdict() {  # verdict <action> <reason> <sleep_seconds>: print the one line and exit
  if [ "$json" = 1 ]; then
    jq -cn --arg a "$1" --arg r "$2" --argjson s "$3" '{action: $a, reason: $r, sleep_seconds: $s}'
  else
    printf '%s %s %s\n' "$1" "$2" "$3"
  fi
  [ "$1" = refuse ] && exit 2
  exit 0
}

# 1 version_check ---------------------------------------------------------------------------
rc=0
report="$("$FACTORY_ROOT/factory/bin/version-check.sh" --json --remote "$remote" --branch "$branch" --manifest "$manifest" 2>/dev/null)" || rc=$?
case "$rc" in
  0) ;;
  2) if jq -e '.version.state == "behind"' <<<"$report" >/dev/null 2>&1; then
       warn "factory/VERSION is behind $remote/$branch: pull and restart"; verdict refuse version_behind 0
     fi
     warn "an adapter pin is behind, drifted or unpinned (version-check.sh): re-pin"; verdict refuse adapter_pins 0 ;;
  *) warn "version-check.sh exit $rc: version state unknown"; verdict sleep version_unknown "$UNKNOWN_S" ;;
esac

# 2 heartbeat -------------------------------------------------------------------------------
seen="$(jq -r '.last_seen // empty' "$manifest")"
seen_e="$(gov_iso_epoch "$seen" || true)"
if [ -n "$seen_e" ] && [ $((NOW - seen_e)) -lt "$BEAT_S" ]; then
  warn "heartbeat: skipped, last_seen $seen is under $((BEAT_S / 60)) min old"
elif [ "$apply" = 0 ]; then
  warn "heartbeat: due (last_seen ${seen:-none}); would push nodes/$handle.json (dry run, no --apply)"
else
  hrc=0
  beat="$(gov_heartbeat "$remote" "$handle" "$owner" "$NOW" "$manifest")" || hrc=$?
  case "$beat" in
    pushed*) read -r _ sha tries <<<"$beat"; warn "heartbeat: pushed ${sha:0:12} to $remote/nodes in $tries attempt(s)" ;;
    unregistered) warn "nodes/$handle.json is not on $remote/nodes: re-run join.sh"; verdict refuse node_unregistered 0 ;;
    retired) warn "nodes/$handle.json on $remote/nodes is retired: re-run join.sh"; verdict refuse node_retired 0 ;;
    held-by-other) warn "nodes/$handle.json on $remote/nodes belongs to another owner"; verdict refuse handle_taken 0 ;;
    *) warn "heartbeat: failed (exit $hrc); the next run retries it" ;;
  esac
fi

# 3 kill_switch_check -----------------------------------------------------------------------
rc=0
"$FACTORY_ROOT/factory/bin/halt-check.sh" --json --remote "$remote" --branch "$branch" >/dev/null 2>&1 || rc=$?
case "$rc" in
  0) ;;
  3) warn "factory/HALT is on $remote/$branch"; verdict sleep halted "$HALT_S" ;;
  *) warn "halt-check.sh exit $rc: halt state unknown"; verdict sleep halt_unknown "$UNKNOWN_S" ;;
esac

# 4 quiet_hours_check -----------------------------------------------------------------------
quiet="$(gov_quiet "$NOW" "$tz" "$qstart" "$qend")" || die "cannot evaluate quiet_hours"
if [ "$quiet" -gt 0 ]; then
  warn "inside quiet hours $qstart-$qend $tz"; verdict sleep quiet_hours "$quiet"
fi

# 5 quota_check -----------------------------------------------------------------------------
payload=""
crc=0
payload="$(gov_cux_payload "$refresh")" || crc=$?
if [ "$crc" != 0 ]; then
  warn "cux usage show failed (exit $crc): quota unknown"; verdict sleep quota_unknown "$UNKNOWN_S"
fi
q="$(gov_quota "$payload" "$NOW" "$cap" "$STALE_S" "$UNKNOWN_S")" || die "cannot evaluate the cux reading"
read -r qstate qwhy qsleep < <(jq -r '"\(.state) \(.why) \(.sleep_seconds)"' <<<"$q")
warn "quota: $(jq -r '"\(.accounts) account(s): \(.under) under, \(.at_cap) at cap, \(.unknown) unknown (\(.why))"' <<<"$q")"
case "$qstate" in
  under) ;;
  exhausted) verdict sleep quota_exhausted "$qsleep" ;;
  *) warn "quota reading unusable ($qwhy): fail closed"; verdict sleep quota_unknown "$qsleep" ;;
esac

verdict claim ok 0
