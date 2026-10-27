#!/usr/bin/env bash
# T4 acceptance 1-2: factory/bin/mirror.sh turns the ADLC ticket store into one Issue per ticket
# (labels w:<weight>, tier:<n>, ready only when the gate record is clean, else needs-desk; body
# with the ticket id and Depends-on: lines) through the fake gh, which records every call. The
# store, gate manifest and forecast come from the fake adlc. Offline, no keys.
# T14 acceptance 1-3 (case node-needs-desk): a node's needs-desk, with the run loop's marker, is kept
# until the ticket's store state changes; one without the marker is recomputed as before.
# T18 acceptance 1-3 (case rails-required): an open ticket without rails gets needs-desk with the
# reason `rails: none declared`; with the rail it can be ready; a completed one is never relabeled.
# T25 (cases depends-on-blocked, forecast-wave-blocked, in-review, links, close-removes-gate-labels):
# one gate label of ready|needs-desk|blocked|in-review. `blocked` when every reason is dependency
# order (an open parent, a forecast wave behind wave 1); `in-review` while an open PR from this
# repository's ticket/<id>/* exists (a fork's or a closed one counts for nothing); `needs-desk` wins.
# Depends-on lines link the parent's Issue `(#n)`, also one created in the same run.
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
ticket() {  # ticket <id> <title> <body> [edge-targets,csv] [completed]: with the default rail
  local tmp; tmp="$(mktemp)"
  jq --arg id "$1" --arg t "$2" --arg b "$3" --arg e "${4:-}" --argjson c "${5:-false}" \
    '. + [{id: $id, title: $t, body: $b, edges: ($e | split(",") | map(select(. != "")) | map({to: .})),
           rails: ["factory/policy/**"], completed: $c}]' \
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
reasons() { jq -sc --arg t "$1" '.[] | select(.ticket == $t) | .reasons' <<<"$OUT"; }   # the line's reasons
line() { jq -sc --arg t "$1" ".[] | select(.ticket == \$t) | $2" <<<"$OUT"; }        # line <ticket> <jq>
dep() { iss "$1" '[.body | split("\n")[] | select(startswith("Depends-on:"))]'; }
fork_pr() {  # fork_pr <n> <head-branch> <owner/name>: an open PR from another repository's branch
  local tmp; tmp="$(mktemp)"
  jq --argjson n "$1" --arg h "$2" --arg r "$3" \
    '.pulls += [{number: $n, headRefName: $h, headRepository: $r, state: "OPEN", createdAt: "2026-10-25T12:00:00Z"}]' \
    "$FAKE_GH_ISSUES" >"$tmp" && mv "$tmp" "$FAKE_GH_ISSUES"
}
pr_state() {  # pr_state <n> <OPEN|CLOSED|MERGED>
  local tmp; tmp="$(mktemp)"
  jq --argjson n "$1" --arg s "$2" '(.pulls[] | select(.number == $n)).state = $s' "$FAKE_GH_ISSUES" >"$tmp" && mv "$tmp" "$FAKE_GH_ISSUES"
}

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
  # in-review is created even though no Issue here wants it: run.sh adds it at the PR hand-off (T25).
  check "the missing labels were created first, in-review always" \
    eq "$(jq -c '[.labels[] | select(. != "in-progress")] | sort' "$FAKE_GH_ISSUES")" '["in-review","ready","tier:0","tier:1","w:heavy","w:light"]'
  check "label-create lines for exactly those" eq "$(lines '.action == "label-create" and .result == "done"')" 6
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
  for t in T2 T3 T4 T5 T7 T9 T11; do check "$t needs-desk" eq "$(labels "$t")" '["needs-desk","tier:1","w:light"]'; done
  # A wave behind wave 1 is dependency order only: blocked, not a case for the desk (T25).
  check "T10 blocked (its only reason is the forecast wave)" eq "$(labels T10)" '["blocked","tier:1","w:light"]'
  check "T6: needs-desk and no w:/tier: label from an invalid header" eq "$(labels T6)" '["needs-desk"]'
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

