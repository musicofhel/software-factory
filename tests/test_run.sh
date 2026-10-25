#!/usr/bin/env bash
# T9: the run loop (factory/bin/run.sh, factory/bin/lib/run.sh). Offline: a fixture origin from
# tests/fixtures/make-repo.sh that is both the clone's `origin` and the fake gh's git store, the
# node's clone, the fake gh (+ a `pr create` shim), the fake adlc (ralon-lock.sh's ticket store),
# cux, ralon, vetto, tamperguard and fleet (tests/fakes/), a fake `claude` for version-check, and a
# recording `sleep`. The clock is FACTORY_NOW.
# Acceptance 1 (one case per fleet reason: success, scope-stub, tamper, quota-paused, wall-clock,
# strikes-exhausted, flail, review-unavailable, anything-else), 2 argv, 3 resume, 4 no-transcript,
# 5 once, 6 scope-stub; plus the paused claim's resume in place, the resume cap, a lost lock, the
# governor's verdicts, the dry run, slot guards and the fakes themselves.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
RUN="$BIN/run.sh"
iso() { jq -nr --argjson e "$1" '$e | todate'; }
T0="$(jq -nr '"2026-10-25T12:00:00Z" | fromdateiso8601')"
MARK=PLANTED-PROMPT-TEXT-5e1f   # planted in the ticket, the Issue, fleet's transcript and tamperguard's findings

