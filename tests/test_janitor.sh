#!/usr/bin/env bash
# T3 acceptance 1-6: factory/bin/janitor.sh against a fixture origin built by
# tests/fixtures/make-repo.sh (main, nodes, flaky-history, lock refs and ticket/** branches of
# chosen ages) and the fake gh, adlc and mirror. The clock is pinned (FACTORY_NOW); offline.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

NOW=1762000000
H=3600 D=86400
MAKE_REPO="$REPO_ROOT/tests/fixtures/make-repo.sh"

# jan_setup < spec: a fresh world whose origin is the fixture; `ci` is the janitor's checkout. The
# open set is saved as [] (the fake adlc lists no tickets) unless the spec has its own state line.
jan_setup() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=janitor-test GIT_AUTHOR_EMAIL=janitor@test.invalid
  export GIT_COMMITTER_NAME=janitor-test GIT_COMMITTER_EMAIL=janitor@test.invalid
  rm -rf "$FAKE_GH_GIT"
  { echo 'state {"open_set": []}'; command cat; } | "$MAKE_REPO" "$FAKE_GH_GIT"
  git clone -q "$FAKE_GH_GIT" "$WORLD/ci"
  export FACTORY_NOW="$NOW" FAKE_GH_NOW="$NOW" FACTORY_ADLC="$FAKES_DIR/adlc" FACTORY_MIRROR="$FAKES_DIR/mirror"
  export RUNNER_ENVIRONMENT=github-hosted DISCORD_WEBHOOK=https://discord.test/hook SUMMONER_TO=desk-human
  mkhook revoke 0; mkhook preview 0
}
mkhook() {  # mkhook <revoke|preview> <exit>: $WORLD/<name>-hook logs "$*" (and a record file) to <name>.log
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/%s.log"\n[ -z "${3:-}" ] || jq -c . "$3" >>"%s/%s.log"\nexit %s\n' \
    "$WORLD" "$1" "$WORLD" "$1" "$2" >"$WORLD/$1-hook"
  chmod +x "$WORLD/$1-hook"
  : >"$WORLD/$1.log"
  if [ "$1" = revoke ]; then export JANITOR_REVOKE_HOOK="$WORLD/revoke-hook"; else export JANITOR_PREVIEW_HOOK="$WORLD/preview-hook"; fi
}
jan() {  # jan <args>: run the janitor in the ci checkout; sets RC, OUT (JSON lines), ERR
  RC=0
  OUT="$(cd "$WORLD/ci" && "$BIN/janitor.sh" "$@" 2>"$WORLD/err")" || RC=$?
  # shellcheck disable=SC2034  # ERR is read inside the eval strings passed to check
  ERR="$(command cat "$WORLD/err")"
}
lines() { if [ -z "$OUT" ]; then echo 0; else jq -c "select($1)" <<<"$OUT" | wc -l | tr -d ' '; fi; }
pick() { jq -sc "[.[] | select($1)] | $2" <<<"$OUT"; }
has_ref() { [ -n "$(fakegh_ref "$1")" ]; }
no_ref() { [ -z "$(fakegh_ref "$1")" ]; }
comments() { jq -c --argjson n "$1" '[.issues[] | select(.number == $n) | .comments[].body]' "$FAKE_GH_ISSUES"; }
labels() { jq -c --argjson n "$1" '[.issues[] | select(.number == $n) | .labels[].name]' "$FAKE_GH_ISSUES"; }
on_nodes() { git -C "$FAKE_GH_GIT" show "nodes:$1" 2>/dev/null; }
snapshot() {  # every ref of the origin and the tree of each, plus the ci checkout's refs
  git -C "$FAKE_GH_GIT" for-each-ref
  git -C "$FAKE_GH_GIT" for-each-ref --format='%(refname)' | while read -r r; do
    echo "== $r"; git -C "$FAKE_GH_GIT" ls-tree -r "$r"
  done
  echo "== ci"; git -C "$WORLD/ci" for-each-ref
}

