#!/usr/bin/env bash
# T30 (specs/factory-step3-v1 TB11, acceptance 2): factory/bin/flaky-check.sh, the quarantine expiry
# gate, and gates.yml's `flaky` job.
#   - --file: an empty list passes; a live entry (expires today or later) passes and is named; an
#     expired one fails (exit 2) naming test, issue and date; live through 23:59:59 UTC of its expiry
#     day, expired at 00:00:00 the next (FACTORY_NOW pins the clock);
#   - every malformed entry fails (exit 2), each on its own; every unusable list (an empty file too)
#     exits 1, never 0;
#   - --json prints {today, file, live, expired, malformed};
#   - --base/--head: the base's file unless BASE...HEAD changes it, then the head's; a head that
#     deletes it, --base without --head, --base with --file: exit 1;
#   - no flags: the repo's own list beside the script, which passes today;
#   - gates.yml: `flaky` runs the base's script on GATE_BASE/GATE_HEAD, no `if:`, no `needs:`, pinned
#     actions; the desk note's branch protection requires `flaky`.
# Offline; every list and repo is a temp dir.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
FC="$BIN/flaky-check.sh"
GATES="$REPO_ROOT/.github/workflows/gates.yml"
DESK_BP="$REPO_ROOT/tests/sim/desk/factory/policy/branch-protection.json"
QPATH=factory/policy/quarantine.json

epoch() { jq -n --arg d "$1" '$d | fromdateiso8601'; }
NOON="$(epoch 2026-10-27T12:00:00Z)"      # "today" is 2026-10-27 for every case but the boundary
LAST="$(epoch 2026-10-27T23:59:59Z)"
NEXT="$(epoch 2026-10-28T00:00:00Z)"

