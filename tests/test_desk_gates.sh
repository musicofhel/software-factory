#!/usr/bin/env bash
# factory/bin/desk-gates.sh, the desk's records and the desk PR's gate (ticket T26, specs/factory-step3-v1
# TB7). Proves: --dry-run (the default) writes nothing and plans a missing or stale record; --write
# records spec-lint (on the body rendered with `## Acceptance criteria`) and the offline coldstart
# verdict on the ticket's current ticketHash, re-records only what went stale, records a coldstart
# verdict with gaps (it stays current and failing) and never a failing spec-lint; a completed ticket
# gets no line; --ticket filters; usage errors exit 1. --check passes a diff with no .adlc/ path at
# once and otherwise fails (exit 2) a manifest that does not extend the base's bytes, a broken hash
# chain (two desk PRs cut from one main and joined), a doctor failure, a ticket-check refusal, and an
# open ticket without current, passing records; it finds the base by merge-base with origin/main. A
# failed adlc read exits 1 with no verdict for it.
# The store is the fake adlc's git-store mode (tests/fakes/adlc, FAKE_ADLC_GITSTORE=1) in a temp
# repository per case. Offline, no keys.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

BODY=$'weight: light\ntier: 0\ncharter: C6\n\nAdd x.\n\nAcceptance criteria:\n1. x exists. Verify: `test -f x`.'

