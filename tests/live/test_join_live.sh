#!/usr/bin/env bash
# T7 against the REAL box (`make live`, never `make test`): the join wizard with the real probe, the
# real adapters, the real pinned tools and the real `make test` suite.
#
#   A. `join.sh --handle dev-box --dry-run --json` in this clone. It must exit 0 with no refusal, a
#      valid manifest and heavy_gates measured, and it must write nothing: the clone's refs, objects
#      and status, ~/.factory, ~/.cargo/bin and ~/.local/bin are the same before and after.
#   B. `join.sh --apply` in a scratch clone whose `fixture` remote is a local bare origin built by
#      tests/fixtures/make-repo.sh (never GitHub, I1), with a scratch FACTORY_HOME and a PATH that
#      hides dcg and cux. That runs the real release download and the pinned sha256 check, fleet's
#      reviewer adversarial-review 2.11.1 from the real npm registry checked against its pinned
#      integrity (T15), primes the npx cache under FACTORY_HOME, stores a token at 0600, writes env +
#      manifest.json and pushes nodes/dev-box.json on top of the fixture's nodes tip without force. A
#      second --apply with the env file sourced must install nothing and push a fast-forward (the
#      next heartbeat). Part B prints `SKIP part B <reason>` when GitHub or the npm registry is
#      unreachable.
#   C. Fail closed with the real tools (T15 AC1): a scratch copy of the wizard whose ADV_SHA512 has
#      one hex digit changed runs --apply with a fresh FACTORY_HOME. The real npm tarball must fail
#      the real sha512sum, the wizard must exit 1, and nothing may be installed or recorded.
#
# Prints `SKIP <reason>` and exits 0 only when a tool it needs is absent. The INFO lines are this box's
# measurements, printed for records/TB2.md, not asserted.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/../fakes/lib.sh"
echo "test_join_live"

for t in git jq make curl tar xz sha256sum sha512sum npm npx cargo uv claude bwrap; do
  command -v "$t" >/dev/null || { echo "SKIP $t not installed"; exit 0; }
done

FAILED=0
info() { printf '    INFO %s\n' "$*"; }
quiet() { "$@" >/dev/null; }
base="${FACTORY_LIVE_TMP:-$HOME/.cache}"
mkdir -p "$base"
S="$(mktemp -d "$base/factory-join-live.XXXXXX")"
trap 'chmod -R u+w "$S" 2>/dev/null; rm -rf "$S"' EXIT

# snap <dir...>: a listing of each dir (name, type, size, mtime), or "<dir> absent".
snap() {
  local d
  for d in "$@"; do
    if [ -e "$d" ]; then find "$d" -maxdepth 1 -printf '%p %y %s %T@\n' | sort; else echo "$d absent"; fi
  done
}
clone_state() {  # clone_state <clone>: refs, loose + packed object files, porcelain status
  git -C "$1" for-each-ref --format='%(refname) %(objectname)'
  find "$(git -C "$1" rev-parse --git-common-dir)/objects" -type f | sort
  git -C "$1" status --porcelain
}

# ---- A. dry run in this clone -------------------------------------------------------------------
echo "  part A: dry run in $REPO_ROOT"
home_before="$(snap "$HOME/.factory" "$HOME/.cargo/bin" "$HOME/.local/bin")"
clone_before="$(clone_state "$REPO_ROOT")"
rc=0
(cd "$REPO_ROOT" && unset FACTORY_HOME && factory/bin/join.sh --handle dev-box --json) >"$S/dry.json" 2>"$S/dry.err" || rc=$?
check "dry run exits 0" eq "$rc" 0
check "no refusal" eq "$(jq -c .refusals "$S/dry.json")" "[]"
check "mode is dry-run and the factory home is ~/.factory" eq "$(jq -r '"\(.mode) \(.factory_home)"' "$S/dry.json")" "dry-run $HOME/.factory"
check "the sandbox backend works" eq "$(jq -r '.probe.sandbox | "\(.present) \(.works)"' "$S/dry.json")" "true true"
check "claude-code is usable: authenticated and at its adapters.json pin" \
  eq "$(jq -r '.manifest.adapters["claude-code"]' "$S/dry.json")" "$(jq -r '.["claude-code"]' "$REPO_ROOT/factory/policy/adapters.json")"