setup() {
  WORLD="$(mktemp -d "${TMPDIR:-/tmp}/flakycheck.XXXXXX")"
  # shellcheck disable=SC2064  # expand now: WORLD is per case
  trap "rm -rf '$WORLD'" EXIT
  CWD="$WORLD"
  export FACTORY_NOW="$NOON"
}
# qlist <file> <entry-json>...: a quarantine list holding the entries
qlist() { local f="$1"; shift; jq -n '{quarantined: [$ARGS.positional[] | fromjson]}' --args "$@" >"$f"; }
ent() { jq -nc --arg t "$1" --argjson i "$2" --arg e "$3" '{test: $t, issue: $i, expires: $e}'; }
# fc [flags]: run flaky-check in CWD; OUT (stdout), ERR (stderr), RC
fc() {
  RC=0
  OUT="$(cd "$CWD" && "$FC" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
has() { [[ "$1" == *"$2"* ]] || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }
lacks() { [[ "$1" != *"$2"* ]] || { printf '      [%s] has [%s]\n' "$1" "$2"; return 1; }; }
jqeq() { eq "$(jq -cS . <<<"$1")" "$(jq -cS . <<<"$2")"; }

case_file_expiry() {
  setup
  qlist "$WORLD/q.json"
  fc --file "$WORLD/q.json"
  check "an empty quarantined list: exit 0" eq "$RC" 0
  check "  stderr: pass, 0 live entries" has "$ERR" "flaky-check: pass: 0 live entries, none expired, on 2026-10-27"
  qlist "$WORLD/q.json" "$(ent tests/a.sh 11 2026-10-27)"
  fc --file "$WORLD/q.json"
  check "an entry expiring today is live: exit 0" eq "$RC" 0
  check "  stderr names it" has "$ERR" "flaky-check: quarantined until 2026-10-27: tests/a.sh (issue #11)"
  check "  stderr: pass, 1 live entry" has "$ERR" "flaky-check: pass: 1 live entry, none expired"
  qlist "$WORLD/q.json" "$(ent tests/b.sh 12 2027-01-15)"
  fc --file "$WORLD/q.json"
  check "an entry expiring in the future is live: exit 0" eq "$RC" 0
  check "  stderr names it" has "$ERR" "flaky-check: quarantined until 2027-01-15: tests/b.sh (issue #12)"
  qlist "$WORLD/q.json" "$(ent tests/c.sh 13 2026-10-26)"
  fc --file "$WORLD/q.json"
  check "an entry that expired yesterday: exit 2" eq "$RC" 2
  check "  stderr: FAIL, the file and today" has "$ERR" "flaky-check: FAIL: $WORLD/q.json on 2026-10-27:"
  check "  stderr names test, issue and date" has "$ERR" "  expired 2026-10-26: tests/c.sh (issue #13)"
  check "  stderr: no pass line" lacks "$ERR" "flaky-check: pass:"
  # One expired among live ones still fails, and the live ones are still named.
  qlist "$WORLD/q.json" "$(ent tests/a.sh 11 2026-10-27)" "$(ent tests/c.sh 13 2026-10-26)"
  fc --file "$WORLD/q.json"
  check "one live + one expired: exit 2, the live one named, the expired one listed" \
    eq "$RC:$(has "$ERR" "quarantined until 2026-10-27: tests/a.sh" && has "$ERR" "expired 2026-10-26: tests/c.sh" && echo both)" 2:both
}

case_boundary() {
  setup
  qlist "$WORLD/q.json" "$(ent tests/edge.sh 7 2026-10-27)"
  FACTORY_NOW="$LAST" fc --file "$WORLD/q.json"
  check "FACTORY_NOW = 23:59:59 UTC on the expiry day: live, exit 0" eq "$RC" 0
  check "  today is the expiry day" has "$ERR" "on 2026-10-27"
  FACTORY_NOW="$NEXT" fc --file "$WORLD/q.json"
  check "FACTORY_NOW = 00:00:00 UTC the next day: expired, exit 2" eq "$RC" 2
  check "  today is the day after; the entry is named" has "$ERR" "FAIL: $WORLD/q.json on 2026-10-28:"
  check "  ... expired 2026-10-27: tests/edge.sh (issue #7)" has "$ERR" "expired 2026-10-27: tests/edge.sh (issue #7)"
}

case_malformed() {
  setup
  local name e
  while IFS='|' read -r name e; do
    printf '{"quarantined":[%s]}\n' "$e" >"$WORLD/q.json"
    fc --file "$WORLD/q.json" --json
    check "malformed ($name): exit 2" eq "$RC" 2
    check "  reported as malformed entry #0, not live or expired" \
      eq "$(jq -c '[(.malformed | length), (.malformed[0].index), (.live | length), (.expired | length)]' <<<"$OUT")" '[1,0,0,0]'
    check "  stderr: malformed entry #0" has "$ERR" "  malformed entry #0: "
  done <<'EOF'
missing test|{"issue":1,"expires":"2027-01-01"}
empty test|{"test":"","issue":1,"expires":"2027-01-01"}
test not a string|{"test":5,"issue":1,"expires":"2027-01-01"}
missing issue|{"test":"t","expires":"2027-01-01"}
issue 0|{"test":"t","issue":0,"expires":"2027-01-01"}
issue negative|{"test":"t","issue":-3,"expires":"2027-01-01"}
issue non-integer|{"test":"t","issue":1.5,"expires":"2027-01-01"}
issue a string|{"test":"t","issue":"12","expires":"2027-01-01"}
missing expires|{"test":"t","issue":1}
expires not YYYY-MM-DD (27/01/2027)|{"test":"t","issue":1,"expires":"27/01/2027"}
expires with a time|{"test":"t","issue":1,"expires":"2027-01-01T00:00:00Z"}
expires a number|{"test":"t","issue":1,"expires":20270101}
expires an impossible date 2026-02-30|{"test":"t","issue":1,"expires":"2026-02-30"}
expires month 13|{"test":"t","issue":1,"expires":"2027-13-01"}
a non-object entry (string)|"tests/x.sh"
a non-object entry (array)|["tests/x.sh",1,"2027-01-01"]
a non-object entry (null)|null
EOF
  # A malformed entry beside a live one still fails, and the live one still reads as live.
  printf '{"quarantined":[{"test":"t","issue":1,"expires":"2027-01-01"},{"test":"u","issue":0,"expires":"2027-01-01"}]}\n' >"$WORLD/q.json"
  fc --file "$WORLD/q.json" --json
  check "live + malformed: exit 2, malformed #1, live [t]" \
    eq "$RC:$(jq -c '[.malformed[0].index, [.live[].test]]' <<<"$OUT")" '2:[1,["t"]]'
  # Sanity: a leap day that exists is well-formed.
  qlist "$WORLD/q.json" "$(ent t 1 2028-02-29)"
  fc --file "$WORLD/q.json"
  check "sanity: 2028-02-29 is a real date, live, exit 0" eq "$RC" 0
}

case_unusable() {
  setup
  fc --file "$WORLD/nope.json"
  check "a missing file: exit 1" eq "$RC" 1
  check "  stderr says so" has "$ERR" "no quarantine list at $WORLD/nope.json"
  printf '{"quarantined": [' >"$WORLD/q.json"
  fc --file "$WORLD/q.json"
  check "not JSON: exit 1" eq "$RC" 1
  check "  stderr says so" has "$ERR" "is not JSON with a \`quarantined\` array"
  : >"$WORLD/q.json"
  fc --file "$WORLD/q.json"
  check "an empty file: exit 1, never a pass" eq "$RC:$(lacks "$ERR" "flaky-check: pass:" >/dev/null && echo nopass)" 1:nopass
  check "  stderr says so" has "$ERR" "is empty, not JSON with a \`quarantined\` array"
  printf '{"_comment": "x"}\n' >"$WORLD/q.json"
  fc --file "$WORLD/q.json"
  check "JSON without a quarantined key: exit 1" eq "$RC" 1
  printf '[]\n' >"$WORLD/q.json"
  fc --file "$WORLD/q.json"
  check "a top-level array: exit 1" eq "$RC" 1
  local v
  for v in '{}' 'null' '"tests/a.sh"' '5'; do
    printf '{"quarantined": %s}\n' "$v" >"$WORLD/q.json"
    fc --file "$WORLD/q.json"
    check "quarantined = $v (not an array): exit 1" eq "$RC" 1
  done
  fc --file
  check "--file with no value: exit 1 (usage)" eq "$RC" 1
  fc --bogus
  check "an unknown flag: exit 1" eq "$RC" 1
}

case_json() {
  setup
  qlist "$WORLD/q.json" "$(ent tests/live.sh 21 2026-12-01)" "$(ent tests/old.sh 22 2026-10-01)" \
    '{"test":"tests/bad.sh","issue":0,"expires":"2026-12-01"}' "$(ent tests/today.sh 23 2026-10-27)"
  fc --file "$WORLD/q.json" --json
  check "exit 2 (one expired, one malformed)" eq "$RC" 2
  check "stdout is exactly {today, file, live, expired, malformed}" jqeq "$OUT" "$(jq -n --arg f "$WORLD/q.json" '{
    today: "2026-10-27", file: $f,
    live: [{test: "tests/live.sh", issue: 21, expires: "2026-12-01"}, {test: "tests/today.sh", issue: 23, expires: "2026-10-27"}],
    expired: [{test: "tests/old.sh", issue: 22, expires: "2026-10-01"}],
    malformed: [{index: 2, entry: {test: "tests/bad.sh", issue: 0, expires: "2026-12-01"}}]}')"
  check "stdout is one line of JSON" eq "$(wc -l <<<"$OUT" | tr -d ' ')" 1
  qlist "$WORLD/q.json" "$(ent tests/live.sh 21 2026-12-01)"
  fc --file "$WORLD/q.json" --json
  check "a passing list: exit 0, live [tests/live.sh], expired and malformed empty" \
    eq "$RC:$(jq -c '[.today, [.live[].test], .expired, .malformed]' <<<"$OUT")" '0:["2026-10-27",["tests/live.sh"],[],[]]'
  fc --file "$WORLD/q.json"
  check "without --json: stdout empty" eq "$OUT" ""
}