# dg_setup: a fresh world; $R is a git repo on main holding README.md, an empty ticket directory
# store and an empty manifest, committed (BASE0).
dg_setup() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export FACTORY_ADLC="$FAKES_DIR/adlc" FAKE_ADLC_GITSTORE=1
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  R="$WORLD/repo"
  git init -q -b main "$R"
  git -C "$R" config user.name desk
  git -C "$R" config user.email desk@fake
  echo 'hello' >"$R/README.md"
  mkdir -p "$R/.adlc/tickets"
  printf '{"format":"adlc-ticket-directory","version":1}\n' >"$R/.adlc/tickets/.store.json"
  : >"$R/.adlc/manifest.jsonl"
  commit "seed"
  BASE0="$(rev HEAD)"
}
commit() { git -C "$R" add -A && git -C "$R" commit -q -m "$1"; }
rev() { git -C "$R" rev-parse "$1"; }
adlc() { (cd "$R" && "$FACTORY_ADLC" "$@"); }
mk() {  # mk <id> [body] [scope-json] [edges-json] [title]: `adlc ticket create` through the fake
  jq -n --arg id "$1" --arg b "${2:-$BODY}" --argjson s "${3:-[\"README.md\"]}" --argjson e "${4:-[]}" \
     --arg t "${5:-ticket $1}" \
    '{id: $id, title: $t, body: $b, category: "feature", duration: 1, scope: $s,
      rails: ["factory/policy/**"], edges: $e}' >"$WORLD/t-$1.json"
  adlc ticket create --input "$WORLD/t-$1.json" --write --allow-unsigned --json >/dev/null 2>&1
}
store_file() {  # store_file <id>: the ticket's file in the directory store
  local f; for f in "$R"/.adlc/tickets/*.json; do [ "$(jq -r .id "$f")" = "$1" ] && { echo "$f"; return 0; }; done; return 1
}
edit() {  # edit <id> <jq>: the desk edits a stored ticket (the fake has no `ticket update`)
  local f tmp; f="$(store_file "$1")"; tmp="$(mktemp)"
  jq -S "$2" "$f" >"$tmp" && mv "$tmp" "$f"
}
dg() {  # dg <args>: desk-gates in the repo; RC, OUT (JSON lines), ERR
  RC=0
  OUT="$(cd "$R" && "$BIN/desk-gates.sh" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
rows() { jq -sc 'map([.check, .ticket, .state, .action, .result])' <<<"$OUT"; }
reasons() { jq -sc --arg c "$1" --arg t "${2:-}" '[.[] | select(.check == $c and (.ticket // "") == $t) | .reasons[]]' <<<"$OUT"; }
mf() { jq -sc . "$R/.adlc/manifest.jsonl"; }
mf_n() { wc -l <"$R/.adlc/manifest.jsonl" | tr -d ' '; }
mf_new() { tail -n "+$(($1 + 1))" "$R/.adlc/manifest.jsonl" | jq -sc .; }   # the entries after the first <n>
thash() { adlc ticket show "$1" --json | jq -r .ticketHash; }
has() { [[ "$1" == *"$2"* ]] || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }
lacks() { [[ "$1" != *"$2"* ]] || { printf '      [%s] has [%s]\n' "$1" "$2"; return 1; }; }
rendered_sha() {  # the sha256 of the spec-lint rendering of a body: `Acceptance criteria:` -> `## Acceptance criteria`
  printf '%s\n' "${1/$'\nAcceptance criteria:\n'/$'\n## Acceptance criteria\n'}" | sha256sum | cut -d' ' -f1
}
# PASSING is spliced after the check name: ["spec-lint", "T1", "current", "none", "pass"]
PASSING='"T1","current","none","pass"'

# ---------------------------------------------------------------------------------------------
case_dry_run_default() {
  dg_setup
  mk T1
  local before status; before="$(command cat "$R/.adlc/manifest.jsonl")"; status="$(git -C "$R" status --porcelain)"
  mkdir -p "$WORLD/tmp"
  OUT=""; RC=0
  OUT="$(cd "$R" && TMPDIR="$WORLD/tmp" "$BIN/desk-gates.sh" 2>"$WORLD/err")" || RC=$?
  check "exit 0" eq "$RC" 0
  check "spec-lint and coldstart are missing, planned, and pass now" \
    eq "$(rows)" '[["spec-lint","T1","missing","planned","pass"],["coldstart","T1","missing","planned","pass"]]'
  check "no reasons" eq "$(jq -sc 'map(.reasons)' <<<"$OUT")" '[[],[]]'
  check "the manifest is byte-identical" eq "$(command cat "$R/.adlc/manifest.jsonl")" "$before"
  check "the working tree is as it was" eq "$(git -C "$R" status --porcelain)" "$status"
  check "no record command ran" eq "$(jq -sc '[.[] | select(index("--record") or index("--record-verdict"))] | length' "$FAKE_ADLC_LOG")" 0
  check "its temp dir is removed" eq "$(ls -A "$WORLD/tmp")" ""
  dg --dry-run --json
  check "--dry-run --json: the same lines" eq "$(rows)" '[["spec-lint","T1","missing","planned","pass"],["coldstart","T1","missing","planned","pass"]]'
}

case_write_records() {
  dg_setup
  mk T1
  local n h sha; n="$(mf_n)"; h="$(thash T1)"; sha="$(rendered_sha "$BODY")"
  dg --write
  check "exit 0" eq "$RC" 0
  check "both recorded, pass" \
    eq "$(rows)" '[["spec-lint","T1","missing","recorded","pass"],["coldstart","T1","missing","recorded","pass"]]'
  check "two entries appended: spec-lint, then coldstart" eq "$(mf_new "$n" | jq -c 'map([.gate, .ticket])')" '[["spec-lint","T1"],["coldstart","T1"]]'
  check "spec-lint: verified, files = {T1.md: sha256 of the rendered body}" \
    eq "$(mf_new "$n" | jq -c '.[0] | {data, files}')" "{\"data\":{\"verified\":true},\"files\":{\"T1.md\":\"$sha\"}}"
  check "coldstart: the verdict on the current ticketHash, no gaps, offline" \
    eq "$(mf_new "$n" | jq -c '.[1].data.verdict | fromjson')" "{\"pass\":true,\"gaps\":[],\"ticketHash\":\"$h\",\"method\":\"offline\"}"
  check "the chain still verifies" eq "$(adlc gate-manifest verify --json | jq -c '[.valid, .count]')" "[true,$((n + 2))]"
  local before; before="$(command cat "$R/.adlc/manifest.jsonl")"
  dg --write
  check "a second --write: exit 0, both current, nothing to do" \
    eval '[ "$RC" = 0 ] && eq "$(rows)" "[[\"spec-lint\",$PASSING],[\"coldstart\",$PASSING]]"'
  check "the manifest is unchanged" eq "$(command cat "$R/.adlc/manifest.jsonl")" "$before"
  dg
  check "a dry-run after: both current, none" eq "$(rows)" "[[\"spec-lint\",$PASSING],[\"coldstart\",$PASSING]]"
}

case_stale_after_edit() {
  dg_setup
  mk T1
  dg --write
  local n h; n="$(mf_n)"
  edit T1 '.body |= sub("Add x\\."; "Add x and y.")'
  h="$(thash T1)"
  dg
  check "a body edit: both stale, planned, exit 0" \
    eval '[ "$RC" = 0 ] && eq "$(rows)" '"'"'[["spec-lint","T1","stale","planned","pass"],["coldstart","T1","stale","planned","pass"]]'"'"''
  check "the dry run wrote nothing" eq "$(mf_n)" "$n"
  dg --write
  check "--write re-records both" \
    eval '[ "$RC" = 0 ] && eq "$(rows)" '"'"'[["spec-lint","T1","stale","recorded","pass"],["coldstart","T1","stale","recorded","pass"]]'"'"''
  check "on the edited body and the new ticketHash" \
    eq "$(mf_new "$n" | jq -c '[.[0].files["T1.md"], (.[1].data.verdict | fromjson | .ticketHash)]')" \
       "[\"$(rendered_sha "${BODY/Add x./Add x and y.}")\",\"$h\"]"
  dg
  check "then both current" eq "$(rows)" "[[\"spec-lint\",$PASSING],[\"coldstart\",$PASSING]]"
  edit T1 '.title = "a new title"'
  dg
  check "a title edit: spec-lint current (same body), coldstart stale (new ticketHash)" \
    eq "$(rows)" '[["spec-lint","T1","current","none","pass"],["coldstart","T1","stale","planned","pass"]]'
}

case_spec_lint_fail() {
  dg_setup
  mk T1 $'weight: light\ntier: 0\ncharter: C6\n\nAdd x.'
  mk T2 $'weight: light\ntier: 0\ncharter: C6\n\nAdd x.\n\nAcceptance criteria:\n1. x exists.\n2. y exists. Verify: `test -f y`.'
  local n; n="$(mf_n)"
  dg
  check "dry-run: exit 2" eq "$RC" 2
  check "spec-lint fails on both, coldstart passes" \
    eq "$(rows)" '[["spec-lint","T1","missing","planned","fail"],["coldstart","T1","missing","planned","pass"],["spec-lint","T2","missing","planned","fail"],["coldstart","T2","missing","planned","pass"]]'
  check "no section: no acceptance criteria" eq "$(reasons spec-lint T1)" '["spec-lint: no acceptance criteria found"]'
  check "a criterion with no Verify: or backticks" eq "$(reasons spec-lint T2)" '["spec-lint: 1 criterion/criteria without a verification method"]'
  check "stderr names the failing checks" has "$ERR" "desk-gates: spec-lint T1, spec-lint T2 failed"
  dg --write
  check "--write: exit 2" eq "$RC" 2
  check "spec-lint failed (no record), coldstart recorded" \
    eq "$(rows)" '[["spec-lint","T1","missing","failed","fail"],["coldstart","T1","missing","recorded","pass"],["spec-lint","T2","missing","failed","fail"],["coldstart","T2","missing","recorded","pass"]]'
  check "the reasons are the same" eq "$(jq -sc '[.[] | select(.check == "spec-lint") | .reasons[]]' <<<"$OUT")" \
    '["spec-lint: no acceptance criteria found","spec-lint: 1 criterion/criteria without a verification method"]'
  check "no spec-lint entry appended, only the two coldstart ones" \
    eq "$(mf_new "$n" | jq -c 'map([.gate, .ticket])')" '[["coldstart","T1"],["coldstart","T2"]]'
}

case_coldstart_gaps() {
  dg_setup
  mk T1 "$BODY" '[]'
  local n; n="$(mf_n)"
  dg
  check "dry-run: exit 2, coldstart fails on the offline gap" \
    eval '[ "$RC" = 2 ] && eq "$(rows)" '"'"'[["spec-lint","T1","missing","planned","pass"],["coldstart","T1","missing","planned","fail"]]'"'"''
  check "the reason starts coldstart: " eq "$(reasons coldstart T1)" '["coldstart: missing scope"]'
  dg --write
  check "--write: exit 2, the verdict is recorded anyway" \
    eval '[ "$RC" = 2 ] && eq "$(rows)" '"'"'[["spec-lint","T1","missing","recorded","pass"],["coldstart","T1","missing","recorded","fail"]]'"'"''
  check "the recorded verdict: pass false, its gaps" \
    eq "$(mf_new "$n" | jq -c '.[] | select(.gate == "coldstart") | .data.verdict | fromjson | [.pass, .gaps, .ticketHash == $h, .method]' --arg h "$(thash T1)")" \
       '[false,[{"what":"missing scope"}],true,"offline"]'
  local before; before="$(command cat "$R/.adlc/manifest.jsonl")"
  dg --write
  check "a re-run: current and still failing until the desk edits (exit 2)" \
    eval '[ "$RC" = 2 ] && eq "$(rows)" '"'"'[["spec-lint","T1","current","none","pass"],["coldstart","T1","current","none","fail"]]'"'"''
  check "with the recorded gap as the reason" eq "$(reasons coldstart T1)" '["coldstart: missing scope"]'
  check "and nothing re-recorded" eq "$(command cat "$R/.adlc/manifest.jsonl")" "$before"
  dg
  check "dry-run: current, failing" eq "$(rows)" '[["spec-lint","T1","current","none","pass"],["coldstart","T1","current","none","fail"]]'
  edit T1 '.scope = ["README.md"]'
  dg --write
  check "the desk edits the scope: coldstart stale, re-recorded, passes" \
    eval '[ "$RC" = 0 ] && eq "$(rows)" '"'"'[["spec-lint","T1","current","none","pass"],["coldstart","T1","stale","recorded","pass"]]'"'"''

  # An edge to a ticket not in the store: the fake's create refuses one (EDGE_TARGET_NOT_FOUND), so the
  # parent's file is removed after the child is created.
  mk P1; mk T3 "$BODY" '["README.md"]' '[{"to":"P1"}]'
  rm "$(store_file P1)"
  dg --ticket T3
  check "an unknown edge target: coldstart fails with the gap and why" \
    eval '[ "$RC" = 2 ] && eq "$(reasons coldstart T3)" '"'"'["coldstart: unknown edge target (edge points to unknown ticket P1)"]'"'"''
}

case_completed_no_line() {
  dg_setup
  mk T1; mk T2
  adlc ticket complete T1 --write --authorize --allow-unsigned --json >/dev/null 2>&1
  check "the fake completed T1" eq "$(adlc ticket show T1 --json | jq .ticket.completed)" true
  dg --write
  check "only T2 gets lines" \
    eval '[ "$RC" = 0 ] && eq "$(rows)" '"'"'[["spec-lint","T2","missing","recorded","pass"],["coldstart","T2","missing","recorded","pass"]]'"'"''
  check "no warning without --ticket" eq "$ERR" ""
  local before; before="$(command cat "$R/.adlc/manifest.jsonl")"
  dg --write --ticket T1
  check "--ticket <completed>: exit 0, no line" eval '[ "$RC" = 0 ] && [ -z "$OUT" ]'
  check "and a warning on stderr" has "$ERR" "desk-gates: T1 is completed; no records are written for it"
  check "nothing written" eq "$(command cat "$R/.adlc/manifest.jsonl")" "$before"
}

case_ticket_filter() {
  dg_setup
  mk T1; mk T2
  local n; n="$(mf_n)"
  dg --write --ticket T2
  check "--ticket T2: only T2" \
    eval '[ "$RC" = 0 ] && eq "$(rows)" '"'"'[["spec-lint","T2","missing","recorded","pass"],["coldstart","T2","missing","recorded","pass"]]'"'"''
  check "only T2's records written" eq "$(mf_new "$n" | jq -c 'map([.gate, .ticket])')" '[["spec-lint","T2"],["coldstart","T2"]]'
  dg
  check "T1 is still missing" eq "$(rows)" \
    '[["spec-lint","T1","missing","planned","pass"],["coldstart","T1","missing","planned","pass"],["spec-lint","T2","current","none","pass"],["coldstart","T2","current","none","pass"]]'
  dg --ticket T1 --ticket T2
  check "two --ticket: both, in that order" eq "$(jq -sc 'map(.ticket)' <<<"$OUT")" '["T1","T1","T2","T2"]'
  n="$(mf_n)"
  dg --write --ticket T1 --ticket T1
  check "a repeated --ticket: one pass, recorded once" \
    eval '[ "$RC" = 0 ] && eq "$(jq -sc '"'"'map(.ticket)'"'"' <<<"$OUT")" '"'"'["T1","T1"]'"'"' && eq "$(mf_new "$n" | jq -c '"'"'map([.gate, .ticket])'"'"')" '"'"'[["spec-lint","T1"],["coldstart","T1"]]'"'"''
  dg --ticket nosuch
  check "--ticket nosuch: exit 1 naming it, no line" \
    eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "no ticket nosuch in the store"'
  dg --ticket a/b
  check "--ticket a/b: exit 1, a bad id" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "bad ticket id '"'"'a/b'"'"'"'
  dg --ticket -x
  check "--ticket -x: exit 1, a bad id" eval '[ "$RC" = 1 ] && has "$ERR" "bad ticket id '"'"'-x'"'"'"'
  dg --ticket
  check "--ticket with no id: exit 1" eval '[ "$RC" = 1 ] && has "$ERR" "--ticket needs an id"'
}

case_argument_errors() {
  dg_setup
  mk T1
  local before; before="$(command cat "$R/.adlc/manifest.jsonl")"
  : >"$FAKE_ADLC_LOG"
  dg --coldstart live
  check "--coldstart live without --write: exit 1" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "--coldstart live calls the LLM and records; it goes with --write"'
  dg --coldstart cheap
  check "--coldstart cheap: exit 1" eval '[ "$RC" = 1 ] && has "$ERR" "--coldstart is offline or live"'
  dg --check --ticket T1
  check "--check --ticket: exit 1" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "--check checks every open ticket; drop --ticket"'
  dg --base x
  check "--base without --check: exit 1" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "--base and --head go with --check"'
  dg --write --head HEAD
  check "--head without --check: exit 1" eval '[ "$RC" = 1 ] && has "$ERR" "--base and --head go with --check"'
  dg --check --base
  check "--base with no sha: exit 1" eval '[ "$RC" = 1 ] && has "$ERR" "--base needs a sha"'
  dg --bogus
  check "an unknown argument: exit 1 with the usage" \
    eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "unknown argument: --bogus" && has "$ERR" "desk-gates.sh --check [--base <sha>]"'
  dg --check --base "$BASE0" --head nosuch
  check "--check with a head that is not a commit: exit 1" eval '[ "$RC" = 1 ] && has "$ERR" "head nosuch is not a commit here"'
  dg --check --base nosuch
  check "--check with a base that is not a commit: exit 1" eval '[ "$RC" = 1 ] && has "$ERR" "base nosuch is not a commit here"'
  check "no adlc call on a usage error" eq "$(wc -l <"$FAKE_ADLC_LOG" | tr -d ' ')" 0
  check "nothing written" eq "$(command cat "$R/.adlc/manifest.jsonl")" "$before"
  RC=0; OUT="$(cd "$WORLD" && "$BIN/desk-gates.sh" 2>"$WORLD/err")" || RC=$?
  check "outside a git checkout: exit 1" eval '[ "$RC" = 1 ] && has "$(command cat "$WORLD/err")" "not inside a git checkout"'
}

CHECK_HEAD='["manifest-extends",null,null,"none","pass"],["manifest-verify",null,null,"none","pass"],["manifest-skipped",null,null,"none","pass"],["doctor",null,null,"none","pass"],["ticket-check",null,null,"none","pass"]'

case_check_no_adlc_path() {
  dg_setup
  echo 'more' >>"$R/README.md"; echo 'x' >"$R/x"; commit "code only"
  : >"$FAKE_ADLC_LOG"
  dg --check --base "$BASE0" --head HEAD
  check "exit 0, no JSON line" eval '[ "$RC" = 0 ] && [ -z "$OUT" ]'
  check "stderr: nothing for the desk gate" has "$ERR" "no .adlc/ path in $BASE0...$(rev HEAD); nothing for the desk gate"
  check "no adlc call" eq "$(wc -l <"$FAKE_ADLC_LOG" | tr -d ' ')" 0
}

case_check_desk_commit_passes() {
  dg_setup
  mk T1; mk T2 "$BODY" '["README.md"]' '[{"to":"T1"}]'
  dg --write; commit "desk: T1 T2 and their records"
  : >"$FAKE_ADLC_LOG"
  dg --check --base "$BASE0" --head HEAD --json
  check "exit 0" eq "$RC" 0
  check "every check passes; each ticket the PR adds is current, none" \
    eq "$(rows)" "[$CHECK_HEAD,[\"spec-lint\",$PASSING],[\"coldstart\",$PASSING],[\"spec-lint\",\"T2\",\"current\",\"none\",\"pass\"],[\"coldstart\",\"T2\",\"current\",\"none\",\"pass\"]]"
  check "no reasons anywhere" eq "$(jq -sc '[.[].reasons[]]' <<<"$OUT")" '[]'
  check "stderr counts the .adlc/ paths" has "$ERR" "desk-gates: 3 .adlc/ path(s) changed; the desk gate runs on the head's store"
  check "--check writes nothing" eq "$(git -C "$R" status --porcelain)" ""
  check "--check never records" eq "$(jq -sc '[.[] | select(index("--record") or index("--record-verdict") or index("--write"))] | length' "$FAKE_ADLC_LOG")" 0
}

case_check_untouched_ticket() {
  # An open ticket on the base without records (the desk keeps it unclaimable) is not the PR's.
  dg_setup
  mk T1; commit "desk: T1, kept without records"
  local base; base="$(rev HEAD)"
  mk T2; dg --write --ticket T2; commit "desk: T2 and its records"
  dg --check --base "$base" --head HEAD
  check "exit 0" eq "$RC" 0
  check "only T2's record lines; no T1 line" \
    eq "$(rows)" "[$CHECK_HEAD,[\"spec-lint\",\"T2\",\"current\",\"none\",\"pass\"],[\"coldstart\",\"T2\",\"current\",\"none\",\"pass\"]]"
  check "T1 still has no record (a dry-run says missing)" \
    eval 'dg --ticket T1; eq "$(rows)" '"'"'[["spec-lint","T1","missing","planned","pass"],["coldstart","T1","missing","planned","pass"]]'"'"''
  # A PR that touches .adlc/ but no ticket file: the store checks only.
  git -C "$R" checkout -q -b note "$base"
  mkdir -p "$R/.adlc/specs"; echo 'a note' >"$R/.adlc/specs/note.md"; commit "desk: a note"
  dg --check --base "$base" --head HEAD
  check "no ticket touched: exit 0, the five store lines only" eval '[ "$RC" = 0 ] && eq "$(rows)" "[$CHECK_HEAD]"'
  check "stderr: no records to check" has "$ERR" "desk-gates: the PR adds or changes no ticket; no records to check"
}

case_check_edge_to_parent() {
  # Adding an edge changes the parent's file: the parent's ticketHash moves, so its coldstart record
  # goes stale and the PR must carry a fresh one.
  dg_setup
  mk T1; dg --write; commit "desk: T1 and its records"
  local base; base="$(rev HEAD)"
  mk T2; edit T1 '.edges = [{"to": "T2"}]'
  dg --write --ticket T2; commit "desk: T2, T1 -> T2, only T2's records"
  dg --check --base "$base" --head HEAD
  check "exit 2" eq "$RC" 2
  check "T1 is the PR's: spec-lint current (same body), coldstart stale" \
    eq "$(rows)" "[$CHECK_HEAD,[\"spec-lint\",$PASSING],[\"coldstart\",\"T1\",\"stale\",\"none\",\"fail\"],[\"spec-lint\",\"T2\",\"current\",\"none\",\"pass\"],[\"coldstart\",\"T2\",\"current\",\"none\",\"pass\"]]"
  check "the reason: stale record" eq "$(reasons coldstart T1)" '["coldstart: stale record (the desk runs factory/bin/desk-gates.sh --write)"]'
  check "stderr names it" has "$ERR" "desk-gates: coldstart T1 failed"
  dg --write; commit "desk: T1's record"
  dg --check --base "$base" --head HEAD
  check "after --write: exit 0, all current" \
    eval '[ "$RC" = 0 ] && eq "$(jq -sc '"'"'[.[] | select(.ticket) | [.ticket, .state, .result]] | unique'"'"' <<<"$OUT")" '"'"'[["T1","current","pass"],["T2","current","pass"]]'"'"''
}

case_check_missing_records() {
  dg_setup
  mk T1; commit "desk: T1 without records"
  dg --check --base "$BASE0" --head HEAD
  check "exit 2" eq "$RC" 2
  check "the store checks pass; spec-lint and coldstart fail, missing" \
    eq "$(rows)" "[$CHECK_HEAD,[\"spec-lint\",\"T1\",\"missing\",\"none\",\"fail\"],[\"coldstart\",\"T1\",\"missing\",\"none\",\"fail\"]]"
  check "spec-lint: missing record" eq "$(reasons spec-lint T1)" '["spec-lint: missing record (the desk runs factory/bin/desk-gates.sh --write)"]'
  check "coldstart: missing record" eq "$(reasons coldstart T1)" '["coldstart: missing record (the desk runs factory/bin/desk-gates.sh --write)"]'
  check "stderr names the failing checks" has "$ERR" "desk-gates: spec-lint T1, coldstart T1 failed"
  # stale records fail --check the same way
  dg --write; edit T1 '.body |= sub("Add x\\."; "Add z.")'; commit "desk: records, then an edit"
  dg --check --base "$BASE0" --head HEAD
  check "an edit after the records: exit 2, both stale" \
    eval '[ "$RC" = 2 ] && eq "$(jq -sc '"'"'[.[] | select(.ticket) | [.check, .state, .result, .reasons[0]]]'"'"' <<<"$OUT")" '"'"'[["spec-lint","stale","fail","spec-lint: stale record (the desk runs factory/bin/desk-gates.sh --write)"],["coldstart","stale","fail","coldstart: stale record (the desk runs factory/bin/desk-gates.sh --write)"]]'"'"''
  # a current coldstart record with gaps fails --check too
  edit T1 '.scope = []'; dg --write; commit "desk: a scope-less ticket with its records"
  dg --check --base "$BASE0" --head HEAD
  check "a current record with gaps: exit 2, coldstart current, fail" \
    eval '[ "$RC" = 2 ] && eq "$(jq -sc '"'"'[.[] | select(.check == "coldstart") | [.state, .result]]'"'"' <<<"$OUT")" '"'"'[["current","fail"]]'"'"''
  check "and the reason is the gap, once (the record's and CI's re-run agree)" eq "$(reasons coldstart T1)" '["coldstart: missing scope"]'
}

case_check_chain_race() {
  dg_setup
  mk T0; dg --write; commit "desk: T0"
  local b one two n
  b="$(rev HEAD)"; n="$(mf_n)"
  git -C "$R" checkout -q -b one "$b"
  mk TA; dg --write; commit "desk: TA"; one="$(rev HEAD)"
  git -C "$R" checkout -q -b two "$b"
  mk TC; dg --write; commit "desk: TC"; two="$(rev HEAD)"
  git -C "$R" checkout -q -b joined "$one"
  git -C "$R" checkout "$two" -- .adlc/tickets
  git -C "$R" show "$two:.adlc/manifest.jsonl" | tail -n "+$((n + 1))" >>"$R/.adlc/manifest.jsonl"
  commit "joined by hand"
  check "the joined manifest holds both branches' lines" eq "$(mf_n)" "$((n + 6))"
  dg --check --base "$b" --head HEAD
  check "exit 2" eq "$RC" 2
  check "extends passes (only appended); verify and doctor fail; the PR's tickets' records are current (T0 is not the PR's)" \
    eq "$(rows)" '[["manifest-extends",null,null,"none","pass"],["manifest-verify",null,null,"none","fail"],["manifest-skipped",null,null,"none","pass"],["doctor",null,null,"none","fail"],["ticket-check",null,null,"none","pass"],["spec-lint","TA","current","none","pass"],["coldstart","TA","current","none","pass"],["spec-lint","TC","current","none","pass"],["coldstart","TC","current","none","pass"]]'
  check "manifest-verify: chain broken" has "$(reasons manifest-verify)" "chain broken at seq $((n + 1)) (line $((n + 4))): seq mismatch"
  check "doctor names store:storehash-manifest-bind" eq "$(reasons doctor)" '["store:storehash-manifest-bind: MANIFEST_CHAIN_INVALID"]'
  check "stderr names both" has "$ERR" "desk-gates: manifest-verify, doctor failed"
}

case_check_stale_base() {
  dg_setup
  mk T0; dg --write; commit "desk: T0"
  local old; old="$(rev HEAD)"
  mk T1; dg --write; commit "desk: T1 (main moved on)"
  local base; base="$(rev HEAD)"
  git -C "$R" checkout -q -b stale "$old"
  mkdir -p "$R/.adlc/specs"; echo 'a note' >"$R/.adlc/specs/note.md"; commit "desk: a note, cut from the old main"
  dg --check --base "$base" --head HEAD
  check "exit 2" eq "$RC" 2
  check "manifest-extends fails; the rest pass; no ticket touched, no record line" \
    eq "$(rows)" '[["manifest-extends",null,null,"none","fail"],["manifest-verify",null,null,"none","pass"],["manifest-skipped",null,null,"none","pass"],["doctor",null,null,"none","pass"],["ticket-check",null,null,"none","pass"]]'
  check "the reason: does not extend the base's bytes" \
    has "$(reasons manifest-extends)" ".adlc/manifest.jsonl: the head does not extend the base's $(git -C "$R" cat-file -s "$base:.adlc/manifest.jsonl") bytes (rebase the desk PR onto main"
  check "stderr names it" has "$ERR" "desk-gates: manifest-extends failed"
}

case_check_rewrite_manifest() {
  dg_setup
  mk T1; dg --write; commit "desk: T1"
  local base; base="$(rev HEAD)"
  git -C "$R" checkout -q -b drop "$base"
  sed -i '$d' "$R/.adlc/manifest.jsonl"; commit "drop the last manifest line"
  dg --check --base "$base" --head HEAD
  check "a dropped line: exit 2, manifest-extends fails" \
    eval '[ "$RC" = 2 ] && eq "$(jq -sc '"'"'[.[0].check, .[0].result]'"'"' <<<"$OUT")" '"'"'["manifest-extends","fail"]'"'"' && has "$(reasons manifest-extends)" "does not extend"'
  git -C "$R" checkout -q -b rewrite "$base"
  local tmp; tmp="$(mktemp)"
  jq -c 'if .seq == 1 then .data.operation = "forged" else . end' "$R/.adlc/manifest.jsonl" >"$tmp" && mv "$tmp" "$R/.adlc/manifest.jsonl"
  commit "rewrite the first manifest line"
  dg --check --base "$base" --head HEAD
  check "a rewritten line: exit 2, manifest-extends fails" \
    eval '[ "$RC" = 2 ] && eq "$(jq -sc '"'"'[.[0].check, .[0].result]'"'"' <<<"$OUT")" '"'"'["manifest-extends","fail"]'"'"' && has "$(reasons manifest-extends)" "does not extend"'
  git -C "$R" checkout -q -b gone "$base"
  git -C "$R" rm -q .adlc/manifest.jsonl; commit "delete the manifest"
  dg --check --base "$base" --head HEAD
  check "a deleted manifest: exit 2, manifest-extends fails, deleted" \
    eval '[ "$RC" = 2 ] && eq "$(reasons manifest-extends)" '"'"'[".adlc/manifest.jsonl: deleted"]'"'"''
}

case_check_ticket_check_fails() {
  dg_setup
  mk T1 "$BODY" '["nosuch/**"]'; dg --write; commit "desk: T1 with a scope that matches nothing"
  dg --check --base "$BASE0" --head HEAD
  check "exit 2" eq "$RC" 2
  check "ticket-check fails; the records pass" \
    eq "$(rows)" '[["manifest-extends",null,null,"none","pass"],["manifest-verify",null,null,"none","pass"],["manifest-skipped",null,null,"none","pass"],["doctor",null,null,"none","pass"],["ticket-check",null,null,"none","fail"],["spec-lint","T1","current","none","pass"],["coldstart","T1","current","none","pass"]]'
  check "the reason names the ticket, the glob and the forecast warning" \
    eq "$(reasons ticket-check)" "[\"T1: scope: 'nosuch/**' matches no path and no declared new path (a \`New paths:\` line of this ticket or a parent); forecast: ticket \\\"T1\\\" scope matches 0 files in repo\"]"
  check "stderr names it" has "$ERR" "desk-gates: ticket-check failed"
}

case_check_doctor_fails() {
  # adlc ticket doctor's own checks: here the archive carries the ticket directory's format marker
  # (a fault the sim world had, which only real adlc caught).
  dg_setup
  mkdir -p "$R/.adlc/ticket-archive"
  printf '{"format":"adlc-ticket-directory","version":1}\n' >"$R/.adlc/ticket-archive/.store.json"
  mk T1; dg --write; commit "desk: T1, and an archive with the wrong marker"
  dg --check --base "$BASE0" --head HEAD
  check "exit 2: doctor fails naming store:archive" \
    eval '[ "$RC" = 2 ] && eq "$(reasons doctor)" '"'"'["store:archive: unsupported ticket store manifest (expected format version 1)"]'"'"''
  check "stderr names doctor" has "$ERR" "desk-gates: doctor failed"
}

case_check_merge_base() {
  dg_setup
  mk T1; dg --write; commit "desk: T1"
  git -C "$R" update-ref refs/remotes/origin/main "$BASE0"
  dg --check
  check "no --base: the merge-base with origin/main; every check passes" \
    eval '[ "$RC" = 0 ] && eq "$(rows)" "[$CHECK_HEAD,[\"spec-lint\",$PASSING],[\"coldstart\",$PASSING]]"'
  git -C "$R" update-ref refs/remotes/origin/main HEAD
  dg --check
  check "origin/main at the head: no .adlc/ path, exit 0" eval '[ "$RC" = 0 ] && [ -z "$OUT" ] && has "$ERR" "nothing for the desk gate"'
  git -C "$R" update-ref -d refs/remotes/origin/main
  dg --check
  check "no origin/main: exit 1 asking for --base" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "(pass --base)"'
  # adlc reads the checkout's store: a --head other than the checkout, or uncommitted .adlc/ edits, refuse.
  dg --check --base "$BASE0" --head "$BASE0"
  check "--head is not the checkout: exit 1, no line" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "the checkout is not the head"'
  edit T1 '.title = "edited, not committed"'
  dg --check --base "$BASE0" --head HEAD
  check "uncommitted .adlc/ edits: exit 1, no line" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "uncommitted changes under .adlc/"'
}

case_read_failures() {
  dg_setup
  mk T1
  FAKE_ADLC_FAIL='ticket list' dg
  check "a failed ticket list: exit 1, no line" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "desk-gates: adlc ticket list failed"'
  FAKE_ADLC_FAIL='gate-manifest show' dg --write
  check "a failed gate-manifest show: exit 1, no line" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "adlc gate-manifest show failed"'
  FAKE_ADLC_FAIL='ticket show' dg
  check "a failed ticket show: exit 1, no line" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "adlc ticket show T1 failed"'
  FAKE_ADLC_FAIL='^spec-lint' dg
  check "a failed spec-lint: exit 1, no line" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "adlc spec-lint T1 failed (exit 1)"'
  FAKE_ADLC_FAIL='coldstart T1 --offline' dg
  check "a failed coldstart --offline: exit 1, no coldstart line" \
    eval '[ "$RC" = 1 ] && eq "$(rows)" '"'"'[["spec-lint","T1","missing","planned","pass"]]'"'"' && has "$ERR" "adlc coldstart T1 --offline failed (exit 1)"'
  local n; n="$(mf_n)"
  FAKE_ADLC_FAIL='record-verdict' dg --write
  check "a failed --record-verdict: exit 1, no coldstart line" \
    eval '[ "$RC" = 1 ] && eq "$(rows)" '"'"'[["spec-lint","T1","missing","recorded","pass"]]'"'"' && has "$ERR" "adlc coldstart T1 --record-verdict failed"'
  check "no coldstart entry written" eq "$(mf_new "$n" | jq -c 'map(.gate)')" '["spec-lint"]'
  dg --write; commit "desk: T1"
  FAKE_ADLC_FAIL='gate-manifest verify' dg --check --base "$BASE0" --head HEAD
  check "--check, a failed verify: exit 1, no manifest-verify line" \
    eval '[ "$RC" = 1 ] && eq "$(jq -sc '"'"'map(.check)'"'"' <<<"$OUT")" '"'"'["manifest-extends"]'"'"' && has "$ERR" "adlc gate-manifest verify failed (exit 1)"'
  FAKE_ADLC_FAIL='ticket doctor' dg --check --base "$BASE0" --head HEAD
  check "--check, a failed doctor: exit 1, no doctor line" \
    eval '[ "$RC" = 1 ] && lacks "$OUT" "\"doctor\"" && has "$ERR" "adlc ticket doctor failed (exit 1)"'
  FAKE_ADLC_FAIL='merge-forecast' dg --check --base "$BASE0" --head HEAD
  check "--check, ticket-check cannot read: exit 1, no ticket-check line" \
    eval '[ "$RC" = 1 ] && lacks "$OUT" "\"ticket-check\"" && has "$ERR" "ticket-check.sh failed (exit 1)"'
}

for c in dry-run-default write-records stale-after-edit spec-lint-fail coldstart-gaps completed-no-line \
         ticket-filter argument-errors check-no-adlc-path check-desk-commit-passes check-untouched-ticket check-edge-to-parent check-missing-records \
         check-chain-race check-stale-base check-rewrite-manifest check-ticket-check-fails check-doctor-fails check-merge-base \
         read-failures; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