# ---------------------------------------------------------------------------------------------
case_stale_lock() {
  jan_setup <<EOF
node alpha $((NOW - H)) active 8
lock 1 alpha $((NOW - 25 * H))
lock 2 alpha $((NOW - 23 * H))
lock 3 alpha $((NOW - 25 * H))
branch ticket/3/alpha $((NOW - 30 * H))
lock 4 alpha $((NOW - 24 * H))
lock 5 alpha $((NOW - 24 * H - 1))
EOF
  for n in 1 2 3 4 5; do fakegh_issue "$n" "$((NOW - 3 * D))" ready,w:light,in-progress; done
  jan --apply
  check "exit 0" eq "$RC" 0
  check "25 h old lock with no branch: released" no_ref refs/locks/issue-1
  check "25 h old lock whose branch is 30 h old: released" no_ref refs/locks/issue-3
  check "24 h and one second: released" no_ref refs/locks/issue-5
  check "23 h old lock: kept" has_ref refs/locks/issue-2
  check "exactly 24 h is not older than 24 h: kept" has_ref refs/locks/issue-4
  check "three release lines, reason stale-lock, all done" \
    eq "$(pick '.action == "release-lock"' 'map([.issue, .reason, .result])')" \
       '[[1,"stale-lock","done"],[3,"stale-lock","done"],[5,"stale-lock","done"]]'
  check "one comment on each released Issue, none on a kept one" \
    eq "$(for n in 1 2 3 4 5; do comments "$n" | jq length; done | tr '\n' ' ')" "1 0 1 0 1 "
  check "the comment names the ref, the holder and the reason" \
    eq "$(comments 1 | jq -r '.[0] | test("refs/locks/issue-1.*`alpha`.*no heartbeat for more than 24 h")')" true
  check "in-progress removed from a released Issue" eq "$(labels 1)" '["ready","w:light"]'
  check "in-progress kept on a held Issue" eq "$(labels 2)" '["ready","w:light","in-progress"]'
  check "the old branch itself is not touched by a lock release" has_ref refs/heads/ticket/3/alpha
  check "a second run finds nothing to do" eval 'jan --apply; [ "$RC" = 0 ] && [ -z "$OUT" ]'
}

case_stale_node() {
  jan_setup <<EOF
node alpha $((NOW - H)) active 4
node beta $((NOW - 30 * H)) active 4
node gamma $((NOW - 48 * H)) stale 4
lock 5 beta $((NOW - H))
lock 6 gamma $((NOW - 2 * H))
lock 7 alpha $((NOW - H))
lock 8 beta $((NOW - 2 * H))
branch ticket/8/beta $((NOW - H))
EOF
  for n in 5 6 7 8; do fakegh_issue "$n" "$((NOW - 3 * D))" ready,w:light,in-progress; done
  jan --apply
  check "exit 0" eq "$RC" 0
  check "fresh lock of a node that went stale this run: released" no_ref refs/locks/issue-5
  check "fresh lock of a node already stale: released" no_ref refs/locks/issue-6
  check "lock of an active node: kept" has_ref refs/locks/issue-7
  check "stale node's lock with a branch pushed inside the TTL: kept (must not)" has_ref refs/locks/issue-8
  check "reasons" eq "$(pick '.action | test("lock")' 'map([.action, .issue, .reason, .result])')" \
    '[["release-lock",5,"node-stale","done"],["release-lock",6,"node-stale","done"],["keep-lock",8,"node-stale","kept"]]'
  check "beta marked stale on the nodes branch" eq "$(on_nodes nodes/beta.json | jq -r .status)" stale
  check "the comment says the node is stale" eq "$(comments 5 | jq -r '.[0] | test("node `beta` is stale")')" true
  check "no comment on the kept lock's Issue" eq "$(comments 8)" '[]'
}

case_over_slots() {
  jan_setup <<EOF
node alpha $((NOW - H)) active 2
lock 10 alpha $((NOW - 5 * H))
lock 11 alpha $((NOW - 3 * H))
lock 12 alpha $((NOW - H))
branch ticket/12/alpha $((NOW - H))
lock 13 alpha $((NOW - 2 * H))
node beta $((NOW - H)) active 3
lock 14 beta $((NOW - H))
lock 15 beta $((NOW - 2 * H))
EOF
  for n in 10 11 12 13 14 15; do fakegh_issue "$n" "$((NOW - 3 * D))" ready,w:light,in-progress; done
  jan --apply
  check "exit 0" eq "$RC" 0
  check "4 locks on 2 slots: the two newest without a fresh branch go (13, then 11)" \
    eq "$(pick '.action == "release-lock"' 'map([.issue, .reason, .result])')" '[[11,"over-slots","done"],[13,"over-slots","done"]]'
  check "the oldest lock is kept" has_ref refs/locks/issue-10
  check "the newest lock has a fresh branch: kept (must not)" has_ref refs/locks/issue-12
  check "locks 11 and 13 are gone" eval 'no_ref refs/locks/issue-11 && no_ref refs/locks/issue-13'
  check "a node under its slots keeps all its locks" eval 'has_ref refs/locks/issue-14 && has_ref refs/locks/issue-15'
  check "the comment names the slot count" eq "$(comments 13 | jq -r '.[0] | test("more locks than its 2 slot")')" true
}