# A repo R: ROOT has $QPATH with an expired entry (and a README); branches are built from it.
repo_setup() {
  setup
  R="$WORLD/r"; CWD="$R"
  git init -q -b main "$R"
  git -C "$R" config user.name t; git -C "$R" config user.email t@t.invalid
  mkdir -p "$R/factory/policy"; echo base >"$R/README.md"
  qlist "$R/$QPATH" "$(ent tests/stale.sh 31 2026-10-01)"
  git -C "$R" add -A; git -C "$R" commit -qm root
  BASE="$(git -C "$R" rev-parse HEAD)"
}
# branch <name>: a branch from BASE, checked out; commit_all <msg>: commit everything, print the sha
branch() { git -C "$R" checkout -q -B "$1" "$BASE"; }
commit_all() { git -C "$R" add -A; git -C "$R" commit -qm "$1"; git -C "$R" rev-parse HEAD; }

case_base_head() {
  repo_setup
  local h
  branch unrelated; echo more >>"$R/README.md"; h="$(commit_all unrelated)"
  fc --base "$BASE" --head "$h" --json
  check "head does not touch the list: the base's expired entry fails (exit 2)" eq "$RC" 2
  check "  the file read is BASE:$QPATH" eq "$(jq -r .file <<<"$OUT")" "$BASE:$QPATH"
  check "  stderr names the expired entry" has "$ERR" "expired 2026-10-01: tests/stale.sh (issue #31)"
  # The head's work tree holding a fixed list without committing it changes nothing: commits are read.
  qlist "$R/$QPATH"
  fc --base "$BASE" --head "$h"
  check "  an uncommitted fix in the work tree is not read (still exit 2)" eq "$RC" 2
  git -C "$R" checkout -q -- "$QPATH"

  branch drop; qlist "$R/$QPATH"; h="$(commit_all "drop the stale entry")"
  fc --base "$BASE" --head "$h" --json
  check "a head that drops the expired entry: the head's file, exit 0" eq "$RC:$(jq -r .file <<<"$OUT")" "0:$h:$QPATH"

  branch renew; qlist "$R/$QPATH" "$(ent tests/stale.sh 31 2026-11-30)"; h="$(commit_all "renew")"
  fc --base "$BASE" --head "$h"
  check "a head that renews it: exit 0, named live" eq "$RC:$(has "$ERR" "quarantined until 2026-11-30: tests/stale.sh" && echo named)" 0:named

  # A clean base, then a head that adds an expired entry.
  branch main; qlist "$R/$QPATH"; local clean; clean="$(commit_all "clean list")"
  fc --base "$clean" --head "$clean"
  check "sanity: the clean base on its own passes" eq "$RC" 0
  git -C "$R" checkout -q -B adds "$clean"
  qlist "$R/$QPATH" "$(ent tests/new.sh 32 2026-10-20)"; h="$(commit_all "add an expired entry")"
  fc --base "$clean" --head "$h" --json
  check "a head that adds an expired entry: the head's file, exit 2" eq "$RC:$(jq -r .file <<<"$OUT")" "2:$h:$QPATH"
  check "  stderr names it" has "$ERR" "expired 2026-10-20: tests/new.sh (issue #32)"

  git -C "$R" checkout -q -B deletes "$clean"; git -C "$R" rm -q "$QPATH"; h="$(commit_all "delete the list")"
  fc --base "$clean" --head "$h"
  check "a head that deletes the list: exit 1 (unusable, never a pass)" eq "$RC" 1
  check "  stderr: no $QPATH at the head" has "$ERR" "no $QPATH at ${h:0:12}"
}