check "the manifest has no schema error" eq "$(jq -c .manifest_errors "$S/dry.json")" "[]"
check "the suite ran and heavy_gates is its verdict" \
  quiet jq -e '.suite.ran and (.heavy_gates == (.suite.exit == 0 and (.suite.timed_out | not)))' "$S/dry.json"
check "slots = min(8, floor(free GiB / 2) - 1) from the probe" \
  quiet jq -e '.slots == ([8, ((.probe.ram_free_kb / 2097152 | floor) - 1)] | min)' "$S/dry.json"
check "the plan names every pinned tool once" eq "$(jq -c '[.plan[].tool] | sort' "$S/dry.json")" \
  '["@adlc/cli","adlc init","adversarial-review","claude-code","cux","dcg","ralon","tamperguard","vetto"]'
check "the dry run pushed nothing" eq "$(jq -r .nodes.pushed "$S/dry.json")" false
check "the dry run wrote nothing under ~/.factory, ~/.cargo/bin, ~/.local/bin" eq "$(snap "$HOME/.factory" "$HOME/.cargo/bin" "$HOME/.local/bin")" "$home_before"
check "the dry run wrote no ref, no git object and no file in the clone" eq "$(clone_state "$REPO_ROOT")" "$clone_before"
info "probe: $(jq -r '.probe | "os \(.os), \(.cpu) cpu, \(.ram_total_kb / 1048576 * 100 | round / 100) GiB total, \(.ram_free_kb / 1048576 * 100 | round / 100) GiB free, sandbox \(.sandbox.backend)"' "$S/dry.json")"
info "slots $(jq -r .slots "$S/dry.json"), heavy_gates $(jq -r .heavy_gates "$S/dry.json"), suite $(jq -c .suite "$S/dry.json")"
info "plan: $(jq -r '[.plan[] | "\(.tool) \(.pin) \(.state)"] | join("; ")' "$S/dry.json")"
info "nodes: $(jq -c .nodes "$S/dry.json")"
jq -r '.warnings[]' "$S/dry.json" | while IFS= read -r w; do info "warning: $w"; done

