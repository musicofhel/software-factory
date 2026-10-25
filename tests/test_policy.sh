#!/usr/bin/env bash
# T6 acceptance 1 and 2 (offline): the ralon lock renderer (factory/bin/lib/ralon-lock.sh), the
# adapter pins (factory/policy/adapters.json), the shape of the vetto policies and the dcg config,
# and the behaviour of the fakes later rows test against (tests/fakes/{vetto,ralon,dcg}). The real
# tools are proven in tests/live/test_policy_live.sh (`make live`).
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
POLICY="$REPO_ROOT/factory/policy"
RENDER="$BIN/lib/ralon-lock.sh"

# The adapters fleet 1.12.0 registers (@adlc/fleet lib/adapters/index.mjs, records/TB0.md §4), and
# the egress hosts its claude-code adapter declares (lib/adapters/claude-code.mjs egressHosts).
FLEET_ADAPTERS='["agy","claude-code","codex","copilot","cursor","gemini","jetski","opencode","pi"]'
CLAUDE_EGRESS='["api.anthropic.com:443","console.anthropic.com:443","platform.claude.com:443"]'

# A world: a git repo `wt` (the worktree a lock protects), the fakes first on PATH, logs.
pol_setup() {
  WORLD="$(mktemp -d "${TMPDIR:-/tmp}/policy.XXXXXX")"
  # shellcheck disable=SC2064  # expand now: WORLD is per case
  trap "rm -rf '$WORLD'" EXIT
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@fake GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@fake
  export FAKE_ADLC_LOG="$WORLD/adlc.log" FAKE_VETTO_LOG="$WORLD/vetto.log" FAKE_RALON_LOG="$WORLD/ralon.log" \
         FAKE_DCG_LOG="$WORLD/dcg.log" FACTORY_ADLC="$FAKES_DIR/adlc" PATH="$FAKES_DIR:$PATH"
  unset FAKE_ADLC_STORE FAKE_ADLC_FAIL FAKE_VETTO_EXIT FAKE_VETTO_FAIL_CLOSED FAKE_DCG_DENY
  export FAKE_ADLC_TICKETS='[{"id":"T1","title":"no rails"},
    {"id":"T2","title":"rails","rails":["src/auth/**","./docs/charter.md","config/","factory/policy/**"]}]'
  : >"$FAKE_ADLC_LOG"; : >"$FAKE_VETTO_LOG"; : >"$FAKE_RALON_LOG"; : >"$FAKE_DCG_LOG"
  git init -q -b main "$WORLD/wt"
  mkdir -p "$WORLD/wt/src"; echo x >"$WORLD/wt/src/a.txt"
  git -C "$WORLD/wt" add -A; git -C "$WORLD/wt" commit -q -m root
}
rails() { FAKE_ADLC_TICKETS="$(jq -cn --argjson r "$1" '[{id: "T9", title: "t", rails: $r}]')"; export FAKE_ADLC_TICKETS; }
render() {  # render <args>: run the renderer; sets RC, OUT, ERR
  RC=0
  OUT="$("$RENDER" "$@" 2>"$WORLD/err")" || RC=$?
  # shellcheck disable=SC2034  # ERR is read inside the eval strings passed to check
  ERR="$(command cat "$WORLD/err")"
}
# toml_tables <file>: the [table] headers, one per line.
toml_tables() { sed -nE 's/^[[:space:]]*\[([^]]+)\][[:space:]]*(#.*)?$/\1/p' "$1"; }
# toml_get <file> <table> <key>: the raw value of key in table (single-line values only).
toml_get() {
  awk -v t="$2" -v k="$3" '
    /^[[:space:]]*\[/ { sub(/^[[:space:]]*\[/, ""); sub(/\].*$/, ""); cur = $0; next }
    cur == t && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); print; exit }' "$1"
}

