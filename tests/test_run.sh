#!/usr/bin/env bash
# T9: the run loop (factory/bin/run.sh, factory/bin/lib/run.sh). Offline: a fixture origin from
# tests/fixtures/make-repo.sh that is both the clone's `origin` and the fake gh's git store, the
# node's clone, the fake gh (+ a `pr create` shim), the fake adlc (ralon-lock.sh's ticket store),
# cux, ralon, vetto, tamperguard and fleet (tests/fakes/), a fake `claude` for version-check, and a
# recording `sleep`. The clock is FACTORY_NOW.
# Acceptance 1 (one case per fleet reason: success, tamper, quota-paused, wall-clock,
# strikes-exhausted, flail, review-unavailable, anything-else), 2 argv, 3 resume, 4 no-transcript,
# 5 once; plus the paused claim's resume in place, the resume cap, a lost lock, the governor's
# verdicts, the dry run, slot guards and the fakes themselves. T12 acceptance 4: the bwrap
# shim on fleet's PATH only, and only at fleet pin 1.12.0 (case bwrap-shim). T14 acceptance 4: every
# needs-desk path comments the reason with the needs-desk marker before the label (desk_case,
# tamper, resume-cap, desk-marker). T17: tamperguard's policy is the claim's render of build.toml,
# which differs from the template only by existing absolute allow_read roots (I14; cases
# policy-render, policy-render-lib), a missing interpreter fails closed before the step (case
# policy-missing-root), and tamperguard's stderr is kept in the claim's log base (case tamper).
# T22: the real diff gates on the commit the node pushes, GATE_BASE...GATE_HEAD from the
# merge-base with origin/main, the ticket's scope and rails read from main's store (run_setup puts
# T-run there): tamperguard, rails-proof, scope-check all pass and the gated sha is pushed (success,
# argv); a rail edit or a path outside the scope → desk, nothing pushed (rails-fail, scope-fail,
# desk-marker); a lapsed-branch resume gates from main, not the lapsed tip (lapsed-range, acceptance
# 2); no adversarial-review on PATH → the loop does not start (no-adversarial-review).
# T23 acceptance 1 (node:G2): a built ticket pushes ONE commit over the merge-base with origin/main,
# fleet's final tree with all four trailers (Ticket, Node, Assisted-by, Signed-off-by); fleet's own
# commits never reach the origin but stay in the node's clone (success); a resumed pause and a
# lapsed branch are squashed the same way, their work kept in the tree (resume-in-place,
# lapsed-range).
# tamperguard is laid out as a uv tool (fake_uv): its own install dir, and a python reached through a
# version link, as on a real node.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
# shellcheck source=factory/bin/lib/desk-marker.sh
. "$REPO_ROOT/factory/bin/lib/desk-marker.sh"
RUN="$BIN/run.sh"
iso() { jq -nr --argjson e "$1" '$e | todate'; }
T0="$(jq -nr '"2026-10-25T12:00:00Z" | fromdateiso8601')"
MARK=PLANTED-PROMPT-TEXT-5e1f   # planted in the ticket, the Issue, fleet's transcript and tamperguard's findings

run_setup() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TZ=UTC
  export GIT_AUTHOR_NAME=node GIT_AUTHOR_EMAIL=node@fake GIT_COMMITTER_NAME=node GIT_COMMITTER_EMAIL=node@fake
  rm -rf "$FAKE_GH_GIT"
  # T-run in main's ticket store (adlc's file name): the diff gates read its scope and rails from the base
  printf '%s\n' 'main-file factory/policy/adapters.json {"claude-code": "2.1.280", "codex": null}' \
    "main-file .adlc/tickets/t-run--$(printf %s T-run | sha256sum | cut -d' ' -f1).json"' {"id": "T-run", "title": "add hello.sh", "scope": ["hello.sh", "half.txt"], "rails": ["tests/rail/**"]}' \
    "node dev-box $((T0 - 7200)) active 2 dev-box" | tests/fixtures/make-repo.sh "$FAKE_GH_GIT"
  git clone -q "$FAKE_GH_GIT" "$WORLD/clone"
  export FACTORY_NOW="$T0" FAKE_GH_NOW="$T0" FACTORY_HOME="$WORLD/fh" FACTORY_MANIFEST="$WORLD/manifest.json"
  export FAKE_CUX_USAGE="$WORLD/usage.json" FAKE_CUX_LOG="$WORLD/cux.log" FAKE_FLEET_LOG="$WORLD/fleet.log"
  export FAKE_RALON_LOG="$WORLD/ralon.log" FAKE_VETTO_LOG="$WORLD/vetto.log" FAKE_TAMPERGUARD_LOG="$WORLD/tg.log"
  export FACTORY_ADLC="$FAKES_DIR/adlc" FACTORY_FLEET="$FAKES_DIR/fleet" FACTORY_SLEEP="$WORLD/bin/nap"
  export FACTORY_FLEET_PIN=1.12.0   # the fake copies fleet 1.12.0
  export FAKE_FLEET_TRANSCRIPT="worker said: $MARK" FAKE_TAMPERGUARD_DETAIL="assert True  # $MARK"
  export FAKE_ADLC_TICKETS='[{"id": "T-run", "title": "add hello.sh", "body": "Build hello.sh. '"$MARK"'", "rails": ["tests/rail/**"]}]'
  unset FAKE_FLEET_REASON FAKE_FLEET_REASONS FAKE_FLEET_FILE FAKE_TAMPERGUARD_VERDICT FAKE_FLEET_STRIKES FAKE_CLAUDE_VERSION
  : >"$FAKE_CUX_LOG"; : >"$FAKE_FLEET_LOG"; : >"$FAKE_RALON_LOG"; : >"$FAKE_VETTO_LOG"; : >"$FAKE_TAMPERGUARD_LOG"
  mkdir -p "$WORLD/bin" "$WORLD/prs"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo "${FAKE_CLAUDE_VERSION:-2.1.280} (Claude Code)"\n' >"$WORLD/bin/claude"
  printf '#!/usr/bin/env bash\necho "$1" >>"%s/naps"\n' "$WORLD" >"$WORLD/bin/nap"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$WORLD/bin/adversarial-review"   # fleet's review step: only its presence is checked
  # gh pr create is not in the fake gh: a shim records it (the body in prs/<n>.md) and opens the PR
  # in the fake's store, unless $WORLD/pr-create-fails holds a count > 0 (that many creates fail);
  # everything else goes to tests/fakes/gh.
  command cat >"$WORLD/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-} \${2:-}" = "pr create" ]; then
  for a in "\$@"; do jq -n --arg a "\$a" '\$a'; done | jq -sc . >>"\$FAKE_GH_LOG"
  fails="\$(command cat "$WORLD/pr-create-fails" 2>/dev/null || echo 0)"   # T25: the next <n> creates fail
  if [ "\$fails" -gt 0 ]; then
    echo "\$((fails - 1))" >"$WORLD/pr-create-fails"
    echo "pull request create failed: HTTP 502 (injected)" >&2; exit 1
  fi
  shift 2; head="" base="" title="" body=""
  while [ \$# -gt 0 ]; do
    case "\$1" in
      --repo) [ "\$2" = "\$FAKE_GH_REPO" ] || { echo "no such repo" >&2; exit 1; }; shift ;;
      --head) head="\$2"; shift ;;
      --base) base="\$2"; shift ;;
      --title) title="\$2"; shift ;;
      --body-file) [ "\$2" = - ] && body="\$(command cat)" || body="\$(command cat "\$2")"; shift ;;
      *) echo "pr create shim: unsupported \$1" >&2; exit 1 ;;
    esac
    shift
  done
  [ -n "\$title" ] && [ -n "\$base" ] || { echo "pr create shim: needs --title and --base" >&2; exit 1; }
  git -C "\$FAKE_GH_GIT" rev-parse -q --verify "refs/heads/\$head" >/dev/null || { echo "pull request create failed: head \$head not found" >&2; exit 1; }
  n="\$(jq '[.issues[].number, (.pulls // [])[].number] | max + 1' "\$FAKE_GH_ISSUES")"
  printf '%s' "\$body" >"$WORLD/prs/\$n.md"
  tmp="\$(mktemp)"
  jq --argjson n "\$n" --arg h "\$head" --arg t "\$title" '.pulls = ((.pulls // []) + [{number: \$n, headRefName: \$h, state: "OPEN", createdAt: "2026-10-25T12:00:00Z", title: \$t}])' "\$FAKE_GH_ISSUES" >"\$tmp"
  mv "\$tmp" "\$FAKE_GH_ISSUES"
  echo "https://github.com/\$FAKE_GH_REPO/pull/\$n"
  exit 0