case_fresh_branch_kept() {
  jan_setup <<EOF
node alpha $((NOW - H)) active 8
lock 20 alpha $((NOW - 30 * H))
branch ticket/20/alpha $((NOW - 2 * H))
lock 21 alpha $((NOW - 30 * H))
branch ticket/21/alpha $((NOW - 2 * H))
lock 22 alpha $((NOW - 30 * H))
branch ticket/22/alpha $((NOW - 24 * H))
lock 23 alpha $((NOW - 30 * H))
branch ticket/23/alpha $((NOW - 24 * H - 1))
lock 24 alpha $((NOW - 30 * H))
branch ticket/T9/alpha $((NOW - 2 * H))
EOF
  for n in 20 21 22 23; do fakegh_issue "$n" "$((NOW - 3 * D))" ready,in-progress; done
  fakegh_issue 24 "$((NOW - 3 * D))" ready,in-progress "issue 24" $'Mirrored from the store.\nTicket: T9\n'
  fakegh_pr 100 ticket/20/alpha OPEN
  jan --apply
  check "exit 0" eq "$RC" 0
  check "stale lock, fresh branch, open PR: kept" has_ref refs/locks/issue-20
  check "stale lock, fresh branch, no PR, 30 h < 48 h: kept" has_ref refs/locks/issue-21
  check "branch exactly 24 h old is not older than the TTL: kept" has_ref refs/locks/issue-22
  check "branch 24 h and one second old: released" no_ref refs/locks/issue-23
  check "the branch is found through the Issue's Ticket: line (ticket/T9/*): kept" has_ref refs/locks/issue-24
  check "keep lines name the branch they were kept for" \
    eq "$(pick '.action == "keep-lock"' 'map([.issue, .kept_for, .result])')" \
       '[[20,"ticket/20/alpha","kept"],[21,"ticket/21/alpha","kept"],[22,"ticket/22/alpha","kept"],[24,"ticket/T9/alpha","kept"]]'
  check "no comment on a kept lock" eq "$(comments 20)$(comments 24)" '[][]'
  check "every branch is still there" eq "$(git -C "$FAKE_GH_GIT" for-each-ref refs/heads/ticket/ | wc -l | tr -d ' ')" 5
}

case_no_pr_48h() {
  jan_setup <<EOF
node alpha $((NOW - H)) active 8
lock 30 alpha $((NOW - 49 * H))
branch ticket/30/alpha $((NOW - H))
lock 31 alpha $((NOW - 49 * H))
branch ticket/31/alpha $((NOW - H))
lock 32 alpha $((NOW - 47 * H))
branch ticket/32/alpha $((NOW - H))
EOF
  for n in 30 31 32; do fakegh_issue "$n" "$((NOW - 3 * D))" ready,in-progress; done
  fakegh_pr 101 ticket/31/alpha OPEN
  fakegh_pr 99 ticket/30/alpha CLOSED
  jan --apply
  check "exit 0" eq "$RC" 0
  check "49 h, fresh branch, only a closed PR: released" no_ref refs/locks/issue-30
  check "its branch is kept for the next claimant" has_ref refs/heads/ticket/30/alpha
  check "49 h, fresh branch, open PR: kept" has_ref refs/locks/issue-31
  check "47 h, fresh branch, no PR: kept" has_ref refs/locks/issue-32
  check "release line: reason no-pr-48h, branch_kept named" \
    eq "$(pick '.action == "release-lock"' 'map([.issue, .reason, .branch_kept, .result])')" '[[30,"no-pr-48h","ticket/30/alpha","done"]]'
  check "the comment says the branch is kept" \
    eq "$(comments 30 | jq -r '.[0] | test("no open PR for `ticket/30/alpha`.*Branch `ticket/30/alpha` is kept for the next claimant")')" true
}

case_branch_sweep() {
  jan_setup <<EOF
node alpha $((NOW - H)) active 8
branch ticket/40/alpha $((NOW - H))
branch ticket/41/alpha $((NOW - 8 * D))
branch ticket/42/alpha $((NOW - 6 * D))
branch ticket/43/alpha $((NOW - 8 * D))
lock 43 alpha $((NOW - H))
branch ticket/44/alpha $((NOW - 8 * D))
branch ticket/45/alpha $((NOW - H))
branch ticket/46/alpha $((NOW - 7 * D))
branch ticket/T99/x $((NOW - 8 * D))
branch ticket/T98/x $((NOW - H))
EOF
  for n in 40 41 42 43 44 45 46; do fakegh_issue "$n" "$((NOW - 9 * D))" ready; done
  fakegh_close 40; fakegh_close 45
  fakegh_pr 102 ticket/44/alpha OPEN
  fakegh_pr 103 ticket/45/alpha OPEN
  local main; main="$(fakegh_ref refs/heads/main)"
  jan --apply
  check "exit 0" eq "$RC" 0
  check "deleted: closed Issue; unclaimed 8 days; no Issue and 8 days" \
    eq "$(pick '.action == "delete-branch"' 'map([.branch, .reason, .result])')" \
       '[["ticket/40/alpha","issue-closed","done"],["ticket/41/alpha","unclaimed-7d","done"],["ticket/T99/x","unclaimed-7d","done"]]'
  check "the three are gone" eval 'no_ref refs/heads/ticket/40/alpha && no_ref refs/heads/ticket/41/alpha && no_ref refs/heads/ticket/T99/x'
  check "6 days unclaimed: kept" has_ref refs/heads/ticket/42/alpha
  check "8 days old but claimed: kept" has_ref refs/heads/ticket/43/alpha
  check "8 days old with an open PR: kept" has_ref refs/heads/ticket/44/alpha
  check "closed Issue with an open PR: kept (deleting would close the PR)" has_ref refs/heads/ticket/45/alpha
  check "exactly 7 days is not older than 7 days: kept" has_ref refs/heads/ticket/46/alpha
  check "fresh branch with no Issue: kept" has_ref refs/heads/ticket/T98/x
  check "main is untouched" eq "$(fakegh_ref refs/heads/main)" "$main"
  check "flaky-history is untouched" has_ref refs/heads/flaky-history
}