case_flag_combos() {
  repo_setup
  qlist "$WORLD/q.json"
  fc --base "$BASE"
  check "--base without --head: exit 1" eq "$RC" 1
  check "  stderr says they go together" has "$ERR" "--base and --head go together, and never with --file"
  fc --head "$BASE"
  check "--head without --base: exit 1" eq "$RC" 1
  fc --base "$BASE" --file "$WORLD/q.json"
  check "--base with --file: exit 1" eq "$RC" 1
  fc --base "$BASE" --head "$BASE" --file "$WORLD/q.json"
  check "--base --head with --file: exit 1" eq "$RC" 1
  fc --base deadbeef --head "$BASE"
  check "a base that is not a commit: exit 1" eq "$RC" 1
}

case_default_list() {
  setup
  unset FACTORY_NOW
  CWD="$WORLD"   # not the repo: the list is found beside the script, not in the cwd
  fc --json
  check "no flags, the real clock: the repo's own list passes (exit 0)" eq "$RC" 0
  check "  the file read is $QPATH beside the script" eq "$(jq -r .file <<<"$OUT")" "$REPO_ROOT/$QPATH"
  check "  nothing expired or malformed" eq "$(jq -c '[.expired, .malformed]' <<<"$OUT")" '[[],[]]'
  check "  today is the real UTC date" eq "$(jq -r .today <<<"$OUT")" "$(date -u +%Y-%m-%d)"
}

