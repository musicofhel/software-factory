#!/usr/bin/env bash
# mirror — the ADLC ticket store (the source of truth, written only from main) → GitHub Issues (the
# display). SPEC-v0.2 "Decisions baked in" and ADR-0002. Labels are set only here, so nothing a
# stranger files becomes claimable without the desk.
#
#   mirror.sh [--dry-run | --apply] [--forecast FILE] [--repo owner/name] [--json]
#
# Reads every ticket (`adlc ticket list --json`, then `adlc ticket show <id> --json` for the body,
# edges and completed flag), the gate records (`adlc gate-manifest show --json`: .adlc/manifest.jsonl
# plus .adlc/manifest.d/), the merge forecast (FILE, which the janitor passes, else `adlc
# merge-forecast --json`; exit 2 with a JSON object is still a forecast) and every Issue. Then:
#
#   open ticket       one Issue: created if missing, reopened if closed, and its title, body and
#                     labels edited only where they differ (a run with nothing new writes nothing)
#   completed ticket  its Issue is closed (reason completed, `ready` removed); none is created
#
# The Issue body is the marker line, `Ticket: <id>`, one `Depends-on: <id>` per ticket holding an
# edge to this one (ADLC edges point prerequisite → dependent), `Ticket-Hash: <ticketHash>` (the
# store state a node claims; run.sh copies it into its needs-desk marker), the gate verdict and its
# reasons, then the ticket body verbatim. Labels: `w:<weight>` and `tier:<n>` from the body header
# (`weight: light|heavy`, `tier: 0|1|2`, `charter: C<n>`), plus `ready` when all of these hold and
# `needs-desk` otherwise:
#   header          weight, tier and charter parse
#   spec-lint       the ticket's latest spec-lint record is a verified pass
#   coldstart       the ticket's latest coldstart record has an empty gap list and was taken on the
#                   ticket's current ticketHash (a ticket edited since is stale)
#   merge-forecast  the ticket has a merge-forecast record that is not a failure, and the forecast
#                   certifies it now: no forecast gateFailures, the ticket is in wave 1, and no
#                   SEQUENCE pair puts it behind a wave-1 ticket earlier in mergeOrder
# One exception (step-2 ruling Q3, factory/RULES.md): an open Issue a node labeled `needs-desk` keeps
# it, and gets no `ready`, while its newest trusted marker-or-claim comment is the run loop's
# needs-desk marker for this ticket at the store's current ticketHash (format and rule:
# factory/bin/lib/desk-marker.sh). A desk edit (a new ticketHash) or a new claim cycle (a claim
# comment after the marker) ends the hold; a `needs-desk` without the marker is recomputed as above.
# Other labels (in-progress, ...) are never touched. An Issue is the mirror's when its author is in
# MIRROR_AUTHORS and its body has a `Ticket: <id>` line (the first one counts); the marker line is a
# notice for humans, not proof, so a hand edit that keeps the Ticket line is overwritten on the next
# run, while a mirror Issue wiped of its Ticket line is reported as an orphan and a fresh Issue is
# created. A human's Issue is never adopted. A bot outside MIRROR_AUTHORS carrying the marker is a
# conflict (MIRROR_AUTHORS is probably wrong) and no Issue is created for its ticket, so a
# misconfiguration cannot mint a duplicate every run. Of two mirror Issues for one ticket the lower
# number is kept and the other reported.
#
# --dry-run (the default) writes nothing. Both modes print one JSON line per action on stdout:
#   {"mode", "action": label-create|create|update|reopen|close|unchanged|conflict|orphan, "ticket",
#    "issue", "gate", "reasons", "desk_hold" ({node, reason} when a node's needs-desk is kept, else
#    null), "add", "remove", "title_changed", "body_changed", "result":
#    planned|done|failed|unchanged|conflict|kept}
# --apply refuses (exit 2) unless RUNNER_ENVIRONMENT=github-hosted and the checkout is on main.
# Exit 0 done or planned; 1 a read failed (then nothing is written), a write failed or a conflict
# exists; 2 refused.
#
# Environment: FACTORY_REPO; FACTORY_ADLC (default `npx -y @adlc/cli@1.12.0`); MIRROR_AUTHORS
# (comma-separated gh author logins, default `app/github-actions,github-actions[bot]`: what gh
# reports for an Issue the Actions token created).
set -euo pipefail
PROG=mirror
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/desk-marker.sh
. "$(dirname "$0")/lib/desk-marker.sh"