case_node_lifecycle() {
  jan_setup <<EOF
node a1 $((NOW - 23 * H)) active
node a2 $((NOW - 25 * H)) active
node a3 $((NOW - 8 * D)) stale 2 owner3
node a4 $((NOW - 6 * D)) paused
node a5 $((NOW - 7 * D - 1)) active
node a6 $((NOW - 25 * H)) joining
node a7 $((NOW - 7 * D)) stale
lock 50 a3 $((NOW - H))
lock 51 a3 $((NOW - 9 * D))
EOF
  fakegh_issue 50 "$((NOW - 9 * D))" ready,in-progress "issue 50" $'Ticket: T7\n'
  fakegh_issue 51 "$((NOW - 9 * D))" ready,in-progress
  local a1; a1="$(on_nodes nodes/a1.json)"
  jan --apply
  check "exit 0" eq "$RC" 0
  check "node lines: a2, a4, a6 stale; a3, a5 retired; a1 and a7 untouched" \
    eq "$(pick '.action | startswith("node-")' 'map([.action, .handle, .status_before, .status_after, .result])')" \
       '[["node-stale","a2","active","stale","done"],["node-retire","a3","stale","retired","done"],["node-stale","a4","paused","stale","done"],["node-retire","a5","active","retired","done"],["node-stale","a6","joining","stale","done"]]'
  check "a2, a4, a6 manifests say stale" eq "$(for h in a2 a4 a6; do on_nodes "nodes/$h.json" | jq -r .status; done | tr '\n' ' ')" "stale stale stale "
  check "a1 (23 h) is byte-identical" eq "$(on_nodes nodes/a1.json)" "$a1"
  check "a7 (exactly 7 days, already stale) stays stale and live" eq "$(on_nodes nodes/a7.json | jq -r .status)" stale
  check "retired manifests leave nodes/" eval '! on_nodes nodes/a3.json >/dev/null && ! on_nodes nodes/a5.json >/dev/null'
  check "and are archived with status retired" \
    eq "$(for h in a3 a5; do on_nodes "archive/nodes/$h.json" | jq -c '[.handle, .status]'; done | tr '\n' ' ')" '["a3","retired"] ["a5","retired"] '
  check "one commit on the nodes branch for all of it" \
    eq "$(git -C "$FAKE_GH_GIT" log --format=%s nodes | head -n1)" "janitor: 7 file(s) at $(jq -nr --argjson e "$NOW" '$e | todate')"
  check "token revoked for each retired node (handle, owner)" eq "$(command cat "$WORLD/revoke.log")" $'a3 owner3\na5 a5'
  check "both claims of the retired node released, even the fresh one" \
    eq "$(pick '.action == "release-lock"' 'map([.issue, .reason, .result])')" '[[50,"node-retired","done"],[51,"node-retired","done"]]'
  check "the comment says the node is retired" eq "$(comments 50 | jq -r '.[0] | test("node `a3` is retired")')" true
  check "one halt notice, for the retired node with open claims" eq "$(jq -s length "$FAKE_CURL_LOG")" 1
  check "the halt notice names the ticket, the reason and the link" \
    eq "$(jq -r '.body | fromjson | .content | test("Ticket: T7") and test("node a3 retired with open claims \\(#50, #51\\)") and test("issues/50")' "$FAKE_CURL_LOG")" true
  check "summon-halt line" eq "$(pick '.action == "summon-halt"' 'map([.handle, .ticket, .result])')" '[["a3","T7","done"]]'
  check "a second run changes nothing" eval 'jan --apply; [ "$RC" = 0 ] && [ -z "$OUT" ]'
}

case_preview_ttl() {
  jan_setup <<EOF
preview p1 $((NOW - 1))
preview p2 $((NOW + H)) 60
preview p3 $((NOW + H)) 61
preview p4 $NOW
preview p5 $((NOW + 1))
EOF
  fakegh_pr 61 integration/p3 OPEN
  fakegh_pr 60 integration/p2 CLOSED
  jan --apply
  check "exit 0" eq "$RC" 0
  check "torn down: past TTL, PR closed, at TTL exactly" \
    eq "$(pick '.action == "preview-teardown"' 'map([.preview, .reason, .result])')" '[["p1","ttl","done"],["p2","pr-closed","done"],["p4","ttl","done"]]'
  check "the hook got teardown <name> <record> with the record's content" \
    eq "$(sed -n 1p "$WORLD/preview.log" | cut -d' ' -f1,2) $(sed -n 2p "$WORLD/preview.log" | jq -r .address)" \
       'teardown p1 https://p1.preview.test'
  check "records removed from the nodes branch; open ones kept" \
    eq "$(git -C "$FAKE_GH_GIT" ls-tree --name-only nodes previews/ | tr '\n' ' ')" "previews/p3.json previews/p5.json "
  # A failing hook keeps the record and fails the run, so it retries next hour.
  jan_setup <<EOF
preview p1 $((NOW - 1))
EOF
  mkhook preview 1
  jan --apply
  check "failing hook: exit 1" eq "$RC" 1
  check "failing hook: the line says failed" eq "$(pick '.action == "preview-teardown"' 'map(.result)')" '["failed"]'
  check "failing hook: the record is kept" eq "$(git -C "$FAKE_GH_GIT" ls-tree --name-only nodes previews/)" previews/p1.json
}

case_ready_recompute() {
  jan_setup <<EOF
state {"open_set": ["T1"]}
EOF
  export FAKE_ADLC_TICKETS='[{"id":"T2","title":"b","ticketHash":"h2"},{"id":"T1","title":"a","ticketHash":"h1"}]'
  jan
  check "dry run: exit 0" eq "$RC" 0
  check "dry run: forecast run, mirror not called" eq "$(jq -s length "$FAKE_MIRROR_LOG")" 0
  check "dry run: planned line with the diff" eq "$(pick '.action == "ready-recompute"' 'map([.added, .removed, .result])')" '[[["T2"],[],"planned"]]'
  check "dry run: state unchanged" eq "$(on_nodes janitor/state.json | jq -c .open_set)" '["T1"]'
  : >"$FAKE_ADLC_LOG"
  jan --apply
  check "changed set: exit 0" eq "$RC" 0
  check "changed set: ticket list then merge-forecast" eq "$(jq -sc 'map(.[0:2])' "$FAKE_ADLC_LOG")" '[["ticket","list"],["merge-forecast","--json"]]'
  check "changed set: the mirror recomputes labels from the forecast" \
    eq "$(jq -sc 'map([.argv[0], .argv[1], .forecast.mergeOrder])' "$FAKE_MIRROR_LOG")" '[["--apply","--forecast",["T1","T2"]]]'
  check "changed set: line done" eq "$(pick '.action == "ready-recompute"' 'map([.open_set, .merge_order, .result])')" '[[["T1","T2"],["T1","T2"],"done"]]'
  check "changed set: the new open set is saved on the nodes branch" eq "$(on_nodes janitor/state.json | jq -c '[.open_set, .forecast.certifiedWidth]')" '[["T1","T2"],2]'
  : >"$FAKE_ADLC_LOG"; : >"$FAKE_MIRROR_LOG"
  jan --apply
  check "same set: no forecast, no mirror, no line" \
    eval '[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(jq -sc "map(.[0:2])" "$FAKE_ADLC_LOG")" = "[[\"ticket\",\"list\"]]" ] && [ ! -s "$FAKE_MIRROR_LOG" ]'
  export FAKE_ADLC_TICKETS='[{"id":"T1","title":"a","ticketHash":"h1"}]' FAKE_MIRROR_FAIL=1
  jan --apply
  check "mirror fails: exit 1, line failed" eq "$RC $(pick '.action == "ready-recompute"' 'map(.result)')" '1 ["failed"]'
  check "mirror fails: the set is not saved" eq "$(on_nodes janitor/state.json | jq -c .open_set)" '["T1","T2"]'
  unset FAKE_MIRROR_FAIL
  jan --apply
  check "next run retries and saves" eq "$RC $(on_nodes janitor/state.json | jq -c .open_set)" '0 ["T1"]'
  export FAKE_ADLC_TICKETS='[{"id":"T1"},{"id":"T3"}]' FAKE_ADLC_FORECAST_EXIT=2
  jan --apply
  check "forecast exit 2 (a gate failed, forecast printed): still recomputed and saved" \
    eq "$RC $(pick '.action == "ready-recompute"' 'map([.forecast_exit, .result])') $(on_nodes janitor/state.json | jq -c .open_set)" \
       '0 [[2,"done"]] ["T1","T3"]'
  unset FAKE_ADLC_FORECAST_EXIT
  export FAKE_ADLC_FAIL=merge-forecast FAKE_ADLC_TICKETS='[]'
  jan --apply
  check "forecast fails: exit 1, set not saved, mirror not called" \
    eq "$RC $(on_nodes janitor/state.json | jq -c .open_set) $(jq -s length "$FAKE_MIRROR_LOG")" '1 ["T1","T3"] 3'
}

# Everything fires at once. --dry-run (and no flag) must leave every ref and tree byte-identical,
# write nothing through gh, call no hook, mirror or webhook, and print the same actions --apply takes.
everything() {
  jan_setup <<EOF
state {"open_set": ["T1"]}
node alpha $((NOW - H)) active 2
node beta $((NOW - 30 * H)) active 2
node gone $((NOW - 8 * D)) stale 2
lock 1 alpha $((NOW - 25 * H))
lock 2 alpha $((NOW - H))
lock 3 alpha $((NOW - 2 * H))
lock 4 alpha $((NOW - 3 * H))
lock 5 beta $((NOW - H))
lock 6 gone $((NOW - H))
lock 7 alpha $((NOW - 49 * H))
branch ticket/7/alpha $((NOW - H))
lock 8 alpha $((NOW - 30 * H))
branch ticket/8/alpha $((NOW - H))
branch ticket/9/alpha $((NOW - H))
branch ticket/10/alpha $((NOW - 8 * D))
preview old $((NOW - H))
EOF
  for n in 1 2 3 4 5 6 7 8 9 10; do fakegh_issue "$n" "$((NOW - 9 * D))" ready,in-progress; done
  fakegh_close 9
  export FAKE_ADLC_TICKETS='[{"id":"T1"},{"id":"T2"}]'
}
case_dry_run_inert() {
  everything
  unset RUNNER_ENVIRONMENT            # a dry run runs anywhere
  local before issues dry; before="$(snapshot)"; issues="$(command cat "$FAKE_GH_ISSUES")"
  jan
  check "no flag: exit 0" eq "$RC" 0
  dry="$OUT"
  check "every duty is in the plan" \
    eq "$(jq -sc 'map(.action) | unique' <<<"$dry")" \
       '["comment","delete-branch","keep-lock","node-retire","node-stale","nodes-commit","preview-teardown","ready-recompute","release-lock","remove-label","revoke-token","summon-halt"]'
  check "every line is dry-run, planned or kept" eq "$(jq -sc 'map([.mode, .result]) | unique' <<<"$dry")" '[["dry-run","kept"],["dry-run","planned"]]'
  check "origin refs and trees byte-identical (git for-each-ref + ls-tree -r)" eq "$(snapshot)" "$before"
  check "issue store byte-identical" eq "$(command cat "$FAKE_GH_ISSUES")" "$issues"
  check "gh: reads only" eq "$(jq -sc 'map(.[0:2]) | unique' "$FAKE_GH_LOG")" '[["issue","list"],["pr","list"]]'
  check "no webhook, mirror or hook call" eq "$(wc -c <"$FAKE_CURL_LOG" "$FAKE_MIRROR_LOG" "$WORLD/revoke.log" "$WORLD/preview.log" | awk '{s+=$1} END {print s}')" 0
  jan --dry-run
  check "--dry-run prints the same plan" eq "$OUT" "$dry"
  check "and still changes nothing" eq "$(snapshot)" "$before"
  export RUNNER_ENVIRONMENT=github-hosted
  jan --apply
  check "--apply: exit 0" eq "$RC" 0
  local key='map([.action, (.issue // .branch // .handle // .preview // "")]) | sort'
  check "--apply takes exactly the actions the dry run printed" eq "$(jq -sc "$key" <<<"$OUT")" "$(jq -sc "$key" <<<"$dry")"
  check "--apply: every action done or kept" eq "$(jq -sc 'map(.result) | unique' <<<"$OUT")" '["done","kept"]'
}

case_refuses_off_hosted() {
  everything
  local before; before="$(snapshot)"
  unset RUNNER_ENVIRONMENT
  jan --apply
  check "--apply with no RUNNER_ENVIRONMENT: exit 2" eq "$RC" 2
  check "the refusal says why" eval 'grep -q "never runs on a node" <<<"$ERR"'
  RUNNER_ENVIRONMENT=self-hosted jan --apply
  check "--apply on a self-hosted runner (a node): exit 2" eq "$RC" 2
  check "nothing changed, no gh call" eval '[ "$(snapshot)" = "$before" ] && [ ! -s "$FAKE_GH_LOG" ]'
}

# A node heartbeats between the janitor's read and its delete: the lease fails and the lock stays.
case_lease_race() {
  jan_setup <<EOF
node alpha $((NOW - H)) active 2
lock 70 alpha $((NOW - 30 * H))
EOF
  fakegh_issue 70 "$((NOW - 3 * D))" ready,in-progress
  local tip beat
  tip="$(fakegh_ref refs/heads/nodes)"
  beat="$(printf 'lock issue-70: alpha\n\n{"handle":"alpha","run_id":"r","slots":2,"claimed_at":"x"}' |
          git -C "$FAKE_GH_GIT" commit-tree "$tip^{tree}" -p "$tip")"
  # reference-transaction runs in the ci checkout when the janitor's fetch writes its refs.
  printf '#!/usr/bin/env bash\n[ "$1" = committed ] || exit 0\nif grep -q refs/janitor/locks/issue-70 && [ ! -e "%s/raced" ]; then\n  touch "%s/raced"; git -C "%s" update-ref refs/locks/issue-70 %s\nfi\n' \
    "$WORLD" "$WORLD" "$FAKE_GH_GIT" "$beat" >"$WORLD/ci/.git/hooks/reference-transaction"
  chmod +x "$WORLD/ci/.git/hooks/reference-transaction"
  jan --apply
  check "the race happened" test -e "$WORLD/raced"
  check "exit 0: a lost lease is not an error" eq "$RC" 0
  check "the line says skipped" eq "$(pick '.action == "release-lock"' 'map([.issue, .result])')" '[[70,"skipped"]]'
  check "the heartbeated lock survives" eq "$(fakegh_ref refs/locks/issue-70)" "$beat"
  check "no comment" eq "$(comments 70)" '[]'
}