run_setup() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TZ=UTC
  export GIT_AUTHOR_NAME=node GIT_AUTHOR_EMAIL=node@fake GIT_COMMITTER_NAME=node GIT_COMMITTER_EMAIL=node@fake
  rm -rf "$FAKE_GH_GIT"
  printf '%s\n' 'main-file factory/policy/adapters.json {"claude-code": "2.1.280", "codex": null}' \
    "node dev-box $((T0 - 7200)) active 2 dev-box" | tests/fixtures/make-repo.sh "$FAKE_GH_GIT"
  git clone -q "$FAKE_GH_GIT" "$WORLD/clone"
  export FACTORY_NOW="$T0" FAKE_GH_NOW="$T0" FACTORY_HOME="$WORLD/fh" FACTORY_MANIFEST="$WORLD/manifest.json"
  export FAKE_CUX_USAGE="$WORLD/usage.json" FAKE_CUX_LOG="$WORLD/cux.log" FAKE_FLEET_LOG="$WORLD/fleet.log"
  export FAKE_RALON_LOG="$WORLD/ralon.log" FAKE_VETTO_LOG="$WORLD/vetto.log" FAKE_TAMPERGUARD_LOG="$WORLD/tg.log"
  export FACTORY_ADLC="$FAKES_DIR/adlc" FACTORY_FLEET="$FAKES_DIR/fleet" FACTORY_SLEEP="$WORLD/bin/nap"
  export FAKE_FLEET_TRANSCRIPT="worker said: $MARK" FAKE_TAMPERGUARD_DETAIL="assert True  # $MARK"
  export FAKE_ADLC_TICKETS='[{"id": "T-run", "title": "add hello.sh", "body": "Build hello.sh. '"$MARK"'", "rails": ["tests/rail/**"]}]'
  unset FACTORY_SCOPE_CHECK FAKE_FLEET_REASON FAKE_FLEET_REASONS FAKE_TAMPERGUARD_VERDICT FAKE_FLEET_STRIKES FAKE_CLAUDE_VERSION
  : >"$FAKE_CUX_LOG"; : >"$FAKE_FLEET_LOG"; : >"$FAKE_RALON_LOG"; : >"$FAKE_VETTO_LOG"; : >"$FAKE_TAMPERGUARD_LOG"
  mkdir -p "$WORLD/bin" "$WORLD/prs"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo "${FAKE_CLAUDE_VERSION:-2.1.280} (Claude Code)"\n' >"$WORLD/bin/claude"
  printf '#!/usr/bin/env bash\necho "$1" >>"%s/naps"\n' "$WORLD" >"$WORLD/bin/nap"
  # gh pr create is not in the fake gh: a shim records it (the body in prs/<n>.md) and opens the PR
  # in the fake's store; everything else goes to tests/fakes/gh.
  command cat >"$WORLD/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-} \${2:-}" = "pr create" ]; then
  for a in "\$@"; do jq -n --arg a "\$a" '\$a'; done | jq -sc . >>"\$FAKE_GH_LOG"
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
  chmod +x "$WORLD/bin/claude" "$WORLD/bin/nap" "$WORLD/bin/gh"
  export PATH="$WORLD/bin:$PATH"
  jq -n --arg seen "$(iso $((T0 - 600)))" '
    {handle: "dev-box", owner: "dev-box", os: "linux", cpu: 8, ram_gb: 16, slots: 2, heavy_gates: false,
     adapters: {"claude-code": "2.1.280"}, quota_tier: "pro", quota_cap: 0.4,
     quiet_hours: {tz: "UTC", start: "00:00", end: "00:00"}, accounts: 1, factory_version: "0.1.0",
     last_seen: $seen, status: "active"}' >"$FACTORY_MANIFEST"
  under_cap
  fakegh_issue 1 $((T0 - 86400)) ready,w:light "T-run: add hello.sh" \
    "$(printf '<!-- mirrored by factory/bin/mirror.sh -->\nTicket: T-run\n\nBuild hello.sh. %s\n' "$MARK")"
  WT="$WORLD/clone/.worktrees/T-run"
}
under_cap() {
  printf '{"a@example.invalid": {"polled_at": "%s", "five_hour": {"utilization": 10, "resets_at": "%s"}, "seven_day": {"utilization": 20, "resets_at": "%s"}}}\n' \
    "$(iso $((FACTORY_NOW - 60)))" "$(iso $((FACTORY_NOW + 3600)))" "$(iso $((FACTORY_NOW + 86400)))" >"$FAKE_CUX_USAGE"
}
passing_scope() {  # a built scope-check that passes (step 3's real one will replace the stub)
  printf '#!/usr/bin/env bash\necho "$*" >>"%s/scope.log"\nexit 0\n' "$WORLD" >"$WORLD/bin/scope-pass"
  chmod +x "$WORLD/bin/scope-pass"
  export FACTORY_SCOPE_CHECK="$WORLD/bin/scope-pass"
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
no_mark() { ! grep -rqF "$MARK" "$@"; }

case_success() {
  run_setup
  passing_scope
  loop --once
  check "fleet success, both gates pass: exit 0" eq "$RC" 0
  check "  outcome built" eq "$(field .outcome)" built
  check "  pushed ticket/T-run/dev-box" eq "$(field .pushed.branch)" ticket/T-run/dev-box
  check "  the pushed tip is on the origin" eq "$(pushed)" "$(field .pushed.sha)"
  check "  the tip is a record commit on top of fleet's integration merge" \
    eq "$(git -C "$FAKE_GH_GIT" log -1 --format=%s "$(pushed)^")" "Merge branch 'fleet/t-run' into fleet/run-fake-1"
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
  check "  the lock stays (released at merge)" test -n "$(lock)"
  check "  the worktree is gone" test ! -e "$WT"
  check "  fleet's local branches are gone" eq "$(git -C "$WORLD/clone" for-each-ref --format=x refs/heads/fleet | wc -l | tr -d ' ')" 0
  check "  no slot state left" test ! -e "$FACTORY_HOME/run/slot-1.json"
  check "  the ledger has the same line" eq "$(tail -n1 "$FACTORY_HOME/run/ledger.jsonl")" "$LAST"
  check "  scope-check got the ticket and the range" grep -qE '^--ticket T-run --base [0-9a-f]{40} --head [0-9a-f]{40}$' "$WORLD/scope.log"
  check "  no nap under --once" test ! -e "$WORLD/naps"
}

case_scope_stub() {
  run_setup
  loop --once
  check "scope-check is step 3's stub (exit 2, 'not built'): exit 2, the slot stops" eq "$RC" 2
  check "  the record says scope-check not built" eq "$(field .scope_check)" "scope-check not built"
  check "  reason scope-check-not-built, outcome held" eq "$(field '"\(.reason) \(.outcome)"')" "scope-check-not-built held"
  check "  nothing pushed to the origin" eq "$(git -C "$FAKE_GH_GIT" for-each-ref --format=x refs/heads/ticket | wc -l | tr -d ' ')" 0
  check "  no PR" eq "$(jq '.pulls // [] | length' "$FAKE_GH_ISSUES")" 0
  check "  the work is kept on a LOCAL ticket branch at fleet's integration merge" \
    eq "$(git -C "$WORLD/clone" log -1 --format=%s ticket/T-run/dev-box)" "Merge branch 'fleet/t-run' into fleet/run-fake-1"
  check "  tamperguard ran first (ok)" eq "$(field .tamperguard.verdict)" ok
  check "  the lock is released" test -z "$(lock)"
  check "  the comment gives the reason code" grep -qF '`scope-check-not-built`' <<<"$(last_comment)"
  check "  no needs-desk label" eq "$(labels)" in-progress,ready,w:light
  check "  the worktree is gone" test ! -e "$WT"
}

case_tamper() {
  run_setup
  passing_scope
  export FAKE_TAMPERGUARD_VERDICT=tamper
  loop --once
  check "tamperguard says tamper: exit 0, the loop goes on" eq "$RC" 0
  check "  outcome desk, reason tamper" eq "$(field '"\(.outcome) \(.reason)"')" "desk tamper"
  check "  verdict, score and finding count only" eq "$(jq -c .tamperguard <<<"$LAST")" '{"verdict":"tamper","score":10,"findings":1}'
  check "  scope-check never ran" test ! -e "$WORLD/scope.log"
  check "  nothing pushed" test -z "$(pushed)"
  check "  labeled needs-desk" eq "$(labels)" in-progress,needs-desk,ready,w:light
  check "  the lock is released" test -z "$(lock)"
  check "  the comment says nothing was pushed" grep -qF 'Nothing pushed.' <<<"$(last_comment)"
  jq -r '.issues[].comments[].body' "$FAKE_GH_ISSUES" >"$WORLD/comments.txt"; printf '%s\n' "$OUT" >"$WORLD/stdout.txt"
  check "  no finding text left the node (comments, ledger, stdout)" \
    no_mark "$WORLD/comments.txt" "$FACTORY_HOME/run/ledger.jsonl" "$WORLD/stdout.txt"
  export FAKE_TAMPERGUARD_VERDICT=error
  run_setup; passing_scope; export FAKE_TAMPERGUARD_VERDICT=error
  loop --once
  check "tamperguard itself fails: exit 1 (no false green), nothing pushed" eq "$RC:$(field .reason):$(pushed)" 1:tamperguard-error:
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
  passing_scope
  export FAKE_FLEET_REASONS="quota-paused success"
  loop --once
  local first lock0
  first="$(jq -c '.argv' "$FAKE_FLEET_LOG")"
  lock0="$(lock)"
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
  check "  the push is a fast-forward of the partial branch" \
    git -C "$FAKE_GH_GIT" merge-base --is-ancestor "$(git -C "$FAKE_GH_GIT" rev-parse "$(pushed)^^2^")" "$(pushed)"
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
    eq "$(labels) $(lock) $([ -e "$WT" ] && echo kept || echo gone)" "in-progress,needs-desk,ready,w:light  gone"
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

desk_case() {
  run_setup
  export FAKE_FLEET_REASON="$1"
  loop --once
  check "$1: exit 0, the loop goes on" eq "$RC" 0
  check "  outcome desk" eq "$(field '"\(.outcome) \(.reason)"')" "desk $1"
  check "  the branch is pushed with the reason" eq "$(trailer "$(pushed)" Fleet-Reason)" "$1"
  check "  labeled needs-desk" eq "$(labels)" in-progress,needs-desk,ready,w:light
  check "  the lock is released" test -z "$(lock)"
  check "  the comment: reason, strikes, branch" grep -qE "reason \`$1\`, strikes 1 of 2, .*Branch \`ticket/T-run/dev-box\`" <<<"$(last_comment)"
  check "  the worktree is gone, no slot state" eq "$([ -e "$WT" ] && echo kept)$([ -e "$FACTORY_HOME/run/slot-1.json" ] && echo state)" ""
  check "  no nap after it" eq "$(field .sleep_seconds)" 0
}
case_strikes_exhausted() { desk_case strikes-exhausted; }
case_flail() { desk_case flail; }

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
  passing_scope
  # a ralon shim keeps a copy of the lock ralon reads (the worktree is gone after the iteration)
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "run -C" ] && command cp "$3/agent.lock" "%s/seen.lock"\nexec "%s/ralon" "$@"\n' \
    "$WORLD" "$FAKES_DIR" >"$WORLD/bin/ralon"
  chmod +x "$WORLD/bin/ralon"
  loop --once
  local wt ps
  wt="$(cd "$WORLD/clone" && pwd -P)/.worktrees/T-run"
  check "ralon: run -C <worktree> -- <fleet> run …" \
    eq "$(jq -c '.[0:5]' "$FAKE_RALON_LOG")" "$(jq -cn --arg wt "$wt" --arg f "$FAKES_DIR/fleet" '["run", "-C", $wt, "--", $f]')"
  check "  the rest of ralon's argv is fleet's" eq "$(jq -c '.[5:]' "$FAKE_RALON_LOG")" "$(jq -c .argv "$FAKE_FLEET_LOG")"
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
  check "vetto wraps the loop's own tamperguard step with build.toml" \
    eq "$(jq -c '.[0:7]' "$FAKE_VETTO_LOG")" "$(jq -cn --arg p "$REPO_ROOT/factory/policy/build.toml" '["--profile", "strict", "--policy", $p, "--tui", "none", "--"]')"
  check "  and never wraps fleet" eq "$(jq -s 'map(select(any(.[]; test("fleet")))) | length' "$FAKE_VETTO_LOG")" 0
  check "tamperguard: --range <base>..<integration tip> --json" \
    eq "$(jq -c '.' "$FAKE_TAMPERGUARD_LOG")" "$(jq -cn --arg r "$(field .base.sha)..$(git -C "$FAKE_GH_GIT" rev-parse "$(pushed)^")" '["--range", $r, "--json"]')"
  check "the rails lock was rendered from the ticket (ralon-lock.sh → adlc ticket show)" \
    eq "$(jq -sc 'map(select(.[0:2] == ["ticket", "show"]))' "$FAKE_ADLC_LOG")" '[["ticket","show","T-run","--json"]]'
  check "  ralon found <worktree>/agent.lock with the ticket's rail" grep -qxE '[[:space:]]+- "?tests/rail/\*\*"?' "$WORLD/seen.lock"
}

