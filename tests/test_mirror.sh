#!/usr/bin/env bash
# T4 acceptance 1-2: factory/bin/mirror.sh turns the ADLC ticket store into one Issue per ticket
# (labels w:<weight>, tier:<n>, ready only when the gate record is clean, else needs-desk; body
# with the ticket id and Depends-on: lines) through the fake gh, which records every call. The
# store, gate manifest and forecast come from the fake adlc. Offline, no keys.
# T14 acceptance 1-3 (case node-needs-desk): a node's needs-desk, with the run loop's marker, is kept
# until the ticket's store state changes; one without the marker is recomputed as before.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
# shellcheck source=factory/bin/lib/desk-marker.sh
. "$REPO_ROOT/factory/bin/lib/desk-marker.sh"

HDR=$'weight: light\ntier: 1\ncharter: C1'
WRITES='(.[0] == "issue" and (.[1] | IN("create", "edit", "close", "reopen", "comment"))) or (.[0] == "label" and .[1] == "create")'

# mir_setup: a fresh world; $WORLD/repo is a checkout of main holding .adlc/manifest.jsonl; the
# store is $FAKE_ADLC_STORE (empty); gh answers as the Actions bot, which the mirror trusts by
# default; the forecast is the fake's (every open ticket in wave 1) unless a case sets one.
mir_setup() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q -b main "$WORLD/repo"
  mkdir -p "$WORLD/repo/.adlc"
  : >"$WORLD/repo/.adlc/manifest.jsonl"
  echo '[]' >"$WORLD/store.json"
  export FACTORY_ADLC="$FAKES_DIR/adlc" FAKE_ADLC_STORE="$WORLD/store.json"
  export FAKE_GH_USER=app/github-actions FAKE_GH_BOT=1 RUNNER_ENVIRONMENT=github-hosted
}
ticket() {  # ticket <id> <title> <body> [edge-targets,csv] [completed]
  local tmp; tmp="$(mktemp)"
  jq --arg id "$1" --arg t "$2" --arg b "$3" --arg e "${4:-}" --argjson c "${5:-false}" \
    '. + [{id: $id, title: $t, body: $b, edges: ($e | split(",") | map(select(. != "")) | map({to: .})), completed: $c}]' \
    "$WORLD/store.json" >"$tmp"
  mv "$tmp" "$WORLD/store.json"
}
set_ticket() {  # set_ticket <id> <jq update>
  local tmp; tmp="$(mktemp)"
  jq --arg id "$1" "map(if .id == \$id then $2 else . end)" "$WORLD/store.json" >"$tmp"
  mv "$tmp" "$WORLD/store.json"
}
record() { printf '%s\n' "$1" >>"$WORLD/repo/.adlc/manifest.jsonl"; }
gated() {  # gated <id> [ticketHash]: clean spec-lint, coldstart and merge-forecast records
  record "{\"gate\":\"spec-lint\",\"ticket\":\"$1\",\"data\":{\"verified\":true}}"
  record "{\"gate\":\"coldstart\",\"ticket\":\"$1\",\"data\":{\"tier\":\"cheap\",\"cache\":{\"ticketHash\":\"${2:-hash-$1}\",\"model\":\"m\",\"gaps\":[]}}}"
  record "{\"gate\":\"merge-forecast\",\"ticket\":\"$1\",\"data\":{\"certifiedWidth\":2}}"
}
mir() {  # mir <args>: run the mirror in the checkout; sets RC, OUT (JSON lines), ERR
  RC=0
  OUT="$(cd "$WORLD/repo" && "$BIN/mirror.sh" "$@" 2>"$WORLD/err")" || RC=$?
  # shellcheck disable=SC2034  # ERR is read inside the eval strings passed to check
  ERR="$(command cat "$WORLD/err")"
}
lines() { if [ -z "$OUT" ]; then echo 0; else jq -c "select($1)" <<<"$OUT" | wc -l | tr -d ' '; fi; }
iss() {  # iss <ticket-id> <jq>: the jq of the one Issue whose body has the line `Ticket: <id>`
  jq -c --arg l "Ticket: $1" "[.issues[] | select(.body | split(\"\n\") | index(\$l) != null)] | if length == 1 then .[0] | $2 else error(\"\(length) Issues for \(\$l)\") end" "$FAKE_GH_ISSUES"
}
labels() { iss "$1" '[.labels[].name] | sort'; }
body() { iss "$1" .body | jq -r .; }   # the raw body text (iss prints JSON)
writes() { fakegh_calls "$WRITES"; }
has() { [[ "$1" == *"$2"* ]] || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }
lacks() { [[ "$1" != *"$2"* ]] || { printf '      [%s] has [%s]\n' "$1" "$2"; return 1; }; }