# Each hook alone: an unset hook makes the run red by itself, whatever else succeeded.
case_hooks_unconfigured() {
  local spec
  spec="node gone $((NOW - 8 * D)) active
preview p1 $((NOW - 1))"
  jan_setup <<<"$spec"
  unset JANITOR_REVOKE_HOOK
  jan --apply
  check "no revoke hook: exit 1, a human must notice" eq "$RC" 1
  check "no revoke hook: revoke-token unconfigured, the teardown done" \
    eq "$(pick '.action | test("revoke|preview")' 'map([.action, .result])')" '[["preview-teardown","done"],["revoke-token","unconfigured"]]'
  check "the node is still archived (one red run, not one every hour)" eval 'on_nodes archive/nodes/gone.json >/dev/null'
  jan_setup <<<"$spec"
  unset JANITOR_PREVIEW_HOOK
  jan --apply
  check "no preview hook: exit 1" eq "$RC" 1
  check "no preview hook: preview-teardown unconfigured, the revoke done" \
    eq "$(pick '.action | test("revoke|preview")' 'map([.action, .result])')" '[["preview-teardown","unconfigured"],["revoke-token","done"]]'
  check "the preview record is kept" eq "$(git -C "$FAKE_GH_GIT" ls-tree --name-only nodes previews/)" previews/p1.json
}