usage() { sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

apply=0 forecast="" repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --json) ;;                      # the output is always JSON lines
    --forecast) forecast="${2:-}"; [ -n "$forecast" ] || die "--forecast needs a file"; shift ;;
    --repo) repo="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need gh jq git
MODE="$([ "$apply" = 1 ] && echo apply || echo dry-run)"
if [ "$apply" = 1 ]; then
  [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] ||
    refuse "--apply runs only on a GitHub-hosted runner (RUNNER_ENVIRONMENT=${RUNNER_ENVIRONMENT:-unset}); labels are set only by the mirror job"
  branch="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  [ "$branch" = main ] || refuse "--apply runs only in a checkout of main (HEAD is ${branch:-detached}); the store is read from main"
fi
REPO="$(resolve_repo "$repo")"
read -r -a ADLC <<<"${FACTORY_ADLC:-npx -y @adlc/cli@1.12.0}"
AUTHORS="$(jq -cn --arg a "${MIRROR_AUTHORS:-app/github-actions,github-actions[bot]}" '$a | split(",") | map(select(. != ""))')"
MARKER='<!-- factory-mirror: generated from the ADLC ticket store by factory/bin/mirror.sh; edits here are overwritten -->'
LIMIT=1000

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mirror.XXXXXX")"
# shellcheck disable=SC2317  # invoked by the trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
FAILED=0
EMPTY_FORECAST='{"pairs":[],"waves":[],"mergeOrder":[],"firstWaveWidth":0,"certifiedWidth":0,"warnings":[],"gateFailures":[]}'

# ------------------------------------------------------------------------------------- read
# Every read completes before the first write: a failed read exits 1 with nothing changed.
list="$("${ADLC[@]}" ticket list --json)" || die "adlc ticket list failed"
ids="$(jq -r 'if type == "array" then .[].id else error("not a list") end' <<<"$list" 2>/dev/null)" ||
  die "adlc ticket list is not a JSON list of tickets"
: >"$WORK/tickets.jsonl"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  valid_ticket_id "$id" || die "refusing ticket id '$id' from the store"
  "${ADLC[@]}" ticket show "$id" --json >"$WORK/show.json" || die "adlc ticket show $id failed"
  jq -ce --arg id "$id" 'select(.ticket.id == $id and (.ticketHash | type) == "string")
    | {id: .ticket.id, title: (.ticket.title // ""), body: (.ticket.body // ""), edges: (.ticket.edges // []),
       completed: (.ticket.completed == true), hash: .ticketHash}' "$WORK/show.json" >>"$WORK/tickets.jsonl" 2>/dev/null ||
    die "adlc ticket show $id: not the ticket asked for"
done <<<"$ids"

"${ADLC[@]}" gate-manifest show --json >"$WORK/gm.json" || die "adlc gate-manifest show failed"
jq -e '(.entries | type) == "array"' "$WORK/gm.json" >/dev/null 2>&1 || die "adlc gate-manifest show: no entries list"
skipped="$(jq '.skipped // [] | length' "$WORK/gm.json")"
[ "$skipped" = 0 ] || die "the gate manifest has $skipped unreadable entries; refusing to label from a partial record"

if [ -n "$forecast" ]; then
  [ -f "$forecast" ] || die "forecast file not found: $forecast"
  command cp "$forecast" "$WORK/forecast.json"
elif ! jq -se 'any(.completed | not)' "$WORK/tickets.jsonl" >/dev/null; then
  # No open ticket: `adlc merge-forecast` exits 1 ("no active tickets found"), so the forecast is
  # the empty one and every Issue is just closed.
  printf '%s\n' "$EMPTY_FORECAST" >"$WORK/forecast.json"
else
  rc=0
  "${ADLC[@]}" merge-forecast --json >"$WORK/forecast.json" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 2 ] || die "adlc merge-forecast failed (exit $rc)"
fi
jq -e 'type == "object" and (.waves | type) == "array"' "$WORK/forecast.json" >/dev/null 2>&1 ||
  die "the forecast is not a merge-forecast JSON object"

gh issue list --repo "$REPO" --state all --limit "$LIMIT" --json number,title,body,state,labels,author \
  >"$WORK/issues.json" || die "gh issue list failed"
[ "$(jq length "$WORK/issues.json")" -lt "$LIMIT" ] || die "gh returned $LIMIT Issues, its limit; the list may be truncated"
# The comments of open needs-desk Issues only: where a node's marker can hold the label.
gh issue list --repo "$REPO" --state open --label needs-desk --limit "$LIMIT" --json number,comments \
  >"$WORK/desk.json" || die "gh issue list (needs-desk comments) failed"
