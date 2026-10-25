#!/usr/bin/env bash
# T3 acceptance 7: version-check.sh exits 2 when the local factory/VERSION or an adapter pin is
# behind origin/main (and when the installed CLI drifted from its pin), 0 when current, 1 when the
# state is unknown. Against a local bare origin built here; the CLIs are fakes on a closed PATH.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

# A world: bare origin with main at VERSION 0.1.0; `node` is the run loop's checkout; `desk` pushes.
vc_setup() {
  WORLD="$(mktemp -d "${TMPDIR:-/tmp}/vc.XXXXXX")"
  # shellcheck disable=SC2064  # expand now: WORLD is per case
  trap "rm -rf '$WORLD'" EXIT
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=desk GIT_AUTHOR_EMAIL=desk@fake GIT_COMMITTER_NAME=desk GIT_COMMITTER_EMAIL=desk@fake
  unset FACTORY_MANIFEST
  git init -q --bare -b main "$WORLD/origin.git"
  git init -q -b main "$WORLD/desk"
  mkdir -p "$WORLD/desk/factory/policy"
  echo 0.1.0 >"$WORLD/desk/factory/VERSION"
  git -C "$WORLD/desk" add -A
  git -C "$WORLD/desk" commit -q -m "main: root"
  git -C "$WORLD/desk" remote add origin "$WORLD/origin.git"
  git -C "$WORLD/desk" push -q origin main
  git clone -q "$WORLD/origin.git" "$WORLD/node"
  # A closed PATH: the tools the script needs, plus fake CLIs in $WORLD/cli, and no real adapter.
  mkdir -p "$WORLD/sys" "$WORLD/cli"
  local t
  for t in bash env git jq tr grep head sed cat dirname; do ln -s "$(command -v "$t")" "$WORLD/sys/$t"; done
  VC_PATH="$WORLD/cli:$WORLD/sys"
}
desk_push() {  # desk_push <path> <content>: the desk changes a file on origin/main
  mkdir -p "$(dirname "$WORLD/desk/$1")"
  printf '%s\n' "$2" >"$WORLD/desk/$1"
  git -C "$WORLD/desk" add -A
  git -C "$WORLD/desk" commit -q -m "desk: $1"
  git -C "$WORLD/desk" push -q origin main
}
fake_cli() {  # fake_cli <name> <version-line>
  printf '#!/usr/bin/env bash\n[ "$1" = --version ] && echo "%s"\n' "$2" >"$WORLD/cli/$1"
  chmod +x "$WORLD/cli/$1"
}
manifest() {  # manifest <adapters-json>: the node's manifest at $WORLD/me.json
  jq --argjson a "$1" '.adapters = $a' "$REPO_ROOT/factory/nodes/example.json" >"$WORLD/me.json"
}
vc() {  # vc <args>: run version-check in the node checkout on the closed PATH; sets RC, OUT, ERR
  RC=0
  OUT="$(cd "$WORLD/node" && PATH="$VC_PATH" "$BIN/version-check.sh" "$@" 2>"$WORLD/err")" || RC=$?
  # shellcheck disable=SC2034  # ERR is read inside the eval strings passed to check
  ERR="$(command cat "$WORLD/err")"
}

# ---------------------------------------------------------------------------------------------
case_current() {
  vc_setup
  vc
  check "same VERSION: exit 0" eq "$RC" 0
  check "the line says current" eq "$OUT" "factory/VERSION 0.1.0: current with origin/main (0.1.0)"
  vc --json
  check "--json: ok, current, no pins on main, no manifest" \
    eq "$(jq -c '[.ok, .version.state, .pins_source, .manifest, .adapters, .sha]' <<<"$OUT")" \
       "[true,\"current\",null,null,[],\"$(git -C "$WORLD/origin.git" rev-parse main)\"]"
}

case_version_behind() {
  vc_setup
  desk_push factory/VERSION 0.2.0
  check "the node's tracking ref is stale before the check runs" \
    eq "$(git -C "$WORLD/node" show origin/main:factory/VERSION)" 0.1.0
  vc
  check "behind origin/main: exit 2" eq "$RC" 2
  check "the refusal names both versions" eval 'grep -q "factory/VERSION 0.1.0 is behind origin/main (0.2.0)" <<<"$ERR"'
  git -C "$WORLD/node" pull -q --ff-only
  vc
  check "after the pull: exit 0" eq "$RC" 0
  echo 0.3.0 >"$WORLD/node/factory/VERSION"
  vc --json
  check "ahead of main: exit 0, state ahead" eq "$RC $(jq -r .version.state <<<"$OUT")" "0 ahead"
}

case_numeric_compare() {
  vc_setup
  desk_push factory/VERSION 0.10.0
  echo 0.9.0 >"$WORLD/node/factory/VERSION"
  vc
  check "0.9.0 is behind 0.10.0 (numbers, not strings): exit 2" eq "$RC" 2
  echo 0.10.0-rc.1 >"$WORLD/node/factory/VERSION"
  vc
  check "a suffix after x.y.z is ignored: 0.10.0-rc.1 = 0.10.0" eq "$RC" 0
}