# race_hook <once|always>: when the janitor's fetch writes refs/janitor/nodes in the ci checkout,
# a commit lands on the origin's nodes branch first (once: beta's heartbeat, prebuilt in
# $WORLD/beat; always: a fresh empty commit every time), so the janitor's fast-forward is rejected.
race_hook() {
  printf '#!/usr/bin/env bash
[ "$1" = committed ] || exit 0
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
hit=0
while read -r _ new ref; do [ "$ref" = refs/janitor/nodes ] && [ "${new//0/}" ] && hit=1; done
[ "$hit" = 1 ] || exit 0
o="%s"; w="%s"
echo x >>"$w/races"
' \
    "$FAKE_GH_GIT" "$WORLD" >"$WORLD/ci/.git/hooks/reference-transaction"
  if [ "$1" = once ]; then
    printf '[ "$(wc -l <"$w/races")" = 1 ] || exit 0
git -C "$o" update-ref refs/heads/nodes "$(command cat "$w/beat")"
'
  else
    printf 'tip="$(git -C "$o" rev-parse nodes)"
git -C "$o" update-ref refs/heads/nodes "$(git -C "$o" commit-tree "$tip^{tree}" -p "$tip" -m beat)"
'
  fi >>"$WORLD/ci/.git/hooks/reference-transaction"
  chmod +x "$WORLD/ci/.git/hooks/reference-transaction"
}