# ---- B. --apply against a fixture origin --------------------------------------------------------
echo "  part B: --apply against a fixture origin with a scratch FACTORY_HOME"
part_b() {
  local u
  [ "$(uname -sm)" = "Linux x86_64" ] || { echo "  SKIP part B not Linux x86_64 (the checks name those release assets)"; return 0; }
  for u in https://github.com https://registry.npmjs.org/@adlc%2fcli; do
    curl -fsS -o /dev/null --max-time 15 "$u" 2>/dev/null || { echo "  SKIP part B $u unreachable"; return 0; }
  done
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=live GIT_AUTHOR_EMAIL=live@fake GIT_COMMITTER_NAME=live GIT_COMMITTER_EMAIL=live@fake
  local O="$S/origin.git" C="$S/clone" FH="$S/fh" tok tip0 tip1 tip2 rc d n e i=0 path=""
  echo "node alice 1761300000 active 2" | bash "$REPO_ROOT/tests/fixtures/make-repo.sh" "$O"
  git clone -q "$REPO_ROOT" "$C"
  git -C "$C" remote add fixture "$O"
  tip0="$(git -C "$O" rev-parse refs/heads/nodes)"

  # Shadow every PATH dir that holds dcg or cux with symlinks to everything else in it.
  local -a dirs
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    if [ -e "$d/dcg" ] || [ -e "$d/cux" ]; then
      i=$((i + 1)); mkdir -p "$S/shadow$i"
      for e in "$d"/*; do n="${e##*/}"; [ "$n" = dcg ] || [ "$n" = cux ] || ln -s "$e" "$S/shadow$i/$n"; done
      d="$S/shadow$i"
    fi
    path="${path:+$path:}$d"
  done
  check "the shadow PATH hides dcg and cux" eq "$(PATH="$path" command -v dcg cux || true)" ""

  home_before="$(snap "$HOME/.factory" "$HOME/.cargo/bin" "$HOME/.local/bin")"
  tok="github_pat_$(head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-60)"
  rc=0
  printf '%s\n' "$tok" | (cd "$C" && PATH="$path" FACTORY_HOME="$FH" factory/bin/join.sh --handle dev-box --apply \
    --remote fixture --repo musicofhel/software-factory --no-suite --token-file - --json) >"$S/apply.json" 2>"$S/apply.err" || rc=$?
  check "--apply exits 0" eq "$rc" 0
  [ "$rc" = 0 ] || sed -n '1,80p' "$S/apply.err"
  check "no refusal" eq "$(jq -c .refusals "$S/apply.json")" "[]"
  check "the plan installs exactly dcg, cux, the reviewer and the npx cache" \
    eq "$(jq -c '[.plan[] | select(.state != "installed") | .tool] | sort' "$S/apply.json")" '["@adlc/cli","adversarial-review","cux","dcg"]'
  check "adversarial-review's npm tarball passed the pinned sha512 before npm installed it" \
    grep -q "/adversarial-review-2.11.1.tgz: OK" "$S/apply.err"
  check "adversarial-review 2.11.1 under \$FACTORY_HOME, with the receipt of the pinned integrity" \
    eq "$(jq -r .version "$FH/lib/node_modules/adversarial-review/package.json") $(command cat "$FH/receipts/adversarial-review@2.11.1")" \
       "2.11.1 $(sed -n 's/^ADV_INTEGRITY=//p' "$C/factory/bin/join.sh")"
  check "the receipt's integrity is npm's own for 2.11.1" \
    eq "$(command cat "$FH/receipts/adversarial-review@2.11.1")" "$(npm view adversarial-review@2.11.1 dist.integrity 2>/dev/null)"
  check "the installed reviewer runs (--help exits 0)" quiet "$FH/bin/adversarial-review" --help
  check "the manifest records it, same family on this claude-only box" \
    eq "$(jq -c .review "$FH/manifest.json")" '{"tool":"adversarial-review","pin":"2.11.1","same_family":true}'
  check "the register step carries the cux line for the owner" eq "$(jq -r .register.quota.command "$S/apply.json")" "cux add --no-alias"
  check "dcg came from the release, checked against the pinned sha256" grep -q "dcg-x86_64-unknown-linux-musl.tar.xz: OK" "$S/apply.err"
  check "cux came from the release, checked against the pinned sha256" grep -q "cux-linux-amd64: OK" "$S/apply.err"
  check "dcg is 0.15.3 in \$FACTORY_HOME/bin" eq "$("$FH/bin/dcg" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)" 0.15.3
  check "cux is 0.4.1 in \$FACTORY_HOME/bin" eq "$("$FH/bin/cux" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)" 0.4.1
  check "@adlc/cli 1.12.0 sits in \$FACTORY_HOME's npx cache" \
    eq "$(jq -r .version "$FH"/npm/_npx/*/node_modules/@adlc/cli/package.json 2>/dev/null | sort -u)" 1.12.0
  check "\$FACTORY_HOME is 0700" eq "$(stat -c %a "$FH")" 700
  check "the token is stored at 0600, verbatim" eq "$(stat -c %a "$FH/token") $(command cat "$FH/token")" "600 $tok"
  check "the install temp dirs are gone" eq "$(find "$FH/tmp" -mindepth 1 | wc -l | tr -d ' ')" 0
  check "manifest.json passes --validate" quiet "$C/factory/bin/join.sh" --validate "$FH/manifest.json"
  check "env puts \$FACTORY_HOME/bin first" eq "$(PATH="$path" bash -c ". '$FH/env' && command -v dcg cux adversarial-review")" "$FH/bin/dcg