# ---------------------------------------------------------------------------------------------
case_lock_render() {
  pol_setup
  cd "$WORLD/wt"
  render T2
  check "dry run by default: exit 0" eq "$RC" 0
  check "dry run writes no lock" eval '[ ! -e agent.lock ]'
  check "the lock is ralon 0.1.7's format: version 1 and a protect list" \
    eval 'grep -qx "version: 1" <<<"$OUT" && grep -qx "protect:" <<<"$OUT"'
  check "each rail as itself and under .worktrees/*/, factory/policy/** first, normalized, no duplicates" \
    eq "$(sed -nE 's/^  - (.*)$/\1/p' <<<"$OUT" | jq -sc .)" \
       '["factory/policy/**",".worktrees/*/factory/policy/**","src/auth/**",".worktrees/*/src/auth/**","docs/charter.md",".worktrees/*/docs/charter.md","config",".worktrees/*/config"]'
  check "it asked the store, in the worktree, with --json" eq "$(tail -n1 "$FAKE_ADLC_LOG")" '["ticket","show","T2","--json"]'
  render T2 --json
  check "--json: patterns, the lock path at the worktree root, applied false" \
    eq "$(jq -c '[.ticket, (.patterns | length), .lock, .applied]' <<<"$OUT")" "[\"T2\",8,\"$(pwd -P)/agent.lock\",false]"
  render T1
  check "a ticket with no rails still protects factory/policy/** (ralon refuses an empty lock)" \
    eq "$(sed -nE 's/^  - (.*)$/\1/p' <<<"$OUT" | jq -sc .)" '["factory/policy/**",".worktrees/*/factory/policy/**"]'
  local g
  for g in '../escape/**' 'src/../../x' '/etc/passwd' '~/.ssh/**' '!src/keep' 'C:/x' 'src\\x' '' '   ' '.' './'; do
    rails "$(jq -cn --arg g "$g" '[$g, "ok/**"]')"
    render T9
    check "rail $(jq -cn --arg g "$g" '$g') is refused: exit 2, named on stderr" \
      eval '[ "$RC" = 2 ] && grep -q "ralon would refuse it" <<<"$ERR"'
    render T9 --apply
    check "  and --apply writes nothing" eval '[ "$RC" = 2 ] && [ ! -e agent.lock ]'
  done
  rails '["src/a\nb"]'
  render T9
  check "a rail with a control character: exit 2" eq "$RC" 2
  rails '["ok", 3]'
  render T9
  check "a rail that is not a string: exit 1" eq "$RC" 1
  render T404
  check "an unknown ticket: exit 1" eq "$RC" 1
  mkdir -p sub
  render T1 --worktree sub
  check "a directory below the work tree top: exit 1 (patterns are relative to the lock)" \
    eval '[ "$RC" = 1 ] && grep -q "not the top of its work tree" <<<"$ERR"'
}

case_lock_apply() {
  pol_setup
  cd "$WORLD"
  render T2 --worktree wt --apply
  check "--apply: exit 0" eq "$RC" 0
  check "--apply writes agent.lock at the worktree root, the same text the dry run prints" \
    eq "$(command cat wt/agent.lock)" "$("$RENDER" T2 --worktree wt)"
  check "/agent.lock is in info/exclude" eval 'grep -qx /agent.lock wt/.git/info/exclude'
  check "git status stays clean (fleet refuses a dirty tree)" eq "$(git -C wt status --porcelain)" ""
  render T2 --worktree wt --apply
  check "a second --apply: exit 0, info/exclude names it once" eq "$RC $(grep -cx /agent.lock wt/.git/info/exclude)" "0 1"
  check "fake ralon reads the rendered lock: a rail path is locked" eval '! ralon check -C wt src/auth/key.pem >/dev/null'
  check "  a non-rail path is writable" eval 'ralon check -C wt src/a.txt >/dev/null'
  check "  ralon run accepts it and passes the status through" eval 'rc=0; ralon run -C wt -- sh -c "exit 4" || rc=$?; [ "$rc" = 4 ]'
  git -C wt worktree add -q -b ticket/T2/dev-box "$WORLD/linked"
  render T2 --worktree linked --apply
  check "a linked worktree: exit 0, the lock at its root" eval '[ "$RC" = 0 ] && [ -f linked/agent.lock ]'
  check "  excluded through the common info/exclude, status clean" eq "$(git -C linked status --porcelain)" ""
  git -C wt add -f agent.lock; git -C wt commit -q -m "the project's own lock"
  render T2 --worktree wt --apply
  check "a tracked agent.lock is the project's own: --apply refuses with exit 2" \
    eval '[ "$RC" = 2 ] && grep -q "is tracked" <<<"$ERR"'
}

case_adapters_schema() {
  local f="$POLICY/adapters.json"
  check "adapters.json is a JSON object" eval 'jq -e "type == \"object\"" "$f" >/dev/null'
  check "its keys are exactly fleet 1.12.0's adapters" eq "$(jq -c 'keys' "$f")" "$FLEET_ADAPTERS"
  check "every value is null or an exact x.y.z string" \
    eval 'jq -e "all(.[]; . == null or (type == \"string\" and test(\"^[0-9]+\\\\.[0-9]+\\\\.[0-9]+$\")))" "$f" >/dev/null'
  check "claude-code is pinned (ruling Q5: the version on the dev box)" \
    eval 'jq -e ".\"claude-code\" | type == \"string\"" "$f" >/dev/null'
  check "every other adapter is null: not pinned yet" \
    eq "$(jq -c '[to_entries[] | select(.key != "claude-code") | .value] | unique' "$f")" '[null]'
  check "a bad file fails the same checks (the schema test is not vacuous)" \
    eval '! jq -e "all(.[]; . == null or (type == \"string\" and test(\"^[0-9]+\\\\.[0-9]+\\\\.[0-9]+$\")))" <<<"{\"codex\": \"latest\"}" >/dev/null'
}

case_vetto_policies() {
  pol_setup
  local known='^(metadata|security|filesystem|secrets|display_only_deny|environment|network|unix_sockets|net_ports|limits|cgroup|process)$' f
  for f in build agent; do
    check "$f.toml: only tables vetto 0.6.5 parses" eval '! toml_tables "$POLICY/$f.toml" | grep -vqE "$known"'
    check "$f.toml: writes only to the worktree and the dependency cache" \
      eq "$(toml_get "$POLICY/$f.toml" filesystem allow_write)" '["$PROJECT", "$HOME/.factory/cache"]'
  done
  check "build.toml: network mode off (vetto does not reject an unknown mode, so it is pinned here)" \
    eq "$(toml_get "$POLICY/build.toml" network mode)" '"off"'
  check "agent.toml: network mode strict (host and port)" eq "$(toml_get "$POLICY/agent.toml" network mode)" '"strict"'
  check "agent.toml: egress exactly fleet's claude-code egressHosts" \
    eq "$(toml_get "$POLICY/agent.toml" network allow | jq -c 'sort')" "$CLAUDE_EGRESS"
  check "the fake vetto accepts both files and runs the command" \
    eval 'vetto --profile strict --policy "$POLICY/build.toml" -- touch "$WORLD/b" || true; vetto --profile strict --agent claude --policy "$POLICY/agent.toml" -- touch "$WORLD/a" || true; [ -f "$WORLD/b" ] && [ -f "$WORLD/a" ]'
}

case_dcg_config() {
  local f="$POLICY/dcg.toml"
  check "general: fail closed, refuse unverifiable commands, never touch ~/.claude or update itself" \
    eq "$(for k in fail_closed unverified_decision self_heal_hook check_updates update_pin; do toml_get "$f" general "$k"; done | jq -sc .)" \
       '[true,"deny",false,false,true]'
  check "policy: every matched rule denies" eq "$(toml_get "$f" policy default_mode)" '"deny"'
  check "history off: command text stays off disk" eq "$(toml_get "$f" history enabled)" false
  check "no [interactive] table (dcg 0.15.3 requires every field of it, and a failed load runs on defaults)" \
    eval '! toml_tables "$f" | grep -qx interactive'
  check "the agent-side blocks are there: git push, gh writes, skipping permissions" \
    eval 'grep -qF "git\\\\s+push" "$f" && grep -qF "gh\\\\s+(pr|issue|api|" "$f" && grep -qF -- "--dangerously-skip-permissions" "$f"'
}

case_fakes() {
  pol_setup
  cd "$WORLD/wt"
  # vetto
  check "fake vetto --version is the pin" eq "$(vetto --version)" "vetto 0.6.5"
  local rc=0
  vetto --profile strict --policy "$POLICY/build.toml" --tui none -- sh -c 'echo ran >"$1"; exit 3' _ "$WORLD/v1" || rc=$?
  check "fake vetto runs the command, then exits 125 whatever it returned (0.6.5)" eval '[ "$rc" = 125 ] && [ -f "$WORLD/v1" ]'
  rc=0; FAKE_VETTO_EXIT=3 vetto -- true || rc=$?
  check "FAKE_VETTO_EXIT models a fixed vetto" eq "$rc" 3
  printf '[filesystem]\nallow_write = ["$PROJECT"]\n[bogus]\nx = 1\n' >"$WORLD/bad.toml"
  rc=0; vetto --policy "$WORLD/bad.toml" -- touch "$WORLD/v2" 2>"$WORLD/verr" || rc=$?
  check "fake vetto: an unknown table fails closed, 125, the command never runs" \
    eval '[ "$rc" = 125 ] && [ ! -e "$WORLD/v2" ] && grep -q "Security policy load failure" "$WORLD/verr"'
  rc=0; vetto --policy "$WORLD/missing.toml" -- touch "$WORLD/v3" 2>/dev/null || rc=$?
  check "fake vetto: a missing policy fails closed" eval '[ "$rc" = 125 ] && [ ! -e "$WORLD/v3" ]'
  rc=0; FAKE_VETTO_FAIL_CLOSED=1 vetto -- touch "$WORLD/v4" 2>/dev/null || rc=$?
  check "FAKE_VETTO_FAIL_CLOSED=1: 125, the command never runs" eval '[ "$rc" = 125 ] && [ ! -e "$WORLD/v4" ]'
  check "fake vetto logs every argv" eq "$(sed -n 2p "$FAKE_VETTO_LOG")" \
    "$(jq -cn --arg p "$POLICY/build.toml" --arg f "$WORLD/v1" '["--profile","strict","--policy",$p,"--tui","none","--","sh","-c","echo ran >\"$1\"; exit 3","_",$f]')"
  # ralon
  check "fake ralon --version is the pin" eq "$(ralon --version)" "ralon 0.1.7"
  rc=0; ralon run -C . -- true 2>/dev/null || rc=$?
  check "fake ralon: no agent.lock, exit 2" eq "$rc" 2
  printf '# nothing\n' >agent.lock; rc=0; ralon run -- true 2>/dev/null || rc=$?
  check "fake ralon: an empty lock, exit 2" eq "$rc" 2
  printf 'version: 1\nprotect:\n  - "../x"\n' >agent.lock; rc=0; ralon run -- touch "$WORLD/r1" 2>/dev/null || rc=$?
  check "fake ralon: a refused pattern, exit 2, the command never runs" eval '[ "$rc" = 2 ] && [ ! -e "$WORLD/r1" ]'
  printf 'version: 1\nprotect:\n  - "src/**"\n' >agent.lock
  rc=0; ralon run -q -C . -- sh -c 'exit 6' || rc=$?
  check "fake ralon run passes the command's status through" eq "$rc" 6
  check "fake ralon check: a protected path exits 1, a free one 0, agent.lock protects itself" \
    eval '! ralon check src/a.txt >/dev/null && ralon check docs/x >/dev/null && ! ralon check agent.lock >/dev/null'
  check "fake ralon logs every argv" eq "$(tail -n1 "$FAKE_RALON_LOG")" '["check","agent.lock"]'
  # dcg
  check "fake dcg --version is the pin" eq "$(dcg --version)" "0.15.3"
  check "fake dcg: an allowed command exits 0" eval 'dcg test --dialect posix "make test" >/dev/null'
  rc=0; out="$(dcg test -c "$POLICY/dcg.toml" --dialect posix --robot "git push origin x")" || rc=$?
  check "fake dcg: a denied command exits 1 with the robot document" \
    eq "$rc $(jq -c '[.dcg_version, .decision, .command]' <<<"$out")" '1 ["0.15.3","deny","git push origin x"]'
  check "fake dcg --stdin reads the command from stdin" eval '! echo "rm -rf /" | dcg test --stdin >/dev/null'
  check "fake dcg: FAKE_DCG_DENY replaces the deny set" eval '! FAKE_DCG_DENY=make dcg test "make test" >/dev/null'
  check "fake dcg: a missing config warns and goes on with defaults (as 0.15.3)" \
    eval 'dcg test -c "$WORLD/none.toml" ls 2>&1 >/dev/null | grep -q "Failed to load config"'
  check "fake dcg logs every argv" eq "$(sed -n 3p "$FAKE_DCG_LOG")" \
    "$(jq -cn --arg c "$POLICY/dcg.toml" '["test","-c",$c,"--dialect","posix","--robot","git push origin x"]')"
}

echo "test_policy"
for c in lock-render lock-apply adapters-schema vetto-policies dcg-config fakes; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