# The nodes branch moves between the read and the push: the janitor re-reads, re-plans and retries.
# When it never lands, no node changed state, so nothing acts on a transition (NODES_OK).
case_nodes_race() {
  local spec tip idx blob
  spec="node beta $((NOW - 30 * H)) active
node gamma $((NOW - 30 * H)) active
lock 5 beta $((NOW - H))
lock 6 gamma $((NOW - H))"
  jan_setup <<<"$spec"
  for n in 5 6; do fakegh_issue "$n" "$((NOW - 3 * D))" ready,in-progress; done
  tip="$(fakegh_ref refs/heads/nodes)"; idx="$WORLD/beat-index"
  blob="$(on_nodes nodes/beta.json | jq --argjson now "$NOW" '.last_seen = ($now | todate)' | git -C "$FAKE_GH_GIT" hash-object -w --stdin)"
  GIT_INDEX_FILE="$idx" git -C "$FAKE_GH_GIT" read-tree "$tip"
  GIT_INDEX_FILE="$idx" git -C "$FAKE_GH_GIT" update-index --cacheinfo "100644,$blob,nodes/beta.json"
  git -C "$FAKE_GH_GIT" commit-tree "$(GIT_INDEX_FILE="$idx" git -C "$FAKE_GH_GIT" write-tree)" -p "$tip" -m "heartbeat beta" >"$WORLD/beat"
  race_hook once
  jan --apply
  check "raced once, then re-read on the retry" eq "$(wc -l <"$WORLD/races")" 2
  check "exit 0" eq "$RC" 0
  check "the janitor's commit sits on top of the heartbeat" \
    eq "$(git -C "$FAKE_GH_GIT" rev-parse nodes^)" "$(command cat "$WORLD/beat")"
  check "re-planned: beta heartbeated, so it stays active and keeps its lock" \
    eval '[ "$(on_nodes nodes/beta.json | jq -r .status)" = active ] && has_ref refs/locks/issue-5'
  check "gamma went stale and its lock was released" \
    eval '[ "$(on_nodes nodes/gamma.json | jq -r .status)" = stale ] && no_ref refs/locks/issue-6'
  check "lines: only gamma's transition and release" \
    eq "$(pick '.action | test("node-|lock")' 'map([.action, (.handle // .issue), .result])')" \
       '[["node-stale","gamma","done"],["release-lock",6,"done"]]'

  jan_setup <<<"$spec"
  for n in 5 6; do fakegh_issue "$n" "$((NOW - 3 * D))" ready,in-progress; done
  race_hook always
  jan --apply
  check "always moving: three attempts" eq "$(wc -l <"$WORLD/races")" 3
  check "exit 1, the nodes commit failed" eq "$RC $(pick '.action == "nodes-commit"' 'map(.result)')" '1 ["failed"]'
  check "the transitions are reported failed" eq "$(pick '.action == "node-stale"' 'map(.result) | unique')" '["failed"]'
  check "nothing acts on a transition that did not land: both locks kept, no comment" \
    eval 'has_ref refs/locks/issue-5 && has_ref refs/locks/issue-6 && [ "$(comments 5)$(comments 6)" = "[][]" ]'
  check "no release line" eq "$(lines '.action == "release-lock"')" 0
}