# ---------------------------------------------------------------------------------------------
case_creates() {
  mir_setup
  ticket T1 "Claim protocol" "$HDR"$'\n\nBuild claim.sh.'
  ticket T2 "Kill switch" $'weight: heavy\ntier: 0\ncharter: C2\n\nBuild halt-check.sh.'
  ticket T9 "Done already" "$HDR" "" true
  gated T1; gated T2
  local tmp; tmp="$(mktemp)"   # a repo with none of the mirror's labels yet
  jq '.labels = ["in-progress"]' "$FAKE_GH_ISSUES" >"$tmp" && mv "$tmp" "$FAKE_GH_ISSUES"
  mir --apply
  check "exit 0" eq "$RC" 0
  check "one Issue per open ticket, none for the completed one" eq "$(jq '.issues | length' "$FAKE_GH_ISSUES")" 2
  check "T1: title from the store" eq "$(iss T1 .title)" '"Claim protocol"'
  check "T1: labels w:light tier:1 ready" eq "$(labels T1)" '["ready","tier:1","w:light"]'
  check "T2: labels w:heavy tier:0 ready" eq "$(labels T2)" '["ready","tier:0","w:heavy"]'
  check "T1: body carries the ticket id line" has "$(body T1)" $'\nTicket: T1\n'
  check "T1: body carries the store's ticketHash (run.sh copies it into its needs-desk marker)" \
    has "$(body T1)" $'\nTicket: T1\nTicket-Hash: hash-T1\n\nGate: ready'
  check "T1: body carries the ticket body" has "$(body T1)" "Build claim.sh."
  check "created by gh issue create, two calls, labels passed at creation" \
    eq "$(fakegh_calls '.[0] == "issue" and .[1] == "create" and (index("--label") != null)')" 2
  check "the missing labels were created first" \
    eq "$(jq -c '[.labels[] | select(. != "in-progress")] | sort' "$FAKE_GH_ISSUES")" '["ready","tier:0","tier:1","w:heavy","w:light"]'
  check "label-create lines for exactly those" eq "$(lines '.action == "label-create" and .result == "done"')" 5
  check "create lines carry the new Issue numbers" \
    eq "$(jq -sc '[.[] | select(.action == "create") | [.ticket, .issue, .result]]' <<<"$OUT")" '[["T1",1,"done"],["T2",2,"done"]]'
  check "the completed ticket gets no line and no Issue" eq "$(lines '.ticket == "T9"')" 0
  check "every Issue is authored by the Actions bot" eq "$(jq -c '[.issues[].author.login] | unique' "$FAKE_GH_ISSUES")" '["app/github-actions"]'
}

case_updates_idempotent() {
  mir_setup
  ticket T1 "Claim protocol" "$HDR"$'\n\nBuild claim.sh.'
  ticket T2 "Kill switch" "$HDR"$'\n\nBuild halt.'
  gated T1; gated T2
  mir --apply
  check "first run exit 0" eq "$RC" 0
  local before; before="$(writes)"
  mir --apply
  check "second run exit 0" eq "$RC" 0
  check "second run: no write call at all" eq "$(writes)" "$before"
  check "second run: every ticket unchanged" eq "$(lines '.action == "unchanged" and .result == "unchanged"')" 2
  local n1; n1="$(iss T1 .number)"
  # A claim adds in-progress (claim.sh owns it); a human rewrites T2's body (marker gone, Ticket
  # line kept); the desk edits T1.
  gh issue edit "$n1" --repo test/repo --add-label in-progress >/dev/null
  gh issue edit "$(iss T2 .number)" --repo test/repo --body $'Ticket: T2\n\nhand-edited' >/dev/null
  set_ticket T1 '.title = "Claim protocol v2" | .body = "weight: heavy\ntier: 1\ncharter: C1\n\nBuild claim.sh and heartbeat.sh."'
  : >"$FAKE_GH_LOG"
  mir --apply
  check "third run exit 0" eq "$RC" 0
  check "the same Issue is updated, not a new one" eq "$(jq '.issues | length' "$FAKE_GH_ISSUES")" 2
  check "T1 title updated" eq "$(iss T1 .title)" '"Claim protocol v2"'
  check "T1 body updated" has "$(body T1)" "heartbeat.sh"
  check "w:light swapped for w:heavy, in-progress kept" eq "$(labels T1)" '["in-progress","ready","tier:1","w:heavy"]'
  check "T1 line names exactly the diff" \
    eq "$(jq -sc '.[] | select(.ticket == "T1") | [.action, .add, .remove, .title_changed, .body_changed]' <<<"$OUT")" \
       '["update",["w:heavy"],["w:light"],true,true]'
  check "T2: the hand edit is overwritten from the store" eval 'has "$(body T2)" "Build halt." && lacks "$(body T2)" "hand-edited"'
  check "T2: the marker is back" has "$(body T2)" "<!-- factory-mirror:"
  check "T2: body only (labels untouched)" \
    eq "$(jq -sc '.[] | select(.ticket == "T2") | [.action, .add, .remove, .title_changed, .body_changed]' <<<"$OUT")" \
       '["update",[],[],false,true]'
  check "two gh issue edit calls, no create" eq "$(fakegh_calls '.[0] == "issue" and (.[1] | IN("edit", "create"))')" 2
  before="$(writes)"
  mir --apply
  check "fourth run: nothing left to write" eq "$(writes)" "$before"
  # A web-UI save stores CRLF line ends and a trailing newline; the text is the same, so no write.
  local tmp; tmp="$(mktemp)"
  jq --argjson n "$n1" '(.issues[] | select(.number == $n)).body |= (gsub("\n"; "\r\n") + "\r\n")' "$FAKE_GH_ISSUES" >"$tmp" && mv "$tmp" "$FAKE_GH_ISSUES"
  mir --apply
  check "a CRLF copy of the same body: unchanged, no write" eval '[ "$(writes)" = "$before" ] && [ "$(lines '"'"'.ticket == "T1" and .action == "unchanged"'"'"')" = 1 ]'
  # A body wiped of its Ticket line can no longer be matched: a fresh Issue, the old one an orphan.
  local n2; n2="$(iss T2 .number)"
  gh issue edit "$n2" --repo test/repo --body "wiped" >/dev/null
  mir --apply
  check "wiped Ticket line: exit 0" eq "$RC" 0
  check "wiped Ticket line: T2 gets a new Issue" eval '[ "$(iss T2 .number)" != "$n2" ]'
  check "wiped Ticket line: the old Issue is reported as an orphan and kept" \
    eq "$(jq -sc '[.[] | select(.action == "orphan") | [.issue, .result]]' <<<"$OUT")" "[[$n2,\"kept\"]]"
}

