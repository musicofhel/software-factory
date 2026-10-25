#!/usr/bin/env bash
# ticket-check — the desk's check on the ticket store, behind `make tickets` (factory-run-calls-v1
# TB2, ticket T18).
#
#   ticket-check.sh [--json]
#
# Reads every ticket (`adlc ticket list --json`, then `adlc ticket show <id> --json`) and refuses an
# open ticket that declares no rail: its `rails` is missing, `[]`, or holds no non-blank string. The
# desk's convention (factory/RULES.md, ADR-0002) is that every ticket declares at least
# `factory/policy/**`; fleet's gate runs `adlc rails-guard --ticket <id>`, which fails every strike
# on a ticket without rails. factory/bin/mirror.sh holds such a ticket at `needs-desk` with the same
# reason. A completed ticket is reported and never refused (T1-T16 predate the rule).
#
# Prints one JSON line per ticket, the output is always JSON lines:
#   {"ticket", "completed", "rails", "result": ok|refused|completed, "reasons"}
# Exit 0 every open ticket passes; 1 a read failed; 2 an open ticket is refused.
#
# Environment: FACTORY_ADLC (default `npx -y @adlc/cli@1.12.0`).
set -euo pipefail
PROG=ticket-check
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --json) ;;                      # the output is always JSON lines
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need jq
read -r -a ADLC <<<"${FACTORY_ADLC:-npx -y @adlc/cli@1.12.0}"

# Every read completes before the first line: a failed read exits 1 with no verdict.
list="$("${ADLC[@]}" ticket list --json)" || die "adlc ticket list failed"
ids="$(jq -r 'if type == "array" then .[].id else error("not a list") end' <<<"$list" 2>/dev/null)" ||
  die "adlc ticket list is not a JSON list of tickets"
out=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  valid_ticket_id "$id" || die "refusing ticket id '$id' from the store"
  show="$("${ADLC[@]}" ticket show "$id" --json)" || die "adlc ticket show $id failed"
  # The rail test is mirror.sh's rails_reasons: a rail is a non-blank string in the `rails` list.
  line="$(jq -c --arg id "$id" 'select(.ticket.id == $id)
    | (.ticket.rails // null) as $r | (.ticket.completed == true) as $c
    | ([$r | arrays | .[] | strings | select(test("\\S"))] | length > 0) as $railed
    | {ticket: $id, completed: $c, rails: $r,
       result: (if $c then "completed" elif $railed then "ok" else "refused" end),
       reasons: (if $c or $railed then [] else ["rails: none declared"] end)}' <<<"$show" 2>/dev/null)" || line=""
  [ -n "$line" ] || die "adlc ticket show $id: not the ticket asked for"
  out+="$line"$'\n'
done <<<"$ids"

printf '%s' "$out"
refused="$(jq -rs '[.[] | select(.result == "refused") | .ticket] | join(" ")' <<<"$out")"
[ -z "$refused" ] || refuse "open ticket(s) without rails: $refused (declare at least factory/policy/**; factory/RULES.md)"
exit 0
