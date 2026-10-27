#!/usr/bin/env bash
# ticket-check — the desk's contract lint on the ticket store, behind `make tickets` and the `desk` job
# of .github/workflows/gates.yml (factory-run-calls-v1 TB2, ticket T18; specs/factory-step3-v1 TB7,
# ticket T26).
#
#   ticket-check.sh [--json]
#
# Reads every ticket (`adlc ticket list --json`, then `adlc ticket show <id> --json`), the paths of the
# checkout it runs in (`git ls-files`, the tracked ones: CI's ./.base copy is untracked) and the merge forecast
# (`adlc merge-forecast --json`; exit 2 with a JSON object is still a forecast), and refuses an open
# ticket for any of:
#   rails     its `rails` is missing, `[]`, or holds no non-blank string. The desk's convention
#             (factory/RULES.md, ADR-0002) is that every ticket declares at least `factory/policy/**`;
#             fleet's gate runs `adlc rails-guard --ticket <id>`, which fails every strike on a ticket
#             without rails. factory/bin/mirror.sh holds such a ticket at `needs-desk` with the same reason
#   header    the ADR-0002 header block (`weight: light|heavy`, `tier: 0|1|2`, `charter: C<n>`, before
#             the first blank line of the body) is missing or malformed; the reasons are mirror.sh's
#             header_reasons, word for word
#   scope     no scope glob, or a glob that matches no path of the checkout and no declared new path.
#             The globs are fleet's (lib/diff-gates.sh dg_glob, the scope gate's own matcher). A new
#             path is declared on a body line starting `New paths` (or `New path`), each in backticks,
#             by the ticket itself or by any ticket it waits on (its parents, their parents, ...): a
#             parent's new file exists by the time the child can build
#   edges     an edge target that is not in the store
#   tier      a tier inversion: an open parent (a ticket with an edge to this one) whose header tier is
#             higher than this ticket's (foundation first, SPEC-v0.2 L671); a completed parent orders
#             nothing any more
#   forecast  any forecast warning naming the ticket (`ticket "<id>" ...`, merge-forecast
#             lib/forecast.mjs:69-72): a scope that matches 0 files makes adlc call the ticket
#             `unscoped` and sequence it behind every other ticket (records/sim intake.md I7)
# A completed ticket is reported and never refused (T1-T16 predate these rules).
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
# shellcheck source=factory/bin/lib/diff-gates.sh
. "$(dirname "$0")/lib/diff-gates.sh"

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --json) ;;                      # the output is always JSON lines
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need jq git
read -r -a ADLC <<<"${FACTORY_ADLC:-npx -y @adlc/cli@1.12.0}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git checkout (the scope check reads its paths)"
cd "$ROOT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ticket-check.XXXXXX")"
# shellcheck disable=SC2317  # invoked by the trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Every read completes before the first line: a failed read exits 1 with no verdict.
list="$("${ADLC[@]}" ticket list --json)" || die "adlc ticket list failed"
ids="$(jq -r 'if type == "array" then .[].id else error("not a list") end' <<<"$list" 2>/dev/null)" ||
  die "adlc ticket list is not a JSON list of tickets"
: >"$WORK/tickets.jsonl"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  valid_ticket_id "$id" || die "refusing ticket id '$id' from the store"
  show="$("${ADLC[@]}" ticket show "$id" --json)" || die "adlc ticket show $id failed"
  jq -ce --arg id "$id" 'select(.ticket.id == $id) | .ticket | {id, body: (.body // ""), scope: (.scope // null),
      edges: (.edges // []), rails: (.rails // null), completed: (.completed == true)}' <<<"$show" >>"$WORK/tickets.jsonl" 2>/dev/null ||
    die "adlc ticket show $id: not the ticket asked for"
done <<<"$ids"

git ls-files -z | jq -Rsc 'split("\u0000") | map(select(. != ""))' >"$WORK/files.json" ||
  die "git ls-files failed"
if jq -se 'any(.[]; .completed | not)' "$WORK/tickets.jsonl" >/dev/null; then
  rc=0; "${ADLC[@]}" merge-forecast --json >"$WORK/forecast.json" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 2 ] || die "adlc merge-forecast failed (exit $rc)"
  jq -e 'type == "object"' "$WORK/forecast.json" >/dev/null 2>&1 || die "the forecast is not a merge-forecast JSON object"