case_ready_only_when_gated() {
  mir_setup
  ticket T1 "all clean" "$HDR"
  ticket T2 "no spec-lint" "$HDR"
  ticket T3 "coldstart gaps" "$HDR"
  ticket T4 "coldstart stale" "$HDR"
  ticket T5 "no merge-forecast record" "$HDR"
  ticket T6 "bad header" $'weight: medium\ntier: 7\n\nno charter'
  ticket T7 "spec-lint failed later" "$HDR"
  ticket T8 "prompt-only coldstart, clean" "$HDR"
  ticket T9 "sequenced behind T1" "$HDR"
  ticket T10 "wave 2" "$HDR"
  ticket T11 "merge-forecast record is a failure" "$HDR"
  gated T1
  record '{"gate":"coldstart","ticket":"T2","data":{"cache":{"ticketHash":"hash-T2","gaps":[]}}}'
  record '{"gate":"merge-forecast","ticket":"T2","data":{}}'
  gated T3; record '{"gate":"coldstart","ticket":"T3","data":{"cache":{"ticketHash":"hash-T3","gaps":[{"kind":"missing-file"}]}}}'
  gated T4 hash-T4-old
  record '{"gate":"spec-lint","ticket":"T5","data":{"verified":true}}'
  record '{"gate":"coldstart","ticket":"T5","data":{"cache":{"ticketHash":"hash-T5","gaps":[]}}}'
  gated T6
  gated T7; record '{"gate":"spec-lint","ticket":"T7","data":{"verified":false}}'
  record '{"gate":"spec-lint","ticket":"T8","data":{"verified":true}}'
  record '{"gate":"coldstart","ticket":"T8","data":{"verdict":"{\"gaps\":[],\"ticketHash\":\"hash-T8\"}"}}'
  record '{"gate":"merge-forecast","ticket":"T8","data":{}}'
  gated T9; gated T10
  gated T11; record '{"gate":"merge-forecast","ticket":"T11","data":{"verified":false}}'
  record '{"gate":"spec-lint","ticket":"T1-other","data":{"verified":false}}'
  export FAKE_ADLC_FORECAST='{"waves":[["T1","T2","T3","T4","T5","T6","T7","T8","T9","T11"],["T10"]],
    "mergeOrder":["T1","T2","T3","T4","T5","T6","T7","T8","T9","T11","T10"],
    "pairs":[{"a":"T1","b":"T9","verdict":"SEQUENCE","hardVeto":true},{"a":"T2","b":"T3","verdict":"PARALLEL","hardVeto":false}],
    "gateFailures":[],"certifiedWidth":8}'
  mir --apply
  check "exit 0" eq "$RC" 0
  local t want
  for t in T1 T8; do check "$t ready" eq "$(labels "$t")" '["ready","tier:1","w:light"]'; done
  for t in T2 T3 T4 T5 T7 T9 T10 T11; do check "$t needs-desk" eq "$(labels "$t")" '["needs-desk","tier:1","w:light"]'; done
  check "T6: needs-desk and no w:/tier: label from an invalid header" eq "$(labels T6)" '["needs-desk"]'
  reasons() { jq -sc --arg t "$1" '.[] | select(.ticket == $t) | .reasons' <<<"$OUT"; }
  check "T2 reason" eq "$(reasons T2)" '["spec-lint: no record"]'
  check "T3 reason" eq "$(reasons T3)" '["coldstart: 1 unresolved gap(s)"]'
  check "T4 reason" eq "$(reasons T4)" '["coldstart: stale (the ticket changed after coldstart ran)"]'
  check "T5 reason" eq "$(reasons T5)" '["merge-forecast: no record"]'
  check "T6 reasons" eq "$(reasons T6)" \
    '["header: weight '"'"'medium'"'"' is not light|heavy","header: tier '"'"'7'"'"' is not 0|1|2","header: charter missing"]'
  check "T7: the latest spec-lint record counts" eq "$(reasons T7)" '["spec-lint: the latest record is not a verified pass"]'
  check "T9 reason" eq "$(reasons T9)" '["merge-forecast: sequenced behind T1 in wave 1"]'
  check "T10 reason" eq "$(reasons T10)" '["merge-forecast: in wave 2, not wave 1"]'
  check "T11: the latest merge-forecast record counts" eq "$(reasons T11)" '["merge-forecast: the latest record is a failure"]'
  check "the Issue body shows the verdict and reasons" has "$(body T3)" $'Gate: needs-desk\n- coldstart: 1 unresolved gap(s)'
  # The gate turns: T2 gets its spec-lint pass, T1 regresses. Labels swap; in-progress stays.
  gh issue edit "$(iss T1 .number)" --repo test/repo --add-label in-progress >/dev/null
  record '{"gate":"spec-lint","ticket":"T2","data":{"verified":true}}'
  record '{"gate":"coldstart","ticket":"T1","data":{"cache":{"ticketHash":"hash-T1","gaps":[{"kind":"x"},{"kind":"y"}]}}}'
  mir --apply
  check "T2 becomes ready" eq "$(labels T2)" '["ready","tier:1","w:light"]'
  check "T1 drops ready for needs-desk, keeps in-progress" eq "$(labels T1)" '["in-progress","needs-desk","tier:1","w:light"]'
  # Forecast gate failures hold every ticket.
  export FAKE_ADLC_FORECAST='{"waves":[["T1","T2","T8"]],"mergeOrder":["T1","T2","T8"],"pairs":[],"gateFailures":["vetoed pair T2-T8 concurrent"]}'
  FAKE_ADLC_FORECAST_EXIT=2 mir --apply
  check "a forecast with gate failures (exit 2) still runs" eq "$RC" 0
  check "and readies nothing" eq "$(lines '.gate == "ready"')" 0
  want='merge-forecast: the forecast has gate failures (vetoed pair T2-T8 concurrent)'
  check "T8 names the forecast failure" eq "$(reasons T8)" "[\"$want\"]"
}

