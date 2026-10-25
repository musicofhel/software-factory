#!/usr/bin/env bash
# quota-gate — may the next strike start? fleet's pre-strike command (ADR-0005; ticket T8).
#
#   quota-gate.sh [--json] [--cap X] [--manifest FILE] [--no-refresh]
#
# `fleet run --pre-strike-argv '["<abs>/factory/bin/quota-gate.sh"]' --pre-strike-env '{…}'` runs it
# before every strike: argv[0] absolute, no shell, and the environment is EXACTLY --pre-strike-env
# (fleet adds nothing), so that env must carry PATH (bash, jq, cux) and HOME (cux's state), plus
# FACTORY_MANIFEST or FACTORY_CUX when used. fleet pauses the ticket as quota-paused on any non-zero.
#
# Reads `cux usage refresh` (skipped with --no-refresh; its output is dropped, it lists the account
# e-mails) then `cux usage show`, and judges it as governor.sh's quota_check does (lib/governor.sh).
# The cap is --cap, else the manifest's quota_cap (--manifest, else $FACTORY_MANIFEST), else
# budget.json governor.quotaCapDefault. The clock is FACTORY_NOW when set.
#
# Exit 0: at least one account is under the cap. Exit 2: every account is at or above it.
# Exit 1: the reading is malformed, empty, stale or failed (the state is unknown: do not strike).
# --json prints {state, why, accounts, under, at_cap, unknown, sleep_seconds}: counts only.
set -euo pipefail
PROG=quota-gate
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/governor.sh
. "$(dirname "$0")/lib/governor.sh"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

json=0 refresh=1 cap="" manifest="${FACTORY_MANIFEST:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1 ;;
    --no-refresh) refresh=0 ;;
    --cap) cap="${2:-}"; shift ;;
    --manifest) manifest="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need jq
if [ -z "$cap" ] && [ -n "$manifest" ]; then
  [ -f "$manifest" ] || die "manifest not found: $manifest"
  cap="$(jq -r '.quota_cap // empty' "$manifest")" || die "manifest is not JSON: $manifest"
fi
[ -n "$cap" ] || cap="$(budget .governor.quotaCapDefault)"
jq -en --argjson c "$cap" '$c > 0 and $c <= 1' >/dev/null 2>&1 || die "the quota cap must be in (0, 1], got '$cap'"
stale="$(budget .governor.quotaStaleMinutes)"
unknown="$(budget .governor.unknownStateSleepMinutes)"
[[ "$stale" =~ ^[1-9][0-9]*$ && "$unknown" =~ ^[1-9][0-9]*$ ]] || die "budget.json governor.quotaStaleMinutes and unknownStateSleepMinutes must be positive integers"
NOW="$(gov_now)"

payload=""
crc=0
payload="$(gov_cux_payload "$refresh")" || crc=$?
if [ "$crc" != 0 ]; then
  q="$(jq -cn --argjson u "$((unknown * 60))" '{state: "unknown", why: "cux-failed", accounts: 0, under: 0, at_cap: 0, unknown: 0, sleep_seconds: $u}')"
else
  q="$(gov_quota "$payload" "$NOW" "$cap" "$((stale * 60))" "$((unknown * 60))")" || die "cannot evaluate the cux reading"
fi
if [ "$json" = 1 ]; then printf '%s\n' "$q"; fi
warn "$(jq -r '"\(.state): \(.accounts) account(s), \(.under) under the cap, \(.at_cap) at it, \(.unknown) unknown (\(.why))"' <<<"$q")"
case "$(jq -r .state <<<"$q")" in
  under) exit 0 ;;
  exhausted) exit 2 ;;
  *) exit 1 ;;
esac
