#!/usr/bin/env bash
# T24 (specs/factory-step3-v1 TB5): factory/bin/build-test.sh runs the base's fleet.gate commands the
# way fleet runs them on the node, and gates.yml's build-test job runs it from the base (I16, I17).
#   - --list on main's config, an empty or null key skipped; the run order, the caller's cwd, the trace;
#   - the first failure stops the list (exit 2); every unusable config exits 1 and runs nothing;
#   - the commands come from the config beside the script (the base), never the cwd's (the head);
#   - a gate command reads the caller's stdin, not the list; a command passes byte for byte;
#   - gates.yml: the base's script with no args, both checkouts, no `make test|lint` anywhere, a
#     pinned shellcheck equal to join.sh's; node (fleet's jq read) and CI (--list) run one list.
# Offline; every config and checkout is a temp dir.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
BT="$BIN/build-test.sh"
GATES="$REPO_ROOT/.github/workflows/gates.yml"

setup() {
  WORLD="$(mktemp -d "${TMPDIR:-/tmp}/buildtest.XXXXXX")"
  # shellcheck disable=SC2064  # expand now: WORLD is per case
  trap "rm -rf '$WORLD'" EXIT
  CWD="$WORLD/cwd"; mkdir -p "$CWD"
}
# gatecfg <file> <build> <test>: a config whose fleet.gate holds the two strings
gatecfg() { jq -n --arg b "$2" --arg t "$3" '{fleet: {gate: {build: $b, test: $t}}}' >"$1"; }
# bt [flags]: run build-test (or $SCRIPT) in CWD with the caller's stdin; RC, OUT, ERR.
bt() {
  RC=0
  OUT="$(cd "$CWD" && "${SCRIPT:-$BT}" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(/bin/cat "$WORLD/err")"
}
has() { [[ "$1" == *"$2"* ]] || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }
matches() { [[ "$1" =~ $2 ]] || { printf '      [%s] does not match /%s/\n' "$1" "$2"; return 1; }; }
lacks() { [[ "$1" != *"$2"* ]] || { printf '      [%s] has [%s]\n' "$1" "$2"; return 1; }; }
jqeq() { eq "$(jq -cS . <<<"$1")" "$(jq -cS . <<<"$2")"; }

case_list() {
  setup
  bt --list </dev/null
  check "main's config: exit 0" eq "$RC" 0
  check "  build then test, each /bin/sh -c" jqeq "$OUT" \
    '[{"key":"build","command":"make lint","argv":["/bin/sh","-c","make lint"]},{"key":"test","command":"make test","argv":["/bin/sh","-c","make test"]}]'
  gatecfg "$WORLD/c.json" "" x; bt --config "$WORLD/c.json" --list
  check "build \"\": only test" jqeq "$OUT" '[{"key":"test","command":"x","argv":["/bin/sh","-c","x"]}]'
  echo '{"fleet":{"gate":{"build":null,"test":"x"}}}' >"$WORLD/c.json"; bt --config "$WORLD/c.json" --list
  check "build null: only test" jqeq "$OUT" '[{"key":"test","command":"x","argv":["/bin/sh","-c","x"]}]'
}

case_runs() {
  setup
  gatecfg "$WORLD/c.json" 'echo build >>order.txt' 'echo test >>order.txt'
  bt --config "$WORLD/c.json" </dev/null
  check "exit 0" eq "$RC" 0
  check "build then test, in the caller's cwd" eq "$(/bin/cat "$CWD/order.txt")" $'build\ntest'
  check "trace: build" has "$ERR" "build-test: build: /bin/sh -c echo build >>order.txt"
  check "trace: test" has "$ERR" "build-test: test: /bin/sh -c echo test >>order.txt"
  check "trace: pass" has "$ERR" "build-test: pass:"
}

case_stops_at_first_failure() {
  setup
  gatecfg "$WORLD/c.json" 'exit 3' "touch '$WORLD/marker'"
  bt --config "$WORLD/c.json" </dev/null
  check "build fails: exit 2" eq "$RC" 2
  check "  test never ran" test ! -e "$WORLD/marker"
  check "  names the key and its code" eval 'has "$ERR" "FAIL: build" && has "$ERR" "exited 3"'
  gatecfg "$WORLD/c.json" true 'exit 5'
  bt --config "$WORLD/c.json" </dev/null
  check "build passes, test fails: exit 2" eq "$RC" 2
  check "  names test and its code" eval 'has "$ERR" "build passed" && has "$ERR" "FAIL: test" && has "$ERR" "exited 5"'
}

