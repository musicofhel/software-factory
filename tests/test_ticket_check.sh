#!/usr/bin/env bash
# T18 acceptance 4: factory/bin/ticket-check.sh, the check behind `make tickets`, fails (exit 2) on an
# open ticket whose `rails` is empty or missing and passes on a store whose open tickets declare a
# rail, completed rail-free ones included (T1-T16).
# T26 (specs/factory-step3-v1 TB7): it is now the desk's contract lint. An open ticket is also
# refused for its ADR-0002 header (mirror.sh's wording), a scope glob that matches no tracked path
# of the checkout and no declared `New paths:` entry (its own or an ancestor's), an edge target not
# in the store, a tier inversion, and a merge-forecast warning naming it; every reason is listed.
# The store and the forecast come from the fake adlc (STORE mode), the checkout is a temp git
# repository. Offline, no keys.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

HDR='weight: light\ntier: 0\ncharter: C1'   # a valid header, as a jq string body

tc_setup() {  # a temp checkout with README.md, docs/a.md, factory/policy/x.json tracked; an empty store
  fakegh_setup
  REPO="$WORLD/repo"
  mkdir -p "$REPO/docs" "$REPO/factory/policy"
  printf 'readme\n' >"$REPO/README.md"
  printf 'a\n' >"$REPO/docs/a.md"
  printf '{}\n' >"$REPO/factory/policy/x.json"
  git -C "$REPO" init -q
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=fixture -c user.email=fixture@fake -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -qm root
  echo '[]' >"$WORLD/store.json"
  export FACTORY_ADLC="$FAKES_DIR/adlc" FAKE_ADLC_STORE="$WORLD/store.json"
}
tk() {  # tk <id> [jq object over the defaults; a null value drops the key]
  # defaults: a valid header, scope ["README.md"], the default rail, open
  local o="${2:-}" tmp; [ -n "$o" ] || o='{}'
  tmp="$(mktemp "$WORLD/store.XXXXXX")"
  jq --arg id "$1" '. + [({id: $id, title: "t \($id)", body: "'"$HDR"'", scope: ["README.md"],
        rails: ["factory/policy/**"], completed: false} + ('"$o"')) | with_entries(select(.value != null))]' \
    "$WORLD/store.json" >"$tmp"
  mv "$tmp" "$WORLD/store.json"
}
ticket() {  # ticket <id> <rails-json|none> [completed]: the T18 shape (a valid header and scope)
  local r=null; [ "$2" = none ] || r="$2"
  tk "$1" "{rails: $r, completed: ${3:-false}}"
}
tc() {  # tc <args>: sets RC, OUT (JSON lines), ERR; runs in $TC_DIR (default the checkout's root)
  RC=0
  OUT="$(cd "${TC_DIR:-$REPO}" && "$BIN/ticket-check.sh" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
results() { jq -sc 'map([.ticket, .result])' <<<"$OUT"; }
reasons() { jq -sc --arg id "$1" '.[] | select(.ticket == $id) | .reasons' <<<"$OUT"; }
forecast_calls() { jq -c 'select(.[0] == "merge-forecast")' "$FAKE_ADLC_LOG" | wc -l | tr -d ' '; }
has() { [[ "$1" == *"$2"* ]] || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }
SCOPE_TAIL='matches no path and no declared new path (a `New paths:` line of this ticket or a parent)'

# ---------------------------------------------------------------------------------------------
case_passes_store_as_it_stands() {
  # main's store since TB0: T1-T5 completed with no rails key, T6-T16 completed with rails: [],
  # T17-T19 open with the default rail.
  tc_setup
  local i; for i in 1 2 3 4 5; do ticket "T$i" none true; done
  for i in 6 7 8 9 10 11 12 13 14 15 16; do ticket "T$i" '[]' true; done
  for i in 17 18 19; do ticket "T$i" '["factory/policy/**"]'; done
  tc
  check "exit 0" eq "$RC" 0
  check "one line per ticket" eq "$(jq -s length <<<"$OUT")" 19
  check "the completed ones are reported, not refused" eq "$(jq -sc '[.[] | select(.completed) | .result] | unique' <<<"$OUT")" '["completed"]'
  check "the open ones are ok, with their rails" \
    eq "$(jq -sc '[.[] | select(.completed | not) | [.ticket, .result, .rails, .reasons]]' <<<"$OUT")" \
       '[["T17","ok",["factory/policy/**"],[]],["T18","ok",["factory/policy/**"],[]],["T19","ok",["factory/policy/**"],[]]]'
  check "nothing on stderr" eq "$ERR" ""
  check "the forecast is read once" eq "$(forecast_calls)" 1
  check "--json is accepted (the output is always JSON lines)" eval 'tc --json; [ "$RC" = 0 ]'
  TC_DIR="$REPO/docs" tc
  check "from a subdirectory: the paths are the checkout's (README.md resolves)" \
    eval '[ "$RC" = 0 ] && [ "$(jq -sc '"'"'[.[].result] | unique'"'"' <<<"$OUT")" = '"'"'["completed","ok"]'"'"' ]'
}

case_refuses_open_without_rails() {
  tc_setup
  ticket T1 '["factory/policy/**"]'
  ticket T2 '[]'
  ticket T3 none
  ticket T4 '["", "  "]'
  ticket T5 '["docs/**"]'
  ticket T6 none true
  tc
  check "exit 2 (a gate fail)" eq "$RC" 2
  check "T2, T3 and T4 refused; T1 and T5 ok; T6 completed" \
    eq "$(results)" '[["T1","ok"],["T2","refused"],["T3","refused"],["T4","refused"],["T5","ok"],["T6","completed"]]'
  check "the reason is rails: none declared" \
    eq "$(jq -sc '[.[] | select(.result == "refused") | .reasons] | unique' <<<"$OUT")" '[["rails: none declared"]]'
  check "a missing rails key reads as null" eq "$(jq -sc '.[] | select(.ticket == "T3") | .rails' <<<"$OUT")" null
  check "stderr names the refused tickets and where the reasons are" \
    eq "$ERR" 'ticket-check: open ticket(s) refused: T2 T3 T4 (the reasons are on each line; factory/RULES.md, the desk runbook)'
  local tmp; tmp="$(mktemp "$WORLD/store.XXXXXX")"
  jq 'map(if .id | IN("T2", "T3", "T4") then .rails = ["factory/policy/**"] else . end)' "$WORLD/store.json" >"$tmp" &&
    mv "$tmp" "$WORLD/store.json"
  tc
  check "the desk adds the rail: exit 0" eval '[ "$RC" = 0 ] && [ "$(jq -sc '"'"'[.[].result] | unique'"'"' <<<"$OUT")" = '"'"'["completed","ok"]'"'"' ]'
}

case_read_failures() {
  tc_setup
  ticket T1 '[]'
  FAKE_ADLC_FAIL='ticket show' tc
  check "a failed ticket show: exit 1, no verdict line" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "adlc ticket show T1 failed"'
  FAKE_ADLC_FAIL='ticket list' tc
  check "a failed ticket list: exit 1, no verdict line" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "adlc ticket list failed"'
  FAKE_ADLC_FAIL='merge-forecast' tc
  check "a failed forecast: exit 1, no verdict line" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "adlc merge-forecast failed (exit 1)"'
  printf '#!/usr/bin/env bash\necho '"'"'{"not": "a list"}'"'"'\n' >"$WORLD/adlc-object"; chmod +x "$WORLD/adlc-object"
  FACTORY_ADLC="$WORLD/adlc-object" tc
  check "a list that is not a list: exit 1" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "not a JSON list"'
  TC_DIR="$WORLD" tc
  check "outside a git checkout: exit 1, no verdict line" \
    eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "not inside a git checkout"'
  unset FAKE_ADLC_STORE
  FAKE_ADLC_TICKETS='[{"id": "bad id; rm"}]' tc
  check "a ticket id the store should never hold: exit 1" eval '[ "$RC" = 1 ] && has "$ERR" "refusing ticket id"'
  FAKE_ADLC_TICKETS='[]' tc
  check "an empty store: exit 0, no line" eval '[ "$RC" = 0 ] && [ -z "$OUT" ]'
  tc --bogus
  check "an unknown argument: exit 1 with the usage" eval '[ "$RC" = 1 ] && has "$ERR" "ticket-check.sh [--json]"'
}

case_header() {
  tc_setup
  tk H1
  tk H2 '{body: "tier: 0\ncharter: C1"}'
  tk H3 '{body: "weight: light\ntier: x\ncharter: C1"}'
  tk H4 '{body: "weight: light\ntier: 0\ncharter: P1"}'
  tk H5 '{body: "weight: medium\ntier: 3\ncharter: C"}'
  tk H6 '{body: "weight: light\n\ntier: 0\ncharter: C1"}'
  tk H7 '{body: null}'
  tk H8 '{body: "weight: heavy\r\ntier: 2 \r\ncharter:   C12\r\n\r\nweight: bogus\ntier: x"}'
  tk H9 '{body: "Some title line\nweight: light\ntier: 1\ncharter: C3\n\nbody text"}'
  tc
  check "exit 2" eq "$RC" 2
  check "H2-H7 refused; H1, H8, H9 ok" \
    eq "$(results)" '[["H1","ok"],["H2","refused"],["H3","refused"],["H4","refused"],["H5","refused"],["H6","refused"],["H7","refused"],["H8","ok"],["H9","ok"]]'
  check "a missing weight" eq "$(reasons H2)" '["header: weight missing"]'
  check "a bad tier, mirror.sh's words" eq "$(reasons H3)" "[\"header: tier 'x' is not 0|1|2\"]"
  check "a bad charter, mirror.sh's words" eq "$(reasons H4)" "[\"header: charter 'P1' is not a PROJECT.md line id (C<n>)\"]"
  check "three bad fields, three reasons" eq "$(reasons H5)" \
    "[\"header: weight 'medium' is not light|heavy\",\"header: tier '3' is not 0|1|2\",\"header: charter 'C' is not a PROJECT.md line id (C<n>)\"]"
  check "fields after the first blank line do not count" eq "$(reasons H6)" '["header: tier missing","header: charter missing"]'
  check "no body: everything missing" eq "$(reasons H7)" '["header: weight missing","header: tier missing","header: charter missing"]'
  check "stderr names exactly the refused" \
    eq "$ERR" 'ticket-check: open ticket(s) refused: H2 H3 H4 H5 H6 H7 (the reasons are on each line; factory/RULES.md, the desk runbook)'
}

case_scope() {
  tc_setup
  mkdir -p "$REPO/untracked"; printf 'u\n' >"$REPO/untracked/u.txt"
  tk S1                                                    # README.md
  tk S2 '{scope: null}'
  tk S3 '{scope: []}'
  tk S4 '{scope: ["nosuch/**"]}'
  tk S5 '{scope: ["untracked/**"]}'
  tk S6 '{scope: ["docs/*.md", "factory/**", "nosuch/**"]}'
  tk S7 '{scope: ["docs/*.md", "factory/policy/*.json"]}'
  tk S8 '{scope: ["nosuch/**"], body: "'"$HDR"'\n\nNew paths: `nosuch/new.sh`, `other/x.md`"}'
  tk S9 '{scope: ["nosuch/one.sh"], body: "'"$HDR"'\n\nNew path: `nosuch/one.sh`"}'
  tk S10 '{scope: ["nosuch/**"], body: "'"$HDR"'\n\nTouches `nosuch/new.sh` (not a New paths line)"}'
  tk S11 '{scope: [42]}'
  tc
  check "exit 2" eq "$RC" 2
  check "S1, S7, S8, S9 ok; the rest refused" \
    eq "$(results)" '[["S1","ok"],["S2","refused"],["S3","refused"],["S4","refused"],["S5","refused"],["S6","refused"],["S7","ok"],["S8","ok"],["S9","ok"],["S10","refused"],["S11","refused"]]'
  check "no scope key: none declared" eq "$(reasons S2)" '["scope: none declared"]'
  check "scope []: none declared" eq "$(reasons S3)" '["scope: none declared"]'
  check "a glob matching nothing" eq "$(reasons S4)" "$(jq -cn --arg t "$SCOPE_TAIL" '["scope: '"'"'nosuch/**'"'"' \($t)"]')"
  check "a glob matching only an untracked file still fails" \
    eq "$(reasons S5)" "$(jq -cn --arg t "$SCOPE_TAIL" '["scope: '"'"'untracked/**'"'"' \($t)"]')"
  check "only the unmatched glob of several is named" \
    eq "$(reasons S6)" "$(jq -cn --arg t "$SCOPE_TAIL" '["scope: '"'"'nosuch/**'"'"' \($t)"]')"
  check "a backticked path off a New paths line does not count" \
    eq "$(reasons S10)" "$(jq -cn --arg t "$SCOPE_TAIL" '["scope: '"'"'nosuch/**'"'"' \($t)"]')"
  check "a scope of no strings: none declared" eq "$(reasons S11)" '["scope: none declared"]'
}

case_scope_new_paths_from_parents() {
  tc_setup
  # G -> P -> C (an edge {to: X} on Y: X waits on Y). G and P declare new paths; C uses both.
  tk G '{edges: [{to: "P"}], body: "'"$HDR"'\n\nNew paths: `gp/new.sh`"}'
  tk P '{edges: [{to: "C"}], body: "'"$HDR"'\n\nNew paths: `gen/new.sh`"}'
  tk C '{scope: ["gen/**", "gp/*.sh"]}'
  # The other way round: the child K declares a new path, its parent Q cannot use it.
  tk Q '{edges: [{to: "K"}], scope: ["kid/**"]}'
  tk K '{scope: ["kid/**"], body: "'"$HDR"'\n\nNew paths: `kid/new.sh`"}'
  # An unrelated ticket does not lend its new paths either.
  tk U '{scope: ["gen/**"]}'
  tc
  check "exit 2" eq "$RC" 2
  check "C (parent's and grandparent's new paths) and K (its own) ok; Q and U refused" \
    eq "$(results)" '[["G","ok"],["P","ok"],["C","ok"],["Q","refused"],["K","ok"],["U","refused"]]'
  check "a child's new path does not help its parent" \
    eq "$(reasons Q)" "$(jq -cn --arg t "$SCOPE_TAIL" '["scope: '"'"'kid/**'"'"' \($t)"]')"
  check "an unrelated ticket's new path does not help" \
    eq "$(reasons U)" "$(jq -cn --arg t "$SCOPE_TAIL" '["scope: '"'"'gen/**'"'"' \($t)"]')"
}

case_edges() {
  tc_setup
  tk E1 '{edges: [{to: "T99"}]}'
  tk E2 '{edges: [{to: "E3"}, {to: "E4"}]}'
  tk E3
  tk E4 '{completed: true}'
  tc
  check "exit 2" eq "$RC" 2
  check "E1 refused; E2, E3 ok (a completed target is in the store)" \
    eq "$(results)" '[["E1","refused"],["E2","ok"],["E3","ok"],["E4","completed"]]'
  check "the reason names the target" eq "$(reasons E1)" "[\"edges: target 'T99' is not in the store\"]"
}

case_tier() {
  tc_setup
  tk A2 '{edges: [{to: "B0"}], body: "weight: light\ntier: 2\ncharter: C1"}'
  tk B0
  tk C0 '{edges: [{to: "D1"}]}'
  tk D1 '{body: "weight: light\ntier: 1\ncharter: C1"}'
  tk E1 '{edges: [{to: "F1"}], body: "weight: light\ntier: 1\ncharter: C1"}'
  tk F1 '{body: "weight: light\ntier: 1\ncharter: C1"}'
  tc
  check "exit 2" eq "$RC" 2
  check "B0 refused (its parent is tier 2); 0 -> 1 and 1 -> 1 fine; the parent itself fine" \
    eq "$(results)" '[["A2","ok"],["B0","refused"],["C0","ok"],["D1","ok"],["E1","ok"],["F1","ok"]]'
  check "the reason is on the child, naming the parent" \
    eq "$(reasons B0)" '["tier: tier 0 waits on A2, tier 2 (a parent never has a higher tier)"]'
  # A completed parent orders nothing any more: its higher tier never refuses an open child.
  local tmp; tmp="$(mktemp)"
  jq 'map(if .id == "A2" then .completed = true else . end)' "$WORLD/store.json" >"$tmp" && mv "$tmp" "$WORLD/store.json"
  tc
  check "A2 completed: exit 0, B0 ok" eq "$RC:$(results)" '0:[["A2","completed"],["B0","ok"],["C0","ok"],["D1","ok"],["E1","ok"],["F1","ok"]]'
}

case_forecast() {
  tc_setup
  tk T1; tk T2; tk T20
  FAKE_ADLC_FORECAST='{"warnings": ["ticket \"T2\" scope matches 0 files in repo", "something general"]}' tc
  check "exit 2" eq "$RC" 2
  check "T2 refused; T1 and T20 not" eq "$(results)" '[["T1","ok"],["T2","refused"],["T20","ok"]]'
  check "the reason is the warning" eq "$(reasons T2)" '["forecast: ticket \"T2\" scope matches 0 files in repo"]'
  check "merge-forecast --json is called once" \
    eq "$(jq -c 'select(.[0] == "merge-forecast")' "$FAKE_ADLC_LOG")" '["merge-forecast","--json"]'
  FAKE_ADLC_FORECAST='{"warnings": ["ticket \"T20\" has no scope defined"]}' FAKE_ADLC_FORECAST_EXIT=2 tc
  check "exit 2 with a JSON object is still a forecast" \
    eval '[ "$RC" = 2 ] && [ "$(results)" = '"'"'[["T1","ok"],["T2","ok"],["T20","refused"]]'"'"' ]'
  FAKE_ADLC_FORECAST='{"warnings": []}' FAKE_ADLC_FORECAST_EXIT=2 tc
  check "exit 2 with no warning: every ticket ok, exit 0" eval '[ "$RC" = 0 ] && [ -n "$OUT" ] && [ -z "$ERR" ]'
  FAKE_ADLC_FORECAST='{"waves": []}' tc
  check "an object without warnings: nothing to refuse" eval '[ "$RC" = 0 ]'
  FAKE_ADLC_FORECAST='["ticket \"T2\" scope matches 0 files in repo"]' tc
  check "a forecast that is not an object: exit 1, no verdict line" \
    eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "the forecast is not a merge-forecast JSON object"'
  FAKE_ADLC_FORECAST='{"warnings": []}' FAKE_ADLC_FORECAST_EXIT=1 tc
  check "a forecast exit 1 with open tickets: exit 1, no verdict line" \
    eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "adlc merge-forecast failed (exit 1)"'
}

case_no_open_ticket_no_forecast() {
  tc_setup
  tk T1 '{completed: true}'; tk T2 '{completed: true, scope: null}'
  FAKE_ADLC_FORECAST_EXIT=1 tc
  check "exit 0" eq "$RC" 0
  check "both completed" eq "$(results)" '[["T1","completed"],["T2","completed"]]'
  check "merge-forecast is not called" eq "$(forecast_calls)" 0
}

case_completed_never_refused() {
  tc_setup
  tk T1
  tk T2 '{completed: true, body: "weight: x\ntier: 9", scope: null, rails: null, edges: [{to: "T99"}]}'
  tk T3 '{completed: true, body: null, scope: ["nosuch/**"], edges: [{to: "T1"}]}'
  tk T4 '{completed: true, body: "weight: light\ntier: 2\ncharter: C1", edges: [{to: "T5"}]}'
  tk T5 '{completed: true}'
  FAKE_ADLC_FORECAST='{"warnings": ["ticket \"T2\" has no scope defined", "ticket \"T3\" scope matches 0 files in repo"]}' tc
  check "exit 0" eq "$RC" 0
  check "the completed ones are completed, with no reason" \
    eq "$(jq -sc 'map([.ticket, .result, .reasons])' <<<"$OUT")" \
       '[["T1","ok",[]],["T2","completed",[]],["T3","completed",[]],["T4","completed",[]],["T5","completed",[]]]'
  check "nothing on stderr" eq "$ERR" ""
}

case_multiple_reasons() {
  tc_setup
  tk T1
  tk T2 '{body: "weight: light\ntier: 0", rails: [], scope: ["nosuch/**"], edges: [{to: "T99"}]}'
  tk T3 '{body: "weight: light\ntier: 2\ncharter: C1", edges: [{to: "T4"}]}'
  tk T4 '{body: "tier: 1\ncharter: C1", scope: null}'
  FAKE_ADLC_FORECAST='{"warnings": ["ticket \"T2\" scope matches 0 files in repo", "ticket \"T4\" has no scope defined"]}' tc
  check "exit 2" eq "$RC" 2
  check "T2 and T4 refused" eq "$(results)" '[["T1","ok"],["T2","refused"],["T3","ok"],["T4","refused"]]'
  check "every reason of T2, in rule order" eq "$(reasons T2)" "$(jq -cn --arg t "$SCOPE_TAIL" \
    '["rails: none declared", "header: charter missing", "scope: '"'"'nosuch/**'"'"' \($t)",
      "edges: target '"'"'T99'"'"' is not in the store", "forecast: ticket \"T2\" scope matches 0 files in repo"]')"
  check "every reason of T4, in rule order" eq "$(reasons T4)" \
    '["header: weight missing","scope: none declared","tier: tier 1 waits on T3, tier 2 (a parent never has a higher tier)","forecast: ticket \"T4\" has no scope defined"]'
  check "stderr names both" has "$ERR" "open ticket(s) refused: T2 T4 "
}

case_make_tickets() {
  local mk="$REPO_ROOT/Makefile"
  check "make tickets runs the check after the list" \
    eq "$(sed -n '/^tickets:/,/^$/p' "$mk")" $'tickets:\n\t@npx -y @adlc/cli@1.12.0 ticket list\n\t@./factory/bin/ticket-check.sh'
  check "ticket-check.sh is executable" test -x "$BIN/ticket-check.sh"
}

for c in passes-store-as-it-stands refuses-open-without-rails read-failures header scope scope-new-paths-from-parents \
         edges tier forecast no-open-ticket-no-forecast completed-never-refused multiple-reasons make-tickets; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