[ "$(jq length "$WORK/desk.json")" -lt "$LIMIT" ] || die "gh returned $LIMIT needs-desk Issues, its limit; the list may be truncated"
gh label list --repo "$REPO" --json name --limit "$LIMIT" >"$WORK/labels.json" || die "gh label list failed"
[ "$(jq length "$WORK/labels.json")" -lt "$LIMIT" ] || die "gh returned $LIMIT labels, its limit; the list may be truncated"

# ------------------------------------------------------------------------------------- plan
# Pure: tickets, gate records, forecast and Issues in; one action object per line out.
PLAN_JQ='
def lines: gsub("\r"; "") | split("\n");
def norm: gsub("\r"; "") | sub("\\s+$"; "");
def etype: .type // .gate;
def latest($g; $id): [$E[] | select(etype == $g and .ticket == $id)] | last;
def owned: test("^(ready|needs-desk|w:.+|tier:.+)$");

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

# coldstart records come in two shapes (adlc runner/lib/assertions.mjs): live data.cache, or a
# prompt-only data.verdict JSON string.
def coldstart_shape:
  if (.data.cache | type) == "object" then {gaps: .data.cache.gaps, hash: .data.cache.ticketHash}
  elif (.data.verdict | type) == "string" then
    (.data.verdict | try fromjson catch null) as $v
    | if ($v | type) == "object" then {gaps: $v.gaps, hash: $v.ticketHash} else null end
  else null end;