$FH/bin/cux
$FH/bin/adversarial-review"
  tip1="$(git -C "$O" rev-parse refs/heads/nodes)"
  check "the fixture's nodes tip is the pushed commit" eq "$(jq -r .nodes.commit "$S/apply.json")" "$tip1"
  check "the push is a fast-forward of the old tip (no force)" eq "$(git -C "$O" rev-parse "$tip1^")" "$tip0"
  check "nodes/dev-box.json on the tip is the manifest" \
    eq "$(git -C "$O" cat-file blob "$tip1:nodes/dev-box.json" | jq -c .)" "$(jq -c . "$FH/manifest.json")"
  check "alice's manifest is untouched" eq "$(git -C "$O" rev-parse "$tip1:nodes/alice.json")" "$(git -C "$O" rev-parse "$tip0:nodes/alice.json")"
  check "the commit carries Node: dev-box" eq "$(git -C "$O" log -1 --format='%(trailers:key=Node,valueonly)' "$tip1" | sed '/^$/d')" dev-box
  check "nothing written under ~/.factory, ~/.cargo/bin, ~/.local/bin" eq "$(snap "$HOME/.factory" "$HOME/.cargo/bin" "$HOME/.local/bin")" "$home_before"
  info "plan: $(jq -r '[.plan[] | "\(.tool) \(.pin) \(.state)"] | join("; ")' "$S/apply.json")"
  sed -n '/== apply: install/,/== 5\/5/p' "$S/apply.err" | grep -v '^npm notice' | sed 's/^/    | /'

  rc=0
  (cd "$C" && export PATH="$path" && . "$FH/env" && factory/bin/join.sh --handle dev-box --apply \
    --remote fixture --repo musicofhel/software-factory --no-suite --json) >"$S/again.json" 2>"$S/again.err" || rc=$?
  check "a second --apply with the env sourced exits 0" eq "$rc" 0
  check "and installs nothing" eq "$(jq -c '[.plan[] | select(.state != "installed")]' "$S/again.json")" "[]"
  tip2="$(git -C "$O" rev-parse refs/heads/nodes)"
  check "and pushes the next heartbeat as a fast-forward" eq "$(git -C "$O" rev-parse "$tip2^")" "$tip1"
  check "the token from the first run is kept" eq "$(command cat "$FH/token")" "$tok"
}
part_b

# ---- C. a tampered pin fails closed with the real npm and sha512sum ------------------------------
echo "  part C: --apply with a wrong ADV_SHA512 in a scratch copy of the wizard"
part_c() {
  curl -fsS -o /dev/null --max-time 15 https://registry.npmjs.org/adversarial-review 2>/dev/null ||
    { echo "  SKIP part C the npm registry is unreachable"; return 0; }
  local O="$S/origin-c.git" C="$S/clone-c" FH="$S/fh-c" good bad tip0 rc
  echo "node alice 1761300000 active 2" | bash "$REPO_ROOT/tests/fixtures/make-repo.sh" "$O"
  git clone -q "$REPO_ROOT" "$C"
  git -C "$C" remote add fixture "$O"
  good="$(sed -n 's/^ADV_SHA512=//p' "$C/factory/bin/join.sh")"
  bad="${good%?}$(case "${good: -1}" in 0) echo 1 ;; *) echo 0 ;; esac)"
  sed -i "s/^ADV_SHA512=$good\$/ADV_SHA512=$bad/" "$C/factory/bin/join.sh"
  check "the copy's pin differs from the real one in one digit" eq "$(sed -n 's/^ADV_SHA512=//p' "$C/factory/bin/join.sh" | cut -c1-127) ${#bad}" "${good:0:127} 128"
  tip0="$(git -C "$O" rev-parse refs/heads/nodes)"
  rc=0
  (cd "$C" && FACTORY_HOME="$FH" factory/bin/join.sh --handle dev-box --apply --remote fixture \
     --repo musicofhel/software-factory --no-suite --json) >"$S/tamper.json" 2>"$S/tamper.err" || rc=$?
  check "--apply exits 1" eq "$rc" 1
  check "the real sha512sum refused the real tarball" grep -q "/adversarial-review-2.11.1.tgz: FAILED" "$S/tamper.err"
  check "the wizard names the failed install step" grep -q "^join: install step failed: rm -f $FH/receipts/adversarial-review@2.11.1" "$S/tamper.err"
  check "nothing installed or recorded: no package, no bin link, no receipt, no temp dir" \
    eq "$(find "$FH" \( -path "$FH/lib/node_modules/adversarial-review" -o -path "$FH/bin/adv*" -o -path "$FH/receipts/*" \
            -o -path "$FH/tmp/*" \) -print)" ""
  check "no manifest pushed" eq "$(git -C "$O" rev-parse refs/heads/nodes)" "$tip0"
}
part_c

[ "$FAILED" = 0 ] && echo "PASS test_join_live" || echo "FAIL test_join_live ($FAILED)"
[ "$FAILED" = 0 ]