case_depends_on_lines() {
  mir_setup
  ticket T1 "claim" "$HDR" "T3,T4,T2"
  ticket T2 "kill switch" "$HDR" "T4,T3"
  ticket T3 "janitor" "$HDR" "T4"
  ticket T4 "mirror" "$HDR"
  ticket T5 "adr" "$HDR"
  mir --apply
  check "exit 0" eq "$RC" 0
  dep() { iss "$1" '[.body | split("\n")[] | select(startswith("Depends-on:"))]'; }
  check "T4 depends on T1, T2, T3 (edges point prerequisite → dependent)" eq "$(dep T4)" '["Depends-on: T1","Depends-on: T2","Depends-on: T3"]'
  check "T3 depends on T1, T2" eq "$(dep T3)" '["Depends-on: T1","Depends-on: T2"]'
  check "T2 depends on T1" eq "$(dep T2)" '["Depends-on: T1"]'
  check "T1 and T5 depend on nothing" eq "$(dep T1)$(dep T5)" '[][]'
  check "Depends-on lines sit right under the Ticket line" \
    eq "$(iss T3 '.body | split("\n")[1:4]')" '["Ticket: T3","Depends-on: T1","Depends-on: T2"]'
  # The janitor and summon.sh read the ticket id with this exact expression (factory/bin/janitor.sh).
  check "the janitor's Ticket-line parser reads every Issue's id" \
    eq "$(jq -c '[.issues[] | [(.body // "") | splits("\r?\n") | capture("^ticket:[ \t]*(?<id>[A-Za-z0-9._-]+)[ \t]*$"; "i") | .id] | first] | sort' "$FAKE_GH_ISSUES")" \
       '["T1","T2","T3","T4","T5"]'
  # A new edge changes the body of the dependant only.
  set_ticket T5 '.edges = [{to: "T1"}]'
  mir --apply
  check "T1 now depends on T5" eq "$(dep T1)" '["Depends-on: T5"]'
  check "only T1 changed" eq "$(jq -sc '[.[] | select(.action != "unchanged") | .ticket]' <<<"$OUT")" '["T1"]'
}

case_dry_run_inert() {
  mir_setup
  ticket T1 "one" "$HDR"; ticket T2 "two" "$HDR" "" true; gated T1
  fakegh_issue 5 1761300000 "ready" "stale" "$(printf '%s\nTicket: T1\n' '<!-- factory-mirror: generated from the ADLC ticket store by factory/bin/mirror.sh; edits here are overwritten -->')" app/github-actions true
  fakegh_issue 6 1761300000 "ready" "two" "$(printf '%s\nTicket: T2\n' '<!-- factory-mirror: generated from the ADLC ticket store by factory/bin/mirror.sh; edits here are overwritten -->')" app/github-actions true
  local tmp; tmp="$(mktemp)"; jq '.labels -= ["w:light"]' "$FAKE_GH_ISSUES" >"$tmp" && mv "$tmp" "$FAKE_GH_ISSUES"
  local before; before="$(sha256sum <"$FAKE_GH_ISSUES")"
  mir
  check "no flag: exit 0" eq "$RC" 0
  check "no flag: the store is byte-identical" eq "$(sha256sum <"$FAKE_GH_ISSUES")" "$before"
  check "no flag: zero write calls" eq "$(writes)" 0
  check "the plan names a label create, an update and a close, all planned" \
    eq "$(jq -sc '[.[] | [.action, .result]]' <<<"$OUT")" '[["label-create","planned"],["update","planned"],["close","planned"]]'
  mir --dry-run
  check "--dry-run: exit 0, still nothing written" eval '[ "$RC" = 0 ] && [ "$(writes)" = 0 ] && [ "$(sha256sum <"$FAKE_GH_ISSUES")" = "$before" ]'
  mir --apply
  check "--apply takes exactly the planned actions" \
    eq "$(jq -sc '[.[] | [.action, .result]]' <<<"$OUT")" '[["label-create","done"],["update","done"],["close","done"]]'
}

case_closes_completed() {
  mir_setup
  ticket T1 "one" "$HDR"; ticket T2 "two" "$HDR"; gated T1; gated T2
  mir --apply
  local n1 n2; n1="$(iss T1 .number)"; n2="$(iss T2 .number)"
  gh issue edit "$n1" --repo test/repo --add-label in-progress >/dev/null
  set_ticket T1 '.completed = true'
  gh issue close "$n2" --repo test/repo >/dev/null 2>&1    # a human closes an open ticket's Issue
  mir --apply
  check "exit 0" eq "$RC" 0
  check "the completed ticket's Issue is closed as completed" eq "$(iss T1 '[.state, .stateReason]')" '["closed","completed"]'
  check "with a comment naming the ticket" eval 'has "$(iss T1 ".comments[-1].body")" "Ticket T1 is complete"'
  check "ready removed on close; other labels kept" eq "$(labels T1)" '["in-progress","tier:1","w:light"]'
  check "the open ticket's closed Issue is reopened" eq "$(iss T2 .state)" '"open"'
  check "lines: close T1, reopen T2" eq "$(jq -sc '[.[] | [.action, .ticket, .result]]' <<<"$OUT")" '[["close","T1","done"],["reopen","T2","done"]]'
  local before; before="$(writes)"
  mir --apply
  check "a closed completed Issue is left alone" eq "$(writes)" "$before"
  check "and gets no line" eq "$(lines '.ticket == "T1"')" 0
}

