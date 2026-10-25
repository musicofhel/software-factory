#!/usr/bin/env bash
# T18 acceptance 4: factory/bin/ticket-check.sh, the check behind `make tickets`, fails (exit 2) on an
# open ticket whose `rails` is empty or missing and passes on a store whose open tickets declare a
# rail, completed rail-free ones included (T1-T16). The store comes from the fake adlc. Offline,
# no keys.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

tc_setup() {
  fakegh_setup
  echo '[]' >"$WORLD/store.json"
  export FACTORY_ADLC="$FAKES_DIR/adlc" FAKE_ADLC_STORE="$WORLD/store.json"
}
ticket() {  # ticket <id> <rails-json|none> [completed]
  local tmp; tmp="$(mktemp)"
  jq --arg id "$1" --arg r "$2" --argjson c "${3:-false}" \
    '. + [{id: $id, title: "t \($id)", body: "weight: light\ntier: 0\ncharter: C1"}
          + (if $r == "none" then {} else {rails: ($r | fromjson)} end) + {completed: $c}]' "$WORLD/store.json" >"$tmp"
  mv "$tmp" "$WORLD/store.json"
}
tc() {  # tc <args>: sets RC, OUT (JSON lines), ERR
  RC=0
  OUT="$(cd "$WORLD" && "$BIN/ticket-check.sh" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
results() { jq -sc 'map([.ticket, .result])' <<<"$OUT"; }
has() { [[ "$1" == *"$2"* ]] || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }

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
  check "--json is accepted (the output is always JSON lines)" eval 'tc --json; [ "$RC" = 0 ]'
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
  check "stderr names the refused tickets and the default rail" \
    eval 'has "$ERR" "open ticket(s) without rails: T2 T3 T4" && has "$ERR" "factory/policy/**"'
  local tmp; tmp="$(mktemp)"
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
  printf '#!/usr/bin/env bash\necho '"'"'{"not": "a list"}'"'"'\n' >"$WORLD/adlc-object"; chmod +x "$WORLD/adlc-object"
  FACTORY_ADLC="$WORLD/adlc-object" tc
  check "a list that is not a list: exit 1" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "not a JSON list"'
  unset FAKE_ADLC_STORE
  FAKE_ADLC_TICKETS='[{"id": "bad id; rm"}]' tc
  check "a ticket id the store should never hold: exit 1" eval '[ "$RC" = 1 ] && has "$ERR" "refusing ticket id"'
  FAKE_ADLC_TICKETS='[]' tc
  check "an empty store: exit 0, no line" eval '[ "$RC" = 0 ] && [ -z "$OUT" ]'
  tc --bogus
  check "an unknown argument: exit 1 with the usage" eval '[ "$RC" = 1 ] && has "$ERR" "ticket-check.sh [--json]"'
}

case_make_tickets() {
  local mk="$REPO_ROOT/Makefile"
  check "make tickets runs the check after the list" \
    eq "$(sed -n '/^tickets:/,/^$/p' "$mk")" $'tickets:\n\t@npx -y @adlc/cli@1.12.0 ticket list\n\t@./factory/bin/ticket-check.sh'
  check "ticket-check.sh is executable" test -x "$BIN/ticket-check.sh"
}

for c in passes-store-as-it-stands refuses-open-without-rails read-failures make-tickets; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