# The fakes' new verbs: gh pr list, gh issue list state/body as gh answers them, adlc, mirror.
case_fake_semantics() {
  fakegh_setup
  fakegh_issue 1 1761300000 ready
  fakegh_issue 2 1761300001 ready "two" $'Ticket: T2\n'
  fakegh_close 1
  fakegh_pr 5 ticket/T1/a OPEN 1761300000
  fakegh_pr 6 ticket/T2/a MERGED 1761300001
  fakegh_pr 7 ticket/T3/a CLOSED 1761300002
  check "issue list answers OPEN/CLOSED and an empty body" \
    eq "$(gh issue list --repo test/repo --state all --json number,state,body | jq -c 'map([.number, .state, .body])')" '[[2,"OPEN","Ticket: T2\n"],[1,"CLOSED",""]]'
  check "issue list --state open still filters" eq "$(gh issue list --repo test/repo --state open --json number | jq -c 'map(.number)')" '[2]'
  check "pr list defaults to open" eq "$(gh pr list --repo test/repo --json number,headRefName | jq -c .)" '[{"number":5,"headRefName":"ticket/T1/a"}]'
  check "pr list --state merged / closed / all" \
    eq "$(for s in merged closed all; do gh pr list --repo test/repo --state "$s" --json number | jq -c 'map(.number)'; done | tr '\n' ' ')" '[6] [7] [7,6,5] '
  check "pr list --head filters" eq "$(gh pr list --repo test/repo --state all --head ticket/T2/a --json number | jq -c .)" '[{"number":6}]'
  check "pr list needs --repo" eval '! gh pr list --json number 2>/dev/null'
  check "pr list rejects a bad state" eval '! gh pr list --repo test/repo --state bogus --json number 2>/dev/null'
  export FAKE_ADLC_TICKETS='[{"id":"T2"},{"id":"T1"}]'
  check "adlc ticket list answers the fixture" eq "$(adlc ticket list --json)" '[{"id":"T2"},{"id":"T1"}]'
  check "adlc merge-forecast defaults to one wave of the sorted ids" \
    eq "$(adlc merge-forecast --json | jq -c '[.mergeOrder, .waves, .certifiedWidth]')" '[["T1","T2"],[["T1","T2"]],2]'
  check "adlc logs argv" eq "$(jq -sc 'map(.[0])' "$FAKE_ADLC_LOG")" '["ticket","merge-forecast"]'
  check "adlc refuses an unknown verb" eval '! adlc ticket complete T1 2>/dev/null'
  check "FAKE_ADLC_FORECAST_EXIT: prints the forecast, then exits with it" \
    eval '[ "$(FAKE_ADLC_FORECAST_EXIT=2 adlc merge-forecast --json | jq -c .mergeOrder; echo "${PIPESTATUS[0]}")" = $'"'"'["T1","T2"]\n2'"'"' ]'
  check "FAKE_ADLC_FAIL fails a matching call" eval '! FAKE_ADLC_FAIL=forecast adlc merge-forecast --json >/dev/null 2>&1'
  printf '{"mergeOrder":["T9"]}' >"$WORLD/f.json"
  mirror --apply --forecast "$WORLD/f.json"
  check "mirror records argv and the forecast" eq "$(jq -c '[.argv, .forecast.mergeOrder]' "$FAKE_MIRROR_LOG")" '[["--apply","--forecast","'"$WORLD"'/f.json"],["T9"]]'
  check "FAKE_MIRROR_FAIL=1 fails after recording" eval '! FAKE_MIRROR_FAIL=1 mirror --apply 2>/dev/null && [ "$(wc -l <"$FAKE_MIRROR_LOG")" = 2 ]'
}

echo "test_janitor"
for c in stale-lock stale-node over-slots fresh-branch-kept no-pr-48h branch-sweep node-lifecycle preview-ttl \
         ready-recompute dry-run-inert refuses-off-hosted lease-race nodes-race hooks-unconfigured fake-semantics; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