fi
exec "$FAKES_DIR/gh" "\$@"
EOF
  chmod +x "$WORLD/bin/claude" "$WORLD/bin/nap" "$WORLD/bin/adversarial-review" "$WORLD/bin/gh"
  # in-review, as the mirror creates it when the repo lacks it (mirror.sh); run.sh's hand-off adds it (T25)
  jq '.labels += ["in-review"]' "$FAKE_GH_ISSUES" >"$WORLD/labels.tmp" && mv "$WORLD/labels.tmp" "$FAKE_GH_ISSUES"
  export PATH="$WORLD/bin:$PATH"
  jq -n --arg seen "$(iso $((T0 - 600)))" '
    {handle: "dev-box", owner: "dev-box", os: "linux", cpu: 8, ram_gb: 16, slots: 2, heavy_gates: false,
     adapters: {"claude-code": "2.1.280"}, quota_tier: "pro", quota_cap: 0.4,
     quiet_hours: {tz: "UTC", start: "00:00", end: "00:00"}, accounts: 1, factory_version: "0.1.0",
     last_seen: $seen, status: "active"}' >"$FACTORY_MANIFEST"
  under_cap
  fakegh_issue 1 $((T0 - 86400)) ready,w:light "T-run: add hello.sh" \
    "$(printf '<!-- mirrored by factory/bin/mirror.sh -->\nTicket: T-run\nTicket-Hash: hash-T-run\n\nBuild hello.sh. %s\n' "$MARK")"
  WT="$WORLD/clone/.worktrees/T-run"
  fake_uv "$WORLD/uv"
}
fake_uv() {  # fake_uv <dir>: tamperguard as uv installs it under <dir>, and $WORLD/bin/tamperguard → it
  local u="$1"
  mkdir -p "$u/python/cpython-9.9.9-fake/bin" "$u/tools/tamperguard/bin"
  command cp "$(readlink -f "$(command -v bash)")" "$u/python/cpython-9.9.9-fake/bin/python9.9"   # the "interpreter"
  ln -sfn cpython-9.9.9-fake "$u/python/cpython-9.9-fake"
  ln -sf "$u/python/cpython-9.9-fake/bin/python9.9" "$u/tools/tamperguard/bin/python"
  printf '#!%s\nexec "%s/tamperguard" "$@"\n' "$u/tools/tamperguard/bin/python" "$FAKES_DIR" >"$u/tools/tamperguard/bin/tamperguard"
  chmod +x "$u/tools/tamperguard/bin/tamperguard"
  ln -sf "$u/tools/tamperguard/bin/tamperguard" "$WORLD/bin/tamperguard"
}
under_cap() {
  printf '{"a@example.invalid": {"polled_at": "%s", "five_hour": {"utilization": 10, "resets_at": "%s"}, "seven_day": {"utilization": 20, "resets_at": "%s"}}}\n' \
    "$(iso $((FACTORY_NOW - 60)))" "$(iso $((FACTORY_NOW + 3600)))" "$(iso $((FACTORY_NOW + 86400)))" >"$FAKE_CUX_USAGE"
}
loop() {  # loop <args>: run.sh --slot 1 --apply --json in the clone; sets RC, OUT (stdout), LAST (last line); stderr in $WORLD/err
  RC=0
  OUT="$(cd "$WORLD/clone" && "$RUN" --slot 1 --apply --json "$@" 2>"$WORLD/err")" || RC=$?
  LAST="$(tail -n1 <<<"$OUT")"
}
field() { jq -r "$1" <<<"$LAST"; }
lock() { fakegh_ref refs/locks/issue-1; }
pushed() { fakegh_ref "refs/heads/ticket/T-run/${1:-dev-box}"; }
comments() { jq -r '.issues[] | select(.number == 1) | .comments | length' "$FAKE_GH_ISSUES"; }
last_comment() { jq -r '.issues[] | select(.number == 1) | .comments[-1].body' "$FAKE_GH_ISSUES"; }
labels() { jq -r '.issues[] | select(.number == 1) | [.labels[].name] | sort | join(",")' "$FAKE_GH_ISSUES"; }
trailer() { git -C "$FAKE_GH_GIT" log -1 --format="%(trailers:key=$2,valueonly)" "$1" | sed '/^$/d'; }
fleet_calls() { wc -l <"$FAKE_FLEET_LOG" | tr -d ' '; }
# clone_commit <subject>: the commit objects with that subject in the node's clone, reachable or not
# (run.sh deletes fleet's local branches and keeps the run's tip under refs/factory/fleet/<run id>)
clone_commit() {
  local c
  git -C "$WORLD/clone" cat-file --batch-all-objects --batch-check='%(objecttype) %(objectname)' | sed -n 's/^commit //p' |
    while IFS= read -r c; do [ "$(git -C "$WORLD/clone" log -1 --format=%s "$c")" != "$1" ] || printf '%s\n' "$c"; done
}
on_origin() { git -C "$FAKE_GH_GIT" cat-file -e "$1^{commit}" 2>/dev/null; }
over_main() { git -C "$FAKE_GH_GIT" rev-list "$(git -C "$FAKE_GH_GIT" rev-parse main)..$1" | wc -l | tr -d ' '; }
no_mark() { ! grep -rqF "$MARK" "$@"; }
marker() { desk_marker_read "$(last_comment)"; }   # the needs-desk marker of the result comment
want_marker() { jq -cn --arg r "$1" --arg h "${2:-hash-T-run}" '{ticket: "T-run", hash: $h, reason: $r, node: "dev-box"}'; }

case_success() {
  run_setup
  loop --once
  check "fleet success, both gates pass: exit 0" eq "$RC" 0
  check "  outcome built" eq "$(field .outcome)" built
  check "  pushed ticket/T-run/dev-box" eq "$(field .pushed.branch)" ticket/T-run/dev-box
  check "  the pushed tip is on the origin" eq "$(pushed)" "$(field .pushed.sha)"
  local main fmerge fwork
  main="$(git -C "$FAKE_GH_GIT" rev-parse main)"
  fmerge="$(clone_commit "Merge branch 'fleet/t-run' into fleet/run-$(field .fleet.run)")"
  fwork="$(clone_commit "feat(T-run): fleet worker build")"
  check "  exactly one commit over the merge-base with origin main (T23 acceptance 1)" eq "$(over_main "$(pushed)")" 1
  check "  its only parent is that merge-base, main" eq "$(git -C "$FAKE_GH_GIT" rev-list --parents -n1 "$(pushed)")" "$(pushed) $main"
  check "  its tree is fleet's final tree (the integration tip's)" \
    eq "$(git -C "$FAKE_GH_GIT" rev-parse "$(pushed)^{tree}")" "$(git -C "$WORLD/clone" rev-parse "$fmerge^{tree}")"
  check "  its subject names the ticket, the outcome and the node" \
    eq "$(git -C "$FAKE_GH_GIT" log -1 --format=%s "$(pushed)")" "factory: T-run built on dev-box"
  check "  one trailer paragraph: Factory-Outcome, Fleet-Run, Fleet-Strikes, Assisted-by, Ticket, Node, Signed-off-by" \
    eq "$(git -C "$FAKE_GH_GIT" log -1 --format=%B "$(pushed)" | git interpret-trailers --parse | cut -d: -f1 | tr '\n' ' ')" \
       "Factory-Outcome Fleet-Run Fleet-Strikes Assisted-by Ticket Node Signed-off-by "
  check "  trailers: Fleet-Run, Fleet-Strikes" \
    eq "$(trailer "$(pushed)" Fleet-Run) $(trailer "$(pushed)" Fleet-Strikes)" "$(field .fleet.run) 1"
  check "  fleet's worker commit and merge stay in the node's clone (one each, the merge of the worker)" \
    eq "$(wc -w <<<"$fmerge $fwork" | tr -d ' ') $(git -C "$WORLD/clone" rev-parse "$fmerge^2")" "2 $fwork"
  check "  and stay reachable in the node's log: refs/factory/fleet/<run id> is fleet's merge (never pushed)" \
    eq "$(git -C "$WORLD/clone" rev-parse -q --verify "refs/factory/fleet/$(field .run_id)") $(git -C "$FAKE_GH_GIT" for-each-ref refs/factory)" "$fmerge "
  check "  and never reach the origin (not reachable from the pushed ref, not even as objects)" \
    eq "$(on_origin "$fmerge" && echo merge)$(on_origin "$fwork" && echo worker)" ""
  check "  trailers: Ticket" eq "$(trailer "$(pushed)" Ticket)" T-run
  check "  trailers: Node" eq "$(trailer "$(pushed)" Node)" dev-box
  check "  trailers: Assisted-by" eq "$(trailer "$(pushed)" Assisted-by)" claude-code@2.1.280
  check "  trailers: Signed-off-by" eq "$(trailer "$(pushed)" Signed-off-by)" "node <node@fake>"
  check "  trailers: Factory-Outcome built" eq "$(trailer "$(pushed)" Factory-Outcome)" built
  check "  a PR from the branch" eq "$(jq -r '.pulls[0].headRefName' "$FAKE_GH_ISSUES")" ticket/T-run/dev-box
  check "  the PR number is in the record" eq "$(field .pr)" 2
  check "  the PR body carries the strikes and the gate verdicts" \
    grep -qF '| strikes | 1 of 2 |' "$WORLD/prs/2.md"
  check "  two comments: the claim and the result" eq "$(comments)" 2
  check "  the result comment names the branch and the PR" grep -qF 'PR #2' <<<"$(last_comment)"
  # T25: the PR is the claim from here; the hand-off labels the Issue in-review and releases the lock
  check "  the lock is released at the hand-off (T25), the Issue in-review" eq "$(lock)|$(labels)" "|in-review,w:light"
  check "  the worktree is gone" test ! -e "$WT"
  check "  fleet's local branches are gone" eq "$(git -C "$WORLD/clone" for-each-ref --format=x refs/heads/fleet | wc -l | tr -d ' ')" 0
  check "  no slot state left" test ! -e "$FACTORY_HOME/run/slot-1.json"
  check "  the ledger has the same line" eq "$(tail -n1 "$FACTORY_HOME/run/ledger.jsonl")" "$LAST"
  check "  the gates ran on the pushed commit, from main: .gate_base is origin main" \
    eq "$(field .gate_base)" "$(git -C "$FAKE_GH_GIT" rev-parse main)"
  check "  the pushed sha is the gated one (.gate_head)" eq "$(pushed)" "$(field .gate_head)"
  check "  tamperguard ok, rails-proof pass, scope-check pass" \
    eq "$(field '"\(.tamperguard.verdict) \(.rails_proof) \(.scope_check)"')" "ok pass pass"
  check "  in that order, before the push" \
    eq "$(field '[.actions[] | select(test("^(tamperguard|rails-proof|scope-check|push )"))] | join(",")')" \
       "tamperguard,rails-proof,scope-check,push ticket/T-run/dev-box"
  check "  the real scripts passed (their stderr in the claim's log base)" \
    eval 'grep -qF "rails-proof: pass" "$FACTORY_HOME/run/logs/$(field .run_id).rails.err" &&
          grep -qF "scope-check: pass" "$FACTORY_HOME/run/logs/$(field .run_id).scope.err"'
  check "  no nap under --once" test ! -e "$WORLD/naps"
}

gate_desk() {  # gate_desk <reason>: a diff gate failed on the gated commit: desk, nothing pushed
  check "  outcome desk, reason $1, the loop goes on" eq "$RC $(field '"\(.outcome) \(.reason)"')" "0 desk $1"
  check "  nothing pushed to the origin, no PR" \
    eq "$(git -C "$FAKE_GH_GIT" for-each-ref --format=x refs/heads/ticket | wc -l | tr -d ' ') $(jq '.pulls // [] | length' "$FAKE_GH_ISSUES")" "0 0"
  check "  tamperguard ran first (ok), on the same range" \
    eq "$(field .tamperguard.verdict) $(jq -r '.[1]' "$FAKE_TAMPERGUARD_LOG")" "ok $(field .gate_base)...$(field .gate_head)"
  check "  labeled needs-desk, ready removed" eq "$(labels)" in-progress,needs-desk,w:light
  check "  the comment ends in the needs-desk marker, reason $1" eq "$(marker)" "$(want_marker "$1")"
  check "  the comment says nothing was pushed" grep -qF 'Nothing pushed.' <<<"$(last_comment)"
  check "  the lock is released, the worktree gone, no slot state" \
    eq "$(lock)$([ -e "$WT" ] && echo kept)$([ -e "$FACTORY_HOME/run/slot-1.json" ] && echo state)" ""
}

