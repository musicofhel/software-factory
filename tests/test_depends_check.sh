#!/usr/bin/env bash
# T27 (specs/factory-step3-v1 TB8): factory/bin/depends-check.sh, the Depends-on hold.
#   - the parents of a ticket are the base store's tickets with an edge to it: none passes, an open
#     parent holds (named on stdout and stderr), a completed parent passes;
#   - the PR body is never read: an invented `Depends-on:` holds nothing, a dropped one frees nothing;
#   - merge_group (PR N from the queue ref, read through the fake gh) answers as pull_request does;
#   - an unknown or completed own ticket is refused (exit 2);
#   - a parent completed only off the base (a side branch, the PR head's own store) still holds;
#   - the store is read at origin/main when it descends from the event's base (the re-run labeler.sh
#     asks for), and at the base when origin/main diverged;
#   - a human PR passes with its class; an edge cycle holds and is named; a corrupt store fails closed
#     (exit 1);
#   - the node call (--ticket --base, as labeler.sh makes it) gives CI's answer.
# Offline; every repo is a temp dir, gh is the fake.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
DC="$BIN/depends-check.sh"
EV="$REPO_ROOT/tests/fixtures/events"
FREPO=Codertocat/Hello-World   # the repository of GitHub's example payloads

# A repo R whose root commit (ROOT) has README and an empty .adlc/tickets/; the cases write the store
# on main with tk, commit it with main_commit and point origin/main at it.
setup() {
  fakegh_setup
  export FAKE_GH_REPO="$FREPO" GITHUB_REPOSITORY="$FREPO"
  printf '{"labels":[],"issues":[],"pulls":[],"collaborators":["dev-box-owner"]}\n' >"$FAKE_GH_ISSUES"
  R="$WORLD/r"
  git init -q -b main "$R"
  git -C "$R" config user.name t; git -C "$R" config user.email t@t.invalid
  mkdir -p "$R/.adlc/tickets"; echo base >"$R/README.md"; : >"$R/.adlc/tickets/.keep"
  git -C "$R" add -A; git -C "$R" commit -qm root
  ROOT="$(git -C "$R" rev-parse HEAD)"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH GH_TOKEN
}
# tk <id> <completed true|false> [child...]: write ticket <id> into R's work tree, an edge to each child
# (so <id> is a parent of each child). The file name is the store's: <slug>--<sha256 of the id>.json.
tk() {
  local id="$1" done="$2" slug hex; shift 2
  slug="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
  hex="$(printf '%s' "$id" | sha256sum | cut -d' ' -f1)"
  jq -n --arg id "$id" --argjson c "$done" \
    '{id: $id, completed: $c, title: $id, body: "weight: light\ntier: 0\n\nprose", edges: [$ARGS.positional[] | {to: .}]}' \
    --args "$@" >"$R/.adlc/tickets/$slug--$hex.json"
}
main_commit() {  # main_commit <msg>: commit R's work tree on main; prints the sha
  git -C "$R" checkout -q main
  git -C "$R" add -A; git -C "$R" commit -qm "$1"
  git -C "$R" rev-parse HEAD
}
origin() { git -C "$R" update-ref refs/remotes/origin/main "$1"; }
# work <id>: a ticket branch ticket/<id>/dev-box from BASE with one commit (trailer Ticket: <id>);
# prints its sha and leaves R on main.
work() {
  git -C "$R" checkout -q -B "ticket/$1/dev-box" "$BASE"
  mkdir -p "$R/sim"; echo "$1" >>"$R/sim/$1.txt"; git -C "$R" add -A
  git -C "$R" commit -qm "$(printf 'work on %s\n\nTicket: %s' "$1" "$1")"
  git -C "$R" rev-parse HEAD
  git -C "$R" checkout -q main
}
# pr_event <head-sha> <head-ref> <body> [assoc]: GitHub's example pull_request payload with this world's
# base (BASE, branch main), head, ref, body and association.
pr_event() {
  jq --arg b "$BASE" --arg h "$1" --arg r "$2" --arg body "$3" --arg a "${4:-OWNER}" --arg hr "$FREPO" \
    '.pull_request.base.sha = $b | .pull_request.base.ref = "main" | .pull_request.head.sha = $h | .pull_request.head.ref = $r
     | .pull_request.body = $body | .pull_request.author_association = $a | .pull_request.head.repo.full_name = $hr' \
    "$EV/pull_request-opened.json" >"$WORLD/event.json"
  export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$WORLD/event.json"
}
# mg_event <ticket-id> <head-sha>: the merge queue's group for PR 104 (GitHub's example merge_group
# payload): a merge of the head onto BASE, and the fake's PR 104 with head ref ticket/<id>/dev-box.
mg_event() {
  local g
  g="$(git -C "$R" commit-tree "$2^{tree}" -p "$BASE" -p "$2" -m "Merge pull request #104 from ticket/$1/dev-box")"
  jq --arg b "$BASE" --arg g "$g" '.merge_group.base_sha = $b | .merge_group.head_sha = $g' \
    "$EV/merge_group-checks_requested.json" >"$WORLD/event.json"
  jq --arg id "$1" --arg h "$2" '.pulls = [{number: 104, headRefName: "ticket/\($id)/dev-box", headRefOid: $h,
      baseRefName: "main", state: "OPEN", title: $id, body: "Ticket: \($id)\nNode: dev-box", author: {login: "dev-box-owner"}}]' \
    "$FAKE_GH_ISSUES" >"$WORLD/s" && mv "$WORLD/s" "$FAKE_GH_ISSUES"
  export GITHUB_EVENT_NAME=merge_group GITHUB_EVENT_PATH="$WORLD/event.json" GH_TOKEN=ghs_readonly
}
dc() {  # dc [flags]: run depends-check.sh in R; OUT (stdout), ERR (stderr), RC
  RC=0
  OUT="$(cd "$R" && "$DC" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
field() { jq -r "$1" <<<"$OUT"; }
has() { /usr/bin/grep -qF -- "$1" <<<"$ERR"; }
hasnt() { ! /usr/bin/grep -qF -- "$1" <<<"$ERR"; }

case_no_parents() {
  setup
  tk T-c false; tk T-other false
  BASE="$(main_commit store)"; origin "$BASE"
  pr_event "$(work T-c)" ticket/T-c/dev-box 'Ticket: T-c'
  dc
  check "exit 0" eq "$RC" 0
  check "stdout: ticket, store, base, no parents, nothing waiting, no cycle, pass" \
    eq "$OUT" "{\"ticket\":\"T-c\",\"store\":\"$BASE\",\"base\":\"$BASE\",\"parents\":[],\"waiting\":[],\"cycle\":false,\"result\":\"pass\"}"
  check "stderr: has no parents" has "depends-check: pass: T-c has no parents in the store at ${BASE:0:12}"
  check "stderr: the base's copy of the gate ran, class ticket" has "depends-check: ticket gate from $REPO_ROOT on"
}

case_open_parent() {
  setup
  tk T-p false T-c; tk T-c false
  BASE="$(main_commit store)"; origin "$BASE"
  pr_event "$(work T-c)" ticket/T-c/dev-box 'Ticket: T-c'
  dc
  check "exit 2 (held)" eq "$RC" 2
  check "result held, waiting [T-p]" eq "$(field '[.result, (.waiting | join(","))] | join(" ")')" "held T-p"
  check "parents [{T-p, open}]" eq "$(field '.parents | tojson')" '[{"id":"T-p","completed":false}]'
  check "stderr names the parent" has "depends-check: HELD: T-c waits on parent T-p (open in the store at ${BASE:0:12})"
  check "no cycle" eq "$(field .cycle)" false
  # Two parents, one completed: only the open one waits, and only it is named.
  tk T-q true T-c
  BASE="$(main_commit "T-q completes")"; origin "$BASE"
  pr_event "$(work T-c)" ticket/T-c/dev-box 'Ticket: T-c'
  dc
  check "two parents, one open: exit 2, waiting [T-p] only" eq "$RC:$(field '.waiting | join(",")')" 2:T-p
  check "  both parents listed with their state" eq "$(field '.parents | sort_by(.id) | map("\(.id)=\(.completed)") | join(",")')" \
    "T-p=false,T-q=true"
  check "  stderr does not hold on T-q" hasnt "waits on parent T-q"
}

case_completed_parent() {
  setup
  tk T-p true T-c; tk T-q true T-c; tk T-c false
  BASE="$(main_commit store)"; origin "$BASE"
  pr_event "$(work T-c)" ticket/T-c/dev-box 'Ticket: T-c'
  dc
  check "exit 0" eq "$RC" 0
  check "result pass, nothing waiting, both parents completed" \
    eq "$(field '[.result, (.waiting | length), (.parents | sort_by(.id) | map("\(.id)=\(.completed)") | join(","))] | join(" ")')" \
       "pass 0 T-p=true,T-q=true"
  check "stderr: every parent is completed" has "waits on nothing: every parent is completed"
  check "stderr: no HELD line" hasnt "HELD"
}

case_body_ignored() {
  setup
  tk T-p false T-c; tk T-c false; tk T-free false
  BASE="$(main_commit store)"; origin "$BASE"
  # A body inventing a parent, on a ticket with none.
  pr_event "$(work T-free)" ticket/T-free/dev-box $'Ticket: T-free\nDepends-on: T-x\nDepends-on: T-p'
  dc
  check "an invented Depends-on: holds nothing (exit 0, pass, no parents)" \
    eq "$RC:$(field '[.result, (.parents | length)] | join(" ")')" "0:pass 0"
  # A body dropping the real open parent.
  pr_event "$(work T-c)" ticket/T-c/dev-box $'Ticket: T-c\nNode: dev-box'
  dc
  check "a body with no Depends-on: still holds on T-p" eq "$RC:$(field '.waiting | join(",")')" 2:T-p
  # A body that says the parent is done.
  pr_event "$(work T-c)" ticket/T-c/dev-box $'Ticket: T-c\nDepends-on: none\nDepends-on: T-p (completed)'
  dc
  check "a body claiming the parent is completed still holds" eq "$RC:$(field '.waiting | join(",")')" 2:T-p
  check "  naming it" has "HELD: T-c waits on parent T-p"
}

case_merge_group() {
  setup
  local h pr_out
  tk T-p false T-c; tk T-c false
  BASE="$(main_commit store)"; origin "$BASE"
  h="$(work T-c)"
  pr_event "$h" ticket/T-c/dev-box 'Ticket: T-c'
  dc; pr_out="$OUT"
  check "pull_request: held" eq "$RC" 2
  mg_event T-c "$h"
  dc
  check "merge_group: held too (exit 2)" eq "$RC" 2
  check "  the same stdout as pull_request" eq "$OUT" "$pr_out"
  check "  stderr names the parent" has "HELD: T-c waits on parent T-p"
  check "  the ticket came from PR 104 (one gh read)" eq "$(jq -c . "$FAKE_GH_LOG")" "[\"api\",\"repos/$FREPO/pulls/104\"]"
  # The parent completed: both events pass, with the same stdout.
  tk T-p true T-c
  BASE="$(main_commit "T-p completes")"; origin "$BASE"
  h="$(work T-c)"
  pr_event "$h" ticket/T-c/dev-box 'Ticket: T-c'
  dc; pr_out="$OUT"
  check "pull_request, parent completed: pass" eq "$RC:$(field .result)" 0:pass
  mg_event T-c "$h"
  dc
  check "merge_group, parent completed: pass, the same stdout" eq "$RC:$OUT" "0:$pr_out"
}

case_unknown_ticket() {
  setup
  tk T-p false T-c; tk T-c false; tk T-done true
  BASE="$(main_commit store)"; origin "$BASE"
  pr_event "$(work T-nope)" ticket/T-nope/dev-box 'Ticket: T-nope'
  dc
  check "a ticket not in the store is refused (exit 2, no stdout)" eq "$RC:$OUT" 2:
  check "  saying so" has "depends-check: ticket T-nope is not in the store at ${BASE:0:12}"
  pr_event "$(work T-done)" ticket/T-done/dev-box 'Ticket: T-done'
  dc
  check "a ticket already completed in the store is refused (exit 2, no stdout)" eq "$RC:$OUT" 2:
  check "  saying so" has "ticket T-done is completed in the store at ${BASE:0:12}: nothing to merge"
}

case_side_branch_parent() {
  setup
  local h
  tk T-p false T-c; tk T-c false
  BASE="$(main_commit store)"; origin "$BASE"
  # The parent's own branch completes it, but it never merged.
  git -C "$R" checkout -q -B ticket/T-p/other "$BASE"; tk T-p true T-c; git -C "$R" commit -qam "T-p completes on its branch"
  git -C "$R" update-ref refs/remotes/origin/ticket/T-p/other HEAD
  git -C "$R" checkout -q main
  pr_event "$(work T-c)" ticket/T-c/dev-box 'Ticket: T-c'
  dc
  check "a parent completed only on its own branch still holds" eq "$RC:$(field '[.store, (.waiting | join(","))] | join(" ")')" "2:$BASE T-p"
  # The PR's own head marks the parent completed: the head's store is never read.
  git -C "$R" checkout -q ticket/T-c/dev-box; tk T-p true T-c; git -C "$R" commit -qam "$(printf 'mark parent\n\nTicket: T-c')"
  h="$(git -C "$R" rev-parse HEAD)"; git -C "$R" checkout -q main
  pr_event "$h" ticket/T-c/dev-box 'Ticket: T-c'
  dc
  check "a head that completes its parent in its own store still holds" eq "$RC:$(field '.waiting | join(",")')" 2:T-p
  check "  named on stderr" has "HELD: T-c waits on parent T-p (open in the store at ${BASE:0:12})"
}

case_base_moved() {
  setup
  local m
  tk T-p false T-c; tk T-c false
  BASE="$(main_commit store)"; origin "$BASE"
  pr_event "$(work T-c)" ticket/T-c/dev-box 'Ticket: T-c'
  dc
  check "the first run: held at base" eq "$RC:$(field .store)" "2:$BASE"
  # The parent merges: main moves on, the PR's event (and its base sha) stays as it was.
  tk T-p true T-c
  m="$(main_commit "T-p completes on main")"; origin "$m"
  dc
  check "the re-run reads origin/main, a descendant of base: pass" eq "$RC:$(field .result)" 0:pass
  check "  .store is origin/main's sha, .base the event's" eq "$(field '[.store, .base] | join(" ")')" "$m $BASE"
  check "  the parent is completed" eq "$(field '.parents | tojson')" '[{"id":"T-p","completed":true}]'
  check "  stderr says the base branch moved" \
    has "depends-check: the base branch moved: reading the store at origin/main ${m:0:12}, a descendant of base ${BASE:0:12}"
}

case_diverged_origin() {
  setup
  local s
  tk T-p false T-c; tk T-c false
  BASE="$(main_commit store)"; origin "$BASE"
  # origin/main somewhere that does not contain BASE, where the parent is completed.
  git -C "$R" checkout -q -B elsewhere "$ROOT"; tk T-p true T-c; tk T-c false
  git -C "$R" add -A; git -C "$R" commit -qm "a store not descended from base"
  s="$(git -C "$R" rev-parse HEAD)"; git -C "$R" checkout -q main
  origin "$s"
  pr_event "$(work T-c)" ticket/T-c/dev-box 'Ticket: T-c'
  dc
  check "a diverged origin/main is ignored: held" eq "$RC:$(field '.waiting | join(",")')" 2:T-p
  check "  .store is the base" eq "$(field .store)" "$BASE"
  check "  stderr does not claim the base moved" hasnt "the base branch moved"
  # An origin/main behind the base (an ancestor) is not read either.
  origin "$ROOT"
  dc
  check "an origin/main behind base is ignored: held at base" eq "$RC:$(field .store)" "2:$BASE"
}

case_human_pr() {
  setup
  local h
  tk T-p false T-c; tk T-c false
  BASE="$(main_commit store)"; origin "$BASE"
  git -C "$R" checkout -q -B docs/x "$BASE"; echo more >>"$R/README.md"; git -C "$R" commit -qam "docs"
  h="$(git -C "$R" rev-parse HEAD)"; git -C "$R" checkout -q main
  pr_event "$h" docs/x $'a human PR\nDepends-on: T-p'
  dc
  check "a human PR passes (exit 0)" eq "$RC" 0
  check "  stdout: class human, pass" eq "$OUT" '{"class":"human","result":"pass"}'
  check "  stderr: nothing to hold" has "depends-check: pass: class human: no ticket, nothing to hold"
}

case_cycle() {
  setup
  tk T-a false T-b; tk T-b false T-a
  BASE="$(main_commit "a hand-made cycle")"; origin "$BASE"
  pr_event "$(work T-a)" ticket/T-a/dev-box 'Ticket: T-a'
  dc
  check "a cycle: exit 2, held, cycle true" eq "$RC:$(field '[.result, .cycle] | join(" ")')" "2:held true"
  check "  stderr says cycle" has "depends-check: HELD: T-a is on an edge cycle"
  check "  and names the open parent" has "HELD: T-a waits on parent T-b"
  # The parent on the cycle completed: nothing waits, the cycle alone holds.
  tk T-b true T-a
  BASE="$(main_commit "T-b completed")"; origin "$BASE"
  pr_event "$(work T-a)" ticket/T-a/dev-box 'Ticket: T-a'
  dc
  check "a cycle through a completed parent: still held (exit 2), nothing waiting" \
    eq "$RC:$(field '[.result, .cycle, (.waiting | length)] | join(" ")')" "2:held true 0"
  check "  stderr says cycle" has "is on an edge cycle"
  # A longer cycle through a grandparent: T-a <- T-b <- T-g <- T-a.
  tk T-a false T-g; tk T-g true T-b; tk T-b true T-a
  BASE="$(main_commit "a three-cycle")"; origin "$BASE"
  pr_event "$(work T-a)" ticket/T-a/dev-box 'Ticket: T-a'
  dc
  check "a three-ticket cycle: held, cycle true" eq "$RC:$(field .cycle)" 2:true
  # A cycle among the ancestors that does not come back to the ticket is not the ticket's cycle.
  tk T-a false; tk T-b true T-a T-g; tk T-g true T-b
  BASE="$(main_commit "a cycle above T-a")"; origin "$BASE"
  pr_event "$(work T-a)" ticket/T-a/dev-box 'Ticket: T-a'
  dc
  check "a cycle above the ticket (not through it): cycle false, pass" eq "$RC:$(field '[.cycle, .result] | join(" ")')" "0:false pass"
}

case_corrupt_store() {
  setup
  local bad hex
  tk T-p true T-c; tk T-c false
  hex="$(printf 'broken' | sha256sum | cut -d' ' -f1)"
  bad="$R/.adlc/tickets/broken--$hex.json"
  echo '{"id": "T-broken", "completed": ' >"$bad"
  BASE="$(main_commit "a corrupt ticket")"; origin "$BASE"
  pr_event "$(work T-c)" ticket/T-c/dev-box 'Ticket: T-c'
  dc
  check "a ticket file that is not JSON: exit 1, no stdout" eq "$RC:$OUT" 1:
  check "  naming the file" has "broken--$hex.json at ${BASE:0:12} is not a ticket (fail closed)"
  # JSON, but not a ticket object.
  echo '[1, 2]' >"$bad"
  BASE="$(main_commit "an array")"; origin "$BASE"
  pr_event "$(work T-c)" ticket/T-c/dev-box 'Ticket: T-c'
  dc
  check "a ticket file that is an array: exit 1" eq "$RC:$OUT" 1:
  # A file outside the store's name pattern is not read at all.
  rm "$bad"; echo 'not json' >"$R/.adlc/tickets/README.txt"
  BASE="$(main_commit "a non-ticket file")"; origin "$BASE"
  pr_event "$(work T-c)" ticket/T-c/dev-box 'Ticket: T-c'
  dc
  check "a non-ticket file name in .adlc/tickets/ is skipped: pass" eq "$RC:$(field .result)" 0:pass
}

case_node_mode() {
  setup
  local h ci m
  tk T-p false T-c; tk T-c false
  BASE="$(main_commit store)"; origin "$BASE"
  h="$(work T-c)"
  pr_event "$h" ticket/T-c/dev-box 'Ticket: T-c'
  dc; ci="$RC:$OUT"
  check "CI: held" eq "$RC" 2
  # labeler.sh's call: a checkout of main, no event, --ticket --base <main>.
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  git -C "$R" checkout -q main
  dc --ticket T-c --base "$BASE"
  check "node (--ticket --base): the same exit and stdout as CI" eq "$RC:$OUT" "$ci"
  check "  stderr names the parent" has "HELD: T-c waits on parent T-p"
  check "  the context is the node's" has '"event":"node"'
  # The parent merges: CI's re-run (the old event) and the node (--base <new main>) agree on pass.
  tk T-p true T-c
  m="$(main_commit "T-p completes")"; origin "$m"
  pr_event "$h" ticket/T-c/dev-box 'Ticket: T-c'
  dc; ci="$RC:$(field '[.store, .result, (.parents | tojson)] | join(" ")')"
  check "CI re-run after the merge: pass at origin/main" eq "$ci" "0:$m pass [{\"id\":\"T-p\",\"completed\":true}]"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  dc --ticket T-c --base "$m"
  check "node --base <main>: the same answer" eq "$RC:$(field '[.store, .result, (.parents | tojson)] | join(" ")')" "$ci"
  # The node with the old base sees main's tip too (origin/main descends from it).
  dc --ticket T-c --base "$BASE"
  check "node --base <old base>: reads origin/main, pass" eq "$RC:$(field '[.store, .base, .result] | join(" ")')" "0:$m $BASE pass"
  dc --ticket T-nope --base "$m"
  check "node: an unknown ticket is refused (exit 2)" eq "$RC:$OUT" 2:
}

for c in no-parents open-parent completed-parent body-ignored merge-group unknown-ticket side-branch-parent \
         base-moved diverged-origin human-pr cycle corrupt-store node-mode; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