case_config_errors() {
  setup
  local m="touch '$WORLD/marker'" c="$WORLD/c.json" body name want
  while IFS='|' read -r name body want; do
    if [ "$name" = missing ]; then c="$WORLD/none.json"; else c="$WORLD/c.json"; printf '%s\n' "${body//MARK/$m}" >"$c"; fi
    bt --config "$c" </dev/null
    check "$name: exit 1, '$want'" eval '[ "$RC" = 1 ] && has "$ERR" "$want"'
    check "  ran nothing" test ! -e "$WORLD/marker"
  done <<'EOF'
missing||no config at
not JSON|{"fleet": {"gate": {"build": "MARK"|is not a JSON object
an array|[{"fleet":{"gate":{"build":"MARK"}}}]|is not a JSON object
fleet.gate a string|{"fleet":{"gate":"MARK"}}|fleet.gate is not an object
gate.build a number|{"fleet":{"gate":{"build":3,"test":"MARK"}}}|fleet.gate.build is not a string
no fleet key|{"gate":{"build":"MARK"}}|has no fleet.gate.build or fleet.gate.test
both empty|{"fleet":{"gate":{"build":"","test":""}}}|has no fleet.gate.build or fleet.gate.test
EOF
}

case_base_config() {
  setup
  check "FACTORY_ROOT is three dirs above lib/common.sh" /usr/bin/grep -q \
    'FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE\[0\]}")/../../.." && pwd)"' "$BIN/lib/common.sh"
  local base="$WORLD/base"
  mkdir -p "$base/factory" "$base/.adlc" "$CWD/.adlc"
  cp -R "$BIN" "$base/factory/bin"
  gatecfg "$base/.adlc/config.json" 'echo BASE-BUILD' 'echo BASE-TEST'
  gatecfg "$CWD/.adlc/config.json" 'echo HEAD-GATE' 'echo HEAD-GATE'
  SCRIPT="$base/factory/bin/build-test.sh" bt </dev/null
  check "the base's script, no args, cwd = head: exit 0" eq "$RC" 0
  check "  ran the base's build and test" eval 'has "$OUT" BASE-BUILD && has "$OUT" BASE-TEST'
  check "  never the head's gate" eval 'lacks "$OUT$ERR" HEAD-GATE'
  check "  names the base's config" has "$ERR" "$base/.adlc/config.json"
}

case_stdin() {
  setup
  # shellcheck disable=SC2016  # $x is the gate command's, not ours
  gatecfg "$WORLD/c.json" 'read -r x || true; echo "got:[$x]"' 'echo test-ran'
  bt --config "$WORLD/c.json" <<<"FROM-CALLER"
  check "exit 0" eq "$RC" 0
  check "build read the caller's stdin, not the list" has "$OUT" "got:[FROM-CALLER]"
  check "test still ran (the list was not eaten)" has "$OUT" "test-ran"
  local s=$'TAB:\t|dq:"x"|sq:\'"\'"\'|bs:\\\\ \\n|'
  gatecfg "$WORLD/c.json" "printf '%s' '$s' >bytes.out" true
  bt --config "$WORLD/c.json" --list </dev/null
  check "--list keeps the command byte for byte" eq "$(jq -r '.[0].command' <<<"$OUT")" "printf '%s' '$s' >bytes.out"
  bt --config "$WORLD/c.json" </dev/null
  check "tabs, quotes, backslashes reach /bin/sh unchanged" eq "$(/bin/cat "$CWD/bytes.out")" $'TAB:\t|dq:"x"|sq:\'|bs:\\\\ \\n|'
}

case_gates_yml() {
  setup
  local j job pin pip
  j="$(yq -o=json '.' "$GATES")"; job="$(jq -c '.jobs["build-test"]' <<<"$j")"
  check "build-test runs ./.base/factory/bin/build-test.sh, no args" \
    eq "$(jq '[.steps[] | select(.run? != null and (.run | test("build-test")))] | map(.run) == ["./.base/factory/bin/build-test.sh"]' <<<"$job")" true
  check "a checkout of env.GATE_BASE into .base" eq "$(jq '[.steps[] | select((.uses // "") | startswith("actions/checkout"))
    | select(.with.path == ".base" and (.with.ref | test("env\\.GATE_BASE")))] | length' <<<"$job")" 1
  check "a checkout of env.GATE_HEAD" eq "$(jq '[.steps[] | select((.uses // "") | startswith("actions/checkout"))
    | select((.with.path // "") != ".base" and (.with.ref | test("env\\.GATE_HEAD")))] | length' <<<"$job")" 1
  local re='(^|[^A-Za-z0-9_./-])make[ \t]+(test|lint)\b'
  check "  the make regex does match a make call (sanity)" eq "$(jq -n --arg re "$re" '"x && make  test\n" | test($re)')" true
  check "no job runs make test or make lint" eq "$(jq -c --arg re "$re" \
    '[.jobs | to_entries[] | .key as $k | .value.steps[]? | select(.run? and (.run | test($re))) | $k]' <<<"$j")" '[]'
  pin="$(sed -n 's/^SHELLCHECK_PIN=//p' "$BIN/join.sh")"
  pip="$(jq -r '[.steps[] | select(.run? and (.run | test("pipx install"))) | .run] | join("\n")' <<<"$job")"
  check "the pipx line pins shellcheck-py==<X.Y.Z>.1" matches "$pip" 'shellcheck-py==[0-9]+\.[0-9]+\.[0-9]+\.1'
  check "join.sh has SHELLCHECK_PIN" test -n "$pin"
  check "  gates.yml installs shellcheck-py==\$PIN.1" has "$pip" "shellcheck-py==${pin}.1"
  check "  gates.yml checks 'version: \$PIN'" has "$pip" "'version: ${pin}'"
}

case_node_ci_same_list() {
  setup
  local fleet
  fleet="$(jq -c '[.fleet.gate.build, .fleet.gate.test | select(. != null and . != "")]' "$REPO_ROOT/.adlc/config.json")"
  bt --list </dev/null
  check "fleet's read is not empty" eval '[ "$(jq length <<<"$fleet")" -gt 0 ]'
  check "--list's commands == fleet's (build, test, empty skipped)" eq "$(jq -c 'map(.command)' <<<"$OUT")" "$fleet"
}

for c in list runs stops-at-first-failure config-errors base-config stdin gates-yml node-ci-same-list; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