case_scope_fail() {
  run_setup
  export FAKE_FLEET_FILE=outside.sh
  loop --once
  check "fleet built outside.sh, the ticket's scope is [hello.sh, half.txt]: scope-check fails" eq "$(field .scope_check)" fail
  check "  rails-proof passed first" eq "$(field .rails_proof)" pass
  check "  scope-check named the path" grep -qxF '  outside.sh' "$FACTORY_HOME/run/logs/$(field .run_id).scope.err"
  gate_desk scope-fail
}

case_rails_fail() {
  run_setup
  export FAKE_FLEET_FILE=tests/rail/x
  loop --once
  check "fleet wrote tests/rail/x, a rail of the ticket (tests/rail/**): rails-proof fails" eq "$(field .rails_proof)" fail
  check "  scope-check never ran" eq "$(field '.scope_check, (.actions | index("scope-check"))' | tr '\n' ' ')" "null null "
  gate_desk rails-fail
}

case_no_adversarial_review() {
  run_setup
  rm -f "$WORLD/bin/adversarial-review"
  loop --once
  check "adversarial-review not on PATH: exit 1, the loop does not start" eq "$RC $OUT" "1 "
  check "  it says why" grep -qF 'adversarial-review not found on PATH' "$WORLD/err"
  check "  no claim, no fleet, no governor read, no \$FACTORY_HOME/run" \
    eq "$(lock)|$(fakegh_calls '.[0] == "api"')|$(fleet_calls)|$(wc -l <"$FAKE_CUX_LOG" | tr -d ' ')|$([ -e "$FACTORY_HOME/run" ] && echo run)" "|0|0|0|"
}

case_tamper() {
  run_setup
  export FAKE_TAMPERGUARD_VERDICT=tamper
  loop --once
  check "tamperguard says tamper: exit 0, the loop goes on" eq "$RC" 0
  check "  outcome desk, reason tamper" eq "$(field '"\(.outcome) \(.reason)"')" "desk tamper"
  check "  verdict, score and finding count only" eq "$(jq -c .tamperguard <<<"$LAST")" '{"verdict":"tamper","score":10,"findings":1}'
  check "  rails-proof and scope-check never ran" eq "$(field '[.rails_proof, .scope_check, (.actions | index("rails-proof"), index("scope-check"))] | unique | tojson')" "[null]"
  check "  nothing pushed" test -z "$(pushed)"
  check "  labeled needs-desk, ready removed" eq "$(labels)" in-progress,needs-desk,w:light
  check "  the comment ends in the needs-desk marker, reason tamper" eq "$(marker)" "$(want_marker tamper)"
  check "  the lock is released" test -z "$(lock)"
  check "  the comment says nothing was pushed" grep -qF 'Nothing pushed.' <<<"$(last_comment)"
  jq -r '.issues[].comments[].body' "$FAKE_GH_ISSUES" >"$WORLD/comments.txt"; printf '%s\n' "$OUT" >"$WORLD/stdout.txt"
  check "  no finding text left the node (comments, ledger, stdout)" \
    no_mark "$WORLD/comments.txt" "$FACTORY_HOME/run/ledger.jsonl" "$WORLD/stdout.txt"
  export FAKE_TAMPERGUARD_VERDICT=error
  run_setup; export FAKE_TAMPERGUARD_VERDICT=error
  loop --once
  check "tamperguard itself fails: exit 1 (no false green), nothing pushed" eq "$RC:$(field .reason):$(pushed)" 1:tamperguard-error:
  check "  its stderr is kept in the claim's log base, next to its JSON" \
    grep -qxF 'Traceback (most recent call last): injected' "$FACTORY_HOME/run/logs/$(field .run_id).tamperguard.err"
}

