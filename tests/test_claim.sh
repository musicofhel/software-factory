#!/usr/bin/env bash
# T1 acceptance: the git-ref claim protocol (claim.sh, heartbeat.sh, release.sh) against the fake
# gh, offline. Cases are named by T1's acceptance criteria, plus fake-gh-semantics for the
# instrument itself.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

T0=1792836000                              # 2026-10-24T10:00:00Z, the pinned clock
H=3600
iso() { jq -nr --argjson e "$1" '$e | todate'; }
POSTREF='.[0] == "api" and index("POST") and index("repos/test/repo/git/refs")'
WRITES='(.[0] == "api" and (index("POST") or index("PATCH") or index("DELETE"))) or (.[0] == "issue" and (.[1] == "edit" or .[1] == "comment"))'

# ---------------------------------------------------------------------------------------------
case_fake_gh_semantics() {
  fakegh_setup
  local tip tree c1 c2 c3 out err rc
  G() { echo >>"$WORLD/calls"; gh "$@"; }   # counts every call, including those inside $(...)
  tip="$(G api repos/test/repo/git/ref/heads/nodes --jq .object.sha)"
  tree="$(G api "repos/test/repo/git/commits/$tip" --jq .tree.sha)"
  c1="$(G api -X POST repos/test/repo/git/commits -f message=one -f tree="$tree" -f "parents[]=$tip" --jq .sha)"
  c2="$(G api -X POST repos/test/repo/git/commits -f message=two -f tree="$tree" -f "parents[]=$c1" --jq .sha)"
  c3="$(G api repos/test/repo/git/commits -f message=three -f tree="$tree" -f "parents[]=$tip" --jq .sha)"
  check "fields without -X are a POST, like gh" eq "$(fakegh_calls '.[1] == "repos/test/repo/git/commits" and (index("-X") | not)')" 1
  check "created commit reads back with message and parent" \
    eq "$(G api "repos/test/repo/git/commits/$c2" | jq -c '[.message, .parents[0].sha]')" "[\"two\",\"$c1\"]"

  G api -X POST repos/test/repo/git/refs -f ref=refs/locks/issue-1 -f sha="$c1" >/dev/null
  check "POST git/refs creates the ref" eq "$(fakegh_ref refs/locks/issue-1)" "$c1"
  rc=0; out="$(G api -X POST repos/test/repo/git/refs -f ref=refs/locks/issue-1 -f sha="$c2" 2>"$WORLD/err")" || rc=$?
  err="$(command cat "$WORLD/err")"
  check "duplicate POST git/refs exits 1" eq "$rc" 1
  check "duplicate POST git/refs is HTTP 422 on stderr" eq "$err" "gh: Reference already exists (HTTP 422)"
  check "duplicate POST git/refs prints the error body" eq "$(jq -r .status <<<"$out")" 422
  check "duplicate POST leaves the ref alone" eq "$(fakegh_ref refs/locks/issue-1)" "$c1"
  rc=0; G api -X POST repos/test/repo/git/refs -f ref=refs/locks/issue-2 -f sha=deadbeef >/dev/null 2>&1 || rc=$?
  check "POST git/refs to a missing object is refused" eq "$rc:$(fakegh_ref refs/locks/issue-2)" "1:"

  rc=0; G api -X PATCH repos/test/repo/git/refs/locks/issue-1 -f sha="$c3" >/dev/null 2>&1 || rc=$?
  check "PATCH without force refuses a non-fast-forward" eq "$rc:$(fakegh_ref refs/locks/issue-1)" "1:$c1"
  G api -X PATCH repos/test/repo/git/refs/locks/issue-1 -f sha="$c2" >/dev/null
  check "PATCH without force takes a fast-forward" eq "$(fakegh_ref refs/locks/issue-1)" "$c2"
  G api -X PATCH repos/test/repo/git/refs/locks/issue-1 -f sha="$c3" -F force=true >/dev/null
  check "PATCH with force=true changes the sha" eq "$(fakegh_ref refs/locks/issue-1)" "$c3"
  rc=0; G api -X PATCH repos/test/repo/git/refs/locks/issue-9 -f sha="$c3" -F force=true >/dev/null 2>&1 || rc=$?
  check "PATCH of a missing ref is refused, not created" eq "$rc:$(fakegh_ref refs/locks/issue-9)" "1:"

  G api -X POST repos/test/repo/git/refs -f ref=refs/locks/issue-10 -f sha="$c1" >/dev/null
  check "matching-refs is a string prefix, like GitHub (issue-1 matches issue-10)" \
    eq "$(G api repos/test/repo/git/matching-refs/locks/issue-1 | jq -c '[.[].ref]')" '["refs/locks/issue-1","refs/locks/issue-10"]'
  check "matching-refs of nothing is []" eq "$(G api repos/test/repo/git/matching-refs/locks/issue-7)" "[]"
  rc=0; G api repos/test/repo/git/ref/locks/issue-7 >/dev/null 2>"$WORLD/err" || rc=$?
  check "GET git/ref of a missing ref is 404" eq "$rc:$(command cat "$WORLD/err")" "1:gh: Not Found (HTTP 404)"

  G api -X DELETE repos/test/repo/git/refs/locks/issue-1 >/dev/null
  check "DELETE removes the ref" eq "$(fakegh_ref refs/locks/issue-1)" ""
  rc=0; G api -X DELETE repos/test/repo/git/refs/locks/issue-1 >/dev/null 2>&1 || rc=$?
  check "DELETE of a missing ref is 422" eq "$rc" 1
  rc=0; G api repos/other/repo/git/matching-refs/locks/ >/dev/null 2>&1 || rc=$?
  check "another repo is 404" eq "$rc" 1

  # The CAS is real: eight concurrent creators of one ref, exactly one wins.
  local i wins=0
  for i in 1 2 3 4 5 6 7 8; do
    ( G api -X POST repos/test/repo/git/refs -f ref=refs/locks/issue-50 -f sha="$c1" >/dev/null 2>&1 && echo win ) >"$WORLD/race.$i" &
  done
  wait
  for i in 1 2 3 4 5 6 7 8; do [ -s "$WORLD/race.$i" ] && wins=$((wins + 1)); done
  check "8 concurrent POSTs of one ref: exactly one wins" eq "$wins" 1

  for i in $(seq 1 35); do fakegh_issue "$i" "$((T0 - 100 * H + i * 60))" "ready,w:light"; done
  fakegh_issue 99 "$((T0 - 200 * H))" "w:light"
  check "issue list defaults to 30, newest first" \
    eq "$(G issue list --repo test/repo --label ready --json number | jq -c '[length, .[0].number]')" "[30,35]"
  check "issue list --label is AND, --limit honoured" \
    eq "$(G issue list --repo test/repo --label ready --label w:light --limit 100 --json number | jq length)" 35
  check "issue list projects only --json fields" \
    eq "$(G issue list --repo test/repo --label w:light --limit 100 --json number | jq -c '.[0] | keys')" '["number"]'
  rc=0; G issue list --label ready --json number >/dev/null 2>&1 || rc=$?
  check "issue commands without --repo fail (never infer a remote)" eq "$rc" 1
  G issue edit 3 --repo test/repo --add-assignee @me --add-label in-progress >/dev/null
  check "issue edit: @me is FAKE_GH_USER, label added" \
    eq "$(jq -c '.issues[] | select(.number == 3) | [.assignees[].login, (.labels | map(.name) | sort)]' "$FAKE_GH_ISSUES")" \
       '["fake-user",["in-progress","ready","w:light"]]'
  rc=0; G issue edit 3 --repo test/repo --add-label no-such-label >/dev/null 2>&1 || rc=$?
  check "issue edit with a label the repo lacks fails" eq "$rc" 1
  G issue comment 3 --repo test/repo --body hello >/dev/null
  check "issue comment appends one comment" eq "$(jq -c '[.issues[] | select(.number == 3) | .comments[].body]' "$FAKE_GH_ISSUES")" '["hello"]'
  rc=0; FAKE_GH_FAIL='matching-refs' G api repos/test/repo/git/matching-refs/locks/ >/dev/null 2>"$WORLD/err" || rc=$?
  check "FAKE_GH_FAIL injects an HTTP 500" eq "$rc:$(command cat "$WORLD/err")" "1:gh: Server Error (injected) (HTTP 500)"

  check "every call is in the log, one JSON argv per line" eq "$(wc -l <"$FAKE_GH_LOG" | tr -d ' ')" "$(wc -l <"$WORLD/calls" | tr -d ' ')"
  check "the log keeps argv intact" eq "$(fakegh_calls '. == ["issue","comment","3","--repo","test/repo","--body","hello"]')" 1
}

