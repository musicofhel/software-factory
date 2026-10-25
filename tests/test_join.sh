#!/usr/bin/env bash
# T7: the join wizard (factory/bin/join.sh, factory/bin/lib/probe.sh). Offline: a temporary HOME,
# a probe root standing in for /proc and /etc, a fixture origin from tests/fixtures/make-repo.sh,
# and a closed PATH whose tools are the multi-call fake tests/fakes/join/multi plus a few real
# coreutils. Acceptance 1 (one case per refusal), 2 (slots), 3 (home-diff), 4 (nodes-cas). T12
# acceptance 6: the probe reports the bwrap shim's prerequisites (case shim-prereqs); the probe root
# is a merged-usr host unless a case says otherwise. T15: the reviewer pinned by npm integrity and
# failing closed (case review-pin, AC1), the manifest's review field (case review-field, AC2), the
# printed cux line and no credential in any argv join hands a tool (case cux-line, AC3).
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
JOIN="$BIN/join.sh"
MULTI="$REPO_ROOT/tests/fakes/join/multi"
GIB=1048576   # kB per GiB

join_setup() {
  WORLD="$(mktemp -d "${TMPDIR:-/tmp}/join.XXXXXX")"
  # shellcheck disable=SC2064  # expand now: WORLD is per case
  trap "rm -rf '$WORLD'" EXIT
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=node GIT_AUTHOR_EMAIL=node@fake GIT_COMMITTER_NAME=node GIT_COMMITTER_EMAIL=node@fake
  export HOME="$WORLD/home" FACTORY_PROBE_ROOT="$WORLD/root" FAKE_JOIN_LOG="$WORLD/fake.log" FACTORY_REPO=test/repo
  export TZ=UTC
  unset FACTORY_HOME FACTORY_HANDLE FACTORY_NOW CLAUDE_CONFIG_DIR FAKE_UNAME_S FAKE_UNAME_M FAKE_BWRAP_EXIT \
        FAKE_CLAUDE_LOGGED_IN FAKE_CLAUDE_VERSION FAKE_SUITE_SECONDS FAKE_SUITE_EXIT FAKE_SHA_MISMATCH FAKE_UID \
        FAKE_SANDBOX_EXEC_EXIT FAKE_CURL_FAIL FAKE_SHA512_MISMATCH FAKE_NPM_INSTALL_NOOP npm_config_cache CARGO_HOME \
        UV_TOOL_DIR UV_TOOL_BIN_DIR UV_CACHE_DIR
  mkdir -p "$HOME/.claude" "$WORLD/root/proc" "$WORLD/root/etc" "$WORLD/bin" "$WORLD/sys" "$WORLD/tools"
  : >"$FAKE_JOIN_LOG"
  echo 'alias ll="ls -l"' >"$HOME/.bashrc"
  echo '{"permissions": {"defaultMode": "default"}}' >"$HOME/.claude/settings.json"
  echo "Linux version 6.8.0-fake (gcc) #1 SMP" >"$WORLD/root/proc/version"
  printf 'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\n' >"$WORLD/root/etc/os-release"
  mkdir -p "$WORLD/root/usr/bin" "$WORLD/root/usr/sbin" "$WORLD/root/usr/lib" "$WORLD/root/usr/lib64" "$WORLD/root/etc/ssl"
  for t in bin sbin lib lib64; do ln -s "usr/$t" "$WORLD/root/$t"; done
  echo 'nameserver 10.0.0.1' >"$WORLD/root/etc/resolv.conf"; echo '127.0.0.1 localhost' >"$WORLD/root/etc/hosts"
  meminfo 16 12
  tests/fixtures/make-repo.sh "$WORLD/origin.git" </dev/null
  git clone -q "$WORLD/origin.git" "$WORLD/clone"
  # The closed PATH: fakes first, then stubs of "installed" tools, then real basics.
  local t
  for t in uname nproc df sysctl vm_stat bwrap claude codex make cargo uv npx npm curl sha256sum sha512sum; do
    ln -s "$MULTI" "$WORLD/bin/$t"
  done
  for t in bash env git jq sed grep awk cat date mktemp rm mkdir chmod cp mv head tail tr sort find wc \
           dirname basename id sleep readlink cut touch tar xz install ls stat ln; do
    ln -s "$(command -v "$t")" "$WORLD/sys/$t"
  done
  JPATH="$WORLD/bin:$WORLD/tools:$WORLD/sys"
}
meminfo() {  # meminfo <total-GB> <free-GB> (decimals allowed): /proc/meminfo in kB
  local tk fk
  tk="$(jq -n --argjson g "$1" --argjson k "$GIB" '$g * $k | floor')"
  fk="$(jq -n --argjson g "$2" --argjson k "$GIB" '$g * $k | floor')"
  printf 'MemTotal:       %s kB\nMemFree:        1000 kB\nMemAvailable:   %s kB\n' "$tk" "$fk" >"$WORLD/root/proc/meminfo"
}
installed() {  # installed <tool...>: put every pinned tool on PATH at its pin (as on dev-box)
  local t
  for t in "$@"; do
    case "$t" in
      vetto) v="vetto 0.6.5" ;; ralon) v="ralon 0.1.7" ;; dcg) v="0.15.3" ;; cux) v="cux 0.4.1" ;;
      tamperguard) mkdir -p "$HOME/.local/share/uv/tools/tamperguard"; echo 0.2.0 >"$HOME/.local/share/uv/tools/tamperguard/version"; continue ;;
      adlc) FH_NPX="$HOME/.factory/npm/_npx/x/node_modules/@adlc/cli"; mkdir -p "$FH_NPX"; echo '{"version": "1.12.0"}' >"$FH_NPX/package.json"; continue ;;
      adv) adv_install 2.11.1 "$ADV_INTEGRITY"; continue ;;
    esac
    printf '#!/usr/bin/env bash\necho "%s"\n' "$v" >"$WORLD/tools/$t"
    chmod +x "$WORLD/tools/$t"
  done
}
ADV_INTEGRITY=sha512-LiPc0R5UXJQ/tsUd3yEOVkISYxtbyFlvDlMFPtLW1lcVNhLjOqluDZXaVmYYEb0oONdsSs+xVbAbyWN2e0HCEA==  # ruling Q4
adv_install() {  # adv_install <version> <receipt|''>: the reviewer under ~/.factory as join's install leaves it
  local m="$HOME/.factory/lib/node_modules/adversarial-review"
  mkdir -p "$m/bin" "$HOME/.factory/bin" "$HOME/.factory/receipts"
  jq -n --arg v "$1" '{name: "adversarial-review", version: $v}' >"$m/package.json"
  printf '#!/usr/bin/env bash\necho review\n' >"$m/bin/cli.js"; chmod +x "$m/bin/cli.js"
  ln -sfn ../lib/node_modules/adversarial-review/bin/cli.js "$HOME/.factory/bin/adversarial-review"
  rm -f "$HOME/.factory/receipts/"*
  [ -z "$2" ] || printf '%s\n' "$2" >"$HOME/.factory/receipts/adversarial-review@$1"
}
all_installed() { installed vetto ralon dcg cux tamperguard adlc adv; mkdir -p "$WORLD/clone/.adlc"; }  # .adlc as main has it
jn() {  # jn <args>: join.sh in the clone on the closed PATH; sets RC, OUT, ERR
  RC=0
  OUT="$(cd "$WORLD/clone" && PATH="$JPATH" "$JOIN" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
has_err() { grep -qF -- "$1" <<<"$ERR" || { printf '      stderr lacks [%s]:\n%s\n' "$1" "$ERR" | head -20; return 1; }; }
lacks() { ! grep -qF -- "$1" <<<"$OUT$ERR" || { printf '      output holds [%s]\n' "$1"; return 1; }; }
snapshot() {  # snapshot <dir>: every path with its type, mode and content hash, sorted
  (cd "$1" && find . -mindepth 1 -printf '%y %m %p\n' | sort | while read -r y m p; do
     if [ "$y" = f ]; then printf '%s %s %s %s\n' "$y" "$m" "$p" "$(sha256sum <"$p" | cut -c1-16)"; else printf '%s %s %s\n' "$y" "$m" "$p"; fi
   done)
}

# ---------------------------------------------------------------------------------------------
case_dry_run_ok() {
  join_setup; all_installed
  jn --handle node-a --no-suite
  check "a good box: exit 0" eq "$RC" 0
  check "steps printed in order" eval 'grep -n "^== " <<<"$OUT" | cut -d" " -f2 | tr "\n" " " | grep -q "^1/5 2/5 3/5 4/5 5/5 $"'
  check "the probe line shows wsl2/linux, RAM and sandbox" eval 'grep -q "sandbox bwrap: present true, works true" <<<"$OUT"'
  check "the bwrap probe binds / read-only" eval 'jq -e "select(.tool == \"bwrap\" and .argv == [\"--unshare-all\",\"--ro-bind\",\"/\",\"/\",\"--dev\",\"/dev\",\"--proc\",\"/proc\",\"true\"])" "$FAKE_JOIN_LOG" >/dev/null'
  check "the run-loop command per slot" eval 'grep -c "factory/bin/run.sh --slot" <<<"$OUT" | grep -qx 5'
  check "RULES.md printed" eval 'grep -q "House rules" <<<"$OUT"'
  check "the nodes tip is read, nothing pushed" eval 'grep -q "would commit nodes/node-a.json on origin/nodes" <<<"$OUT"'
  check "the owner's email never printed" lacks owner-secret@example.invalid
  jn --handle node-a --no-suite --json
  check "--json: stdout is one JSON document" eq "$(jq -s length <<<"$OUT")" 1
  check "--json: manifest valid, dry-run, no refusals" \
    eq "$(jq -c '[.mode, .exit, .refusals, .manifest_errors, .manifest.slots, .manifest.adapters, .manifest.status]' <<<"$OUT")" \
       '["dry-run",0,[],[],5,{"claude-code":"2.1.280"},"joining"]'
  check "--json: the manifest records the reviewer, same family on a claude-only box" \
    eq "$(jq -c .manifest.review <<<"$OUT")" '{"tool":"adversarial-review","pin":"2.11.1","same_family":true}'
  check "--json: the probe carries no account data" lacks owner-secret
  check "every plan step installed (dev-box shape)" eq "$(jq -c '[.plan[].state] | unique' <<<"$OUT")" '["installed"]'
}

case_slots() {
  join_setup; all_installed
  local pair free want got
  for pair in 3.9:0 4:1 5.9:1 6:2 18:8 19:8 40:8; do
    free="${pair%%:*}" want="${pair#*:}"
    meminfo 64 "$free"
    jn --handle node-a --no-suite --json
    got="$(jq -r '.slots' <<<"$OUT")"
    check "free ${free} GB -> slots $want" eq "$got" "$want"
    if [ "$want" = 0 ]; then
      check "free ${free} GB refuses (exit 2)" eq "$RC" 2
      check "free ${free} GB: the refusal names slots" has_err "slots = floor(3.9 GB free / 2) - 1 = 0 < 1"
    else
      check "free ${free} GB: exit 0" eq "$RC" 0
      check "free ${free} GB: manifest carries it" eq "$(jq -r .manifest.slots <<<"$OUT")" "$want"
    fi
  done
}

case_refuse_no_sandbox() {
  join_setup; all_installed
  rm "$WORLD/bin/bwrap"
  jn --handle node-a --no-suite
  check "no bwrap: exit 2" eq "$RC" 2
  check "names the cause and the Ubuntu install line" has_err "no sandbox backend: fleet needs bwrap (ADR-0003). Install: sudo apt-get install bubblewrap"
  check "no suite ran after a refusal" eval '! grep -q suite_tmpdir "$FAKE_JOIN_LOG"'
  printf 'ID="fedora"\n' >"$WORLD/root/etc/os-release"
  jn --handle node-a --no-suite
  check "Fedora gets the dnf line" has_err "Install: sudo dnf install bubblewrap"
  ln -s "$MULTI" "$WORLD/bin/bwrap"
  export FAKE_BWRAP_EXIT=1
  jn --handle node-a --no-suite
  check "bwrap that cannot start a sandbox: exit 2" eq "$RC" 2
  check "names it" has_err "sandbox backend bwrap is installed but cannot start a sandbox here"
}

case_refuse_macos_sandbox() {
  join_setup; all_installed
  export FAKE_UNAME_S=Darwin FAKE_UNAME_M=arm64
  ln -s "$MULTI" "$WORLD/bin/sandbox-exec"
  jn --handle node-a --no-suite --json
  check "macOS with sandbox-exec: exit 0" eq "$RC" 0
  # vm_stat: (100000 + 200000 + 10000) pages * 16 KiB = 4960000 KiB free -> floor(4.73/2) - 1 = 1
  check "macOS: os, cpu, RAM from sysctl and vm_stat" \
    eq "$(jq -c '[.probe.os, .probe.cpu, .probe.ram_gb, .probe.ram_free_kb, .slots, .probe.sandbox.backend]' <<<"$OUT")" \
       '["macos",8,16,4960000,1,"sandbox-exec"]'
  check "macOS: the arm64 assets, checked with shasum" eval \
    'jq -r ".plan[] | select(.tool == \"dcg\" or .tool == \"cux\") | .commands[0]" <<<"$OUT" | grep -c "aarch64-apple-darwin.*shasum -a 256\|darwin-arm64.*shasum -a 256" | grep -qx 2'
  rm "$WORLD/bin/sandbox-exec"
  jn --handle node-a --no-suite
  check "macOS without sandbox-exec: exit 2" eq "$RC" 2
  check "names sandbox-exec" has_err "no sandbox backend: fleet needs sandbox-exec"
}

case_refuse_skip_permissions_rc() {
  join_setup; all_installed
  echo "# alias claude='claude --dangerously-skip-permissions'  (commented out: allowed)" >>"$HOME/.zshrc"
  jn --handle node-a --no-suite
  check "a commented-out alias is not a refusal" eq "$RC" 0
  echo "alias claude='claude --dangerously-skip-permissions'" >>"$HOME/.zshrc"
  jn --handle node-a --no-suite
  check "alias in ~/.zshrc: exit 2" eq "$RC" 2
  check "names the rc file" has_err "--dangerously-skip-permissions is set in $HOME/.zshrc (shell-rc"
  : >"$HOME/.zshrc"
  mkdir -p "$WORLD/root/etc/profile.d"
  echo 'export CLAUDE_FLAGS="--permission-mode bypassPermissions"' >"$WORLD/root/etc/profile.d/claude.sh"
  jn --handle node-a --no-suite
  check "bypassPermissions in /etc/profile.d: exit 2" eq "$RC" 2
  check "names that file" has_err "is set in $WORLD/root/etc/profile.d/claude.sh"
}

case_refuse_skip_permissions_settings() {
  join_setup; all_installed
  echo '{"permissions": {"defaultMode": "bypassPermissions"}}' >"$HOME/.claude/settings.json"
  jn --handle node-a --no-suite
  check "defaultMode bypassPermissions in ~/.claude/settings.json: exit 2" eq "$RC" 2
  check "names the settings file" has_err "is set in $HOME/.claude/settings.json (claude-settings, matched permissions.defaultMode = bypassPermissions)"
  echo '{}' >"$HOME/.claude/settings.json"
  mkdir -p "$WORLD/clone/.claude"
  echo '{"env": {"CLAUDE_ARGS": "--dangerously-skip-permissions"}}' >"$WORLD/clone/.claude/settings.local.json"
  jn --handle node-a --no-suite
  check "the flag in the clone's .claude/settings.local.json: exit 2" eq "$RC" 2
  check "names it" has_err "is set in $WORLD/clone/.claude/settings.local.json"
}

case_refuse_no_adapter() {
  join_setup; all_installed
  export FAKE_CLAUDE_LOGGED_IN=false
  jn --handle node-a --no-suite
  check "claude not logged in: exit 2" eq "$RC" 2
  check "names it" has_err "no authenticated adapter with a pin: claude-code not logged in, codex auth not measured, agy absent, opencode absent"
  unset FAKE_CLAUDE_LOGGED_IN
  rm "$WORLD/bin/claude"
  jn --handle node-a --no-suite
  check "no claude at all (codex installed but unpinned): exit 2" eq "$RC" 2
  check "names every adapter" has_err "claude-code absent, codex auth not measured"
}

case_refuse_schema() {
  join_setup; all_installed
  meminfo 6 5   # slots 1, but ram_gb 6 < the schema's minimum 8
  jn --handle node-a --no-suite
  check "a 6 GB box: exit 2" eq "$RC" 2
  check "the refusal quotes the schema error" has_err "the manifest fails factory/nodes/manifest.schema.json: manifest.ram_gb: 6 < minimum 8"
  meminfo 16 12
  jn --handle node-a --no-suite --quiet-start 9am
  check "a bad quiet_hours start fails the schema: exit 2" eq "$RC" 2
  check "names the field" has_err 'manifest.quiet_hours.start: "9am" does not match'
  jn --handle node-a --no-suite --quota-tier platinum
  check "an unknown quota tier: exit 2" eq "$RC" 2
}

case_refuse_other() {
  join_setup; all_installed
  ln -s "$MULTI" "$WORLD/bin/id"
  export FAKE_UID=0
  jn --handle node-a --no-suite
  check "root: exit 2" eq "$RC" 2
  check "root: names it" has_err "running as root"
  unset FAKE_UID; rm "$WORLD/bin/id"
  echo "Linux version 4.4.0-19041-Microsoft (Microsoft@Microsoft.com)" >"$WORLD/root/proc/version"
  jn --handle node-a --no-suite
  check "WSL1: exit 2" eq "$RC" 2
  check "WSL1: names the conversion" has_err "WSL1: no namespaces"
  echo "Linux version 6.18.33.2-microsoft-standard-WSL2" >"$WORLD/root/proc/version"
  jn --handle node-a --no-suite --json
  check "WSL2 is os wsl2" eq "$(jq -r .manifest.os <<<"$OUT")" wsl2
  rm "$WORLD/tools/vetto" "$WORLD/bin/cargo"
  jn --handle node-a --no-suite
  check "vetto missing and no cargo: exit 2" eq "$RC" 2
  check "names the blocked install" has_err "install vetto 0.6.5: cargo not found"
  printf 'ghp_%s\n' 0123456789abcdefghij0123 >"$WORLD/classic"
  ln -s "$MULTI" "$WORLD/bin/cargo"
  jn --handle node-a --no-suite --token-file "$WORLD/classic"
  check "a classic token: exit 2" eq "$RC" 2
  check "names it, never prints it" eval 'has_err "holds a classic or app token" && lacks 0123456789abcdefghij'
  mkdir -p "$WORLD/awsdir"; ln -s "$WORLD/awsdir" "$HOME/.aws"
  jn --handle node-a --no-suite --json
  check "a symlinked ~/.aws is a warning, not a refusal" eval \
    '[ "$RC" = 0 ] && jq -r ".warnings[0]" <<<"$OUT" | grep -qF "vetto 0.6.5 masks $HOME/.aws (a symlink to a directory) and fails closed"'
}

case_heavy_gates() {
  join_setup; all_installed
  jn --handle node-a --json --suite-timeout-seconds 30
  check "a fast green suite: heavy_gates true" eq "$(jq -c '[.heavy_gates, .suite.exit, .suite.timed_out, .manifest.heavy_gates]' <<<"$OUT")" '[true,0,false,true]'
  local tmp
  tmp="$(jq -r 'select(.suite_tmpdir) | .suite_tmpdir' "$FAKE_JOIN_LOG")"
  check "the suite ran in the clone" eq "$(jq -r 'select(.suite_tmpdir) | .pwd' "$FAKE_JOIN_LOG")" "$WORLD/clone"
  check "with its own TMPDIR, removed after" eval '[ -n "$tmp" ] && [ ! -e "$tmp" ]'
  check "the default timeout is budget.json light suiteMinutesMax" eval \
    'jn --handle node-a --json; [ "$(jq -r .suite.timeout_seconds <<<"$OUT")" = "$(( $(jq .weights.light.suiteMinutesMax "$REPO_ROOT/factory/policy/budget.json") * 60 ))" ]'
  export FAKE_SUITE_EXIT=1
  jn --handle node-a --json --suite-timeout-seconds 30
  check "a red suite: heavy_gates false, exit 0, warned" eq "$(jq -c '[.heavy_gates, .exit, (.warnings[0] | startswith("make test exited 1"))]' <<<"$OUT")" '[false,0,true]'
  export FAKE_SUITE_EXIT=0 FAKE_SUITE_SECONDS=30
  local t0; t0="$(date +%s)"
  jn --handle node-a --json --suite-timeout-seconds 1
  check "a slow suite is stopped at the timeout: heavy_gates false" eq "$(jq -c '[.heavy_gates, .suite.timed_out]' <<<"$OUT")" '[false,true]'
  local took=$(( $(date +%s) - t0 ))
  check "the timeout kills the whole suite (returned in < 10 s)" eq "$(( took < 10 ))" 1
  jn --handle node-a --json --no-suite
  check "--no-suite: heavy_gates false, suite not run" eq "$(jq -c '[.heavy_gates, .suite.ran]' <<<"$OUT")" '[false,false]'
}

case_plan() {
  join_setup
  jn --handle node-a --no-suite --json
  check "nothing installed: exit 0 (dry run)" eq "$RC" 0
  check "every pinned tool is planned missing" \
    eq "$(jq -c '[.plan[] | select(.state == "missing") | .tool]' <<<"$OUT")" '["@adlc/cli","adlc init","vetto","ralon","tamperguard","dcg","cux","adversarial-review"]'
  local fh="$HOME/.factory"
  check "cargo installs under FACTORY_HOME, locked, at the pin" \
    eq "$(jq -r '.plan[] | select(.tool == "vetto") | .commands[0]' <<<"$OUT")" "CARGO_HOME=$fh/cargo cargo install --locked --root $fh vetto@0.6.5"
  check "uv installs under FACTORY_HOME" eval 'jq -r ".plan[] | select(.tool == \"tamperguard\") | .commands[0]" <<<"$OUT" | grep -q "UV_TOOL_BIN_DIR=$fh/bin .* uv tool install tamperguard==0.2.0$"'
  check "dcg: the musl asset, the pinned sha256" eval 'jq -r ".plan[] | select(.tool == \"dcg\") | .commands[0]" <<<"$OUT" | grep -q "dcg-x86_64-unknown-linux-musl.tar.xz.*dc7dcec9679f74ac3e6990959771ca0c84168eba658eff64fe9e63f917a84cc4"'
  check "cux: the pinned sha256" eval 'jq -r ".plan[] | select(.tool == \"cux\") | .commands[0]" <<<"$OUT" | grep -q "v0.4.1/cux-linux-amd64.*d336d1f8a6175265977f5a08ce53c20403e13752b90826df1128c29d89401df6"'
  check "no command uses sudo" eval '! jq -r ".plan[].commands[]" <<<"$OUT" | grep -q sudo'
  check "the dry run ran no installer" eval '! jq -e "select(.tool | IN(\"cargo\",\"curl\",\"npx\",\"npm\") ) " "$FAKE_JOIN_LOG" >/dev/null 2>&1'
  export FAKE_CLAUDE_VERSION=2.1.200
  jn --handle node-a --no-suite --json
  check "a drifted claude is re-pinned with npm under FACTORY_HOME" \
    eq "$(jq -r '.plan[] | select(.tool == "claude-code") | "\(.state) \(.found) \(.commands[0])"' <<<"$OUT")" \
       "drift 2.1.200 npm install -g --prefix $fh --cache $fh/npm @anthropic-ai/claude-code@2.1.280"
  check "the manifest records the pin, not the drift" eq "$(jq -r '.manifest.adapters["claude-code"]' <<<"$OUT")" 2.1.280
}

case_home_diff() {
  join_setup
  local h0 c0
  h0="$(snapshot "$HOME")"; c0="$(snapshot "$WORLD/clone")"
  jn --handle node-a --no-suite
  check "dry run: exit 0" eq "$RC" 0
  check "dry run: \$HOME unchanged" eq "$(snapshot "$HOME")" "$h0"
  check "dry run: the clone unchanged, .git included" eq "$(snapshot "$WORLD/clone")" "$c0"
  printf 'github_pat_%s\n' 11ABCDEFG0123456789_abcdefghijklmnop >"$WORLD/pat"
  jn --handle node-a --apply --token-file "$WORLD/pat" --suite-timeout-seconds 30
  check "apply from nothing: exit 0" eq "$RC" 0
  check "apply: every change in \$HOME is under ~/.factory" eval \
    '[ -z "$(diff <(printf "%s\n" "$h0") <(snapshot "$HOME") | grep "^[<>]" | grep -v "^[<>] [a-z] [0-7]* ./.factory\(/\|$\)")" ]'
  check "apply: the worktree changed only by adlc init (.adlc was missing)" eq "$(git -C "$WORLD/clone" status --porcelain)" "?? .adlc/"
  check "apply: tools landed in ~/.factory/bin" eval 'for t in vetto ralon dcg cux tamperguard adversarial-review; do [ -x "$HOME/.factory/bin/$t" ] || exit 1; done'
  check "apply: dcg and cux verified against the pinned sha256, the reviewer against its sha512" eq \
    "$(jq -r 'select(.sha_check) | "\(.bits):\(.sha_check)"' "$FAKE_JOIN_LOG" | tr '\n' ' ')" \
    "256:dc7dcec9679f74ac3e6990959771ca0c84168eba658eff64fe9e63f917a84cc4 256:d336d1f8a6175265977f5a08ce53c20403e13752b90826df1128c29d89401df6 512:2e23dcd11e545c943fb6c51ddf210e564212631b5bc8596f0e53053ed2d6d657153612e33aa96e0d95da56661811bd2838d76c4acfb155b01bc963767b41c210 "
  check "apply: the token at ~/.factory/token, 0600, never printed" eval \
    '[ "$(stat -c %a "$HOME/.factory/token")" = 600 ] && grep -q ^github_pat_11ABC "$HOME/.factory/token" && lacks 11ABCDEFG0123456789'
  check "apply: ~/.factory is 0700" eq "$(stat -c %a "$HOME/.factory")" 700
  check "apply: env puts ~/.factory/bin first and names the manifest" eval \
    'grep -q "^export PATH=$HOME/.factory/bin:\"\$PATH\"$" "$HOME/.factory/env" && grep -q "^export FACTORY_MANIFEST=$HOME/.factory/manifest.json$" "$HOME/.factory/env"'
  check "apply: ~/.factory/manifest.json is valid" eval 'PATH="$JPATH" "$JOIN" --validate "$HOME/.factory/manifest.json" >/dev/null'
  check "apply: no tmp debris" eval '[ -z "$(ls -A "$HOME/.factory/tmp")" ]'
  export FAKE_SHA_MISMATCH=1
  rm -rf "$HOME/.factory/bin/dcg" "$HOME/.factory/bin/cux"
  jn --handle node-a --apply --no-suite
  check "a sha256 mismatch stops the install: exit 1" eq "$RC" 1
  check "and installs nothing unverified" eval '[ ! -e "$HOME/.factory/bin/dcg" ]'
}

case_nodes_cas() {
  join_setup; all_installed
  local tip0
  tip0="$(git -C "$WORLD/origin.git" rev-parse nodes)"
  jn --handle node-a --apply --no-suite --json
  check "apply: exit 0, pushed in one attempt" eq "$(jq -c '[.exit, .nodes.pushed, .nodes.attempts]' <<<"$OUT")" '[0,true,1]'
  local tip1; tip1="$(git -C "$WORLD/origin.git" rev-parse nodes)"
  check "origin nodes moved by exactly one commit on top of the old tip" eq "$(git -C "$WORLD/origin.git" rev-parse "$tip1^")" "$tip0"
  check "the commit is the one reported" eq "$(jq -r .nodes.commit <<<"$OUT")" "$tip1"
  git -C "$WORLD/origin.git" show "$tip1:nodes/node-a.json" >"$WORLD/pushed.json"
  check "the pushed manifest is valid and is node-a's" eval \
    'PATH="$JPATH" "$JOIN" --validate "$WORLD/pushed.json" >/dev/null && [ "$(jq -r .handle "$WORLD/pushed.json")" = node-a ]'
  check "the commit touches only nodes/node-a.json" eq "$(git -C "$WORLD/origin.git" diff --name-only "$tip0" "$tip1")" nodes/node-a.json
  check "the commit carries the Node trailer" eq "$(git -C "$WORLD/origin.git" log -1 --format='%(trailers:key=Node,valueonly)' "$tip1" | head -n1)" node-a

  # A racer pushes another node's manifest right after the wizard's fetch lands (the clone's
  # reference-transaction hook sees refs/remotes/origin/nodes commit), so the wizard's commit is
  # built on a tip that is already stale: a plain push must lose, and a forced one would erase
  # the racer.
  git clone -q "$WORLD/origin.git" "$WORLD/racer"
  git -C "$WORLD/racer" checkout -q nodes
  command cat >"$WORLD/clone/.git/hooks/reference-transaction" <<EOF
#!/usr/bin/env bash
[ "\$1" = committed ] && awk '\$3 == "refs/remotes/origin/nodes" && \$2 !~ /^0+\$/ { f = 1 } END { exit !f }' || exit 0
[ -e "$WORLD/race.once" ] && [ ! -e "$WORLD/race.always" ] && exit 0
touch "$WORLD/race.once"
cd "$WORLD/racer" && unset GIT_DIR GIT_INDEX_FILE && git pull -q --ff-only origin nodes && date +%s%N >>nodes/racer.json &&
  git add -A && git commit -qm racer && git push -q origin nodes
EOF
  chmod +x "$WORLD/clone/.git/hooks/reference-transaction"
  git -C "$WORLD/clone" update-ref -d refs/remotes/origin/nodes   # so the wizard's fetch writes it
  jn --handle node-b --apply --no-suite --json
  check "a lost race retries and lands: exit 0, 2 attempts" eq "$(jq -c '[.exit, .nodes.pushed, .nodes.attempts]' <<<"$OUT")" '[0,true,2]'
  local tip2 racer; tip2="$(git -C "$WORLD/origin.git" rev-parse nodes)"
  racer="$(git -C "$WORLD/racer" rev-parse HEAD)"
  check "the racer's commit survives (no force): it is our parent" eq "$(git -C "$WORLD/origin.git" rev-parse "$tip2^")" "$racer"
  check "both manifests and the racer file are on nodes" eval \
    'git -C "$WORLD/origin.git" cat-file -e "$tip2:nodes/node-a.json" && git -C "$WORLD/origin.git" cat-file -e "$tip2:nodes/node-b.json" && git -C "$WORLD/origin.git" cat-file -e "$tip2:nodes/racer.json"'
  check "the retry is narrated" eval 'jq -r .nodes <<<"$OUT" >/dev/null && grep -q "lost the compare-and-swap" <<<"$ERR"'

  touch "$WORLD/race.always"
  git -C "$WORLD/clone" update-ref -d refs/remotes/origin/nodes
  jn --handle node-c --apply --no-suite
  check "losing every race fails cleanly: exit 1" eq "$RC" 1
  check "names it" has_err "lost the compare-and-swap on origin/nodes 3 times; nothing was forced"
  check "origin nodes is the racer's, node-c never landed" eval \
    '[ "$(git -C "$WORLD/origin.git" rev-parse nodes)" = "$(git -C "$WORLD/racer" rev-parse HEAD)" ] && ! git -C "$WORLD/origin.git" cat-file -e nodes:nodes/node-c.json 2>/dev/null'
  rm "$WORLD/clone/.git/hooks/reference-transaction"

  jn --handle node-a --owner someone-else --apply --no-suite
  check "a handle another owner holds: exit 2" eq "$RC" 2
  check "names the holder" has_err "handle node-a is held by owner node-a on origin/nodes"
  jn --handle node-a --apply --no-suite
  check "the same owner re-joining is a heartbeat: exit 0" eq "$RC" 0
}

case_no_nodes_branch() {
  join_setup; all_installed
  git -C "$WORLD/origin.git" update-ref -d refs/heads/nodes
  jn --handle node-a --no-suite --json
  check "dry run: exit 0, tip null" eq "$(jq -c '[.exit, .nodes.tip, .nodes.reachable]' <<<"$OUT")" '[0,null,true]'
  jn --handle node-a --apply --no-suite
  check "apply without a nodes branch: exit 1, says who creates it" eval '[ "$RC" = 1 ] && has_err "the nodes branch must exist"'
}

case_validator() {
  join_setup
  local ex="$REPO_ROOT/factory/nodes/example.json"
  jn --validate "$ex"
  check "example.json is valid" eq "$RC" 0
  bad() {  # bad <name> <jq-mutation> <expected stderr fragment>
    jq "$2" "$ex" >"$WORLD/m.json"
    jn --validate "$WORLD/m.json"
    check "$1: exit 2" eq "$RC" 2
    check "$1: says why" has_err "$3"
  }
  bad "extra property" '.colour = "red"' "manifest: unexpected property colour"
  bad "missing field" 'del(.slots)' "manifest: missing slots"
  bad "slots 9" '.slots = 9' "manifest.slots: 9 > maximum 8"
  bad "slots 1.5" '.slots = 1.5' "manifest.slots: expected integer, got number"
  bad "unknown adapter" '.adapters = {"vim": "1.0.0"}' 'manifest.adapters key "vim": "vim" is not one of'
  bad "adapter version" '.adapters["claude-code"] = "latest"' 'manifest.adapters.claude-code: "latest" does not match'
  bad "no adapters" '.adapters = {}' "manifest.adapters: fewer than 1 properties"
  bad "date-time" '.last_seen = "yesterday"' 'manifest.last_seen: "yesterday" is not a date-time'
  bad "quota_cap 0" '.quota_cap = 0' "manifest.quota_cap: 0 <= exclusiveMinimum 0"
  bad "review.same_family not a boolean" '.review.same_family = "yes"' "manifest.review.same_family: expected boolean, got string"
  bad "review.tool another reviewer" '.review.tool = "llm-panel"' 'manifest.review.tool: "llm-panel" is not one of "adversarial-review"'
  bad "review without a pin" 'del(.review.pin)' "manifest.review: missing pin"
  bad "review with an extra field" '.review.provider = "claude"' "manifest.review: unexpected property provider"
  bad "review.pin not a version" '.review.pin = "latest"' 'manifest.review.pin: "latest" does not match'
  jq 'del(.review)' "$ex" >"$WORLD/m.json"
  jn --validate "$WORLD/m.json"
  check "a manifest written before the review field still validates" eq "$RC" 0
  jq '.adapters = {"gemini": "1.0.0", "copilot": "1.2.3"}' "$ex" >"$WORLD/m.json"
  jn --validate "$WORLD/m.json"
  check "every fleet adapter name in adapters.json is accepted" eq "$RC" 0
  check "the schema's adapter names are adapters.json's keys" eq \
    "$(jq -c '.properties.adapters.propertyNames.enum | sort' "$REPO_ROOT/factory/nodes/manifest.schema.json")" \
    "$(jq -c 'keys | sort' "$REPO_ROOT/factory/policy/adapters.json")"
  # Fail closed on a schema keyword the validator does not implement: a copy of the wizard with a
  # schema that uses `uniqueItems`.
  mkdir -p "$WORLD/repo/factory/bin/lib" "$WORLD/repo/factory/nodes"
  cp "$JOIN" "$WORLD/repo/factory/bin/"; cp "$BIN/lib/common.sh" "$WORLD/repo/factory/bin/lib/"
  jq '.properties.cpu.uniqueItems = true' "$REPO_ROOT/factory/nodes/manifest.schema.json" >"$WORLD/repo/factory/nodes/manifest.schema.json"
  RC=0; (cd "$WORLD" && PATH="$JPATH" "$WORLD/repo/factory/bin/join.sh" --validate "$ex" 2>"$WORLD/err") || RC=$?
  ERR="$(command cat "$WORLD/err")"
  check "an unsupported schema keyword fails closed" eval '[ "$RC" = 2 ] && has_err "manifest.cpu: schema keyword not supported by the validator: uniqueItems"'
}

case_usage() {
  join_setup; all_installed
  jn --no-suite
  check "no handle: exit 1" eq "$RC" 1
  jn --handle -bad --no-suite
  check "a bad handle: exit 1" eq "$RC" 1
  jn --handle node-a --accounts 0
  check "accounts 0: exit 1" eq "$RC" 1
  jn --handle node-a --quota-cap 1.5
  check "quota cap 1.5: exit 1" eq "$RC" 1
  RC=0; (cd "$WORLD" && PATH="$JPATH" "$JOIN" --handle node-a --no-suite >/dev/null 2>&1) || RC=$?
  check "outside a git clone: exit 1" eq "$RC" 1
  jn --handle node-a --no-suite --tz Mars/Olympus
  check "an unknown time zone: exit 2" eq "$RC" 2
  jn --handle node-a --no-suite --tz America/New_York --quiet-start 08:30 --quiet-end 18:00 --accounts 2 --quota-tier max --json
  check "the owner's flags land in the manifest" \
    eq "$(jq -c '[.manifest.quiet_hours, .manifest.accounts, .manifest.quota_tier, .manifest.quota_cap]' <<<"$OUT")" \
       '[{"tz":"America/New_York","start":"08:30","end":"18:00"},2,"max",0.4]'
}

cd "$REPO_ROOT"
case_shim_prereqs() {
  join_setup; all_installed
  jn --handle node-a --no-suite --json
  check "a merged-usr box: the probe carries the shim's prerequisites, no warning" \
    eq "$(jq -c '[.exit, (.probe.sandbox.shim | .fleet_pin, .bwrap, .ready, .merged_usr), .warnings]' <<<"$OUT")" \
       "[0,\"1.12.0\",\"$WORLD/bin/bwrap\",true,true,[]]"
  check "  every host path the shim reads, with what it inserts" \
    eq "$(jq -c '[.probe.sandbox.shim.paths[] | "\(.path) \(.insert // .why)"]' <<<"$OUT")" \
       '["/usr ro-bind","/bin symlink","/sbin symlink","/lib symlink","/lib64 symlink","/etc/ssl ro-bind","/etc/resolv.conf ro-bind","/etc/hosts ro-bind"]'
  jn --handle node-a --no-suite
  check "  the report prints a shim line" grep -qF -- "bwrap shim for fleet 1.12.0 (ADR-0006): real bwrap $WORLD/bin/bwrap, ready true, merged usr true; adds /usr /bin->usr/bin" <<<"$OUT"
  rm "$WORLD/root/bin"; mkdir "$WORLD/root/bin"
  jn --handle node-a --no-suite --json
  check "/bin a real directory: exit 0, a warning names /bin/sh and #1266" \
    eq "$(jq -c '[.exit, .probe.sandbox.shim.merged_usr, (.warnings | length), (.warnings[0] | test("finds no /bin/sh.*adlc#1266"))]' <<<"$OUT")" '[0,false,1,true]'
  rm -rf "$WORLD/root/usr"
  jn --handle node-a --no-suite --json
  check "no /usr: exit 0, the warning says the shim cannot run" \
    eq "$(jq -c '[.exit, .probe.sandbox.shim.ready, (.warnings[0] | startswith("the bwrap shim (ADR-0006) cannot run here (no /usr to bind)"))]' <<<"$OUT")" '[0,false,true]'
  rm "$WORLD/bin/bwrap"
  jn --handle node-a --no-suite --json
  check "no bwrap: refused for the sandbox, no shim warning on top" \
    eq "$(jq -c '[.exit, .probe.sandbox.shim.bwrap, (.warnings | length)]' <<<"$OUT")" '[2,null,0]'
  ln -s "$MULTI" "$WORLD/bin/sandbox-exec"
  FAKE_UNAME_S=Darwin jn --handle node-a --no-suite --json
  check "macOS: no shim" eq "$(jq -c '.probe.sandbox.shim' <<<"$OUT")" null
}

case_review_pin() {
  join_setup; all_installed
  local fh="$HOME/.factory" hex integ m cmd tip0
  hex="$(sed -n 's/^ADV_SHA512=//p' "$JOIN")" integ="$(sed -n 's/^ADV_INTEGRITY=//p' "$JOIN")"
  check "join pins the ruling's integrity" eq "$integ" "$ADV_INTEGRITY"
  check "  and ADV_SHA512 is that integrity in hex" eq "$hex" "$(printf '%s' "${integ#sha512-}" | base64 -d | od -An -tx1 -v | tr -d ' \n')"
  jn --handle node-a --no-suite --json
  check "a verified install under ~/.factory is installed: exit 0" \
    eq "$(jq -c '[.exit, (.plan[] | select(.tool == "adversarial-review") | .pin, .state, .found)]' <<<"$OUT")" '[0,"2.11.1","installed","2.11.1"]'

  rm -rf "${fh:?}/lib" "$fh/bin/adversarial-review" "$fh/receipts"
  jn --handle node-a --no-suite --json
  cmd="$(jq -r '.plan[] | select(.tool == "adversarial-review") | .commands[0]' <<<"$OUT")"
  check "absent: planned missing, one command" eq "$(jq -c '[.plan[] | select(.tool == "adversarial-review") | .state, (.commands | length)]' <<<"$OUT")" '["missing",1]'
  check "  the command, in full" eq "$cmd" \
    "rm -f $fh/receipts/adversarial-review@2.11.1 && d=\$(mktemp -d $fh/tmp/adversarial-review.XXXXXX) && trap 'rm -rf \"\$d\"' EXIT && npm pack adversarial-review@2.11.1 --pack-destination \"\$d\" --cache $fh/npm --silent >/dev/null && printf '%s  %s\n' $hex \"\$d/adversarial-review-2.11.1.tgz\" | sha512sum -c - && npm install -g --prefix $fh --cache $fh/npm --no-audit --no-fund --ignore-scripts \"\$d/adversarial-review-2.11.1.tgz\" && mkdir -p $fh/receipts && printf '%s\n' $ADV_INTEGRITY >$fh/receipts/adversarial-review@2.11.1"
  check "  no sudo, no npx, no registry spec handed to npm install" eval '! grep -qE "sudo|npx|npm install[^&]*adversarial-review@" <<<"$cmd"'
  check "  the dry run ran no npm" eval '! jq -e "select(.tool == \"npm\")" "$FAKE_JOIN_LOG" >/dev/null'
  FAKE_UNAME_S=Darwin FAKE_UNAME_M=arm64 jn --handle node-a --no-suite --json
  check "  macOS checks it with shasum -a 512" eval 'jq -r ".plan[] | select(.tool == \"adversarial-review\") | .commands[0]" <<<"$OUT" | grep -qF "| shasum -a 512 -c - && npm install"'

  # AC1: a tarball whose sha512 is not the pin fails closed.
  tip0="$(git -C "$WORLD/origin.git" rev-parse nodes)"
  : >"$FAKE_JOIN_LOG"
  export FAKE_SHA512_MISMATCH=1
  jn --handle node-a --apply --no-suite
  check "a mismatching integrity: --apply exits 1" eq "$RC" 1
  check "  names the failed step" has_err "install step failed: rm -f $fh/receipts/adversarial-review@2.11.1"
  check "  the pinned digest was checked against the packed tarball" \
    eq "$(jq -r 'select(.bits == 512) | "\(.sha_check) \(.file | test("/tmp/adversarial-review\\.[^/]+/adversarial-review-2\\.11\\.1\\.tgz$"))"' "$FAKE_JOIN_LOG")" "$hex true"
  check "  npm never installed it" eval '! jq -e "select(.tool == \"npm\" and .argv[0] == \"install\")" "$FAKE_JOIN_LOG" >/dev/null'
  check "  nothing installed or recorded: no package, no bin link, no receipt" \
    eval '[ ! -e "$fh/lib/node_modules/adversarial-review" ] && [ ! -e "$fh/bin/adversarial-review" ] && [ -z "$(ls -A "$fh/receipts" 2>/dev/null)" ]'
  check "  no manifest pushed" eq "$(git -C "$WORLD/origin.git" rev-parse nodes)" "$tip0"
  check "  and its temp dir is gone" eq "$(ls -A "$fh/tmp")" ""
  unset FAKE_SHA512_MISMATCH
  jn --handle node-a --no-suite --json
  check "  the next dry run still plans it missing" eq "$(jq -r '.plan[] | select(.tool == "adversarial-review") | .state' <<<"$OUT")" missing

  FAKE_NPM_INSTALL_NOOP=1 jn --handle node-a --apply --no-suite
  check "npm exits 0 but installs nothing: --apply exits 1 after its own check" \
    eval '[ "$RC" = 1 ] && has_err "adversarial-review is not at 2.11.1 with its pinned integrity under $fh after the install"'
  : >"$FAKE_JOIN_LOG"
  jn --handle node-a --apply --no-suite
  check "a matching integrity: --apply exits 0" eq "$RC" 0
  check "  npm installed the very tarball that was checked" \
    eq "$(jq -r 'select(.tool == "npm" and .argv[0] == "install") | .argv[-1]' "$FAKE_JOIN_LOG")" "$(jq -r 'select(.bits == 512) | .file' "$FAKE_JOIN_LOG")"
  check "  under ~/.factory: package at the pin, bin linked, receipt = the integrity" \
    eq "$(jq -r .version "$fh/lib/node_modules/adversarial-review/package.json") $([ -x "$fh/bin/adversarial-review" ] && echo linked) $(command cat "$fh/receipts/adversarial-review@2.11.1")" "2.11.1 linked $ADV_INTEGRITY"
  check "  the npm cache is ~/.factory/npm and no temp dir is left" \
    eval '[ -e "$fh/npm/_cacache/fetched-adversarial-review" ] && [ -z "$(ls -A "$fh/tmp")" ] && [ ! -e "$HOME/.npm" ]'
  jn --handle node-a --no-suite --json
  check "  the next dry run: installed" eq "$(jq -r '.plan[] | select(.tool == "adversarial-review") | .state' <<<"$OUT")" installed

  rm "$fh/receipts/adversarial-review@2.11.1"
  jn --handle node-a --no-suite --json
  check "2.11.1 with no receipt: drift, reinstalled" \
    eq "$(jq -c '.plan[] | select(.tool == "adversarial-review") | [.state, .found]' <<<"$OUT")" '["drift","2.11.1 without a verified install"]'
  adv_install 2.11.1 sha512-AAAA
  jn --handle node-a --no-suite --json
  check "a receipt naming another integrity: drift" eq "$(jq -r '.plan[] | select(.tool == "adversarial-review") | .state' <<<"$OUT")" drift
  adv_install 2.10.0 "$ADV_INTEGRITY"
  jn --handle node-a --no-suite --json
  check "another version: drift, found 2.10.0" eq "$(jq -c '.plan[] | select(.tool == "adversarial-review") | [.state, .found]' <<<"$OUT")" '["drift","2.10.0"]'
  rm -rf "${fh:?}/lib" "$fh/bin/adversarial-review" "$fh/receipts"
  printf '#!/usr/bin/env bash\necho review\n' >"$WORLD/tools/adversarial-review"; chmod +x "$WORLD/tools/adversarial-review"
  jn --handle node-a --no-suite --json
  check "a copy elsewhere on PATH does not count (no receipt to check): missing" \
    eq "$(jq -r '.plan[] | select(.tool == "adversarial-review") | .state' <<<"$OUT")" missing

  rm "$WORLD/bin/sha512sum"
  jn --handle node-a --no-suite
  check "no sha512sum: refused, named" eval '[ "$RC" = 2 ] && has_err "install adversarial-review 2.11.1: sha512sum not found (needed to verify the reviewer'"'"'s npm integrity)"'
  rm "$WORLD/bin/npm"
  jn --handle node-a --no-suite
  check "no npm: refused, named" eval '[ "$RC" = 2 ] && has_err "install adversarial-review 2.11.1: npm not found"'
  adv_install 2.11.1 "$ADV_INTEGRITY"
  jn --handle node-a --no-suite
  check "no npm but the reviewer verified at its pin: not refused" eq "$RC" 0
}

case_review_field() {
  join_setup; all_installed
  jn --handle node-a --apply --no-suite --json
  check "apply: exit 0" eq "$RC" 0
  git -C "$WORLD/origin.git" show nodes:nodes/node-a.json >"$WORLD/pushed.json"
  check "the pushed manifest records the reviewer and same_family" \
    eq "$(jq -c .review "$WORLD/pushed.json")" '{"tool":"adversarial-review","pin":"2.11.1","same_family":true}'
  check "  and validates against the schema" eval 'PATH="$JPATH" "$JOIN" --validate "$WORLD/pushed.json" >/dev/null'
  check "the schema's review pin is join's pin" eq "$(sed -n 's/^ADV_VERSION=//p' "$JOIN")" "$(jq -r .review.pin "$WORLD/pushed.json")"
}

case_cux_line() {
  join_setup
  local fh="$HOME/.factory" cred0
  printf '{"claudeAiOauth": {"accessToken": "sk-ant-oat01-CREDSECRET", "refreshToken": "sk-ant-ort01-CREDSECRET"}}\n' >"$HOME/.claude/.credentials.json"
  cred0="$(snapshot "$HOME/.claude")"
  jn --handle node-a --no-suite
  check "the register step prints the cux line, who runs it, and why" eval \
    'grep -qF "  c. Quota account, run by you after \`. $fh/env\` (the wizard never runs it): cux add --no-alias" <<<"$OUT" &&
     grep -qF "Why: the run loop'"'"'s governor (factory/bin/lib/governor.sh) reads \`cux usage show\` before every claim and never claims on an unknown reading: with no cux account every slot sleeps 10 minutes" <<<"$OUT" &&
     grep -qF -- "--no-alias: the factory counts accounts and never names them" <<<"$OUT"'
  check "  it sits in step 3, before the manifest" eval 'sed -n "/^== 3\/5/,/^== 4\/5/p" <<<"$OUT" | grep -qF "cux add --no-alias"'
  jn --handle node-a --no-suite --json
  check "--json: register.quota carries the exact command" \
    eq "$(jq -c '.register.quota | [.command, .after, .run_by]' <<<"$OUT")" "[\"cux add --no-alias\",\". $fh/env\",\"owner\"]"
  check "  the sleep it names is budget.json's" eval \
    'jq -r .register.quota.why <<<"$OUT" | grep -qF "sleeps $(jq .governor.unknownStateSleepMinutes "$REPO_ROOT/factory/policy/budget.json") minutes"'

  # --apply from nothing installs the real-shaped cux (a copy of the fake that logs every call).
  printf 'github_pat_%s\n' 11ABCDEFG0123456789_abcdefghijklmnop >"$WORLD/pat"
  : >"$FAKE_JOIN_LOG"
  jn --handle node-a --apply --no-suite --token-file "$WORLD/pat"
  check "apply: exit 0" eq "$RC" 0
  check "  cux was installed and called only for its version (never cux add)" \
    eq "$(jq -sc '[.[] | select(.tool == "cux") | .argv] | unique' "$FAKE_JOIN_LOG")" '[["--version"]]'
  check "  no tool join ran got a credential in its argv (token, key, password, secret, credential)" eval \
    '! jq -r ".argv[]?" "$FAKE_JOIN_LOG" | grep -qiE "token|passw|secret|api[-_]?key|credential|github_pat_|sk-ant-"'
  check "  the token never reached an argv or the output" eval '! grep -q 11ABCDEFG0123456789 "$FAKE_JOIN_LOG" && lacks 11ABCDEFG0123456789'
  check "  the claude credential: never printed, file untouched" \
    eq "$(lacks CREDSECRET && [ "$(snapshot "$HOME/.claude")" = "$cred0" ] && echo yes)" yes
  check "  no cux store was created" eval '[ ! -e "$HOME/.config/cux" ] && [ ! -e "$HOME/.cux" ] && [ -z "$(find "$fh" -path "*cux*" ! -path "$fh/bin/cux" ! -path "$fh/tmp/cux*" -print -quit)" ]'
}

for c in dry-run-ok slots refuse-no-sandbox refuse-macos-sandbox refuse-skip-permissions-rc \
         refuse-skip-permissions-settings refuse-no-adapter refuse-schema refuse-other heavy-gates plan \
         home-diff nodes-cas no-nodes-branch validator usage shim-prereqs review-pin review-field cux-line; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