def record_reasons($t):
  latest("spec-lint"; $t.id) as $s | latest("coldstart"; $t.id) as $c | latest("merge-forecast"; $t.id) as $m
  | [ (if $s == null then "spec-lint: no record"
       elif $s.data.verified == true then empty
       else "spec-lint: the latest record is not a verified pass" end),
      (if $c == null then "coldstart: no record"
       else ($c | coldstart_shape) as $cs
       | if $cs == null then "coldstart: the latest record has no readable verdict"
         elif ($cs.gaps | type) != "array" then "coldstart: the latest record has no gap list"
         elif ($cs.gaps | length) > 0 then "coldstart: \($cs.gaps | length) unresolved gap(s)"
         elif $cs.hash != $t.hash then "coldstart: stale (the ticket changed after coldstart ran)"
         else empty end end),
      (if $m == null then "merge-forecast: no record"
       elif $m.data.verified == false or (($m.data.gateFailures // []) | length) > 0 then
         "merge-forecast: the latest record is a failure"
       else empty end) ];

($F.gateFailures // []) as $gf
| ($F.waves // []) as $waves
| ($waves[0] // []) as $w1
| ($F.mergeOrder // []) as $mo
| ([$mo[] | select(IN($w1[]))] + [$w1[] | select(IN($mo[]) | not)]) as $order
| [($F.pairs // [])[] | select(.verdict == "SEQUENCE" or .hardVeto == true) | [.a, .b]] as $seq
| (reduce $order[] as $x ({cert: [], behind: {}};
     [.cert[] as $c | select(any($seq[]; . == [$c, $x] or . == [$x, $c])) | $c] as $bl
     | if ($bl | length) == 0 then .cert += [$x] else .behind[$x] = $bl end)) as $fc
| def forecast_reasons($id):
    if ($gf | length) > 0 then ["merge-forecast: the forecast has gate failures (\($gf | map(tostring) | join("; ")))"]
    elif ($id | IN($fc.cert[])) then []
    elif $fc.behind[$id] != null then ["merge-forecast: sequenced behind \($fc.behind[$id] | join(", ")) in wave 1"]
    else (first(range(0; $waves | length) as $k | select($id | IN($waves[$k][])) | $k) // null) as $k
      | if $k == null then ["merge-forecast: not in the forecast"] else ["merge-forecast: in wave \($k + 1), not wave 1"] end
    end;

[ $I[] | (.body // "") as $b
  | . + {tid: ([$b | lines | .[] | (capture("^Ticket:[ \t]*(?<id>[^ \t]+)[ \t]*$") | .id)?] | first),
         labels: [.labels[].name], marked: ($b | contains($marker))} ] as $issues
| [$issues[] | select(.author.login | IN($authors[]))] as $mine
| def desk_hold($cur; $t):
    if $cur == null or $cur.state != "OPEN" or ($cur.labels | index("needs-desk")) == null then null
    else ([$D[] | select(.number == $cur.number)][0].comments // null) as $cm
      | if ($cm | type) != "array" or ($cm | length) >= $desk_cap then null
        else [$cm[] | desk_event] | last
          | if . != null and .kind == "desk" and .ticket == $t.id and .hash == $t.hash
            then {node, reason} else null end
        end
    end;
[$issues[] | select(.marked and (.author.login | IN($authors[]) | not) and .author.is_bot == true)] as $impostors
| ($T | map(.id)) as $ids

| ( $T[] as $t
    | ([$mine[] | select(.tid == $t.id)] | sort_by(.number)) as $own
    | ($own[0] // null) as $cur
    | [$impostors[] | select(.tid == $t.id)] as $imp
    | ( if $t.completed then
          if $cur != null and $cur.state == "OPEN" then
            {action: "close", ticket: $t.id, issue: $cur.number, add: [], remove: [$cur.labels[] | select(. == "ready")]}
          else empty end
        elif $cur == null and ($imp | length) > 0 then empty
        else
          ($t | header) as $h
          | (header_reasons($h) + record_reasons($t) + forecast_reasons($t.id)) as $store
          | desk_hold($cur; $t) as $hold
          | ($store + if $hold == null then []
                      else ["node: `\($hold.node)` stopped it (\($hold.reason)); needs-desk holds until the ticket changes or a new claim"]
                      end) as $reasons
          | (if $reasons == [] then "ready" else "needs-desk" end) as $gate
          | ([if ($h.weight | weight_ok) then "w:\($h.weight)" else empty end]
             + [if ($h.tier | tier_ok) then "tier:\($h.tier)" else empty end] + [$gate]) as $want
          | ([$T[] | select(any(.edges[]?; .to == $t.id)) | .id] | unique) as $deps
          | ($t.title | norm | sub("^\\s+"; "") | if . == "" then "Ticket \($t.id)" else . end) as $title
          | ([$marker, "Ticket: \($t.id)"] + ($deps | map("Depends-on: \(.)")) + ["Ticket-Hash: \($t.hash)"]
             + ["", "Gate: \($gate)"] + ($reasons | map("- " + .)) + ["", "---", "", ($t.body | norm)]
             | join("\n") | norm) as $body
          | {ticket: $t.id, gate: $gate, reasons: $reasons, desk_hold: $hold, title: $title, body: $body}
          + if $cur == null then {action: "create", issue: null, add: $want, remove: []}
            else ($want - $cur.labels) as $add | ([$cur.labels[] | select(owned)] - $want) as $rm
              | ($cur.title != $title) as $tc | (($cur.body // "" | norm) != $body) as $bc
              | {issue: $cur.number, add: $add, remove: $rm, title_changed: $tc, body_changed: $bc,
                 action: (if $cur.state != "OPEN" then "reopen"
                          elif $tc or $bc or ($add | length) > 0 or ($rm | length) > 0 then "update"
                          else "unchanged" end)}
            end
        end ),
      ( $own[1:][] | {action: "conflict", ticket: $t.id, issue: .number,
                      reason: "a second mirror Issue for this ticket; #\($cur.number) is kept"} ),
      ( $imp[] | {action: "conflict", ticket: $t.id, issue: .number,
                  reason: ("carries the mirror marker but its author \u0027\(.author.login)\u0027 is not in MIRROR_AUTHORS"
                           + if $cur == null then "; no Issue is created for this ticket" else "" end)} ) ),
  ( $mine[] | select(.tid == null or (.tid | IN($ids[]) | not))
    | {action: "orphan", ticket: .tid, issue: .number, reason: "a mirror Issue whose ticket is not in the store; left as is"} )
'
plan="$(jq -c -n --slurpfile T "$WORK/tickets.jsonl" --slurpfile GM "$WORK/gm.json" --slurpfile FF "$WORK/forecast.json" \
  --slurpfile II "$WORK/issues.json" --slurpfile DD "$WORK/desk.json" --arg marker "$MARKER" --argjson authors "$AUTHORS" \
  --arg desk_re "$DESK_MARKER_RE" --arg claim_re "$DESK_CLAIM_RE" --argjson desk_trusted "$DESK_TRUSTED" \
  --argjson desk_cap "$DESK_COMMENT_CAP" \
  "$DESK_JQ"'$T as $T | $GM[0].entries as $E | $FF[0] as $F | $II[0] as $I | $DD[0] as $D | '"$PLAN_JQ")" || die "could not compute the plan"

# ------------------------------------------------------------------------------------- write
emit() {  # emit <plan-object> <result> [detail]
  jq -c --arg mode "$MODE" --arg r "$2" --arg d "${3:-}" \
    '{mode: $mode, action: .action} + (del(.title, .body)) + {result: $r} + (if $d == "" then {} else {detail: $d} end)' <<<"$1"
}
ERR="$WORK/gh.err"
gh_try() { "$@" 2>"$ERR" >"$WORK/gh.out"; }
gh_detail() { tail -n1 "$ERR"; }

label_color() {
  case "$1" in
    ready) echo 0e8a16 ;; needs-desk) echo d93f0b ;; w:*) echo 1d76db ;; *) echo 5319e7 ;;
  esac
}
missing_labels="$(jq -r -n --argjson have "$(jq -c 'map(.name)' "$WORK/labels.json")" \
  '[inputs | (.add // [])[]] | unique - $have | .[]' <<<"$plan")"
while IFS= read -r l; do
  [ -n "$l" ] || continue
  line="$(jq -cn --arg l "$l" '{action: "label-create", label: $l}')"
  if [ "$apply" = 0 ]; then emit "$line" planned; continue; fi
  if gh_try gh label create "$l" --repo "$REPO" --color "$(label_color "$l")" --description "set by the factory mirror"; then
    emit "$line" "done"
  else
    FAILED=1; emit "$line" failed "$(gh_detail)"
  fi
done <<<"$missing_labels"

csv() { jq -r "$1 | join(\",\")" <<<"$2"; }
while IFS= read -r p; do
  [ -n "$p" ] || continue
  action="$(jq -r .action <<<"$p")"
  case "$action" in
    unchanged) emit "$p" unchanged; continue ;;
    conflict) FAILED=1; emit "$p" conflict; continue ;;
    orphan) emit "$p" kept; continue ;;
  esac
  if [ "$apply" = 0 ]; then emit "$p" planned; continue; fi
  n="$(jq -r '.issue // empty' <<<"$p")"
  jq -j '.body // ""' <<<"$p" >"$WORK/body.md"
  add="$(csv .add "$p")"; rm_l="$(csv .remove "$p")"
  case "$action" in
    create)
      largs=()
      while IFS= read -r l; do [ -z "$l" ] || largs+=(--label "$l"); done < <(jq -r '.add[]' <<<"$p")
      if gh_try gh issue create --repo "$REPO" --title "$(jq -r .title <<<"$p")" --body-file "$WORK/body.md" "${largs[@]}"; then
        url="$(tail -n1 "$WORK/gh.out")"; n="${url##*/}"
        if valid_issue "$n"; then emit "$(jq -c --argjson n "$n" '.issue = $n' <<<"$p")" "done"
        else FAILED=1; emit "$p" failed "gh issue create printed no Issue URL: $url"; fi
      else
        FAILED=1; emit "$p" failed "$(gh_detail)"
      fi ;;
    update|reopen)
      if [ "$action" = reopen ] && ! gh_try gh issue reopen "$n" --repo "$REPO"; then
        FAILED=1; emit "$p" failed "$(gh_detail)"; continue
      fi
      eargs=()
      [ "$(jq -r '.title_changed' <<<"$p")" != true ] || eargs+=(--title "$(jq -r .title <<<"$p")")
      [ "$(jq -r '.body_changed' <<<"$p")" != true ] || eargs+=(--body-file "$WORK/body.md")
      [ -z "$add" ] || eargs+=(--add-label "$add")
      [ -z "$rm_l" ] || eargs+=(--remove-label "$rm_l")
      if [ "${#eargs[@]}" = 0 ] || gh_try gh issue edit "$n" --repo "$REPO" "${eargs[@]}"; then
        emit "$p" "done"
      else
        FAILED=1; emit "$p" failed "$(gh_detail)"
      fi ;;
    close)
      if { [ -z "$rm_l" ] || gh_try gh issue edit "$n" --repo "$REPO" --remove-label "$rm_l"; } &&
         gh_try gh issue close "$n" --repo "$REPO" --reason completed \
           --comment "Ticket $(jq -r .ticket <<<"$p") is complete in the ADLC store; the mirror closed this Issue."; then
        emit "$p" "done"
      else
        FAILED=1; emit "$p" failed "$(gh_detail)"
      fi ;;
    *) die "internal: unknown plan action '$action'" ;;
  esac
done <<<"$plan"

exit "$FAILED"
