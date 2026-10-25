#!/usr/bin/env bash
# T2 acceptance 1 and 5: halt-check.sh reads factory/HALT from origin/main after a fetch, never the
# working tree, against a local bare origin built here; tests/test_layout.sh refuses a tree with
# factory/HALT in it. Offline: the "remote" is a path.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

SLEEP="$(jq -r .governor.haltSleepMinutes "$REPO_ROOT/factory/policy/budget.json")"

# A world: bare origin with main; `node` is the run loop's checkout; `desk` is a human who pushes.
halt_setup() {
  WORLD="$(mktemp -d "${TMPDIR:-/tmp}/halt.XXXXXX")"
  # shellcheck disable=SC2064  # expand now: WORLD is per case
  trap "rm -rf '$WORLD'" EXIT
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=desk GIT_AUTHOR_EMAIL=desk@fake GIT_COMMITTER_NAME=desk GIT_COMMITTER_EMAIL=desk@fake
  git init -q --bare -b main "$WORLD/origin.git"
  git init -q -b main "$WORLD/desk"
  mkdir -p "$WORLD/desk/factory"
  echo 1.0.0 >"$WORLD/desk/factory/VERSION"
  git -C "$WORLD/desk" add -A
  git -C "$WORLD/desk" commit -q -m "main: root"
  git -C "$WORLD/desk" remote add origin "$WORLD/origin.git"
  git -C "$WORLD/desk" push -q origin main
  git clone -q "$WORLD/origin.git" "$WORLD/node"
}
desk_halt() {    # desk_halt <add|rm>: the desk changes factory/HALT on origin/main
  if [ "$1" = add ]; then echo "drill: stop claiming" >"$WORLD/desk/factory/HALT"; git -C "$WORLD/desk" add factory/HALT
  else git -C "$WORLD/desk" rm -q factory/HALT; fi
  git -C "$WORLD/desk" commit -q -m "halt: $1"
  git -C "$WORLD/desk" push -q origin main
}
hc() {           # hc <args>: run halt-check in the node checkout; sets RC, OUT, ERR
  RC=0
  OUT="$(cd "$WORLD/node" && "$BIN/halt-check.sh" "$@" 2>"$WORLD/err")" || RC=$?
  # shellcheck disable=SC2034  # ERR is read inside the eval strings passed to check
  ERR="$(command cat "$WORLD/err")"
}

# ---------------------------------------------------------------------------------------------
case_absent() {
  halt_setup
  hc
  check "absent: exit 0" eq "$RC" 0
  check "absent: nothing on stdout" eq "$OUT" ""
  hc --json
  check "absent --json: halted false, names origin/main and its sha" \
    eq "$(jq -c '[.halted, .ref, .sha, has("sleep_minutes")]' <<<"$OUT")" \
       "[false,\"origin/main\",\"$(git -C "$WORLD/origin.git" rev-parse main)\",false]"
}

case_present() {
  halt_setup
  hc
  check "before the halt: exit 0" eq "$RC" 0
  desk_halt add                       # the node's origin/main is now stale; only a fetch sees it
  check "the node's tracking ref is stale before halt-check runs" \
    test -z "$(git -C "$WORLD/node" ls-tree origin/main factory/HALT)"
  hc
  check "present: exit 3" eq "$RC" 3
  check "present: stdout is the sleep interval from budget.json" eq "$OUT" "$SLEEP"
  check "budget.json says 30 minutes (SPEC-v0.2 Kill switch)" eq "$SLEEP" 30
  check "present: stderr names the halt" eval '[[ "$ERR" == *"factory/HALT is on origin/main"* ]]'
  hc --json
  check "present --json: halted true with sleep_minutes" \
    eq "$(jq -c '[.halted, .sleep_minutes, .path]' <<<"$OUT"):$RC" "[true,$SLEEP,\"factory/HALT\"]:3"
  desk_halt rm
  hc
  check "lifted on origin: exit 0 again (the fetch follows main)" eq "$RC:$OUT" "0:"
}

case_working_tree_ignored() {
  halt_setup
  echo "local only" >"$WORLD/node/factory/HALT"
  hc
  check "HALT only in the working tree: exit 0" eq "$RC" 0
  git -C "$WORLD/node" add factory/HALT
  git -C "$WORLD/node" commit -q -m "local halt, never pushed"
  hc
  check "HALT committed on local main but not on origin: exit 0" eq "$RC" 0
  desk_halt add
  git -C "$WORLD/node" rm -q factory/HALT
  hc
  check "HALT on origin but deleted locally: exit 3" eq "$RC:$OUT" "3:$SLEEP"
}

case_fetch_fails_closed() {
  halt_setup
  desk_halt add
  hc
  check "halted while origin is reachable" eq "$RC" 3
  git -C "$WORLD/node" remote set-url origin "$WORLD/gone.git"
  hc
  check "unreachable origin: exit 1, never 0 (unknown is not absent)" eq "$RC" 1
  check "unreachable origin: no sleep interval printed" eq "$OUT" ""
  check "unreachable origin: says do not claim" eval '[[ "$ERR" == *"do not claim"* ]]'
}

case_layout_refuses_halt() {
  # test_layout.sh runs on a copy of the tracked tree: clean it passes, with factory/HALT it fails.
  local copy rc
  copy="$(mktemp -d "${TMPDIR:-/tmp}/layout.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$copy'" EXIT
  git -C "$REPO_ROOT" ls-files -z | (cd "$REPO_ROOT" && tar --null -T - -cf -) | tar -xf - -C "$copy"
  rc=0; bash "$copy/tests/test_layout.sh" >/dev/null 2>&1 || rc=$?
  check "test_layout passes on the clean copy" eq "$rc" 0
  echo halt >"$copy/factory/HALT"
  rc=0; bash "$copy/tests/test_layout.sh" >/dev/null 2>"$copy/err" || rc=$?
  check "test_layout fails when factory/HALT is in the tree" eq "$rc" 1
  check "and says why" eval 'grep -q "factory/HALT must be ABSENT" "$copy/err"'
}

echo "test_halt"
for c in absent present working-tree-ignored fetch-fails-closed layout-refuses-halt; do
  run_case "$c"
done
exit "$FAILED"