# ---------------------------------------------------------------------------------------------
case_skips_locked() {
  fakegh_setup
  fakegh_issue 9 "$((T0 - 300 * H))" "ready,w:light" "closed one"
  jq '(.issues[] | select(.number == 9)).state = "closed"' "$FAKE_GH_ISSUES" >"$WORLD/i" && mv "$WORLD/i" "$FAKE_GH_ISSUES"
  fakegh_issue 1 "$((T0 - 240 * H))" "ready,w:light" "oldest, locked by beta"
  fakegh_issue 8 "$((T0 - 216 * H))" "ready,w:light" "older than 3 despite its number"
  fakegh_issue 2 "$((T0 - 192 * H))" "ready,w:heavy"
  fakegh_issue 3 "$((T0 - 168 * H))" "ready,w:light"
  fakegh_issue 4 "$((T0 - 144 * H))" "w:light" "not ready"
  fakegh_issue 6 "$((T0 - 120 * H))" "ready" "no weight"
  fakegh_issue 7 "$((T0 - 96 * H))" "ready,w:light,w:heavy" "two weights"
  fakegh_issue 10 "$((T0 - 72 * H))" "ready,w:huge" "unknown weight"
  fakegh_issue 5 "$((T0 - 24 * H))" "ready,w:light"
  local i
  for i in $(seq 100 139); do fakegh_issue "$i" "$((T0 - H + i))" "ready,w:light"; done   # 40 newer ones
  fakegh_lock 1 beta "$((T0 - H))"
  local before; before="$(git -C "$FAKE_GH_GIT" for-each-ref)"

  local out
  out="$("$BIN/claim.sh" --json)"
  check "light node: oldest first, locked and non-claimable skipped" \
    eq "$(jq -c '[.candidates[].number][:3]' <<<"$out")" '[8,3,5]'
  check "all 43 claimable light Issues listed despite gh's 30 default" eq "$(jq '.candidates | length' <<<"$out")" 43
  check "the locked Issue is reported as locked" eq "$(jq -c .locked <<<"$out")" '[1]'
  check "dry run is the default and claims nothing" eq "$(jq -c '[.mode, .claimed, .attempts]' <<<"$out")" '["dry-run",null,[]]'
  out="$("$BIN/claim.sh" --json --capacity heavy)"
  check "heavy node also takes w:heavy, still oldest first" eq "$(jq -c '[.candidates[].number][:4]' <<<"$out")" '[8,2,3,5]'
  out="$("$BIN/claim.sh")"
  check "text mode names the first unlocked Issue" eq "$(tail -n1 <<<"$out")" "would claim #8 (first unlocked; --apply to claim)"
  check "listing wrote nothing through gh" eq "$(fakegh_calls "$WRITES")" 0
  check "listing left every ref as it was" eq "$(git -C "$FAKE_GH_GIT" for-each-ref)" "$before"
  local rc=0; "$BIN/claim.sh" --capacity medium >/dev/null 2>&1 || rc=$?
  check "an unknown capacity is a usage error (exit 1)" eq "$rc" 1
}