# The mirror run of 2026-10-25 18:50Z: every ticket completed, `adlc merge-forecast` exits 1 ("no
# active tickets found"). The mirror uses the empty forecast instead, closes the last Issue, exits 0.
case_all_completed() {
  mir_setup
  ticket T1 "one" "$HDR"; gated T1
  mir --apply
  set_ticket T1 '.completed = true'
  check "the fixture: the fake's merge-forecast exits 1 with no open ticket" \
    eval '! (cd "$WORLD/repo" && "$FAKES_DIR/adlc" merge-forecast --json >/dev/null 2>&1)'
  : >"$FAKE_ADLC_LOG"
  mir --apply
  check "exit 0" eq "$RC" 0
  check "the last Issue is closed as completed" eq "$(iss T1 '[.state, .stateReason]')" '["closed","completed"]'
  check "merge-forecast was not called" eq "$(jq -sc '[.[] | select(.[0] == "merge-forecast")] | length' "$FAKE_ADLC_LOG")" 0
}

case_stranger_issues() {
  mir_setup
  ticket T1 "one" "$HDR"; ticket T2 "two" "$HDR"; gated T1; gated T2
  local mk='<!-- factory-mirror: generated from the ADLC ticket store by factory/bin/mirror.sh; edits here are overwritten -->'
  fakegh_issue 3 1761300000 "" "mine now" "$(printf '%s\nTicket: T1\n' "$mk")" mallory false   # a human copies the marker
  fakegh_issue 4 1761300000 "" "bot copy" "$(printf '%s\nTicket: T2\n' "$mk")" app/other-bot true # a bot not trusted
  fakegh_issue 7 1761300000 "ready" "orphan" "$(printf '%s\nTicket: T77\n' "$mk")" app/github-actions true
  mir --apply
  check "exit 1 (a conflict is reported)" eq "$RC" 1
  check "the human's Issue is not adopted: untouched, no labels" eq "$(jq -c '.issues[] | select(.number == 3) | [.title, .labels]' "$FAKE_GH_ISSUES")" '["mine now",[]]'
  check "T1 gets its own Issue from the mirror" \
    eq "$(jq -c '[.issues[] | select(.author.login == "app/github-actions" and (.body | contains("\nTicket: T1"))) | .number]' "$FAKE_GH_ISSUES")" '[8]'
  check "T2: an untrusted bot carrying the marker is a conflict and nothing is created" \
    eq "$(jq -sc '[.[] | select(.ticket == "T2") | [.action, .issue, .result]]' <<<"$OUT")" '[["conflict",4,"conflict"]]'
  check "T2 has no mirror Issue" eq "$(jq '[.issues[] | select(.body | contains("\nTicket: T2"))] | length' "$FAKE_GH_ISSUES")" 1
  check "the untrusted bot's Issue is untouched" eq "$(jq -c '.issues[] | select(.number == 4) | .labels' "$FAKE_GH_ISSUES")" '[]'
  check "an Issue for a ticket the store lacks is reported and kept" \
    eq "$(jq -sc '[.[] | select(.action == "orphan") | [.issue, .result]]' <<<"$OUT")" '[[7,"kept"]]'
  check "the orphan keeps its labels" eq "$(jq -c '.issues[] | select(.number == 7) | [.labels[].name]' "$FAKE_GH_ISSUES")" '["ready"]'
  MIRROR_AUTHORS=app/github-actions,app/other-bot mir --apply
  check "trusting that bot adopts its Issue for T2: exit 0" eq "$RC" 0
  check "T2's Issue #4 gets the labels" eq "$(jq -c '.issues[] | select(.number == 4) | [.labels[].name] | sort' "$FAKE_GH_ISSUES")" '["ready","tier:1","w:light"]'
  # Two mirror Issues for one ticket: the lower number is kept and edited, the other reported.
  fakegh_issue 20 1761400000 "" "dup" "$(printf '%s\nTicket: T1\n' "$mk")" app/github-actions true
  mir --apply
  check "a duplicate is a conflict: exit 1" eq "$RC" 1
  check "the duplicate is reported, the lower number kept" \
    eq "$(jq -sc '[.[] | select(.ticket == "T1") | [.action, .issue]]' <<<"$OUT")" '[["unchanged",8],["conflict",20]]'
  check "the duplicate is not edited" eq "$(jq -c '.issues[] | select(.number == 20) | .labels' "$FAKE_GH_ISSUES")" '[]'
}

# say <ticket> <authorAssociation> <body>: a comment on the ticket's Issue, as GitHub lists it.
say() {
  local tmp; tmp="$(mktemp)"
  jq --argjson n "$(iss "$1" .number)" --arg a "$2" --arg b "$3" \
    '(.issues[] | select(.number == $n)).comments += [{author: {login: "dev-box-owner"}, authorAssociation: $a, body: $b, createdAt: "2026-10-25T12:00:00Z"}]' \
    "$FAKE_GH_ISSUES" >"$tmp" && mv "$tmp" "$FAKE_GH_ISSUES"
}
# node_desk <ticket> [hash] [authorAssociation]: what run.sh does when it stops a ticket: the result
# comment ending in the marker, then needs-desk added and ready removed in one edit.
node_desk() {
  say "$1" "${3:-COLLABORATOR}" "$(printf 'Node `dev-box` stopped `%s`: reason `strikes-exhausted`.\n\n%s' "$1" \
    "$(desk_marker "$1" "${2:-hash-$1}" strikes-exhausted dev-box)")"
  gh issue edit "$(iss "$1" .number)" --repo test/repo --add-label needs-desk --remove-label ready >/dev/null
}
claim_comment() { say "$1" COLLABORATOR "Claimed by node \`dev-box\`: fleet run \`dev-box-s1-1-2\`, 2 slot(s), expected finish x."; }

