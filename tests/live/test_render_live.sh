#!/usr/bin/env bash
# T17 acceptance 4 against the REAL tools (`make live`, never `make test`): the run loop's tamperguard
# step (factory/bin/lib/policy-render.sh, as run.sh calls it) under vetto 0.6.5 and the claim's
# render of factory/policy/build.toml, for a linked worktree. Prints `SKIP <reason>` and exits 0
# only when a tool is absent.
#
#   render    policy_roots + policy_render under the real HOME: the render differs from the template
#             only by absolute allow_read roots (I14); the roots are printed (INFO)
#   scratch   vetto under a scratch HOME (ruling Q2 of specs/factory-run-calls-v1: vetto 0.6.5 cannot
#             start under this box's real HOME, ADR-0005 amendment T6 item 10), the render's roots
#             pointing at the real uv tool and python dirs: tamperguard rc 0 and a JSON verdict
#   template  the same step under build.toml itself fails closed (no rc 0 with a verdict)
#   minus     each extra root dropped in turn (INFO: which ones are load-bearing)
#   real HOME the same step under the real HOME: when the host has the masking defect (a symlink at
#             ~/.aws) vetto refuses to start and the step never runs (fail-closed), else a verdict
#
# Results are read from the rc and JSON files the command writes, never from vetto's exit status
# (125 after every session, ADR-0005 amendment T6 item 1). The scratch tree lives under
# ${FACTORY_LIVE_TMP:-$HOME/.cache}, not /tmp (vetto strict mounts a private tmpfs there).
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/../fakes/lib.sh"
# shellcheck source=factory/bin/lib/policy-render.sh
. "$REPO_ROOT/factory/bin/lib/policy-render.sh"
TPL="$REPO_ROOT/factory/policy/build.toml"
echo "test_render_live"

[ "$(uname -s)" = Linux ] || { echo "SKIP not Linux (vetto's full tier)"; exit 0; }
for t in vetto tamperguard git jq timeout; do
  command -v "$t" >/dev/null || { echo "SKIP $t not installed"; exit 0; }
done

FAILED=0
info() { printf '    INFO %s\n' "$*"; }
check "vetto is the pinned 0.6.5" eq "$(vetto --version)" "vetto 0.6.5"

base="${FACTORY_LIVE_TMP:-$HOME/.cache}"
mkdir -p "$base"
S="$(mktemp -d "$base/factory-render-live.XXXXXX")"
trap 'chmod -R u+w "$S" 2>/dev/null; rm -rf "$S"' EXIT
H="$S/home" C="$S/clone" W="$S/wt" P="$S/fh/run/policy"
mkdir -p "$H/.factory/cache" "$P"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=live GIT_AUTHOR_EMAIL=live@fake GIT_COMMITTER_NAME=live GIT_COMMITTER_EMAIL=live@fake
git init -q -b main "$C"
mkdir -p "$C/tests"; printf 'def test_a():\n    assert 1 + 1 == 2\n' >"$C/tests/test_a.py"
git -C "$C" add -A; git -C "$C" commit -q -m base
B="$(git -C "$C" rev-parse HEAD)"
printf 'def test_b():\n    assert "a".upper() == "A"\n' >>"$C/tests/test_a.py"
git -C "$C" commit -q -am tip
T="$(git -C "$C" rev-parse HEAD)"
# the loop's shape: a detached linked worktree at the tip, its git dir outside the worktree
git -C "$C" worktree add -q --detach "$W" "$T"
mkdir -p "$W/.factory-run"