# ---------------------------------------------------------------------------------------------
case_cas_422_moves_on() {
  fakegh_setup
  export FACTORY_NOW=$T0
  fakegh_issue 3 "$((T0 - 30 * H))" "ready,w:light"
  fakegh_issue 5 "$((T0 - 20 * H))" "ready,w:light"
  fakegh_issue 7 "$((T0 - 10 * H))" "ready,w:light"
  local out rc=0
  out="$(FAKE_GH_RACE_REFS=refs/locks/issue-3 FAKE_GH_FAIL='git/refs -f ref=refs/locks/issue-5 ' \
           "$BIN/claim.sh" --apply --json --handle alpha --slots 2 --run-id run-1)" || rc=$?
  check "claim exits 0" eq "$rc" 0
  check "422 on #3 and an error on #5 move on to #7" \
    eq "$(jq -c '[.attempts[] | [.issue, .result]]' <<<"$out")" '[[3,"conflict"],[5,"error"],[7,"claimed"]]'
  check "claimed #7" eq "$(jq .claimed <<<"$out")" 7
  check "no retry: one POST git/refs per Issue" \
    eq "$(jq -c "select($POSTREF) | .[] | select(startswith(\"ref=\"))" "$FAKE_GH_LOG" | tr '\n' ' ')" \
       '"ref=refs/locks/issue-3" "ref=refs/locks/issue-5" "ref=refs/locks/issue-7" '
  check "the racer keeps #3's lock" \
    eq "$(git -C "$FAKE_GH_GIT" log -1 --format=%B refs/locks/issue-3 | sed '1,2d' | jq -r .handle)" racer
  check "no lock on #5" eq "$(fakegh_ref refs/locks/issue-5)" ""
  check "#7's lock is alpha's" eq "$(git -C "$FAKE_GH_GIT" log -1 --format=%B refs/locks/issue-7 | sed '1,2d' | jq -r .handle)" alpha
  check "the lock commit sits on the nodes tip" \
    eq "$(git -C "$FAKE_GH_GIT" rev-parse refs/locks/issue-7^)" "$(fakegh_ref refs/heads/nodes)"
  check "lost Issues get no edit and no comment" \
    eq "$(fakegh_calls '.[0] == "issue" and (.[1] == "edit" or .[1] == "comment") and .[2] != "7"')" 0

  rc=0; out="$(FAKE_GH_FAIL='git/refs -f ref=' "$BIN/claim.sh" --apply --json --handle alpha --slots 2)" || rc=$?
  check "every attempt erroring (not 422) is exit 1, nothing claimed" eq "$rc:$(jq .claimed <<<"$out")" "1:null"

  # Real concurrency: four nodes race for one Issue. Exactly one lock, one winner, one comment.
  fakegh_setup
  fakegh_issue 1 "$((T0 - H))" "ready,w:light"
  local h
  for h in n1 n2 n3 n4; do
    "$BIN/claim.sh" --apply --json --handle "$h" --slots 1 >"$WORLD/$h.json" 2>/dev/null &
  done
  wait
  check "four racing nodes: exactly one claimed #1" \
    eq "$(jq -s '[.[] | select(.claimed == 1)] | length' "$WORLD"/n?.json)" 1
  check "the lock names the winner" \
    eq "$(git -C "$FAKE_GH_GIT" log -1 --format=%B refs/locks/issue-1 | sed '1,2d' | jq -r .handle)" \
       "$(jq -sr '.[] | select(.claimed == 1) | .handle' "$WORLD"/n?.json)"
  check "losers saw a 422 or the lock, never a second claim" \
    eq "$(jq -s '[.[] | select(.claimed == null) | .attempts[] | select(.result != "conflict")] | length' "$WORLD"/n?.json)" 0
  check "exactly one comment on the raced Issue" eq "$(jq '.issues[0].comments | length' "$FAKE_GH_ISSUES")" 1
}

# ---------------------------------------------------------------------------------------------
case_one_comment() {
  fakegh_setup
  export FACTORY_NOW=$T0 FAKE_GH_NOW=$T0
  fakegh_issue 4 "$((T0 - 5 * H))" "ready,w:heavy,tier:1"
  local rc=0
  "$BIN/claim.sh" --apply --handle alpha --capacity heavy >/dev/null 2>&1 || rc=$?
  check "--apply without slots is a usage error and writes nothing" eq "$rc:$(fakegh_calls "$WRITES")" "1:0"
  local manifest="$WORLD/alpha.json" out minutes finish
  jq '.handle = "alpha" | .slots = 3' "$REPO_ROOT/factory/nodes/example.json" >"$manifest"
  out="$("$BIN/claim.sh" --apply --json --manifest "$manifest" --run-id run-42 --capacity heavy)"
  minutes="$(jq '.weights.heavy.wallClockMinutes' "$REPO_ROOT/factory/policy/budget.json")"
  finish="$(iso "$((T0 + minutes * 60))")"
  check "claimed #4 with the manifest's handle and slots" eq "$(jq -c '[.claimed, .handle, .slots, .announced]' <<<"$out")" '[4,"alpha",3,true]'
  check "expected finish = claimed_at + the weight's wall clock (budget.json)" eq "$(jq -r .expected_finish <<<"$out")" "$finish"
  check "exactly one issue edit, with exactly the spec's arguments" \
    eq "$(jq -c 'select(.[0] == "issue" and .[1] == "edit")' "$FAKE_GH_LOG")" \
       '["issue","edit","4","--repo","test/repo","--add-assignee","@me","--add-label","in-progress"]'
  check "exactly one comment call" eq "$(fakegh_calls '.[0] == "issue" and .[1] == "comment"')" 1
  check "assigned to @me, in-progress added, no label removed" \
    eq "$(jq -c '.issues[0] | [[.assignees[].login], (.labels | map(.name) | sort)]' "$FAKE_GH_ISSUES")" \
       '[["fake-user"],["in-progress","ready","tier:1","w:heavy"]]'
  local body; body="$(jq -r '.issues[0].comments[0].body' "$FAKE_GH_ISSUES")"
  check "comment names the handle" grep -q '`alpha`' <<<"$body"
  check "comment names the fleet run id" grep -q '`run-42`' <<<"$body"
  check "comment names the slot count" grep -q '3 slot(s)' <<<"$body"
  check "comment names the expected finish" grep -qF "expected finish $finish" <<<"$body"
  FACTORY_HANDLE=alpha "$BIN/heartbeat.sh" 4 --apply >/dev/null
  FACTORY_HANDLE=alpha "$BIN/release.sh" 4 --apply >/dev/null
  check "heartbeat and release add no comment: still exactly one" eq "$(jq '.issues[0].comments | length' "$FAKE_GH_ISSUES")" 1
}

# ---------------------------------------------------------------------------------------------
case_heartbeat_and_stale() {
  fakegh_setup
  fakegh_issue 1 "$((T0 - 30 * H))" "ready,w:light"
  FACTORY_NOW=$((T0 - 25 * H)) FAKE_GH_NOW=$((T0 - 25 * H)) \
    "$BIN/claim.sh" --apply --handle alpha --slots 2 --run-id run-7 >/dev/null
  export FACTORY_NOW=$T0
  local st old new
  st="$("$BIN/claim.sh" --check 1 --json)"
  check "a 25 h old lock is stale" eq "$(jq -c '[.state, .age_seconds, .handle]' <<<"$st")" "[\"stale\",$((25 * H)),\"alpha\"]"
  fakegh_lock 2 beta "$((T0 - 24 * H))"
  fakegh_lock 3 beta "$((T0 - 24 * H - 1))"
  check "exactly 24 h is not yet older than 24 h: fresh" eq "$("$BIN/claim.sh" --check 2 --json | jq -r .state)" fresh
  check "24 h and one second is stale" eq "$("$BIN/claim.sh" --check 3 --json | jq -r .state)" stale
  check "no lock reads absent" eq "$("$BIN/claim.sh" --check 4 --json | jq -r .state)" absent
  check "--check text mode" eq "$("$BIN/claim.sh" --check 4)" "issue #4: absent"

  old="$(fakegh_ref refs/locks/issue-1)"
  FACTORY_HANDLE=alpha "$BIN/heartbeat.sh" 1 >/dev/null
  check "heartbeat without --apply changes nothing" eq "$(fakegh_ref refs/locks/issue-1):$(fakegh_calls 'index("PATCH")')" "$old:0"
  FAKE_GH_NOW=$T0 FACTORY_HANDLE=alpha "$BIN/heartbeat.sh" 1 --apply >/dev/null
  new="$(fakegh_ref refs/locks/issue-1)"
  check "heartbeat moves the ref to a new commit" test "$new" != "$old"
  check "the update is one PATCH with force=true" \
    eq "$(jq -c 'select(index("PATCH")) | .[-4:]' "$FAKE_GH_LOG")" "[\"-f\",\"sha=$new\",\"-F\",\"force=true\"]"
  check "the new commit sits on the nodes tip" eq "$(git -C "$FAKE_GH_GIT" rev-parse "$new^")" "$(fakegh_ref refs/heads/nodes)"
  check "payload keeps handle, run_id, slots and freshens claimed_at" \
    eq "$(git -C "$FAKE_GH_GIT" log -1 --format=%B "$new" | sed '1,2d' | jq -c '[.handle, .run_id, .slots, .claimed_at]')" \
       "[\"alpha\",\"run-7\",2,\"$(iso "$T0")\"]"
  check "after the heartbeat the lock is fresh" eq "$("$BIN/claim.sh" --check 1 --json | jq -c '[.state, .age_seconds]')" '["fresh",0]'

  local rc=0
  FACTORY_HANDLE=beta "$BIN/heartbeat.sh" 1 --apply >/dev/null 2>&1 || rc=$?
  check "another node's heartbeat is refused (exit 2) and the ref is untouched" eq "$rc:$(fakegh_ref refs/locks/issue-1)" "2:$new"
  rc=0; FACTORY_HANDLE=alpha "$BIN/heartbeat.sh" 4 --apply >/dev/null 2>&1 || rc=$?
  check "heartbeat of a lost lock is exit 2 and does not re-create it" eq "$rc:$(fakegh_ref refs/locks/issue-4)" "2:"
}

# ---------------------------------------------------------------------------------------------
case_never_delete_foreign_lock() {
  fakegh_setup
  export FACTORY_NOW=$T0
  fakegh_lock 5 beta "$((T0 - 48 * H))"
  local foreign rc=0 out
  foreign="$(fakegh_ref refs/locks/issue-5)"
  "$BIN/release.sh" 5 --apply --handle alpha >/dev/null 2>"$WORLD/err" || rc=$?
  check "releasing beta's (stale) lock as alpha is exit 2" eq "$rc" 2
  check "the refusal names the holder" grep -q "held by 'beta'" "$WORLD/err"
  check "beta's lock is still there" eq "$(fakegh_ref refs/locks/issue-5)" "$foreign"
  check "no DELETE was sent" eq "$(fakegh_calls 'index("DELETE")')" 0

  local tip junk
  tip="$(fakegh_ref refs/heads/nodes)"
  junk="$(printf 'not a lock' | git -C "$FAKE_GH_GIT" commit-tree "$tip^{tree}" -p "$tip")"
  git -C "$FAKE_GH_GIT" update-ref refs/locks/issue-8 "$junk"
  rc=0; "$BIN/release.sh" 8 --apply --handle alpha >/dev/null 2>&1 || rc=$?
  check "a lock with no readable holder is refused too" eq "$rc:$(fakegh_ref refs/locks/issue-8)" "2:$junk"

  fakegh_issue 6 "$((T0 - H))" "ready,w:light"
  "$BIN/claim.sh" --apply --handle alpha --slots 1 >/dev/null
  "$BIN/release.sh" 6 --handle alpha >/dev/null
  check "release without --apply keeps the lock" test -n "$(fakegh_ref refs/locks/issue-6)"
  out="$("$BIN/release.sh" 6 --apply --json --handle alpha)"
  check "release of its own lock deletes it" eq "$(jq -r .result <<<"$out"):$(fakegh_ref refs/locks/issue-6)" "released:"
  check "exactly one DELETE, for its own ref" \
    eq "$(jq -c 'select(index("DELETE"))' "$FAKE_GH_LOG")" '["api","-X","DELETE","repos/test/repo/git/refs/locks/issue-6"]'
  rc=0; out="$("$BIN/release.sh" 6 --apply --json --handle alpha)" || rc=$?
  check "releasing an absent lock is exit 0 and sends nothing" eq "$rc:$(jq -r .result <<<"$out"):$(fakegh_calls 'index("DELETE")')" "0:absent:1"
}

echo "test_claim"
for c in fake-gh-semantics skips-locked cas-422-moves-on one-comment heartbeat-and-stale never-delete-foreign-lock; do
  run_case "$c"
done
exit "$FAILED"