case_node_needs_desk() {
  mir_setup
  local t
  for t in T1 T2 T3 T4 T5 T6 T7; do ticket "$t" "ticket $t" "$HDR"; gated "$t"; done
  mir --apply
  check "setup: every ticket ready" eq "$(lines '.gate == "ready"')" 7
  local ready='["ready","tier:1","w:light"]' desk='["needs-desk","tier:1","w:light"]'
  node_desk T1                                   # the node's marker at the current hash
  gh issue edit "$(iss T2 .number)" --repo test/repo --add-label needs-desk >/dev/null   # no marker
  node_desk T3 hash-T3 NONE                      # a stranger's comment carrying the marker
  node_desk T4 hash-T4-old                       # the marker names an older ticket state
  node_desk T5; say T5 COLLABORATOR "$(desk_marker T9 hash-T5 flail dev-box)"   # newest marker: another ticket (same hash)
  node_desk T6; gh issue edit "$(iss T6 .number)" --repo test/repo --remove-label needs-desk >/dev/null  # desk took it off
  node_desk T7
  for _ in $(seq 1 99); do say T7 CONTRIBUTOR "chatter"; done     # 100 comments: gh may hide the newest
  mir --apply
  check "run 1: exit 0" eq "$RC" 0
  check "run 1: T1 keeps the node's needs-desk, ready is not put back" eq "$(labels T1)" "$desk"
  check "run 1: T1's line names the hold" eq "$(jq -sc '.[] | select(.ticket == "T1") | [.gate, .desk_hold, .add, .remove]' <<<"$OUT")" \
    '["needs-desk",{"node":"dev-box","reason":"strikes-exhausted"},[],[]]'
  check "run 1: T1's body gives the node's reason" \
    has "$(body T1)" $'Gate: needs-desk\n- node: `dev-box` stopped it (strikes-exhausted); needs-desk holds until the ticket changes or a new claim'
  check "run 1: T2, needs-desk without the marker, is recomputed (ready)" eq "$(labels T2)" "$ready"
  check "run 1: T3, a marker from an author with no repo access, counts for nothing" eq "$(labels T3)" "$ready"
  check "run 1: T4, a marker for an older ticketHash, is stale" eq "$(labels T4)" "$ready"
  check "run 1: T5, the newest marker names another ticket" eq "$(labels T5)" "$ready"
  check "run 1: T6, the label is gone, so nothing is kept (the marker never adds it)" eq "$(labels T6)" "$ready"
  check "run 1: T7, a thread at gh's 100-comment page is not trusted to show the newest" eq "$(labels T7)" "$ready"
  check "run 1: only T1 holds" eq "$(jq -sc '[.[] | select(.desk_hold != null) | .ticket]' <<<"$OUT")" '["T1"]'
  local before; before="$(writes)"
  mir --apply
  check "run 2: T1 still needs-desk" eq "$(labels T1)" "$desk"
  check "run 2: no write at all, every line unchanged" \
    eval '[ "$(writes)" = "$before" ] && [ "$(lines '"'"'.action == "unchanged"'"'"')" = 7 ]'
  mir --apply
  check "run 3: T1 still needs-desk, still nothing written" eval '[ "$(labels T1)" = "$desk" ] && [ "$(writes)" = "$before" ]'
  # A desk edit: a new ticketHash (and a fresh coldstart on it). The hold ends; the store decides.
  set_ticket T1 '.body = "weight: light\ntier: 1\ncharter: C1\n\nclearer acceptance criteria" | .ticketHash = "hash-T1-v2"'
  record '{"gate":"coldstart","ticket":"T1","data":{"cache":{"ticketHash":"hash-T1-v2","gaps":[]}}}'
  mir --apply
  check "after a store edit: T1 is recomputed, ready again" eq "$(labels T1)" "$ready"
  check "  the line holds nothing and swaps the labels" \
    eq "$(jq -sc '.[] | select(.ticket == "T1") | [.gate, .desk_hold, .add, .remove]' <<<"$OUT")" '["ready",null,["ready"],["needs-desk"]]'
  check "  the body carries the new hash" has "$(body T1)" "Ticket-Hash: hash-T1-v2"
  # A node stops it again, at the new hash: held. Then a new claim cycle after the marker ends it.
  node_desk T1 hash-T1-v2
  mir --apply
  check "a second stop at the new hash: held" eq "$(labels T1)" "$desk"
  claim_comment T1
  mir --apply
  check "after a new claim cycle (a claim comment after the marker): recomputed, ready" eq "$(labels T1)" "$ready"
  # A store edit that leaves the ticket not ready: recomputed to needs-desk, with the store's reason.
  node_desk T2
  set_ticket T2 '.ticketHash = "hash-T2-v2"'
  mir --apply
  check "a store edit that leaves coldstart stale: needs-desk for the store's reason only" \
    eq "$(jq -sc '.[] | select(.ticket == "T2") | [.gate, .desk_hold, .reasons]' <<<"$OUT")" \
       '["needs-desk",null,["coldstart: stale (the ticket changed after coldstart ran)"]]'
  # A ticket completed while held: closed as before.
  node_desk T5
  set_ticket T5 '.completed = true'
  mir --apply
  check "a held ticket completed in the store: its Issue closes" eq "$(iss T5 .state)" '"closed"'
  check "one needs-desk read per run, of open needs-desk Issues only" \
    eq "$(fakegh_calls '.[0:2] == ["issue", "list"] and (index("needs-desk") != null) and (index("number,comments") != null) and (index("open") != null)')" \
       "$(jq -sc 'map(select(.[0:2] == ["ticket", "list"])) | length' "$FAKE_ADLC_LOG")"
  node_desk T3
  before="$(writes)"
  FAKE_GH_FAIL='--label needs-desk' mir --apply
  check "the needs-desk read fails: exit 1, nothing written" eval '[ "$RC" = 1 ] && [ "$(writes)" = "$before" ] && has "$ERR" "needs-desk comments"'
}

