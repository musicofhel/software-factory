#!/usr/bin/env bash
# flaky-check — no quarantined test outlives its expiry (specs/factory-step3-v1 TB11, ticket T30;
# ci:G15). The quarantine list is factory/policy/quarantine.json, a desk file (I15): this script only
# reads it.
#
#   flaky-check.sh [--base <sha> --head <sha> | --file <quarantine.json>] [--json]
#
# The list checked is the one that lands: with --base and --head (gates.yml passes GATE_BASE and
# GATE_HEAD), the head's copy when BASE...HEAD changes the file (only a desk or human PR can: every
# ticket rails factory/policy/**, and owners-check wants two owners on factory/**), else the base's.
# CI runs the BASE's copy of this script from ./.base (I16), so the head's file is data that only
# ever shortens or renews the list under two owners' review, never code. With --file, that file;
# with neither, the file next to this script.
#
# Each entry of .quarantined is {test: <non-empty string>, issue: <positive integer>, expires:
# "YYYY-MM-DD"}. It is live through its expiry day (UTC; FACTORY_NOW pins the clock) and expired
# from the day after: the desk then fixes the test and drops the entry, or renews it with a new date.
# A malformed entry fails as well: it never reads as quarantined. The JUnit-history classifier
# (flaky-test-detective on the flaky-history branch) is step 4: it has no pinned release
# (records/TB0.md (c)).
#
# Exit 0 no entry expired or malformed (stderr names the live ones; --json prints {today, file, live,
# expired, malformed}); 2 an entry expired or is malformed; 1 the list is missing, is not JSON, or has
# no `quarantined` array (unusable, never a pass).
set -euo pipefail
PROG=flaky-check
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

QPATH=factory/policy/quarantine.json
file="" base="" head="" json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --file) [ -n "${2:-}" ] || usage; file="$2"; shift ;;
    --base) [ -n "${2:-}" ] || usage; base="$2"; shift ;;
    --head) [ -n "${2:-}" ] || usage; head="$2"; shift ;;
    --json) json=1 ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need jq
{ [ -z "$base" ] && [ -z "$head" ]; } || { [ -n "$base" ] && [ -n "$head" ] && [ -z "$file" ]; } ||
  die "--base and --head go together, and never with --file"

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
if [ -n "$base" ]; then
  need git
  git rev-parse -q --verify "$base^{commit}" >/dev/null || die "base $base is not a commit here"
  git rev-parse -q --verify "$head^{commit}" >/dev/null || die "head $head is not a commit here"
  rc=0; git diff --quiet "$base...$head" -- "$QPATH" || rc=$?
  case "$rc" in 0) at="$base" ;; 1) at="$head" ;; *) die "git diff $base...$head failed" ;; esac
  where="$at:$QPATH"
  git show "$where" >"$tmp" 2>/dev/null || die "no $QPATH at ${at:0:12}"
else
  where="${file:-$FACTORY_ROOT/$QPATH}"
  [ -f "$where" ] || die "no quarantine list at $where"
  command cp "$where" "$tmp"
fi

today="$(jq -nr --argjson e "$(now_epoch)" '$e | strftime("%Y-%m-%d")')"
report="$(jq -c --arg today "$today" --arg file "$where" '
  def date_ok: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
    and ((try (strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) catch null) as $d | $d == .);
  def well: type == "object" and (.test | type == "string" and length > 0)
    and (.issue | type == "number" and . == floor and . > 0) and (.expires | date_ok);
  if type != "object" or (.quarantined | type) != "array" then error("no quarantined array") else . end
  | [.quarantined | to_entries[] | {index: .key, entry: .value}] as $all
  | {today: $today, file: $file,
     malformed: [$all[] | select(.entry | well | not)],
     expired: [$all[] | select(.entry | well) | select(.entry.expires < $today) | .entry],
     live: [$all[] | select(.entry | well) | select(.entry.expires >= $today) | .entry]}' "$tmp" 2>/dev/null)" ||
  die "$where is not JSON with a \`quarantined\` array"
[ -n "$report" ] || die "$where is empty, not JSON with a \`quarantined\` array"

[ "$json" = 0 ] || printf '%s\n' "$report"
jq -r '.live[] | "flaky-check: quarantined until \(.expires): \(.test) (issue #\(.issue))"' <<<"$report" >&2
bad="$(jq -r '(.expired[] | "  expired \(.expires): \(.test) (issue #\(.issue))"),
              (.malformed[] | "  malformed entry #\(.index): \(.entry | tojson)")' <<<"$report")"
if [ -n "$bad" ]; then
  echo "flaky-check: FAIL: $where on $today:" >&2
  printf '%s\n' "$bad" >&2
  echo "flaky-check: the desk fixes each test and drops its entry, or renews it with a new expiry (I15)" >&2
  exit 2
fi
echo "flaky-check: pass: $(jq -r '.live | length' <<<"$report") live entr$( [ "$(jq -r '.live | length' <<<"$report")" = 1 ] && echo y || echo ies), none expired, on $today" >&2