case_adapter_pin_behind() {
  vc_setup
  desk_push factory/policy/adapters.json '{"claude-code": "2.1.300", "codex": "1.0.0"}'
  manifest '{"claude-code": "2.1.280"}'
  fake_cli claude "2.1.280 (Claude Code)"
  vc --manifest "$WORLD/me.json" --json
  check "manifest pin behind main's pin: exit 2" eq "$RC" 2
  check "state behind, source named; codex (not run by this node) not checked" \
    eq "$(jq -c '[.pins_source, [.adapters[] | [.name, .pin, .main_pin, .state]]]' <<<"$OUT")" \
       '["factory/policy/adapters.json",[["claude-code","2.1.280","2.1.300","behind"]]]'
  check "the refusal says re-pin" eval 'grep -q "claude-code pin 2.1.280 is behind origin/main (2.1.300): re-pin" <<<"$ERR"'
  manifest '{"claude-code": "2.1.300"}'
  fake_cli claude "2.1.300 (Claude Code)"
  vc --manifest "$WORLD/me.json"
  check "re-pinned and upgraded: exit 0" eq "$RC" 0
  FACTORY_MANIFEST="$WORLD/me.json" vc --json
  check "FACTORY_MANIFEST is read when --manifest is not given" eq "$(jq -c '[.ok, (.adapters | length)]' <<<"$OUT")" '[true,1]'
  desk_push factory/policy/adapters.json '["not", "an", "object"]'
  vc --manifest "$WORLD/me.json"
  check "a pin file that is not an object: exit 1 (unknown)" eq "$RC" 1
}

case_adapter_unpinned() {
  vc_setup
  desk_push factory/policy/adapters.json "$(command cat "$REPO_ROOT/factory/policy/adapters.json")"
  manifest '{"claude-code": "2.1.280"}'
  fake_cli claude "2.1.280 (Claude Code)"
  vc --manifest "$WORLD/me.json" --json
  check "the repo's adapters.json: claude-code at its pin claims, exit 0" eq "$RC" 0
  check "pins_source is the file, no longer null" \
    eq "$(jq -c '[.pins_source, [.adapters[] | [.name, .main_pin, .state]]]' <<<"$OUT")" \
       '["factory/policy/adapters.json",[["claude-code","2.1.280","current"]]]'
  manifest '{"codex": "0.5.0"}'
  fake_cli codex "codex-cli 0.5.0"
  vc --manifest "$WORLD/me.json" --json
  check "codex is null on main: exit 2 even though it is installed at the manifest pin" eq "$RC" 2
  check "state unpinned, main_pin null" eq "$(jq -c '[.adapters[0].state, .adapters[0].main_pin, .ok]' <<<"$OUT")" '["unpinned",null,false]'
  check "the refusal says not pinned yet" \
    eval 'grep -q "codex is not pinned on origin/main (null in factory/policy/adapters.json): the factory does not claim with it yet" <<<"$ERR"'
  manifest '{"claude-code": "2.1.280", "codex": "0.5.0"}'
  vc --manifest "$WORLD/me.json"
  check "one null-pinned adapter in the manifest refuses the node: exit 2" eq "$RC" 2
  manifest '{"aider": "1.0.0"}'
  fake_cli aider "aider 1.0.0"
  vc --manifest "$WORLD/me.json" --json
  check "an adapter adapters.json does not list: exit 2, state unlisted" eq "$RC $(jq -r '.adapters[0].state' <<<"$OUT")" "2 unlisted"
  check "the refusal says unknown adapter" eval 'grep -q "aider is not in factory/policy/adapters.json on origin/main: unknown adapter" <<<"$ERR"'
  desk_push factory/policy/adapters.json '{"claude-code": "2.1.280-beta"}'
  manifest '{"claude-code": "2.1.280"}'
  vc --manifest "$WORLD/me.json" --json
  check "a main pin that is not exactly x.y.z: exit 2, bad-pin" eq "$RC $(jq -r '.adapters[0].state' <<<"$OUT")" "2 bad-pin"
  desk_push factory/policy/adapters.json '{"claude-code": 2}'
  vc --manifest "$WORLD/me.json" --json
  check "a main pin that is not a string: exit 2, bad-pin" eq "$RC $(jq -r '.adapters[0].state' <<<"$OUT")" "2 bad-pin"
}

case_installed_drift() {
  vc_setup
  manifest '{"claude-code": "2.1.280"}'
  fake_cli claude "2.1.281 (Claude Code)"
  vc --manifest "$WORLD/me.json" --json
  check "installed CLI drifted from the pin: exit 2" eq "$RC" 2
  check "state drift, with no pins on main" eq "$(jq -c '[.pins_source, .adapters[0].installed, .adapters[0].state]' <<<"$OUT")" '[null,"2.1.281","drift"]'
  rm "$WORLD/cli/claude"
  vc --manifest "$WORLD/me.json"
  check "pinned CLI not installed: exit 2" eq "$RC" 2
  check "the refusal names the missing CLI" eval 'grep -q "claude-code is pinned at 2.1.280 but \`claude\` is not installed" <<<"$ERR"'
  manifest '{"codex": "0.5.0"}'
  fake_cli codex "codex-cli 0.5.0"
  vc --manifest "$WORLD/me.json"
  check "codex at its pin: exit 0" eq "$RC" 0
}

case_unknown() {
  vc_setup
  git -C "$WORLD/node" remote set-url origin "$WORLD/nowhere.git"
  vc
  check "fetch fails: exit 1" eq "$RC" 1
  check "the error says do not claim" eval 'grep -q "do not claim" <<<"$ERR"'
  vc_setup
  echo banana >"$WORLD/node/factory/VERSION"
  vc
  check "local VERSION not x.y.z: exit 1" eq "$RC" 1
  vc_setup
  desk_push factory/VERSION ""
  vc
  check "main's VERSION empty: exit 1" eq "$RC" 1
  vc_setup
  vc --manifest "$WORLD/missing.json"
  check "missing manifest: exit 1" eq "$RC" 1
  manifest '{"claude-code": "latest"}'
  vc --manifest "$WORLD/me.json"
  check "a manifest pin that is not x.y.z: exit 1, never a silent pass" eq "$RC" 1
}

echo "test_version_check"
for c in current version-behind numeric-compare adapter-pin-behind adapter-unpinned installed-drift unknown; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