case_forecast_file() {
  mir_setup
  ticket T1 "one" "$HDR"; ticket T2 "two" "$HDR"; gated T1; gated T2
  printf '%s\n' '{"waves":[["T2"],["T1"]],"mergeOrder":["T2","T1"],"pairs":[],"gateFailures":[]}' >"$WORLD/forecast.json"
  mir --apply --forecast "$WORLD/forecast.json"
  check "exit 0" eq "$RC" 0
  check "the janitor's FILE is used: adlc merge-forecast is not called" \
    eq "$(jq -sc 'map(select(.[0] == "merge-forecast")) | length' "$FAKE_ADLC_LOG")" 0
  check "the FILE decides: T2 ready, T1 waits" eq "$(labels T2)$(labels T1)" '["ready","tier:1","w:light"]["needs-desk","tier:1","w:light"]'
  : >"$FAKE_ADLC_LOG"
  mir --apply
  check "without --forecast the mirror runs adlc merge-forecast --json itself" \
    eq "$(jq -sc 'map(select(.[0] == "merge-forecast")) | .[0]' "$FAKE_ADLC_LOG")" '["merge-forecast","--json"]'
  check "and that forecast (both in wave 1) readies T1" eq "$(labels T1)" '["ready","tier:1","w:light"]'
  mir --apply --forecast "$WORLD/missing.json"
  check "a missing FILE: exit 1" eq "$RC" 1
  printf 'not json\n' >"$WORLD/bad.json"
  mir --apply --forecast "$WORLD/bad.json"
  check "a FILE that is not a forecast: exit 1" eq "$RC" 1
}

case_read_failures_write_nothing() {
  mir_setup
  ticket T1 "one" "$HDR"; gated T1
  local v
  for v in 'ticket list' 'ticket show' 'gate-manifest' 'merge-forecast'; do
    FAKE_ADLC_FAIL="$v" mir --apply
    check "adlc $v fails: exit 1, nothing written" eval '[ "$RC" = 1 ] && [ "$(writes)" = 0 ]'
  done
  FAKE_ADLC_SKIPPED='[{"line":3,"reason":"bad signature"}]' mir --apply
  check "unreadable manifest entries: exit 1, nothing written" eval '[ "$RC" = 1 ] && [ "$(writes)" = 0 ] && has "$ERR" "unreadable"'
  FAKE_GH_FAIL='issue list' mir --apply
  check "gh issue list fails: exit 1, nothing written" eval '[ "$RC" = 1 ] && [ "$(writes)" = 0 ]'
  local i
  for i in $(seq 1 1000); do printf '{"number":%s,"title":"x","body":"","state":"open","createdAt":"2026-01-01T00:00:00Z","labels":[],"assignees":[],"comments":[]}\n' "$i"; done |
    jq -s --slurpfile s "$FAKE_GH_ISSUES" '$s[0] + {issues: .}' >"$WORLD/many.json"
  command cp "$WORLD/many.json" "$FAKE_GH_ISSUES"
  mir --apply
  check "a list at gh's limit may be truncated: exit 1, nothing written" eval '[ "$RC" = 1 ] && [ "$(writes)" = 0 ] && has "$ERR" "truncated"'
  printf '%s\n' '{"labels":[],"issues":[]}' >"$FAKE_GH_ISSUES"
  FAKE_GH_FAIL='issue create' mir --apply
  check "a failed write: exit 1, the line says failed" eval '[ "$RC" = 1 ] && [ "$(lines '"'"'.action == "create" and .result == "failed"'"'"')" = 1 ]'
}

case_refuses_apply() {
  mir_setup
  ticket T1 "one" "$HDR"; gated T1
  RUNNER_ENVIRONMENT=self-hosted mir --apply
  check "--apply on a self-hosted runner: exit 2" eval '[ "$RC" = 2 ] && has "$ERR" "GitHub-hosted"'
  (unset RUNNER_ENVIRONMENT; mir --apply; [ "$RC" = 2 ]) && r=ok || r=bad
  check "--apply with RUNNER_ENVIRONMENT unset: exit 2" eq "$r" ok
  git -C "$WORLD/repo" checkout -q -b ticket/T1/alpha
  mir --apply
  check "--apply off main: exit 2" eval '[ "$RC" = 2 ] && has "$ERR" "checkout of main"'
  check "no gh or adlc call was made by a refused run" eval '[ "$(wc -l <"$FAKE_GH_LOG")" = 0 ] && [ "$(wc -l <"$FAKE_ADLC_LOG")" = 0 ]'
  mir --dry-run
  check "a dry run off main and off hosted still reads and plans" eval '[ "$RC" = 0 ] && [ "$(lines '"'"'.result == "planned"'"'"')" -gt 0 ]'
  mir --bogus
  check "an unknown flag: exit 1" eq "$RC" 1
}

case_workflow() {
  # shellcheck disable=SC2034  # wf is read inside the eval strings passed to check
  local wf="$REPO_ROOT/.github/workflows/mirror.yml"
  check "mirror.yml passes --apply (the script is dry-run by default)" eval 'grep -q "mode=--apply" "$wf" && grep -q "./factory/bin/mirror.sh \"\$mode\"" "$wf"'
  check "mirror.yml keeps the shared concurrency group mirror" eval 'grep -Eq "^  group: mirror$" "$wf"'
  check "mirror.yml checks out main (the store is read from main)" eval 'grep -q "ref: main" "$wf"'
  check "mirror.yml only needs issues: write" eval 'grep -q "issues: write" "$wf" && grep -q "contents: read" "$wf"'
}