# step <name> <policy> [HOME]: the loop's step; prints "rc=<rc file or none> verdict=<JSON verdict or none>"
step() {
  local h="${3:-$H}" rc v
  HOME="$h" timeout 300 bash -c '. "$1"; policy_tamperguard "$2" "$3" "$4"' step \
    "$REPO_ROOT/factory/bin/lib/policy-render.sh" "$W" "$2" "$B..$T" >"$S/vetto.$1.log" 2>&1 </dev/null || true
  rc="$(command cat "$W/.factory-run/tamperguard.rc" 2>/dev/null || echo none)"
  v="$(jq -r 'select(type == "object") | .verdict // "none"' "$W/.factory-run/tamperguard.json" 2>/dev/null | head -n1)"
  printf 'rc=%s verdict=%s\n' "$rc" "${v:-none}"
}
ran_ok() { [[ "$1" =~ ^rc=0\ verdict=(ok|review|tamper)$ ]]; }

# ---- render (under the real HOME: I14 is checked against it)
roots="$(policy_roots "$W" "${FACTORY_HOME:-$HOME/.factory}")"
mapfile -t root <<<"$roots"
policy_render "$TPL" "$P/live.build.toml" "${root[@]}"
tool="$(command -v tamperguard)"
info "tamperguard $tool -> $(readlink -f "$tool"); interpreter $(_policy_interpreter "$(readlink -f "$tool")") -> $(readlink -f "$(_policy_interpreter "$(readlink -f "$tool")")")"
for r in "${root[@]}"; do info "root $r"; done
check "the roots: the clone's common git dir first" eq "${root[0]}" "$(cd "$C/.git" && pwd -P)"
check "  then at least the tool's and the interpreter's install roots" test "${#root[@]}" -ge 2
check "I14: the render differs from build.toml only on the allow_read line" \
  eq "$(diff <(grep -v '^allow_read = ' "$TPL") <(grep -v '^allow_read = ' "$P/live.build.toml") && echo same)" same
check "  allow_read = the template's entries + the roots" \
  eq "$(sed -n 's/^allow_read = //p' "$P/live.build.toml")" \
     "$(sed -n 's/^allow_read = //p' "$TPL" | jq -c --args '. + $ARGS.positional' "${root[@]}")"
home="$(cd "$HOME" && pwd -P)"
for r in "${root[@]}"; do
  check "  $r: an absolute existing directory, not \$HOME or above it" eval '[ -d "$r" ] && [[ "$home/" != "${r%/}/"* ]]'
done

# ---- scratch HOME: the render works
res="$(step render "$P/live.build.toml")"
info "render, scratch HOME: $res"
check "under the render and a scratch HOME: tamperguard rc 0 and a JSON verdict" ran_ok "$res"
check "  an ok verdict on this benign diff" eq "$res" "rc=0 verdict=ok"

# ---- the template alone fails closed
res="$(step template "$TPL")"
info "template, scratch HOME: $res ($(head -c 160 "$W/.factory-run/tamperguard.err" 2>/dev/null | tr '\n' ' '))"
check "under build.toml itself the step does not pass (rc 126 or no verdict: tamperguard-error)" eval '! ran_ok "$res"'

# ---- which roots are load-bearing (measured, not asserted)
for r in "${root[@]}"; do
  sed "s|,\"$r\"||" "$P/live.build.toml" >"$P/minus.build.toml"
  res="$(step minus "$P/minus.build.toml")"
  info "minus $r: $res ($(head -c 120 "$W/.factory-run/tamperguard.err" 2>/dev/null | tr '\n' ' '))"
done

# ---- the real HOME
res="$(step real-home "$P/live.build.toml" "$HOME")"
info "render, real HOME: $res; vetto: $(grep -m1 -o 'vetto: error: .*' "$S/vetto.real-home.log" | head -c 240)"
if [ -L "$HOME/.aws" ] && [ -d "$HOME/.aws/" ]; then
  check "real HOME with the ~/.aws symlink defect: vetto refuses to start, the step never runs (fail-closed)" \
    eq "$res" "rc=none verdict=none"
else
  check "real HOME (no masking defect on this host): tamperguard rc 0 and a JSON verdict" ran_ok "$res"
fi
[ "$FAILED" = 0 ]