toml_flat() {  # toml_flat <file>: one `[table] key = value` line per assignment; comments and blanks dropped
  awk '/^[[:space:]]*(#|$)/ { next }
       /^[[:space:]]*\[/ { t = $0; sub(/[[:space:]]*(#.*)?$/, "", t); sub(/^[[:space:]]+/, "", t); next }
       { k = $0; sub(/[[:space:]]*=.*/, "", k); sub(/^[[:space:]]+/, "", k)
         v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); print t " " k " = " v }' "$1"
}
allow_read() { toml_flat "$1" | sed -n 's/^\[filesystem\] allow_read = //p'; }
i14() {  # i14 <render> <extra root>...: the render differs from build.toml only by these allow_read roots
  local tpl="$REPO_ROOT/factory/policy/build.toml" r t extra home
  t="$(allow_read "$tpl")"
  check "I14: every table and key but [filesystem] allow_read is the template's" \
    eq "$(toml_flat "$1" | grep -v '^\[filesystem\] allow_read = ')" "$(toml_flat "$tpl" | grep -v '^\[filesystem\] allow_read = ')"
  check "  [network] unchanged, allow_write unchanged" \
    eq "$(toml_flat "$1" | grep -E '^\[network\]|allow_write')" "$(printf '%s\n' '[filesystem] allow_write = ["$PROJECT", "$HOME/.factory/cache"]' '[network] mode = "off"')"
  check "  allow_read starts with the template's own entries" eq "$(allow_read "$1" | jq -c --argjson t "$t" '.[0:($t | length)] == $t')" true
  extra="$(allow_read "$1" | jq -r --argjson t "$t" '.[($t | length):][]')"
  check "  the extra roots are exactly the step's" eq "$extra" "$(printf '%s\n' "${@:2}")"
  # shellcheck disable=SC2034  # read inside the eval string below
  home="$(cd "$HOME" && pwd -P)"
  while IFS= read -r r; do
    check "  $r: absolute, an existing directory, not \$HOME or above it" \
      eval '[[ "$r" == /* ]] && [ -d "$r" ] && [[ "$home/" != "${r%/}/"* ]]'
  done <<<"$extra"
}

case_policy_render() {
  run_setup
  loop --once
  local render g u
  render="$FACTORY_HOME/run/policy/$(field .run_id).build.toml"
  g="$(cd "$WORLD/clone/.git" && pwd -P)"; u="$(cd "$WORLD/uv" && pwd -P)"
  check "the claim's render is kept under \$FACTORY_HOME/run/policy/<run id>.build.toml, and vetto read it" \
    eq "$(test -f "$render" && echo kept) $(jq -r '.[3]' "$FAKE_VETTO_LOG")" "kept $render"
  check "  the step ran under it: built" eq "$RC $(field .outcome) $(field '.actions | index("policy-render") < index("tamperguard")')" "0 built true"
  i14 "$render" "$g" "$u/tools/tamperguard" "$u/python/cpython-9.9.9-fake"
  # a joined node: tamperguard under $FACTORY_HOME/uv (join.sh's UV_TOOL_DIR, UV_PYTHON_INSTALL_DIR),
  # its link in $FACTORY_HOME/bin. The tool and python roots fall inside $FACTORY_HOME/uv and are dropped.
  run_setup
  mkdir -p "$FACTORY_HOME/bin"
  fake_uv "$FACTORY_HOME/uv"
  rm -rf "$WORLD/uv"
  loop --once
  render="$FACTORY_HOME/run/policy/$(field .run_id).build.toml"
  check "joined-node layout: built" eq "$RC $(field .outcome)" "0 built"
  i14 "$render" "$(cd "$WORLD/clone/.git" && pwd -P)" "$(cd "$FACTORY_HOME/bin" && pwd -P)" "$(cd "$FACTORY_HOME/uv" && pwd -P)"
}

case_policy_missing_root() {
  run_setup
  rm -rf "$WORLD/uv/python/cpython-9.9.9-fake"   # the version link now dangles
  loop --once
  check "tamperguard's interpreter dir is gone: exit 1, tamperguard-error (no false green)" \
    eq "$RC $(field '"\(.outcome) \(.reason)"')" "1 released tamperguard-error"
  check "  the render failed and the step never ran" \
    eq "$(field '[.actions[] | select(test("^(policy-render|policy-render-failed|tamperguard)$"))] | join(",")')" policy-render-failed
  check "  no vetto session, no tamperguard call, no render" \
    eq "$(wc -l <"$FAKE_VETTO_LOG" | tr -d ' ') $(wc -l <"$FAKE_TAMPERGUARD_LOG" | tr -d ' ') $(ls "$FACTORY_HOME/run/policy" 2>/dev/null | wc -l | tr -d ' ')" "0 0 0"
  check "  the reason is in the claim's tamperguard.err" \
    grep -qF "policy-render: interpreter $WORLD/uv/tools/tamperguard/bin/python does not resolve to an executable" \
      "$FACTORY_HOME/run/logs/$(field .run_id).tamperguard.err"
  check "  rails-proof and scope-check never ran, nothing pushed, the lock released" \
    eq "$(field '.actions | index("rails-proof"), index("scope-check")' | tr '\n' ' ')|$(pushed)|$(lock)" "null null ||"
}

case_policy_render_lib() {
  run_setup
  # shellcheck source=factory/bin/lib/policy-render.sh
  . "$BIN/lib/policy-render.sh"
  local tpl="$REPO_ROOT/factory/policy/build.toml" out="$WORLD/out.toml" d="$WORLD/d1" rc r
  mkdir -p "$d"
  policy_render "$tpl" "$out" "$d" "$d"
  check "policy_render: a root given twice is rendered once" eq "$(allow_read "$out")" "$(jq -cn --arg d "$d" '["$HOME/.factory/cache", $d]')"
  for r in "$HOME" / "$HOME/.." relative "$WORLD/none"; do
    rm -f "$out"; rc=0; policy_render "$tpl" "$out" "$d" "$r" 2>/dev/null || rc=$?
    check "  root '$r' is refused, nothing written" eq "$rc $(test -e "$out" && echo written)" "1 "
  done
  printf '[filesystem]\nallow_read = [\n  "$HOME/x",\n]\n' >"$WORLD/multi.toml"
  printf '[metadata]\nallow_read = ["x"]\n[filesystem]\nallow_write = ["$PROJECT"]\n' >"$WORLD/elsewhere.toml"
  for r in multi elsewhere; do
    rm -f "$out"; rc=0; policy_render "$WORLD/$r.toml" "$out" "$d" 2>/dev/null || rc=$?
    check "  a template whose [filesystem] has no one-line allow_read ($r) is refused" eq "$rc $(test -e "$out" && echo written)" "1 "
  done
  mkdir -p "$WORLD/py/bin" "$WORLD/tools/a/bin" "$WORLD/tools/b/bin"
  command cp "$(readlink -f "$(command -v bash)")" "$WORLD/py/bin/fakepy"
  printf '#!/usr/bin/env fakepy\n' >"$WORLD/tools/a/bin/tg-env"
  printf 'echo no interpreter line\n' >"$WORLD/tools/b/bin/tg-none"
  chmod +x "$WORLD/tools/a/bin/tg-env" "$WORLD/tools/b/bin/tg-none"
  r="$(PATH="$WORLD/tools/a/bin:$WORLD/py/bin:$PATH" policy_roots "$WORLD/clone" "$WORLD/no-fh" tg-env)"
  check "policy_roots: #!/usr/bin/env <name> resolves the interpreter through PATH" \
    eq "$r" "$(printf '%s\n' "$(cd "$WORLD/clone/.git" && pwd -P)" "$(cd "$WORLD/tools/a" && pwd -P)" "$(cd "$WORLD/py" && pwd -P)")"
  rc=0; PATH="$WORLD/tools/b/bin:$PATH" policy_roots "$WORLD/clone" "$WORLD/no-fh" tg-none >/dev/null 2>&1 || rc=$?
  check "  a tool with no #! line fails" eq "$rc" 1
  rc=0; PATH="$WORLD/tools/a/bin:$WORLD/py/bin:$PATH" policy_roots "$WORLD/not-a-repo" "$WORLD/no-fh" tg-env >/dev/null 2>&1 || rc=$?
  check "  no git dir fails" eq "$rc" 1
  rc=0; policy_roots "$WORLD/clone" "$WORLD/no-fh" no-such-tool-5e1f >/dev/null 2>&1 || rc=$?
  check "  a tool not on PATH fails" eq "$rc" 1
}

pause_case() {  # pause_case <reason> <expected sleep>
  run_setup
  export FAKE_FLEET_REASON="$1"
  loop --once
  check "$1: exit 0" eq "$RC" 0
  check "  outcome paused, reason $1" eq "$(field '"\(.outcome) \(.reason)"')" "paused $1"
  check "  the partial branch is pushed" test -n "$(pushed)"
  check "  its tip records the reason and the strikes" eq "$(trailer "$(pushed)" Fleet-Reason) $(trailer "$(pushed)" Fleet-Strikes)" "$1 1"
  check "  on top of fleet's worker branch" eq "$(git -C "$FAKE_GH_GIT" log -1 --format=%s "$(pushed)^")" "feat(T-run): fleet worker build"
  check "  the lock is kept" test -n "$(lock)"
  check "  and was heartbeated (heartbeat.sh force-updated it)" eq "$(fakegh_calls '.[0] == "api" and (.[1:] | index("PATCH")) and any(.[]; test("git/refs/locks/issue-1$"))')" 1
  check "  the worktree is kept for the resume" test -d "$WT"
  check "  the slot state names the claim" eq "$(jq -r '"\(.issue) \(.ticket) \(.resumes)"' "$FACTORY_HOME/run/slot-1.json")" "1 T-run 1"
  check "  no result comment (the claim comment only), no label" eq "$(comments) $(labels)" "1 in-progress,ready,w:light"
  check "  sleep $2 s" eq "$(field .sleep_seconds)" "$2"
}
case_quota_paused() { pause_case quota-paused 600; }
case_wall_clock() { pause_case wall-clock 0; }

case_resume_in_place() {
  run_setup
  export FAKE_FLEET_REASONS="quota-paused success"
  loop --once
  local first lock0 partial
  first="$(jq -c '.argv' "$FAKE_FLEET_LOG")"
  lock0="$(lock)"
  partial="$(pushed)"
  FACTORY_NOW=$((T0 + 3700)) FAKE_GH_NOW=$((T0 + 3700)); under_cap
  loop --once
  check "a paused claim resumes: exit 0, built" eq "$RC $(field .outcome)" "0 built"
  check "  no new claim (no second lock POST, the claim comment is still the first)" \
    eq "$(fakegh_calls '.[0] == "api" and any(.[]; . == "ref=refs/locks/issue-1")')" 1
  check "  the governor was asked again" eq "$(field .governor.action)" claim
  check "  the lock was heartbeated before it (60 min passed)" test "$(lock)" != "$lock0"
  check "  fleet got the identical argv" eq "$(jq -sc '.[1].argv' "$FAKE_FLEET_LOG")" "$first"
  check "  in the same worktree" eq "$(jq -sr '.[1].cwd == .[0].cwd' "$FAKE_FLEET_LOG")" true
  check "  fleet's strikes carried over (resume reconciliation)" eq "$(field .fleet.strikes)" 2
  local fmerge; fmerge="$(clone_commit "Merge branch 'fleet/t-run' into fleet/run-$(field .fleet.run)")"
  check "  fleet resumed on the partial work (the partial's worker commit is under fleet's merge, in the clone)" \
    eq "$(git -C "$WORLD/clone" merge-base --is-ancestor "$partial^" "$fmerge" && echo yes)" yes
  check "  the push replaces the partial branch with ONE commit on main, fleet's final tree" \
    eval '[ "$(over_main "$(pushed)")" = 1 ] && [ "$(git -C "$FAKE_GH_GIT" rev-parse "$(pushed)^")" = "$(git -C "$FAKE_GH_GIT" rev-parse main)" ] &&
          [ "$(git -C "$FAKE_GH_GIT" rev-parse "$(pushed)^{tree}")" = "$(git -C "$WORLD/clone" rev-parse "$fmerge^{tree}")" ]'
  check "  the partial's commits are not in the pushed range" \
    eq "$(git -C "$FAKE_GH_GIT" rev-list "main..$(pushed)" | grep -cxF -e "$partial" -e "$(git -C "$FAKE_GH_GIT" rev-parse "$partial^")" || true)" 0
}

case_resume_cap() {
  run_setup
  export FAKE_FLEET_REASON=wall-clock
  for _ in 1 2 3; do loop --once; done
  check "three wall-clock pauses: still paused" eq "$(field .outcome) $(jq -r .resumes "$FACTORY_HOME/run/slot-1.json")" "paused 3"
  loop --once
  check "the fourth is handled as strikes-exhausted: desk" eq "$(field '"\(.outcome) \(.reason)"')" "desk wall-clock"
  check "  the cap is in the record" eq "$(field .note)" "resume cap 3 reached"
  check "  labeled needs-desk, lock released, worktree gone" \
    eq "$(labels) $(lock) $([ -e "$WT" ] && echo kept || echo gone)" "in-progress,needs-desk,w:light  gone"
  check "  the marker carries the Ticket-Hash read at claim time, across the resumes (slot state)" \
    eq "$(marker)" "$(want_marker wall-clock)"
}

case_lock_lost() {
  run_setup
  export FAKE_FLEET_REASON=quota-paused
  loop --once
  git -C "$FAKE_GH_GIT" update-ref -d refs/locks/issue-1
  FACTORY_NOW=$((T0 + 3700)) FAKE_GH_NOW=$((T0 + 3700)); under_cap
  loop --once
  check "the paused claim's lock vanished (janitor): outcome lock-lost" eq "$(field .outcome)" lock-lost
  check "  fleet did not run again" eq "$(fleet_calls)" 1
  check "  the worktree and the slot state are gone" eq "$([ -e "$WT" ] && echo kept)$([ -e "$FACTORY_HOME/run/slot-1.json" ] && echo state)" ""
  check "  no lock was re-created" test -z "$(lock)"
}

# T25: the hand-off. A built ticket's PR is the claim: the Issue goes in-review, the lock is released.
handoff_checks() {  # handoff_checks: the hand-off after the PR was opened (outcome built)
  check "  outcome built, a PR from ticket/T-run/dev-box in the record" \
    eq "$(field '"\(.outcome) \(.pr)"') $(jq -r --argjson p "$(field .pr)" '.pulls[] | select(.number == $p) | .headRefName' "$FAKE_GH_ISSUES")" \
       "built 2 ticket/T-run/dev-box"
  check "  the lock ref is gone" test -z "$(lock)"
  check "  the Issue is in-review, neither ready nor in-progress" eq "$(labels)" in-review,w:light
  check "  one label edit: add in-review, remove ready,in-progress" \
    eq "$(jq -sc 'map(select(.[0:2] == ["issue", "edit"] and (index("in-review") != null)) | .[5:])' "$FAKE_GH_LOG")" \
       '[["--add-label","in-review","--remove-label","ready,in-progress"]]'
  check "  actions: pr-open, comment, label-in-review, release-lock, in that order" \
    eq "$(field '[.actions[] | select(IN("pr-open", "comment", "label-in-review", "release-lock"))] | join(",")')" \
       pr-open,comment,label-in-review,release-lock
  check "  no keep-lock, no slot state, the worktree gone" \
    eq "$(field '.actions | index("keep-lock")')$([ -e "$FACTORY_HOME/run/slot-1.json" ] && echo state)$([ -e "$WT" ] && echo kept)" null
  check "  the result comment names the PR" grep -qF 'PR #2' <<<"$(last_comment)"
}

case_success_handoff() {
  run_setup
  loop --once
  check "all gates pass: exit 0, the lock checked (heartbeat dry run) before the push" \
    eq "$RC $(field '.actions | (index("lock-owned") < index("push ticket/T-run/dev-box"))')" "0 true"
  handoff_checks
}

case_lock_lost_before_push() {
  # a ralon shim takes the lock away while fleet runs: <how> is gone (the janitor) or other (another node's)
  local how other
  for how in gone other; do
    run_setup
    fakegh_lock 1 other-node $((T0 - 60)); other="$(lock)"; git -C "$FAKE_GH_GIT" update-ref -d refs/locks/issue-1
    printf '#!/usr/bin/env bash\nrc=0; "%s/ralon" "$@" || rc=$?\nif [ "$1 $2" = "run -C" ]; then\n  if [ %s = gone ]; then git -C "$FAKE_GH_GIT" update-ref -d refs/locks/issue-1; else git -C "$FAKE_GH_GIT" update-ref refs/locks/issue-1 %s; fi\nfi\nexit "$rc"\n' \
      "$FAKES_DIR" "$how" "$other" >"$WORLD/bin/ralon"
    chmod +x "$WORLD/bin/ralon"
    loop --once
    check "the lock is $how after fleet, all gates pass: exit 0, outcome lock-lost" eq "$RC $(field '"\(.outcome) \(.reason)"')" "0 lock-lost lock-lost"
    check "  the lock check said so after the gates" \
      eq "$(field '.actions | (index("lock-lost") > index("scope-check")) and (index("lock-owned") == null)')" true
    check "  nothing pushed to ticket/T-run/*, no PR" \
      eq "$(git -C "$FAKE_GH_GIT" for-each-ref --format=x refs/heads/ticket | wc -l | tr -d ' ') $(jq '.pulls // [] | length' "$FAKE_GH_ISSUES") $(field .pushed)" "0 0 null"
    check "  no comment beyond the claim's, no label edit (the claim's labels)" eq "$(comments) $(labels)" "1 in-progress,ready,w:light"
    check "  no issue edit after the claim" \
      eq "$(jq -sc 'map(select(.[0:2] == ["issue", "edit"] and (index("in-review") != null or index("needs-desk") != null))) | length' "$FAKE_GH_LOG")" 0
    check "  the lock is left as it is (not released, not re-created)" eq "$(lock)" "$([ "$how" = other ] && echo "$other")"
    check "  the worktree and the slot state are gone" eq "$([ -e "$WT" ] && echo kept)$([ -e "$FACTORY_HOME/run/slot-1.json" ] && echo state)" ""
  done
}

case_pr_open_once_fails() {
  run_setup
  echo 1 >"$WORLD/pr-create-fails"
  loop --once
  local sha; sha="$(field .pushed.sha)"
  check "gh pr create fails once: exit 0, outcome pr-pending" eq "$RC $(field .outcome)" "0 pr-pending"
  check "  the gated sha was pushed, no PR" eq "$(pushed) $(jq '.pulls // [] | length' "$FAKE_GH_ISSUES")" "$sha 0"
  check "  actions: pr-open-failed, keep-lock" eq "$(field '[.actions[] | select(IN("pr-open-failed", "keep-lock", "release-lock", "comment"))] | join(",")')" pr-open-failed,keep-lock
  check "  the slot state holds pr_pending (tries 1, the pushed sha)" \
    eq "$(jq -c '[.pr_pending.tries, .pr_pending.sha == "'"$sha"'"]' "$FACTORY_HOME/run/slot-1.json")" '[1,true]'
  check "  the lock is kept, the Issue's labels untouched, no result comment" eq "$(test -n "$(lock)" && echo kept) $(labels) $(comments)" "kept in-progress,ready,w:light 1"
  check "  the worktree is gone (the pushed sha is all the PR needs)" test ! -e "$WT"
  loop --once
  check "the next iteration retries the PR: exit 0, pr-retry on the pushed sha" \
    eq "$RC $(field '"\(.actions[0]) \(.pr_retry.sha)"')" "0 pr-retry $sha"
  check "  the lock checked first, then the PR opened; fleet did not run again" \
    eq "$(field '.actions | index("lock-owned") < index("pr-open")') $(fleet_calls)" "true 1"
  handoff_checks
}

case_pr_open_twice_fails() {
  run_setup
  echo 2 >"$WORLD/pr-create-fails"
  loop --once
  check "gh pr create fails: pr-pending" eq "$(field .outcome)" pr-pending
  loop --once
  check "and fails again on the retry: exit 0, outcome desk, reason pr-open-failed" \
    eq "$RC $(field '"\(.outcome) \(.reason)"')" "0 desk pr-open-failed"
  check "  no PR, the pushed branch stays" eq "$(jq '.pulls // [] | length' "$FAKE_GH_ISSUES") $(test -n "$(pushed)" && echo pushed)" "0 pushed"
  check "  labeled needs-desk, ready removed" eq "$(labels)" in-progress,needs-desk,w:light
  check "  the comment ends in the needs-desk marker, reason pr-open-failed" eq "$(marker)" "$(want_marker pr-open-failed)"
  check "  the lock is released, no slot state" eq "$(lock)$([ -e "$FACTORY_HOME/run/slot-1.json" ] && echo state)" ""
  check "  actions: pr-retry, lock-owned, pr-open-failed, comment, label-needs-desk, release-lock" \
    eq "$(field '.actions | join(",")')" pr-retry,lock-owned,pr-open-failed,comment,label-needs-desk,release-lock
}

case_budget_override() {
  # budget_run <ticket budget JSON>: the claim with that `budget` on T-run (null: no budget key); sets MS
  # (fleet's --max-strikes --wall-clock-minutes)
  budget_run() {
    run_setup
    FAKE_ADLC_TICKETS="$(jq -c --argjson b "$1" 'if $b == null then . else .[0].budget = $b end' <<<"$FAKE_ADLC_TICKETS")"
    loop --once
    MS="$(jq -r '"\(.argv[(.argv | index("--max-strikes")) + 1]) \(.argv[(.argv | index("--wall-clock-minutes")) + 1])"' "$FAKE_FLEET_LOG")"
  }
  budget_run '{"maxStrikes": 2, "wallClockMinutes": 7}'
  check "ticket budget {maxStrikes 2, wallClockMinutes 7}: fleet gets --max-strikes 2 --wall-clock-minutes 7" eq "$MS" "2 7"
  check "  the ledger's budget says ticket" eq "$(jq -c .budget <<<"$LAST")" '{"max_strikes":2,"wall_clock_minutes":7,"source":"ticket"}'
  check "  the ledger line is the one written" eq "$(tail -n1 "$FACTORY_HOME/run/ledger.jsonl" | jq -r .budget.source)" ticket
  budget_run '{"maxStrikes": 3}'
  check "only maxStrikes 3: it alone overrides (the weight's 45 min), source ticket" eq "$MS $(field .budget.source)" "3 45 ticket"
  budget_run null
  check "no ticket budget: the weight's (w:light: 2 strikes, 45 min), source weights" \
    eq "$MS $(jq -c .budget <<<"$LAST")" '2 45 {"max_strikes":2,"wall_clock_minutes":45,"source":"weights"}'
  budget_run 200000
  check "a number budget (adlc's token ceiling): the weight's, source weights" eq "$MS $(field .budget.source)" "2 45 weights"
  local b
  for b in '{"maxStrikes": 0, "wallClockMinutes": 7}' '{"maxStrikes": "x", "wallClockMinutes": 7}' \
           '{"maxStrikes": 3, "wallClockMinutes": 0}' '{"maxStrikes": 3, "wallClockMinutes": 10000}' \
           '{"maxStrikes": "3", "wallClockMinutes": 7}' '{"maxStrikes": 2.5}'; do
    budget_run "$b"
    check "an invalid ticket budget $b: the weight's for both, source weights-ticket-budget-invalid" \
      eq "$MS $(field .budget.source)" "2 45 weights-ticket-budget-invalid"
  done
}

desk_case() {
  run_setup
  export FAKE_FLEET_REASON="$1"
  loop --once
  check "$1: exit 0, the loop goes on" eq "$RC" 0
  check "  outcome desk" eq "$(field '"\(.outcome) \(.reason)"')" "desk $1"
  check "  the branch is pushed with the reason" eq "$(trailer "$(pushed)" Fleet-Reason)" "$1"
  check "  labeled needs-desk, ready removed" eq "$(labels)" in-progress,needs-desk,w:light
  check "  the comment ends in the needs-desk marker with the reason" eq "$(marker)" "$(want_marker "$1")"
  check "  the lock is released" test -z "$(lock)"
  check "  the comment: reason, strikes, branch" grep -qE "reason \`$1\`, strikes 1 of 2, .*Branch \`ticket/T-run/dev-box\`" <<<"$(last_comment)"
  check "  the worktree is gone, no slot state" eq "$([ -e "$WT" ] && echo kept)$([ -e "$FACTORY_HOME/run/slot-1.json" ] && echo state)" ""
  check "  no nap after it" eq "$(field .sleep_seconds)" 0
}
case_strikes_exhausted() { desk_case strikes-exhausted; }
case_flail() { desk_case flail; }

case_desk_marker() {
  # A scope failure (the real scope-check: fleet built a path outside the ticket's scope): a needs-desk path.
  run_setup
  export FAKE_FLEET_FILE=outside.sh
  loop --once
  check "a scope failure: exit 0, outcome desk, reason scope-fail" eq "$RC $(field '"\(.outcome) \(.reason)"')" "0 desk scope-fail"
  check "  nothing pushed, labeled needs-desk, ready removed" eq "$(pushed) $(labels)" " in-progress,needs-desk,w:light"
  check "  the comment ends in the marker, reason scope-fail" eq "$(marker)" "$(want_marker scope-fail)"
  check "  the marker is the comment's last line" eq "$(last_comment | tail -n1)" \
    "<!-- factory-needs-desk v1 ticket=T-run hash=hash-T-run reason=scope-fail node=dev-box -->"
  # comment first, then one edit that adds needs-desk and removes ready: the mirror never sees the
  # label without the marker, and no node can claim the Issue (claim.sh takes `ready`) in between.
  local ci ei
  ci="$(jq -sc 'map(.[0:2] == ["issue", "comment"] and (.[-1] | contains("factory-needs-desk"))) | index(true)' "$FAKE_GH_LOG")"
  ei="$(jq -sc 'map(.[0:2] == ["issue", "edit"] and (index("needs-desk") != null)) | index(true)' "$FAKE_GH_LOG")"
  check "  the marker comment comes before the label edit" \
    eq "$([ "$ci" != null ] && [ "$ei" != null ] && [ "$ci" -lt "$ei" ] && echo before)" before
  check "  the label edit adds needs-desk and removes ready" \
    eq "$(jq -sc 'map(select(.[0:2] == ["issue", "edit"] and (index("needs-desk") != null)) | [.[2], .[5:]]) | .[0]' "$FAKE_GH_LOG")" \
       '["1",["--add-label","needs-desk","--remove-label","ready"]]'
  # The real claim.sh's claim comment is what the mirror counts as a new claim cycle.
  check "  claim.sh's claim comment reads as a claim (DESK_CLAIM_RE)" \
    eq "$(jq -c --arg desk_re "$DESK_MARKER_RE" --arg claim_re "$DESK_CLAIM_RE" --argjson desk_trusted "$DESK_TRUSTED" \
            "$DESK_JQ"'[.issues[0].comments[0] | . + {authorAssociation: "COLLABORATOR"} | desk_event]' "$FAKE_GH_ISSUES")" '[{"kind":"claim"}]'
  # An Issue from a mirror that wrote no Ticket-Hash line: the marker says unknown, so the mirror
  # recomputes that label rather than hold it.
  run_setup
  local tmp; tmp="$(mktemp)"
  jq '(.issues[] | select(.number == 1)).body |= sub("Ticket-Hash: hash-T-run\n"; "")' "$FAKE_GH_ISSUES" >"$tmp" && mv "$tmp" "$FAKE_GH_ISSUES"
  export FAKE_FLEET_REASON=flail
  loop --once
  check "no Ticket-Hash line on the Issue: the marker's hash is unknown" eq "$(marker)" "$(want_marker flail unknown)"
  # Outcomes that do not label needs-desk carry no marker.
  run_setup
  export FAKE_FLEET_REASON=preflight
  loop --once
  check "a run-level failure (released, no label): no marker" eq "$(marker)$(labels)" in-progress,ready,w:light
}

case_review_unavailable() {
  run_setup
  export FAKE_FLEET_REASON=review-unavailable
  loop --once
  check "review-unavailable: exit 0, outcome released" eq "$RC $(field .outcome)" "0 released"
  check "  the lock is released" test -z "$(lock)"
  check "  no comment beyond the claim, no label, nothing pushed" eq "$(comments) $(labels) $(pushed)" "1 in-progress,ready,w:light "
  check "  sleep reviewUnavailableSleepMinutes" eq "$(field .sleep_seconds)" "$(( $(jq .governor.reviewUnavailableSleepMinutes "$REPO_ROOT/factory/policy/budget.json") * 60 ))"
  check "  the worktree is gone" test ! -e "$WT"
}

case_anything_else() {
  local r
  for r in lock-held ticket-blocked mirror-fetch-failed; do
    run_setup
    export FAKE_FLEET_REASON="$r"
    loop --once
    check "$r: exit 0, released, comment names it" eq "$RC $(field .outcome) $(grep -c "reason \`$r\`" <<<"$(last_comment)")" "0 released 1"
    check "  lock released, nothing pushed, no label, nap nothingClaimable" eq "$(lock)|$(pushed)|$(labels)|$(field .sleep_seconds)" "||in-progress,ready,w:light|600"
  done
  for r in preflight quarantined dispatch-refused; do
    run_setup
    export FAKE_FLEET_REASON="$r"
    loop --once
    check "run-level $r: exit 1 (the slot stops), released, comment names it" \
      eq "$RC $(field .outcome) $(lock)$(grep -c "reason \`$r\`" <<<"$(last_comment)")" "1 released 1"
    check "  the worktree is gone" test ! -e "$WT"
  done
  run_setup
  export FAKE_FLEET_REASON=garbage
  loop --once
  check "fleet prints no JSON: exit 1, reason fleet-output-unreadable" eq "$RC $(field .reason)" "1 fleet-output-unreadable"
  run_setup
  export FAKE_FLEET_REASON=nomerge
  loop --once
  check "fleet exits 0 without a merge: exit 1, reason no-merge, nothing pushed" eq "$RC $(field .reason) $(pushed)" "1 no-merge "
  run_setup
  export FAKE_FLEET_REASON="Leaked:$MARK"
  loop --once
  check "a reason that is not a code is never forwarded: 'unrecognized'" eq "$RC $(field .reason)" "1 unrecognized"
  check "  and the comment says so" grep -qF 'reason `unrecognized`' <<<"$(last_comment)"
  run_setup
  mkdir -p "$FACTORY_HOME/run"; : >"$FACTORY_HOME/run/mirrors"
  loop --once
  check "the model-plane mirror cannot be built: exit 1, reason mirror-failed, fleet not run" \
    eq "$RC $(field .reason) $(fleet_calls)" "1 mirror-failed 0"
  check "  released, the comment names it, the worktree is gone" \
    eq "$(lock)$(grep -c 'reason `mirror-failed`' <<<"$(last_comment)") $(test -e "$WT" && echo kept)" "1 "
}

case_argv() {
  run_setup
  # a ralon shim keeps a copy of the lock ralon reads (the worktree is gone after the iteration)
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "run -C" ] && command cp "$3/agent.lock" "%s/seen.lock"\nexec "%s/ralon" "$@"\n' \
    "$WORLD" "$FAKES_DIR" >"$WORLD/bin/ralon"
  chmod +x "$WORLD/bin/ralon"
  loop --once
  local wt ps
  wt="$(cd "$WORLD/clone" && pwd -P)/.worktrees/T-run"
  check "ralon: run -C <worktree> -- env PATH=<shim dir>:<PATH> <fleet> run …" \
    eq "$(jq -c '.[0:7]' "$FAKE_RALON_LOG")" "$(jq -cn --arg wt "$wt" --arg f "$FAKES_DIR/fleet" \
         --arg p "PATH=$FACTORY_HOME/run/bwrap-shim/slot-1:$PATH" '["run", "-C", $wt, "--", "env", $p, $f]')"
  check "  the rest of ralon's argv is fleet's" eq "$(jq -c '.[7:]' "$FAKE_RALON_LOG")" "$(jq -c .argv "$FAKE_FLEET_LOG")"
  check "fleet runs in the worktree" eq "$(jq -r .cwd "$FAKE_FLEET_LOG")" "$wt"
  check "fleet's argv: ADR-0005's real flags, in order" \
    eq "$(jq -c '.argv | del(.[16], .[18], .[24])' "$FAKE_FLEET_LOG")" \
       '["run","--tickets","T-run","--concurrency","1","--no-pr","--no-complete","--base","'"$(git -C "$WORLD/clone" rev-parse origin/main)"'","--adapter","claude-code","--max-strikes","2","--wall-clock-minutes","45","--pre-strike-argv","--pre-strike-env","--model-plane-read","bounded","--model-plane-git","mirror","--model-plane-git-mirror","--model-plane-egress","allowlist","--json"]'
  check "  the model-plane mirror is \$FACTORY_HOME/run/mirrors/<run id>.git" \
    eq "$(jq -r '.argv[24]' "$FAKE_FLEET_LOG")" "$FACTORY_HOME/run/mirrors/$(field .run_id).git"
  check "  fleet accepted it (bare, one base branch, no remote, no hook) and echoed the bounded plane" \
    eq "$(jq -c '[.readPolicy, .privateTmp, .gitSource, .egress]' "$FACTORY_HOME/run/logs/$(field .run_id).fleet.json")" \
       '["bounded",true,"mirror","allowlist"]'
  check "  the mirror was built before fleet and removed with the worktree" \
    eq "$(field '.actions | (index("mirror") < index("fleet-run")) and (index("worktree-remove") != null)') $(test -e "$(jq -r '.argv[24]' "$FAKE_FLEET_LOG")" && echo kept)" "true "
  check "  --pre-strike-argv is the absolute quota gate" eq "$(jq -r '.argv[16]' "$FAKE_FLEET_LOG")" "[\"$BIN/quota-gate.sh\"]"
  ps="$(jq -r '.argv[18]' "$FAKE_FLEET_LOG")"
  check "  --pre-strike-env carries PATH, HOME, FACTORY_MANIFEST (and FACTORY_NOW when pinned)" \
    eq "$(jq -c 'keys' <<<"$ps")" '["FACTORY_MANIFEST","FACTORY_NOW","HOME","PATH"]'
  check "  its PATH starts with \$FACTORY_HOME/bin and reaches jq and cux" \
    eq "$(jq -r '.PATH | split(":") | .[0]' <<<"$ps") $(PATH="$(jq -r .PATH <<<"$ps")" command -v jq cux | wc -l | tr -d ' ')" "$FACTORY_HOME/bin 2"
  check "  no --dead-end-file on a fresh claim" eq "$(jq '.argv | index("--dead-end-file")' "$FAKE_FLEET_LOG")" null
  check "vetto wraps the loop's own tamperguard step with the claim's render of build.toml" \
    eq "$(jq -c '.[0:7]' "$FAKE_VETTO_LOG")" "$(jq -cn --arg p "$FACTORY_HOME/run/policy/$(field .run_id).build.toml" '["--profile", "strict", "--policy", $p, "--tui", "none", "--"]')"
  check "  and never wraps fleet" eq "$(jq -s 'map(select(any(.[]; test("fleet")))) | length' "$FAKE_VETTO_LOG")" 0
  check "tamperguard: --range <origin main>...<the pushed sha> --json (three dots, the gated commit)" \
    eq "$(jq -c '.' "$FAKE_TAMPERGUARD_LOG")" "$(jq -cn --arg r "$(git -C "$FAKE_GH_GIT" rev-parse main)...$(pushed)" '["--range", $r, "--json"]')"
  # T25: ticket show twice, ralon-lock.sh's render, then ticket_budget's read of the ticket's budget
  check "the rails lock was rendered from the ticket (ralon-lock.sh → adlc ticket show), then the budget read (T25)" \
    eq "$(jq -sc 'map(select(.[0:2] == ["ticket", "show"]))' "$FAKE_ADLC_LOG")" '[["ticket","show","T-run","--json"],["ticket","show","T-run","--json"]]'
  check "  ralon found <worktree>/agent.lock with the ticket's rail" grep -qxE '[[:space:]]+- "?tests/rail/\*\*"?' "$WORLD/seen.lock"
}

lapsed_branch() {  # lapsed_branch <file>: another node's lapsed claim left ticket/T-run/old-node, one
  # commit of work (adding <file> to main's tree) and a record commit; sets work and rec (the tip)
  local main blob tree
  main="$(git -C "$FAKE_GH_GIT" rev-parse main)"
  blob="$(printf 'half done\n' | git -C "$FAKE_GH_GIT" hash-object -w --stdin)"
  tree="$( (git -C "$FAKE_GH_GIT" ls-tree "$main"; printf '100644 blob %s\t%s\n' "$blob" "$1") | git -C "$FAKE_GH_GIT" mktree)"
  work="$(GIT_COMMITTER_DATE="$((T0 - 200000)) +0000" git -C "$FAKE_GH_GIT" commit-tree "$tree" -p "$main" -m "feat(T-run): fleet worker build")"
  rec="$(GIT_COMMITTER_DATE="$((T0 - 190000)) +0000" git -C "$FAKE_GH_GIT" commit-tree "$tree" -p "$work" \
          -m "$(printf 'factory: T-run flail on old-node\n\nFactory-Outcome: flail\nFleet-Reason: flail\nFleet-Strikes: 2\nTicket: T-run\nNode: old-node\n')")"
  git -C "$FAKE_GH_GIT" update-ref refs/heads/ticket/T-run/old-node "$rec"
}

case_resume() {
  run_setup
  local work rec
  lapsed_branch half.txt
  # and an older one that must lose to it
  git -C "$FAKE_GH_GIT" update-ref refs/heads/ticket/T-run/older-node "$work"
  export FAKE_FLEET_REASON=strikes-exhausted
  loop --once
  check "a lapsed ticket/T-run/* branch: the worktree base is the newest one" eq "$(jq -c .base <<<"$LAST")" \
    "$(jq -cn --arg s "$rec" '{kind: "lapsed", sha: $s, lapsed: "ticket/T-run/old-node"}')"
  check "  fleet's --base is that branch" eq "$(jq -r '.argv[(.argv | index("--base")) + 1]' "$FAKE_FLEET_LOG")" "$rec"
  check "  --dead-end-file is passed, absolute, inside the worktree" \
    eq "$(jq -r '.argv[(.argv | index("--dead-end-file")) + 1]' "$FAKE_FLEET_LOG")" "$(jq -r .cwd "$FAKE_FLEET_LOG")/.factory-run/dead-end.md"
  check "  the dead-end material names the lapsed branch" grep -qF 'ticket/T-run/old-node' <<<"$(jq -r .dead_end "$FAKE_FLEET_LOG")"
  check "  and its recorded outcome" grep -qF 'Fleet-Reason: flail' <<<"$(jq -r .dead_end "$FAKE_FLEET_LOG")"
  check "  and its commits and files" eq "$(grep -cE 'fleet worker build|half\.txt' <<<"$(jq -r .dead_end "$FAKE_FLEET_LOG")")" 2
  check "  the new push builds on it (the lapsed tip is an ancestor)" git -C "$FAKE_GH_GIT" merge-base --is-ancestor "$rec" "$(pushed)"
  check "  the other node's branch is untouched" eq "$(fakegh_ref refs/heads/ticket/T-run/old-node)" "$rec"
  check "  the record says lapsed" eq "$(field .actions | jq -r 'index("worktree lapsed") != null')" true
}

case_lapsed_range() {
  # T22 acceptance 2: a lapsed-branch resume gates the range from the merge-base with origin/main
  run_setup
  local work rec main
  main="$(git -C "$FAKE_GH_GIT" rev-parse main)"
  lapsed_branch half.txt   # the lapsed work is in scope
  loop --once
  check "a lapsed branch whose work is in scope: built" eq "$RC $(field '"\(.outcome) \(.base.kind) \(.base.sha == "'"$rec"'")"')" "0 built lapsed true"
  check "  .gate_base is main's sha (the merge-base with origin/main), not the lapsed tip" eq "$(field .gate_base)" "$main"
  check "  tamperguard's range starts at main and ends at the pushed sha" \
    eq "$(jq -c '.' "$FAKE_TAMPERGUARD_LOG")" "$(jq -cn --arg r "$main...$(pushed)" '["--range", $r, "--json"]')"
  check "  the pushed branch is ONE commit whose parent is main (T23: the lapsed commits are squashed)" \
    eq "$(git -C "$FAKE_GH_GIT" rev-list --parents "$main..$(pushed)")" "$(pushed) $main"
  check "  the lapsed commits are not in the pushed range" \
    eq "$(git -C "$FAKE_GH_GIT" rev-list "$main..$(pushed)" | grep -cxE "$work|$rec" || true)" 0
  check "  the lapsed work is kept in the pushed tree, so it is gated with the rest" \
    eq "$(git -C "$FAKE_GH_GIT" show "$(pushed):half.txt") $(git -C "$FAKE_GH_GIT" diff --name-only "$main" "$(pushed)" | tr '\n' ' ')" "half done half.txt hello.sh "
  check "  rails-proof and scope-check passed on it" eq "$(field '"\(.rails_proof) \(.scope_check)"')" "pass pass"
  check "  the pushed sha is the gated one" eq "$(pushed)" "$(field .gate_head)"
  # the lapsed branch's own commits are gated with the rest: its out-of-scope file fails the claim
  run_setup
  lapsed_branch outside.sh
  loop --once
  check "a lapsed branch whose work is out of scope: scope-fail, nothing pushed" \
    eq "$(field '"\(.outcome) \(.reason) \(.base.kind)"') $(pushed)" "desk scope-fail lapsed "
  check "  scope-check named the lapsed file" grep -qxF '  outside.sh' "$FACTORY_HOME/run/logs/$(field .run_id).scope.err"
}

case_no_transcript() {
  run_setup
  loop --once
  check "the marker reached the node (so the grep below is not vacuous): fleet's log" grep -qF "$MARK" "$FACTORY_HOME"/run/logs/*.fleet.json
  collect() {
    git -C "$FAKE_GH_GIT" log --format=%B --all >>"$WORLD/outbound.txt"
    command cat "$FAKE_GH_LOG" "$FACTORY_HOME/run/ledger.jsonl" >>"$WORLD/outbound.txt"
    command cat "$WORLD"/prs/*.md >>"$WORLD/outbound.txt" 2>/dev/null || true
    jq -r '.issues[].comments[].body' "$FAKE_GH_ISSUES" >>"$WORLD/outbound.txt"
    printf '%s\n' "$OUT" >>"$WORLD/outbound.txt"
  }
  : >"$WORLD/outbound.txt"; collect
  check "built: no planted text in commit messages, gh calls, PR body, comments, ledger, stdout" no_mark "$WORLD/outbound.txt"
  local r
  for r in strikes-exhausted quota-paused review-unavailable ticket-blocked preflight; do
    run_setup; export FAKE_FLEET_REASON="$r"
    loop --once; : >"$WORLD/outbound.txt"; collect
    check "$r: no planted text in any outbound payload" no_mark "$WORLD/outbound.txt"
  done
  run_setup; export FAKE_TAMPERGUARD_VERDICT=tamper
  loop --once; : >"$WORLD/outbound.txt"; collect
  check "tamper: no finding text in any outbound payload" no_mark "$WORLD/outbound.txt"
  check "  (tamperguard did print it, into the node-local log)" grep -qF "$MARK" "$FACTORY_HOME"/run/logs/*
}

case_once() {
  run_setup
  fakegh_close 1
  loop --once
  check "--once with nothing claimable: exit 0" eq "$RC" 0
  check "  exactly one iteration (one line, one governor quota read)" \
    eq "$(wc -l <<<"$OUT" | tr -d ' ') $(jq -sc 'map(select(. == ["usage", "show"])) | length' "$FAKE_CUX_LOG")" "1 1"
  check "  outcome nothing-claimable, sleep 600" eq "$(field '"\(.outcome) \(.sleep_seconds)"')" "nothing-claimable 600"
  check "  no nap" test ! -e "$WORLD/naps"
  : >"$FAKE_CUX_LOG"
  loop --max-iterations 2
  check "--max-iterations 2: two iterations, one nap of 600 s between them" \
    eq "$(wc -l <<<"$OUT" | tr -d ' ') $(command cat "$WORLD/naps" | tr '\n' ' ')" "2 600 "
  run_setup
  loop --once
  check "--once with a claim: one claim, one fleet run" eq "$(fakegh_calls '.[0] == "api" and any(.[]; . == "ref=refs/locks/issue-1")') $(fleet_calls)" "1 1"
}

case_governor() {
  run_setup
  FAKE_CLAUDE_VERSION=2.1.279 loop --once
  check "the governor refuses (adapter drifted): exit 2, no claim" \
    eq "$RC $(field '"\(.outcome) \(.governor.reason)"') $(fakegh_calls '.[0] == "api" and any(.[]; . == "ref=refs/locks/issue-1")')" "2 refused adapter_pins 0"
  FAKE_CLAUDE_VERSION=2.1.279 loop --max-iterations 3
  check "  refusal stops the loop even without --once" eq "$RC $(wc -l <<<"$OUT" | tr -d ' ')" "2 1"
  printf '{"a@example.invalid": {"polled_at": "%s", "five_hour": {"utilization": 100, "resets_at": "%s"}}}\n' \
    "$(iso $((T0 - 60)))" "$(iso $((T0 + 3 * 86400)))" >"$FAKE_CUX_USAGE"
  loop --max-iterations 2
  check "quota exhausted for 3 days: outcome sleep, the whole wait in the record" \
    eq "$(jq -sr '.[0] | "\(.outcome) \(.governor.reason) \(.sleep_seconds)"' <<<"$OUT")" "sleep quota_exhausted 259200"
  check "  the nap is one heartbeat-sized piece, then the governor again" eq "$(command cat "$WORLD/naps")" 3600
  check "  no claim while asleep" eq "$(fakegh_calls '.[0] == "api" and any(.[]; . == "ref=refs/locks/issue-1")')" 0
  check "  the account key never appears" no_mark "$FACTORY_HOME/run/ledger.jsonl" && ! grep -q example.invalid "$FACTORY_HOME/run/ledger.jsonl"
}

case_dry_run() {
  run_setup
  RC=0; OUT="$(cd "$WORLD/clone" && "$RUN" --slot 1 --json 2>/dev/null)" || RC=$?
  check "no --apply: exit 0, a dry-run plan" eq "$RC $(jq -r '"\(.mode) \(.would_claim) \(.governor.action)"' <<<"$OUT")" "0 dry-run 1 claim"
  check "  no lock, no fleet, no \$FACTORY_HOME/run" eq "$(lock)|$(fleet_calls)|$([ -e "$FACTORY_HOME/run" ] && echo run)" "|0|"
}

case_guards() {
  run_setup
  RC=0; (cd "$WORLD/clone" && "$RUN" --slot 3 --apply --once >/dev/null 2>&1) || RC=$?
  check "a slot beyond the manifest's slots: exit 2" eq "$RC" 2
  mkdir -p "$FACTORY_HOME/run/slot-1.mutex"; echo $$ >"$FACTORY_HOME/run/slot-1.mutex/pid"
  loop --once
  check "a second loop on a live slot: exit 2, nothing run" eq "$RC $(fleet_calls)" "2 0"
  echo 999999 >"$FACTORY_HOME/run/slot-1.mutex/pid"
  loop --once
  check "a dead holder's slot mutex is broken: the loop runs" eq "$RC $(field .outcome)" "0 built"
  check "  and the mutex is dropped at exit" test ! -e "$FACTORY_HOME/run/slot-1.mutex"
  RC=0; (cd "$WORLD/clone" && FACTORY_MANIFEST='' FACTORY_HOME="$WORLD/none" "$RUN" --slot 1 --apply --once >/dev/null 2>&1) || RC=$?
  check "no manifest and no \$FACTORY_HOME/env: exit 1" eq "$RC" 1
  mkdir -p "$WORLD/fh2"; printf 'export FACTORY_MANIFEST=%q\n' "$FACTORY_MANIFEST" >"$WORLD/fh2/env"
  fakegh_close 1
  RC=0; OUT="$(cd "$WORLD/clone" && FACTORY_MANIFEST='' FACTORY_HOME="$WORLD/fh2" "$RUN" --slot 1 --apply --once --json 2>/dev/null)" || RC=$?
  check "  \$FACTORY_HOME/env (join.sh writes it) is sourced: exit 0" eq "$RC $(jq -r .outcome <<<"$OUT")" "0 nothing-claimable"
}

case_fakes() {
  run_setup
  local wt="$WORLD/fk" doc rc
  git clone -q "$FAKE_GH_GIT" "$wt"
  rc=0; (cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 --json --bogus >/dev/null 2>&1) || rc=$?
  check "fake fleet: an option 1.12.0 lacks → exit 1" eq "$rc" 1
  rc=0; doc="$(cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 --json --pre-strike-argv '["quota-gate.sh"]' 2>/dev/null)" || rc=$?
  check "  a relative pre-strike argv[0] → exit 1, reason preflight" eq "$rc $(jq -r .reason <<<"$doc")" "1 preflight"
  rc=0; doc="$(cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 --max-strikes 51 --json 2>/dev/null)" || rc=$?
  check "  --max-strikes 51 → preflight" eq "$rc $(jq -r .reason <<<"$doc")" "1 preflight"
  rc=0; doc="$(cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 --model-plane-egress allowlist --json 2>"$WORLD/fk.err")" || rc=$?
  check "  allowlist egress without bounded reads → exit 1, dispatch-refused, config.mjs's message" \
    eq "$rc $(jq -r .reason <<<"$doc") $(command cat "$WORLD/fk.err")" \
       "1 dispatch-refused fleet: --model-plane-egress allowlist requires --model-plane-read bounded"
  rc=0; (cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 --model-plane-read bounded --model-plane-egress allowlist --json >/dev/null 2>&1) || rc=$?
  check "  bounded reads without the git mirror → exit 1" eq "$rc" 1
  rc=0; (cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 --model-plane-read bounded --model-plane-git mirror --model-plane-git-mirror rel.git --json >/dev/null 2>&1) || rc=$?
  check "  a relative mirror path → exit 1" eq "$rc" 1
  rc=0; (cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 --wall-clock-minutes 1.5 --json >/dev/null 2>&1) || rc=$?
  check "  --wall-clock-minutes 1.5 → exit 1 (a positive integer, as config.mjs)" eq "$rc" 1
  local -a mp=(--model-plane-read bounded --model-plane-git mirror --model-plane-git-mirror "$WORLD/m.git" --model-plane-egress allowlist)
  git clone -q --bare "$FAKE_GH_GIT" "$WORLD/m.git"
  rc=0; doc="$(cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 "${mp[@]}" --json 2>/dev/null)" || rc=$?
  check "  a bare clone as the mirror (remote.origin.* in its config) → exit 1, pipeline-error (assertBareMirror)" eq "$rc $(jq -r .reason <<<"$doc")" "1 pipeline-error"
  rm -rf "$WORLD/m.git"; git init -q --bare --template= "$WORLD/m.git"
  git -C "$WORLD/m.git" fetch -q "$FAKE_GH_GIT" main:refs/heads/base main:refs/heads/other
  rc=0; (cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 "${mp[@]}" --json >/dev/null 2>&1) || rc=$?
  check "  a mirror with two base branches → exit 1" eq "$rc" 1
  git -C "$WORLD/m.git" update-ref -d refs/heads/other; git -C "$WORLD/m.git" config core.hooksPath /tmp
  rc=0; (cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 "${mp[@]}" --json >/dev/null 2>&1) || rc=$?
  check "  a mirror whose config carries a key outside the allowlist → exit 1" eq "$rc" 1
  git -C "$WORLD/m.git" config --unset core.hooksPath; mkdir -p "$WORLD/m.git/hooks"; : >"$WORLD/m.git/hooks/post-checkout"
  rc=0; (cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 "${mp[@]}" --json >/dev/null 2>&1) || rc=$?
  check "  a mirror with a live hook → exit 1" eq "$rc" 1
  rc=0; doc="$(cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 --base main --json)" || rc=$?
  check "  success: exit 0, reason null, fleet/run-*, merged 1" \
    eq "$rc $(jq -c '[.reason, .integrationBranch, .merged]' <<<"$doc")" '0 [null,"fleet/run-fake-1",1]'
  check "  resultDocument's keys (lib/result.mjs at 1.12.0)" eq "$(jq -c 'keys_unsorted' <<<"$doc")" \
    '["fleetRunId","exitCode","reason","integrationBranch","merged","results","strikes","strikesConsumed","review","tickets","readPolicy","privateTmp","gitSource","mirror","egress","egressAllowlist","homeBinds","writableRoots","warnings"]'
  check "  the integration branch merges the worker branch" eq "$(git -C "$wt" rev-parse fleet/run-fake-1^2)" "$(git -C "$wt" rev-parse fleet/t1)"
  rc=0; doc="$(cd "$wt" && FAKE_FLEET_REASON=flail "$FAKES_DIR/fleet" run --tickets T1 --json)" || rc=$?
  check "  a ticket reason: exit 2, the code in tickets[].reasonCode, strikes carried over" \
    eq "$rc $(jq -c '[.reason, .tickets.T1.reasonCode, .tickets.T1.strikes]' <<<"$doc")" '2 ["flail","flail",2]'
  check "  free text where fleet puts it (tickets[].reason, warnings)" eq "$(jq -r '.tickets.T1.reason == .warnings[0]' <<<"$doc")" true
  rc=0; (cd "$wt" && FAKE_FLEET_REASON=preflight "$FAKES_DIR/fleet" run --tickets T1 --json >/dev/null) || rc=$?
  check "  a run-level reason: exit 1" eq "$rc" 1
  check "  every call logged with its cwd" eq "$(jq -sr 'map(.cwd) | unique | length' "$FAKE_FLEET_LOG")" 1
  rc=0; doc="$(cd "$wt" && FAKE_TAMPERGUARD_VERDICT=tamper "$FAKES_DIR/tamperguard" --range main..fleet/t1 --json)" || rc=$?
  check "fake tamperguard: tamper → exit 2, {verdict, score, findings}" eq "$rc $(jq -c '[.verdict, .score, (.findings | length)]' <<<"$doc")" '2 ["tamper",10,1]'
  rc=0; (cd "$wt" && FAKE_TAMPERGUARD_VERDICT=review "$FAKES_DIR/tamperguard" --range main..fleet/t1 --json >/dev/null) || rc=$?
  check "  review under --fail-on tamper → exit 0" eq "$rc" 0
  rc=0; (cd "$wt" && "$FAKES_DIR/tamperguard" --range main..nowhere --json >/dev/null 2>&1) || rc=$?
  check "  an unresolvable range → exit 1" eq "$rc" 1
  rc=0; (cd "$wt" && "$FAKES_DIR/tamperguard" --version >/dev/null 2>&1) || rc=$?
  check "  no --version (as the real 0.2.0) → exit 2" eq "$rc" 2
  rm -f "$WORLD/m.git/hooks/post-checkout"
  rc=0; doc="$(cd "$wt" && "$FAKES_DIR/fleet" run --tickets T1 "${mp[@]}" --json 2>/dev/null)" || rc=$?
  check "fake fleet: a pristine mirror → the run goes on, the document echoes the plane" \
    eq "$rc $(jq -c '[.readPolicy, .gitSource, .mirror == "'"$WORLD/m.git"'", .egress]' <<<"$doc")" '0 ["bounded","mirror",true,"allowlist"]'
}

shim_world() {  # run_setup + a recording `npx` (the PATH and bwrap fleet sees, then the fake fleet) and `ralon` (its PATH)
  run_setup
  unset FACTORY_FLEET_PIN
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$PATH" >"%s/fleet.path"\n{ command -v bwrap || echo none; } >"%s/fleet.bwrap"\nshift 3\nexec "%s/fleet" "$@"\n' \
    "$WORLD" "$WORLD" "$FAKES_DIR" >"$WORLD/bin/npx"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$PATH" >"%s/ralon.path"\nexec "%s/ralon" "$@"\n' "$WORLD" "$FAKES_DIR" >"$WORLD/bin/ralon"
  chmod +x "$WORLD/bin/npx" "$WORLD/bin/ralon"
  SHIM_DIR="$FACTORY_HOME/run/bwrap-shim/slot-1"
}
case_bwrap_shim() {
  shim_world
  export FACTORY_FLEET="$WORLD/bin/npx -y @adlc/cli@1.12.0 fleet"
  loop --once
  check "pin 1.12.0 (read from @adlc/cli@1.12.0 in the fleet command): the loop ran fleet" eq "$RC $(field .outcome)" "0 built"
  check "  fleet's PATH: the shim directory first, then the node's PATH unchanged" eq "$(command cat "$WORLD/fleet.path")" "$SHIM_DIR:$PATH"
  check "  fleet finds bwrap there: a link to factory/bin/lib/bwrap-shim" \
    eq "$(command cat "$WORLD/fleet.bwrap") $(readlink -f "$SHIM_DIR/bwrap")" "$SHIM_DIR/bwrap $BIN/lib/bwrap-shim"
  check "  the pin beside it is 1.12.0" eq "$(command cat "$SHIM_DIR/fleet-pin")" 1.12.0
  check "  ralon's PATH is the node's (the shim is on fleet's only)" eq "$(command cat "$WORLD/ralon.path")" "$PATH"
  check "  env sets PATH and nothing else" eq "$(jq -c '.[4:6] | .[0], (.[1] | split("=")[0])' "$FAKE_RALON_LOG" | tr '\n' ' ')" '"env" "PATH" '
  check "  the ledger line says the shim was on" eq "$(field .bwrap_shim)" true
  check "  nothing but bwrap and fleet-pin in the shim directory" eq "$(ls "$SHIM_DIR" | tr '\n' ' ')" "bwrap fleet-pin "

  local p
  for p in 1.12.1 1.13.0; do
    shim_world
    mkdir -p "$SHIM_DIR"; ln -s "$BIN/lib/bwrap-shim" "$SHIM_DIR/bwrap"   # left over from a 1.12.0 run
    export FACTORY_FLEET="$WORLD/bin/npx -y @adlc/cli@$p fleet"
    loop --once
    check "pin $p: the loop ran fleet" eq "$RC $(field .outcome)" "0 built"
    check "  fleet's PATH is the node's, no shim" eq "$(command cat "$WORLD/fleet.path")" "$PATH"
    check "  ralon runs fleet directly (no env)" eq "$(jq -r '.[4]' "$FAKE_RALON_LOG")" "$WORLD/bin/npx"
    check "  the stale shim directory is gone" test ! -e "$SHIM_DIR"
    check "  the ledger line says the shim was off" eq "$(field .bwrap_shim)" false
  done

  shim_world
  export FACTORY_FLEET="$FAKES_DIR/fleet" FACTORY_FLEET_PIN=1.12.1
  loop --once
  check "FACTORY_FLEET_PIN 1.12.1 with a fleet command that names no version: no shim" \
    eq "$(field .bwrap_shim) $(jq -r '.[4]' "$FAKE_RALON_LOG")" "false $FAKES_DIR/fleet"
  shim_world
  export FACTORY_FLEET="$FAKES_DIR/fleet"
  loop --once
  check "no pin at all: no shim" eq "$(field .bwrap_shim) $(test -e "$SHIM_DIR" && echo shim)" "false "
}

for c in ${CASES:-success scope-fail rails-fail no-adversarial-review tamper policy-render policy-missing-root policy-render-lib \
                  quota-paused wall-clock resume-in-place resume-cap lock-lost success-handoff lock-lost-before-push \
                  pr-open-once-fails pr-open-twice-fails budget-override strikes-exhausted flail desk-marker \
                  review-unavailable anything-else argv resume lapsed-range no-transcript once governor dry-run guards \
                  fakes bwrap-shim}; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