else
  echo '{"warnings": []}' >"$WORK/forecast.json"   # no open ticket: adlc's forecast exits 1, nothing to warn
fi

CHECK_JQ='
def lines: gsub("\r"; "") | split("\n");
# mirror.sh header and header_reasons, word for word.
def header:
  (.body | lines) as $l | ($l | index("")) as $i
  | [$l[0:($i // ($l | length))][] | capture("^(?<k>weight|tier|charter):[ \t]*(?<v>.*?)[ \t]*$")?]
  | map({(.k): .v}) | add // {};
def weight_ok: . != null and IN("light", "heavy");
def tier_ok: . != null and IN("0", "1", "2");
def header_reasons($h):
  [ (if $h.weight == null then "header: weight missing"
     elif ($h.weight | weight_ok) then empty else "header: weight \u0027\($h.weight)\u0027 is not light|heavy" end),
    (if $h.tier == null then "header: tier missing"
     elif ($h.tier | tier_ok) then empty else "header: tier \u0027\($h.tier)\u0027 is not 0|1|2" end),
    (if $h.charter == null then "header: charter missing"
     elif ($h.charter | test("^C[0-9]+$")) then empty
     else "header: charter \u0027\($h.charter)\u0027 is not a PROJECT.md line id (C<n>)" end) ];
def new_paths: [.body | lines | .[] | select(test("^New paths?\\b"; "i")) | scan("`([^`]+)`") | .[0]];

($T | map({key: .id, value: .}) | from_entries) as $by
| ($T | map({key: .id, value: (header.tier | if tier_ok then tonumber else null end)}) | from_entries) as $tier
| def parents($id): [$T[] | select(any(.edges[]?; .to == $id)) | .id];
  def ancestors($id):
    {seen: [], todo: parents($id)}
    | until(.todo == []; .todo[0] as $x | .todo |= .[1:]
        | .seen as $s | if ($x | IN($s[])) then . else .seen += [$x] | .todo += parents($x) end)
    | .seen;
$T[] as $t
| if $t.completed then {ticket: $t.id, completed: true, rails: $t.rails, result: "completed", reasons: []}
  else
    ($t | header) as $h
    | ([$t] + [ancestors($t.id)[] | $by[.]] | map(new_paths[]) | unique) as $new
    | ([$t.scope | arrays | .[] | strings]) as $globs
    | [ (if ([$t.rails | arrays | .[] | strings | select(test("\\S"))] | length) > 0 then empty
         else "rails: none declared" end),
        header_reasons($h)[],
        (if ($globs | length) == 0 then "scope: none declared"
         else $globs[] as $g
           | if any($F[]; dg_glob($g)) or any($new[]; . == $g or dg_glob($g)) then empty
             else "scope: \u0027\($g)\u0027 matches no path and no declared new path (a `New paths:` line of this ticket or a parent)" end
         end),
        ($t.edges[] | .to as $to | if ($to | type) == "string" and $by[$to] != null then empty
         else "edges: target \u0027\($to)\u0027 is not in the store" end),
        (parents($t.id)[] as $p | select($by[$p].completed | not)
         | if $tier[$p] != null and $tier[$t.id] != null and $tier[$p] > $tier[$t.id]
           then "tier: tier \($tier[$t.id]) waits on \($p), tier \($tier[$p]) (a parent never has a higher tier)" else empty end),
        ($W[] | strings | select(contains("ticket \"\($t.id)\"")) | "forecast: \(.)") ] as $why
    | {ticket: $t.id, completed: false, rails: $t.rails,
       result: (if $why == [] then "ok" else "refused" end), reasons: $why}
  end
'
out="$(jq -c -n --slurpfile T "$WORK/tickets.jsonl" --slurpfile FF "$WORK/files.json" --slurpfile WF "$WORK/forecast.json" \
  "$DG_GLOB_JQ"'$T as $T | $FF[0] as $F | ($WF[0].warnings // []) as $W | '"$CHECK_JQ")" || die "could not compute the check"

[ -z "$out" ] || printf '%s\n' "$out"
refused="$(jq -rs '[.[] | select(.result == "refused") | .ticket] | join(" ")' <<<"$out")"
[ -z "$refused" ] || refuse "open ticket(s) refused: $refused (the reasons are on each line; factory/RULES.md, the desk runbook)"
exit 0