case_resume() {
  run_setup
  # another node's lapsed claim left ticket/T-run/old-node: one commit of work and a record commit
  local main work rec
  main="$(git -C "$FAKE_GH_GIT" rev-parse main)"
  work="$(printf 'half done\n' | git -C "$FAKE_GH_GIT" hash-object -w --stdin)"
  work="$(printf '100644 blob %s\thalf.txt\n' "$work" | git -C "$FAKE_GH_GIT" mktree)"
  work="$(GIT_COMMITTER_DATE="$((T0 - 200000)) +0000" git -C "$FAKE_GH_GIT" commit-tree "$work" -p "$main" -m "feat(T-run): fleet worker build")"
  rec="$(GIT_COMMITTER_DATE="$((T0 - 190000)) +0000" git -C "$FAKE_GH_GIT" commit-tree "$work^{tree}" -p "$work" \
          -m "$(printf 'factory: T-run flail on old-node\n\nFactory-Outcome: flail\nFleet-Reason: flail\nFleet-Strikes: 2\nTicket: T-run\nNode: old-node\n')")"
  git -C "$FAKE_GH_GIT" update-ref refs/heads/ticket/T-run/old-node "$rec"
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

case_no_transcript() {
  run_setup; passing_scope
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
  run_setup; passing_scope; export FAKE_TAMPERGUARD_VERDICT=tamper
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
  passing_scope
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
  passing_scope
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

for c in ${CASES:-success scope-stub tamper quota-paused wall-clock resume-in-place resume-cap lock-lost \
                  strikes-exhausted flail review-unavailable anything-else argv resume no-transcript once \
                  governor dry-run guards fakes}; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