case_gates_yml() {
  setup
  local j job
  j="$(yq -o=json '.' "$GATES")"; job="$(jq -c '.jobs.flaky' <<<"$j")"
  check "gates.yml has a job flaky" eq "$(jq '.jobs | has("flaky")' <<<"$j")" true
  check "  no job-level if:" eq "$(jq 'has("if")' <<<"$job")" false
  check "  no needs:" eq "$(jq 'has("needs")' <<<"$job")" false
  check "  a hosted runner (ubuntu-latest)" eq "$(jq -r '."runs-on"' <<<"$job")" ubuntu-latest
  check "  a checkout of env.GATE_HEAD with fetch-depth 0, at the work tree root" eq "$(jq '[.steps[]
    | select((.uses // "") | test("^actions/checkout@")) | select(.with.path == null and .with["fetch-depth"] == 0
    and (.with.ref | test("^\\$\\{\\{ *env\\.GATE_HEAD *\\}\\}$")))] | length' <<<"$job")" 1
  check "  a checkout of env.GATE_BASE into .base" eq "$(jq '[.steps[]
    | select((.uses // "") | test("^actions/checkout@")) | select(.with.path == ".base"
    and (.with.ref | test("^\\$\\{\\{ *env\\.GATE_BASE *\\}\\}$")))] | length' <<<"$job")" 1
  check "  every action is pinned by a 40-hex sha" eq "$(jq '[.steps[] | select(.uses != null)
    | select(.uses | test("^[^@]+@[0-9a-f]{40}$") | not)] | length' <<<"$job")" 0
  check "  the one run step is the base's flaky-check on GATE_BASE/GATE_HEAD" \
    eq "$(jq -c '[.steps[] | select(.run != null) | .run | sub("\\s+$"; "")]' <<<"$job")" \
    "$(jq -nc '["./.base/factory/bin/flaky-check.sh --base \"$GATE_BASE\" --head \"$GATE_HEAD\""]')"
  check "  the workflow env defines GATE_BASE and GATE_HEAD" eq "$(jq '.env | has("GATE_BASE") and has("GATE_HEAD")' <<<"$j")" true
}

case_desk_note() {
  setup
  check "the desk note requires flaky (integration_id 15368)" eq "$(jq '[.. | objects | select(has("required_status_checks"))
    | .required_status_checks[] | select(.context == "flaky" and .integration_id == 15368)] | length' "$DESK_BP")" 1
}

for c in file-expiry boundary malformed unusable json base-head flag-combos default-list gates-yml desk-note; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