case_fake_semantics() {
  mir_setup
  local url
  url="$(gh issue create --repo test/repo --title t1 --body "b1" --label ready --label w:light)"
  check "issue create prints the URL of number max+1" eq "$url" "https://github.com/test/repo/issues/1"
  check "issue create rejects an unknown label" eval '! gh issue create --repo test/repo --title t --body b --label nope 2>/dev/null'
  check "issue create needs a title" eval '! gh issue create --repo test/repo --body b 2>/dev/null'
  check "the author is @me, a bot under FAKE_GH_BOT=1" eq "$(jq -c '.issues[0].author' "$FAKE_GH_ISSUES")" '{"login":"app/github-actions","is_bot":true}'
  fakegh_pr 9 ticket/T1/a
  check "numbers count PRs too" eq "$(gh issue create --repo test/repo --title t2 --body b2)" "https://github.com/test/repo/issues/10"
  gh issue edit 1 --repo test/repo --title t1b --body-file <(printf 'b1b') --remove-label w:light >/dev/null
  check "issue edit sets title, body and labels" eq "$(jq -c '.issues[0] | [.title, .body, [.labels[].name]]' "$FAKE_GH_ISSUES")" '["t1b","b1b",["ready"]]'
  gh issue close 1 --repo test/repo --reason completed --comment bye 2>/dev/null
  check "issue close sets state, reason and the comment" eq "$(jq -c '.issues[0] | [.state, .stateReason, .comments[-1].body]' "$FAKE_GH_ISSUES")" '["closed","completed","bye"]'
  check "issue close rejects a bad reason" eval '! gh issue close 10 --repo test/repo --reason bogus 2>/dev/null'
  gh issue reopen 1 --repo test/repo 2>/dev/null
  check "issue reopen" eq "$(jq -r '.issues[0].state' "$FAKE_GH_ISSUES")" open
  fakegh_issue 30 1761300000 "" "human"
  check "issue list answers authors (a human by default)" \
    eq "$(gh issue list --repo test/repo --state all --json number,author | jq -c 'map(select(.number == 30)) | .[0].author')" '{"login":"someone","is_bot":false}'
  check "label list" eq "$(gh label list --repo test/repo --json name | jq -c 'map(.name) | index("ready") != null')" true
  check "label create on an existing name fails without --force" eval '! gh label create Ready --repo test/repo 2>/dev/null && gh label create ready --repo test/repo --force 2>/dev/null'
  gh label create tier:2 --repo test/repo --color 5319e7 --description d 2>/dev/null
  check "label create adds the label" eq "$(jq -c '.labels | index("tier:2") != null' "$FAKE_GH_ISSUES")" true
  # fake adlc
  ticket T1 "one" "$HDR" "T2"; ticket T2 "two" "$HDR"
  check "adlc ticket list: id, title, ticketHash" eq "$(adlc ticket list --json | jq -c '.[0]')" '{"id":"T1","title":"one"}'
  check "adlc ticket show: the ticket and its hash" eq "$(adlc ticket show T1 --json | jq -c '[.ticket.id, .ticket.edges, .ticketHash]')" '["T1",[{"to":"T2"}],"hash-T1"]'
  check "adlc ticket show: unknown id exits 2, TICKET_NOT_FOUND on stderr, stdout empty" \
    eval '[ "$(adlc ticket show T9 --json 2>&1 >/dev/null | jq -r .code; echo "${PIPESTATUS[0]}")" = $'"'"'TICKET_NOT_FOUND\n2'"'"' ] && [ -z "$(adlc ticket show T9 --json 2>/dev/null)" ]'
  record '{"type":"p5-finding-verified","ticket":"T1","finding":{"id":"F"}}'
  record '{"gate":"spec-lint","ticket":"T2","data":{"verified":true}}'
  check "adlc gate-manifest show --ticket filters, gate = type" \
    eq "$(cd "$WORLD/repo" && adlc gate-manifest show --ticket T1 --json | jq -c '[.entries[] | [.gate, .segment]], .skipped')" $'[["p5-finding-verified","root"]]\n[]'
  check "adlc ticket complete --write without --authorize exits 2" eval '! (cd "$WORLD/repo" && adlc ticket complete T1 --write >/dev/null 2>&1)'
  (cd "$WORLD/repo" && adlc ticket complete T1 --json >/dev/null)
  check "adlc ticket complete without --write changes nothing" eq "$(jq -c '.[0].completed' "$WORLD/store.json")" false
  check "adlc ticket complete --write --authorize: applied" \
    eq "$(cd "$WORLD/repo" && adlc ticket complete T1 --write --authorize --json | jq -sc 'last.applied')" true
  check "the store says completed and the manifest has the entry" \
    eq "$(jq -c '.[0].completed' "$WORLD/store.json")$(jq -sc 'last | [.gate, .ticket]' "$WORLD/repo/.adlc/manifest.jsonl")" 'true["ticket-complete","T1"]'
  check "adlc merge-forecast leaves completed tickets out" eq "$(adlc merge-forecast --json | jq -c .mergeOrder)" '["T2"]'
}

adlc() { "$FAKES_DIR/adlc" "$@"; }

for c in creates updates-idempotent ready-only-when-gated depends-on-lines dry-run-inert closes-completed all-completed \
         stranger-issues node-needs-desk forecast-file read-failures-write-nothing refuses-apply workflow fake-semantics; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