case_rails_required() {
  mir_setup
  ticket T1 "railed" "$HDR"
  ticket T2 "rails: []" "$HDR"; set_ticket T2 '.rails = []'
  ticket T3 "no rails key" "$HDR"; set_ticket T3 'del(.rails)'
  ticket T4 "blank rails" "$HDR"; set_ticket T4 '.rails = ["", "  "]'
  ticket T5 "another rail only" "$HDR"; set_ticket T5 '.rails = ["docs/**"]'
  ticket T6 "done, no rails key, Issue closed" "$HDR" "" true; set_ticket T6 'del(.rails)'
  ticket T7 "done, rails: [], Issue still open" "$HDR" "" true; set_ticket T7 '.rails = []'
  ticket T8 "done, rails: [], no Issue" "$HDR" "" true; set_ticket T8 '.rails = []'
  local t; for t in T1 T2 T3 T4 T5 T6 T7 T8; do gated "$t"; done
  # T6 and T7 were mirrored while open, as T1-T16 were: T6's Issue is closed, T7's not yet.
  local m='<!-- factory-mirror: generated from the ADLC ticket store by factory/bin/mirror.sh; edits here are overwritten -->'
  fakegh_issue 50 1761300000 "tier:1,w:light" "T6" "$m"$'
Ticket: T6' app/github-actions true; fakegh_close 50
  fakegh_issue 51 1761300000 "ready,tier:1,w:light" "T7" "$m"$'
Ticket: T7' app/github-actions true
  local t6
  # shellcheck disable=SC2034  # t6 is read inside the eval string passed to check
  t6="$(iss T6 .)"
  mir --apply
  check "exit 0" eq "$RC" 0
  check "T1, with the default rail: ready" eq "$(labels T1)" '["ready","tier:1","w:light"]'
  for t in T2 T3 T4; do
    check "$t: needs-desk" eq "$(labels "$t")" '["needs-desk","tier:1","w:light"]'
    check "$t: the reason is rails: none declared, and only that" eq "$(reasons "$t")" '["rails: none declared"]'
  done
  check "the Issue body shows the verdict and the reason" has "$(body T2)" $'Gate: needs-desk\n- rails: none declared\n'
  check "T5: any declared rail satisfies the check (rails-guard can evaluate it): ready" eq "$(labels T5)" '["ready","tier:1","w:light"]'
  check "T6, completed without rails: no line, its closed Issue untouched" \
    eval '[ "$(lines '"'"'.ticket == "T6"'"'"')" = 0 ] && [ "$(iss T6 .)" = "$t6" ]'
  check "T7, completed with rails: []: closed and ready removed, never needs-desk" \
    eq "$(jq -sc '.[] | select(.ticket == "T7") | [.action, .add, .remove, .result]' <<<"$OUT")" '["close",[],["ready"],"done"]'
  check "T7's Issue: closed, no needs-desk" eq "$(iss T7 '[.state, ([.labels[].name] | sort)]')" '["closed",["tier:1","w:light"]]'
  check "T8, completed without rails and no Issue: none is created" eq "$(lines '.ticket == "T8"')" 0
  # The desk adds the rail to T2: ready on the next run, nothing else moves.
  set_ticket T2 '.rails = ["factory/policy/**"]'
  local before; before="$(writes)"
  mir --apply
  check "T2 with the rail: ready, needs-desk removed" \
    eq "$(jq -sc '.[] | select(.ticket == "T2") | [.gate, .reasons, .add, .remove]' <<<"$OUT")" '["ready",[],["ready"],["needs-desk"]]'
  check "one write: T2's edit" eq "$(( $(writes) - before ))" 1
  check "T6 and T7 get no line on the rerun" eq "$(lines '.ticket | IN("T6", "T7", "T8")')" 0
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
  # Each line links the parent's Issue (T25). Creates go parents first: T1 #1 and T5 #2 (no
  # parents), then T2 #3, T3 #4, T4 #5, so every link names a number that exists.
  check "T4 depends on T1, T2, T3 (edges point prerequisite → dependent)" eq "$(dep T4)" '["Depends-on: T1 (#1)","Depends-on: T2 (#3)","Depends-on: T3 (#4)"]'
  check "T3 depends on T1, T2" eq "$(dep T3)" '["Depends-on: T1 (#1)","Depends-on: T2 (#3)"]'
  check "T2 depends on T1" eq "$(dep T2)" '["Depends-on: T1 (#1)"]'
  check "T1 and T5 depend on nothing" eq "$(dep T1)$(dep T5)" '[][]'
  check "Depends-on lines sit right under the Ticket line" \
    eq "$(iss T3 '.body | split("\n")[1:4]')" '["Ticket: T3","Depends-on: T1 (#1)","Depends-on: T2 (#3)"]'
  # The janitor and summon.sh read the ticket id with this exact expression (factory/bin/janitor.sh).
  check "the janitor's Ticket-line parser reads every Issue's id" \
    eq "$(jq -c '[.issues[] | [(.body // "") | splits("\r?\n") | capture("^ticket:[ \t]*(?<id>[A-Za-z0-9._-]+)[ \t]*$"; "i") | .id] | first] | sort' "$FAKE_GH_ISSUES")" \
       '["T1","T2","T3","T4","T5"]'
  # A new edge changes the body of the dependant only.
  set_ticket T5 '.edges = [{to: "T1"}]'
  mir --apply
  check "T1 now depends on T5" eq "$(dep T1)" '["Depends-on: T5 (#2)"]'
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
  # Two label creates: w:light, and in-review, which the mirror always creates when missing (T25).
  check "the plan names two label creates, an update and a close, all planned" \
    eq "$(jq -sc '[.[] | [.action, .label // .ticket, .result]]' <<<"$OUT")" \
       '[["label-create","in-review","planned"],["label-create","w:light","planned"],["update","T1","planned"],["close","T2","planned"]]'
  mir --dry-run
  check "--dry-run: exit 0, still nothing written" eval '[ "$RC" = 0 ] && [ "$(writes)" = 0 ] && [ "$(sha256sum <"$FAKE_GH_ISSUES")" = "$before" ]'
  mir --apply
  check "--apply takes exactly the planned actions" \
    eq "$(jq -sc '[.[] | [.action, .label // .ticket, .result]]' <<<"$OUT")" \
       '[["label-create","in-review","done"],["label-create","w:light","done"],["update","T1","done"],["close","T2","done"]]'
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
  # T1 waits in wave 2: dependency order only, so blocked rather than needs-desk (T25).
  check "the FILE decides: T2 ready, T1 waits (blocked)" eq "$(labels T2)$(labels T1)" '["ready","tier:1","w:light"]["blocked","tier:1","w:light"]'
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

case_depends_on_blocked() {
  mir_setup
  ticket T1 "parent" "$HDR" "T2"
  ticket T2 "child" "$HDR"
  ticket T3 "completed parent, never mirrored" "$HDR" "T2" true
  ticket T4 "second open parent" "$HDR" "T2"
  local t; for t in T1 T2 T3 T4; do gated "$t"; done
  mir --apply
  check "exit 0" eq "$RC" 0
  local ready='["ready","tier:1","w:light"]'
  check "T1 and T4, no parent: ready" eq "$(labels T1)$(labels T4)" "$ready$ready"
  check "T2: blocked, not needs-desk" eq "$(labels T2)" '["blocked","tier:1","w:light"]'
  check "T2: one reason naming the open parents; the completed T3 is not waited on" eq "$(reasons T2)" '["blocked: waits on T1, T4"]'
  check "T2's body shows the verdict and the reason" has "$(body T2)" $'\nGate: blocked\n- blocked: waits on T1, T4\n'
  check "T2 links its parents' Issues; T3, completed with no Issue, is a bare line" \
    eq "$(dep T2)" "[\"Depends-on: T1 (#$(iss T1 .number))\",\"Depends-on: T3\",\"Depends-on: T4 (#$(iss T4 .number))\"]"
  # One parent completes: still blocked, on the other one.
  set_ticket T1 '.completed = true'
  mir --apply
  check "T1 completed: its Issue is closed" eq "$(iss T1 '[.state, .stateReason]')" '["closed","completed"]'
  check "T2 still blocked, now on T4 only (body edited, labels kept)" \
    eq "$(line T2 '[.gate, .reasons, .add, .remove, .body_changed]')" '["blocked",["blocked: waits on T4"],[],[],true]'
  # The last parent completes: ready.
  set_ticket T4 '.completed = true'
  mir --apply
  check "T4 completed: its Issue is closed" eq "$(iss T4 .state)" '"closed"'
  check "T2: every parent completed, ready replaces blocked" \
    eq "$(line T2 '[.gate, .reasons, .add, .remove]')" '["ready",[],["ready"],["blocked"]]'
  check "T2's labels" eq "$(labels T2)" "$ready"
  check "T2 keeps the links to its parents' closed Issues" \
    eq "$(dep T2)" "[\"Depends-on: T1 (#$(iss T1 .number))\",\"Depends-on: T3\",\"Depends-on: T4 (#$(iss T4 .number))\"]"
  local before; before="$(writes)"
  mir --apply
  check "a rerun writes nothing" eq "$(writes)" "$before"
}

case_forecast_wave_blocked() {
  mir_setup
  ticket T1 "wave 1" "$HDR" "T5"
  ticket T2 "wave 2 only" "$HDR"
  ticket T3 "wave 2, no rails" "$HDR"; set_ticket T3 '.rails = []'
  ticket T4 "wave 2, no spec-lint" "$HDR"
  ticket T5 "wave 2, behind an open parent" "$HDR"
  gated T1; gated T2; gated T3; gated T5
  record '{"gate":"coldstart","ticket":"T4","data":{"cache":{"ticketHash":"hash-T4","gaps":[]}}}'
  record '{"gate":"merge-forecast","ticket":"T4","data":{}}'
  export FAKE_ADLC_FORECAST='{"waves":[["T1"],["T2","T3","T4","T5"]],"mergeOrder":["T1","T2","T3","T4","T5"],"pairs":[],"gateFailures":[]}'
  mir --apply
  check "exit 0" eq "$RC" 0
  local wave='merge-forecast: in wave 2, not wave 1'
  check "T1 ready" eq "$(labels T1)" '["ready","tier:1","w:light"]'
  check "T2: the wave is its only reason: blocked" \
    eq "$(line T2 '[.gate, .reasons]')" "[\"blocked\",[\"$wave\"]]"
  check "T2's labels" eq "$(labels T2)" '["blocked","tier:1","w:light"]'
  check "T5: a wave and an open parent, both dependency order: blocked" \
    eq "$(line T5 '[.gate, .reasons]')" "[\"blocked\",[\"$wave\",\"blocked: waits on T1\"]]"
  check "T3: the wave plus no rails: needs-desk" \
    eq "$(line T3 '[.gate, .reasons]')" "[\"needs-desk\",[\"rails: none declared\",\"$wave\"]]"
  check "T4: the wave plus a missing record: needs-desk" \
    eq "$(line T4 '[.gate, .reasons]')" "[\"needs-desk\",[\"spec-lint: no record\",\"$wave\"]]"
  check "T3's and T4's labels" eq "$(labels T3)$(labels T4)" '["needs-desk","tier:1","w:light"]["needs-desk","tier:1","w:light"]'
  # The desk adds T3's rail: only the wave is left, so needs-desk turns into blocked.
  set_ticket T3 '.rails = ["factory/policy/**"]'
  mir --apply
  check "T3 with the rail: blocked replaces needs-desk" \
    eq "$(line T3 '[.gate, .add, .remove]')" '["blocked",["blocked"],["needs-desk"]]'
  # The forecast moves T2 into wave 1: ready.
  export FAKE_ADLC_FORECAST='{"waves":[["T1","T2"],["T3","T4","T5"]],"mergeOrder":["T1","T2","T3","T4","T5"],"pairs":[],"gateFailures":[]}'
  mir --apply
  check "T2 in wave 1: ready replaces blocked" eq "$(line T2 '[.gate, .add, .remove]')" '["ready",["ready"],["blocked"]]'
}

case_in_review() {
  mir_setup
  ticket T1 "open PR" "$HDR" "T5"
  ticket T2 "fork PR only" "$HDR"
  ticket T3 "closed and merged PRs only" "$HDR"
  ticket T4 "a PR for T44" "$HDR"
  ticket T5 "blocked, with an open PR" "$HDR"
  ticket T6 "no rails, with an open PR" "$HDR"; set_ticket T6 '.rails = []'
  local t; for t in T1 T2 T3 T4 T5 T6; do gated "$t"; done
  fakegh_pr 40 ticket/T1/alpha
  fork_pr 41 ticket/T2/alpha stranger/repo          # same branch name, another repository
  fakegh_pr 42 ticket/T3/alpha CLOSED; fakegh_pr 43 ticket/T3/beta MERGED
  fakegh_pr 44 ticket/T44/alpha                     # not T4's: the id ends at the slash
  fakegh_pr 45 ticket/T5/alpha
  fakegh_pr 46 ticket/T6/alpha
  mir --apply
  check "exit 0" eq "$RC" 0
  local ready='["ready","tier:1","w:light"]' review='["in-review","tier:1","w:light"]'
  check "the repo lacked in-review: the mirror created it" eq "$(lines '.action == "label-create" and .label == "in-review" and .result == "done"')" 1
  check "T1, otherwise ready, with an open PR: in-review, not ready" eq "$(labels T1)" "$review"
  check "T1's line" eq "$(line T1 '[.gate, .reasons]')" '["in-review",["in-review: PR #40 is open"]]'
  check "T1's body names the PR" has "$(body T1)" $'\nGate: in-review\n- in-review: PR #40 is open\n'
  check "T2: a fork's PR from ticket/T2/* is ignored: ready" eq "$(labels T2)" "$ready"
  check "T3: closed and merged PRs are ignored: ready" eq "$(labels T3)" "$ready"
  check "T4: ticket/T44/* is not T4's: ready" eq "$(labels T4)" "$ready"
  check "T5: blocked on T1 with an open PR: in-review, the wait kept as a reason" \
    eq "$(line T5 '[.gate, .reasons]')" '["in-review",["blocked: waits on T1","in-review: PR #45 is open"]]'
  check "T5's labels" eq "$(labels T5)" "$review"
  # The PR holds the ticket whatever the store says: the reasons are about claiming it, and they
  # stay in the body for the desk (real adlc's forecast gate failures hit every open ticket).
  check "T6: in-review wins over needs-desk, the reason kept" \
    eq "$(line T6 '[.gate, .reasons]')" '["in-review",["rails: none declared","in-review: PR #46 is open"]]'
  check "T6's labels" eq "$(labels T6)" "$review"
  local before; before="$(writes)"
  mir --apply
  check "a rerun writes nothing" eq "$(writes)" "$before"
  # T1's PR closes; T4 gets two open PRs.
  pr_state 40 CLOSED
  fakegh_pr 60 ticket/T4/a; fakegh_pr 61 ticket/T4/b
  mir --apply
  check "T1's PR closed: ready replaces in-review" eq "$(line T1 '[.gate, .add, .remove]')" '["ready",["ready"],["in-review"]]'
  check "T4 with two open PRs: in-review names both" \
    eq "$(line T4 '[.gate, .reasons, .add, .remove]')" '["in-review",["in-review: PR #60, #61 is open"],["in-review"],["ready"]]'
  check "T5 unchanged (still in review, T1 still open)" eq "$(line T5 .action)" '"unchanged"'
}

case_links() {
  mir_setup
  local m='<!-- factory-mirror: generated from the ADLC ticket store by factory/bin/mirror.sh; edits here are overwritten -->'
  ticket T3 "child, listed first" "$HDR"
  ticket T4 "parent, created in this run" "$HDR" "T3"
  ticket T1 "parent with an Issue already" "$HDR" "T3"
  ticket T5 "completed parent, never mirrored" "$HDR" "T3" true
  local t; for t in T1 T3 T4 T5; do gated "$t"; done
  fakegh_issue 7 1761300000 "ready,tier:1,w:light" "parent with an Issue already" "$m"$'\nTicket: T1' app/github-actions true
  mir --apply
  check "exit 0" eq "$RC" 0
  local n4 n3; n4="$(iss T4 .number)"; n3="$(iss T3 .number)"
  check "the parent T4 is created before its child T3" \
    eq "$(jq -sc '[.[] | select(.action == "create") | .ticket]' <<<"$OUT")$(( n4 < n3 ))" '["T4","T3"]1'
  check "T3 links the existing #7, T4's new Issue, and T5 bare (it has none)" \
    eq "$(dep T3)" "[\"Depends-on: T1 (#7)\",\"Depends-on: T4 (#$n4)\",\"Depends-on: T5\"]"
  check "no placeholder reaches an Issue" eval '[ "$(jq '"'"'[.issues[].body | select(contains("(#?)"))] | length'"'"' "$FAKE_GH_ISSUES")" = 0 ]'
  local before; before="$(writes)"
  mir --apply
  check "a second run writes nothing" eq "$(writes)" "$before"
  check "and every line is unchanged" eq "$(lines '.action != "unchanged"')" 0
  # A parent whose create fails: the child is created with a bare line, linked once the parent exists.
  ticket T6 "parent whose create fails" "$HDR" "T7"
  ticket T7 "child of T6" "$HDR"
  gated T6; gated T7
  FAKE_GH_FAIL='issue create .*parent whose create fails' mir --apply
  check "the failed create: exit 1" eq "$RC" 1
  check "T6 has no Issue, T7's line is bare" eq "$(jq '[.issues[] | select(.body | contains("\nTicket: T6"))] | length' "$FAKE_GH_ISSUES")$(dep T7)" '0["Depends-on: T6"]'
  mir --apply
  check "the next run creates T6" eq "$(line T6 '[.action, .result]')" '["create","done"]'
  # T7's plan was `unchanged` (its bare line equals the unlinked body); T6's create makes it a body edit.
  check "and in the same run T7 links T6's Issue (a body edit)" \
    eq "$(line T7 '[.action, .body_changed, .result]')$(dep T7)" "[\"update\",true,\"done\"][\"Depends-on: T6 (#$(iss T6 .number))\"]"
  before="$(writes)"
  mir --apply
  check "then nothing is written" eq "$(writes)" "$before"
}

case_close_removes_gate_labels() {
  mir_setup
  ticket T1 "in review" "$HDR"
  ticket T2 "blocked child" "$HDR"
  ticket T3 "parent" "$HDR" "T2"
  local t; for t in T1 T2 T3; do gated "$t"; done
  fakegh_pr 40 ticket/T1/alpha
  mir --apply
  check "setup: T1 in-review, T2 blocked" \
    eq "$(labels T1)$(labels T2)" '["in-review","tier:1","w:light"]["blocked","tier:1","w:light"]'
  gh issue edit "$(iss T1 .number)" --repo test/repo --add-label in-progress >/dev/null
  set_ticket T1 '.completed = true'; set_ticket T2 '.completed = true'
  mir --apply
  check "exit 0" eq "$RC" 0
  check "T1 closed, in-review removed" eq "$(line T1 '[.action, .remove, .result]')" '["close",["in-review"],"done"]'
  check "T2 closed, blocked removed" eq "$(line T2 '[.action, .remove, .result]')" '["close",["blocked"],"done"]'
  check "T1's Issue: closed, in-progress kept" eq "$(iss T1 '[.state, ([.labels[].name] | sort)]')" '["closed",["in-progress","tier:1","w:light"]]'
  check "T2's Issue: closed, no gate label" eq "$(iss T2 '[.state, ([.labels[].name] | sort)]')" '["closed",["tier:1","w:light"]]'
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
  set_ticket T2 'del(.rails)'
  check "adlc ticket show carries rails, and no key when the fixture gave none" \
    eq "$(adlc ticket show T1 --json | jq -c '.ticket.rails')$(adlc ticket show T2 --json | jq -c '.ticket | has("rails")')" '["factory/policy/**"]false'
  check "adlc ticket show: unknown id exits 2, TICKET_NOT_FOUND on stderr, stdout empty" \
    eval '[ "$(adlc ticket show T9 --json 2>&1 >/dev/null | jq -r .code; echo "${PIPESTATUS[0]}")" = $'"'"'TICKET_NOT_FOUND\n2'"'"' ] && [ -z "$(adlc ticket show T9 --json 2>/dev/null)" ]'
  record '{"type":"p5-finding-verified","ticket":"T1","finding":{"id":"F"}}'
  record '{"gate":"spec-lint","ticket":"T2","data":{"verified":true}}'
  check "adlc gate-manifest show --ticket filters, gate = type" \
    eq "$(cd "$WORLD/repo" && adlc gate-manifest show --ticket T1 --json | jq -c '[.entries[] | [.gate, .segment]], .skipped')" $'[["p5-finding-verified","root"]]\n[]'
  check "adlc ticket complete --write without --authorize exits 2" eval '! (cd "$WORLD/repo" && adlc ticket complete T1 --write >/dev/null 2>&1)'
  (cd "$WORLD/repo" && adlc ticket complete T1 --json >/dev/null)
  check "adlc ticket complete without --write changes nothing" eq "$(jq -c '.[0].completed' "$WORLD/store.json")" false
  check "a railed store is frozen: --write --authorize alone exits 2, MANIFEST_KEY_REQUIRED, nothing changed" \
    eval '[ "$(cd "$WORLD/repo" && adlc ticket complete T1 --write --authorize --json 2>&1 >/dev/null | jq -r .code; echo "${PIPESTATUS[0]}")" = $'"'"'MANIFEST_KEY_REQUIRED\n2'"'"' ] &&
          [ "$(jq -c '"'"'.[0].completed'"'"' "$WORLD/store.json")" = false ]'
  check "adlc ticket complete --write --authorize --allow-unsigned: applied" \
    eq "$(cd "$WORLD/repo" && adlc ticket complete T1 --write --authorize --allow-unsigned --json 2>/dev/null | jq -sc 'last.applied')" true
  check "the store says completed and the manifest has the entry" \
    eq "$(jq -c '.[0].completed' "$WORLD/store.json")$(jq -sc 'last | [.gate, .ticket, .data.bypass]' "$WORLD/repo/.adlc/manifest.jsonl")" 'true["ticket-complete","T1",true]'
  check "adlc merge-forecast leaves completed tickets out" eq "$(adlc merge-forecast --json | jq -c .mergeOrder)" '["T2"]'
}

adlc() { "$FAKES_DIR/adlc" "$@"; }

for c in creates updates-idempotent ready-only-when-gated rails-required depends-on-lines dry-run-inert closes-completed all-completed \
         stranger-issues node-needs-desk forecast-file depends-on-blocked forecast-wave-blocked in-review links \
         close-removes-gate-labels read-failures-write-nothing refuses-apply workflow fake-semantics; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
