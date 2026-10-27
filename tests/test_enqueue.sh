#!/usr/bin/env bash
# T28 (specs/factory-step3-v1 TB9; merge:G1 G4 G7 G13, ci:G19 G21): factory/bin/enqueue.sh, the merge
# queue, run from a clone of the fake origin against the fake gh.
#   - pick: nothing (no gh call, no tier-order) while factory/HALT is on origin/main; the mode is
#     GraphQL mergeQueue's answer (null → serial, an object → native) and an unreadable answer (an
#     unknown repo, an HTTP error) is exit 1 before tier-order runs;
#   - pick: tier-order.sh --order --base <origin/main> is asked for the candidates (a stub here, and
#     once the real script); no row → `empty`; a row is skipped (named on stderr) when the PR is not
#     open, targets another branch than main, a draft, labeled `autorebase`, its head moved since the row, or its run's `tier-order`
#     job is red or missing; only the first eligible row is acted on, the rest are never read;
#     tier-order failing is exit 1;
#   - serial: every factory-queue/* branch on origin is deleted first, also when no row is eligible
#     (--apply; kept on a dry run); the
#     merge commit S (parents [main, PR head], the merge's tree, author and committer
#     github-actions[bot], subject `Merge pull request #N from <owner>/<head ref>`) is pushed to
#     factory-queue/pr-N and GITHUB_OUTPUT gets queue, pr, base, head; the dry run (the default)
#     pushes nothing and writes no output; refs/pull/N/head not the row's head → head-moved; a
#     conflict → eject.sh --reason conflict (dry: would-eject; --apply: the ledger line on main, the
#     PR labeled autorebase and closed, the Issue ready + rebase-strike), nothing built;
#   - native: an empty queue → enqueuePullRequest with the head (dry: would-enqueue, nothing
#     enqueued); a busy queue → queue-busy; factory-queue/* branches are never touched;
#   - land success: origin main becomes S by a plain push, the queue branch is deleted, merged_mark
#     reported (false as the fake answers, true when GitHub marks the PR merged, null when the PR
#     cannot be read back); main moved since base → main-moved (also when it moves between the check
#     and the push: the push is never forced); the PR pushed again, closed or labeled autorebase →
#     pr-changed; the queue branch not S, or S not the queue commit's shape (identity, subject,
#     parents) → exit 1; HALT → halted; --dry-run → would-land, nothing written;
#   - land failure → eject.sh --reason red-queue-run (record with the queue branch), the queue branch
#     deleted; a queue commit this checkout cannot read → exit 1, nothing ejected; HALT → halted,
#     nothing ejected; cancelled / skipped → not-landed, nothing read or written; bad arguments → exit 1.
# Offline; every repo is a temp dir, gh is the fake (pulls, runs, merge_queue in FAKE_GH_ISSUES).
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

BOT='github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'
WRITES='(.[0] == "pr" and (.[1] == "edit" or .[1] == "close")) or (.[0] == "label" and .[1] == "create")
  or (.[0] == "issue" and .[1] == "edit") or (.[0] == "api" and any(.[]; test("enqueuePullRequest")))'

hex() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }
st() {  # st <jq program> [jq args...]: rewrite the fake's state (FAKE_GH_ISSUES)
  local tmp; tmp="$(mktemp)"
  jq "${@:2}" "$1" "$FAKE_GH_ISSUES" >"$tmp" && mv "$tmp" "$FAKE_GH_ISSUES"
}
sj() { jq -c "$1" "$FAKE_GH_ISSUES"; }                     # sj <jq>: read the fake's state
vd() { jq -c "$1" <<<"$OUT" 2>/dev/null || printf 'not json: [%s]\n' "$OUT"; }   # vd <jq>: of the verdict
oref() { fakegh_ref "$1"; }
qbranches() { git -C "$FAKE_GH_GIT" for-each-ref --format='%(refname:short)' refs/heads/factory-queue/ | tr '\n' ' '; }
has() { grep -qF -- "$2" <<<"$1" || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }

# setup: the fake origin (FAKE_GH_GIT) with main holding a.txt (five lines); W, a clone to author
# commits in; C, the clone enqueue.sh runs in; SB, a bin dir with enqueue.sh, eject.sh and lib/ (the
# real ones) beside a stub tier-order.sh that logs its arguments and prints $STUB_ROWS (or exits
# $STUB_RC). The fake has no PRs, no runs and no merge queue (serial).
setup() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH GITHUB_REPOSITORY GH_TOKEN SHIM_MODE STUB_RC
  st '. + {pulls: [], runs: []}'
  W="$WORLD/w"
  git clone -q -b main "$FAKE_GH_GIT" "$W" 2>/dev/null
  git -C "$W" config user.name t; git -C "$W" config user.email t@t.invalid
  printf 'one\ntwo\nthree\nfour\nfive\n' >"$W/a.txt"
  git -C "$W" add -A; git -C "$W" commit -qm "main: a.txt"; git -C "$W" push -q origin main
  SB="$WORLD/bin"; mkdir -p "$SB"
  ln -s "$BIN/enqueue.sh" "$BIN/eject.sh" "$BIN/lib" "$SB/"
  command cat >"$SB/tier-order.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
[ "${STUB_RC:-0}" = 0 ] || { echo "tier-order: stub failing" >&2; exit "$STUB_RC"; }
command cat "$STUB_ROWS"
EOF
  chmod +x "$SB/tier-order.sh"
  export STUB_ROWS="$WORLD/rows" STUB_LOG="$WORLD/stub.log" GITHUB_OUTPUT="$WORLD/gh-output"
  : >"$STUB_ROWS"; : >"$STUB_LOG"; : >"$GITHUB_OUTPUT"
  C="$WORLD/c"
  git clone -q -b main "$FAKE_GH_GIT" "$C" 2>/dev/null
  shim
}
# shim: $WORLD/shim/gh, the fake gh with one hook on `gh api repos/test/repo/pulls/7` (SHIM_MODE):
#   merge  once origin main is $SHIM_S, GitHub's indirect merge: the PR MERGED, .merged += {7, S}
#   fail   once origin main is $SHIM_S, the read fails
#   race   the first read moves origin main on by one commit (another writer between check and push)
shim() {
  mkdir -p "$WORLD/shim"
  command cat >"$WORLD/shim/gh" <<EOF
#!/usr/bin/env bash
FAKE="$FAKES_DIR/gh"
EOF
  command cat >>"$WORLD/shim/gh" <<'EOF'
if [ "${1:-}" = api ] && [ "${2:-}" = repos/test/repo/pulls/7 ]; then
  m="$(git -C "$FAKE_GH_GIT" rev-parse refs/heads/main)"
  case "${SHIM_MODE:-}" in
    merge) if [ "$m" = "$SHIM_S" ]; then
             t="$(mktemp)"; jq --arg s "$SHIM_S" '(.pulls[] | select(.number == 7)).state = "MERGED"
               | .merged = ((.merged // []) + [{pr: 7, sha: $s}])' "$FAKE_GH_ISSUES" >"$t" && mv "$t" "$FAKE_GH_ISSUES"
           fi ;;
    fail)  if [ "$m" = "$SHIM_S" ]; then echo 'gh: Server Error (HTTP 502)' >&2; exit 1; fi ;;
    race)  if [ ! -e "$FAKE_GH_GIT/raced" ]; then
             : >"$FAKE_GH_GIT/raced"
             r="$(GIT_AUTHOR_NAME=racer GIT_AUTHOR_EMAIL=racer@t.invalid GIT_COMMITTER_NAME=racer GIT_COMMITTER_EMAIL=racer@t.invalid \
                   git -C "$FAKE_GH_GIT" commit-tree "$m^{tree}" -p "$m" -m "racer: another writer")"
             git -C "$FAKE_GH_GIT" update-ref refs/heads/main "$r" "$m"
             printf '%s\n' "$r" >"$FAKE_GH_GIT/racer"
           fi ;;
  esac
fi
exec "$FAKE" "$@"
EOF
  chmod +x "$WORLD/shim/gh"
}

# wmain <line> <text> <message>: line <line> of a.txt set to <text> on origin main (from W); prints it.
wmain() {
  git -C "$W" fetch -q origin main; git -C "$W" checkout -q -B main origin/main
  sed -i "$1s/.*/$2/" "$W/a.txt"
  git -C "$W" commit -qam "$3"; git -C "$W" push -q origin main
  git -C "$W" rev-parse HEAD
}
# wfile <path> <content> <message>: a file added on origin main (from W); prints the new main.
wfile() {
  git -C "$W" fetch -q origin main; git -C "$W" checkout -q -B main origin/main
  mkdir -p "$(dirname "$W/$1")"; printf '%s\n' "$2" >"$W/$1"
  git -C "$W" add -A; git -C "$W" commit -qm "$3"; git -C "$W" push -q origin main
  git -C "$W" rev-parse HEAD
}
# mkpr <n> <ticket> <line> <text> [extra pull json]: ticket/<ticket>/node-<n> from origin main with
# line <line> of a.txt set to <text>, pushed with refs/pull/<n>/head, and an open PR entry for it;
# prints the head.
mkpr() {
  local n="$1" t="$2" b="ticket/$2/node-$1" h
  git -C "$W" fetch -q origin main; git -C "$W" checkout -q -B "$b" origin/main
  sed -i "$3s/.*/$4/" "$W/a.txt"
  git -C "$W" commit -qam "$(printf '%s: work\n\nTicket: %s' "$t" "$t")"
  git -C "$W" push -q origin "$b"
  h="$(git -C "$W" rev-parse HEAD)"
  git -C "$FAKE_GH_GIT" update-ref "refs/pull/$n/head" "$h"
  git -C "$W" checkout -q main
  addpull "$n" "$b" "$h" "${5:-}"
  printf '%s\n' "$h"
}
# addpull <n> <head ref> <head sha> [extra json]: an open PR entry (no labels, no draft).
addpull() {
  st '.pulls += [{number: $n, headRefName: $r, headRefOid: $h, state: "OPEN", isDraft: false, labels: [],
                  createdAt: "2026-10-20T00:00:00Z"} + ($x | if . == "" then {} else fromjson end)]' \
    --argjson n "$1" --arg r "$2" --arg h "$3" --arg x "${4:-}"
}
# addrun <id> <head> <tier-order conclusion|in_progress|absent>: a gates run with a green `build` job.
addrun() {
  st '.runs += [{id: $id, name: "gates", path: ".github/workflows/gates.yml", event: "pull_request", head_sha: $h,
                 head_branch: "x", created_at: "2026-10-27T07:00:00Z", run_attempt: 1,
                 jobs: ([{id: ($id * 100 + 1), name: "build", status: "completed", conclusion: "success",
                          started_at: "2026-10-27T07:00:00Z", completed_at: "2026-10-27T07:10:00Z"}]
                        + (if $c == "absent" then []
                           elif $c == "in_progress" then [{id: ($id * 100 + 2), name: "tier-order", status: "in_progress",
                             conclusion: null, started_at: "2026-10-27T07:00:00Z", completed_at: null}]
                           else [{id: ($id * 100 + 2), name: "tier-order", status: "completed", conclusion: $c,
                             started_at: "2026-10-27T07:00:00Z", completed_at: "2026-10-27T07:10:00Z"}] end))}]' \
    --argjson id "$1" --arg h "$2" --arg c "$3"
}
# row <n> <head> <run> [tier]: one --order line for the stub tier-order.sh.
row() {
  jq -cn --argjson n "$1" --arg h "$2" --argjson r "$3" --argjson t "${4:-1}" \
    '{pr: $n, ticket: "T\($n)", tier: $t, head: $h, approved: true, green: true,
      first_green: "2026-10-27T07:10:00Z", run: $r}' >>"$STUB_ROWS"
}
enq() {  # enq <args>: enqueue.sh (stub tier-order) in C; OUT, ERR, RC
  RC=0
  OUT="$(cd "$C" && "$SB/enqueue.sh" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
enq_real() {  # enq_real <args>: the repo's enqueue.sh with the real tier-order.sh
  RC=0
  OUT="$(cd "$C" && "$BIN/enqueue.sh" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
# build7: PR #7 (T7, line 1) with a green run 70 as the only row, then main moves (line 5), then
# `pick --apply`; sets H (the PR head), M (main), S (the queue commit).
build7() {
  H="$(mkpr 7 T7 1 pr-one)"; addrun 70 "$H" success; row 7 "$H" 70
  M="$(wmain 5 main-five "main: five")"
  enq pick --apply
  S="$(jq -r .head <<<"$OUT")"
  check "build7: built" eq "$RC:$(vd .result):$(oref refs/heads/factory-queue/pr-7)" "0:\"built\":$S"
  : >"$FAKE_GH_LOG"
}
land7() { enq land --pr 7 --base "$M" --queue factory-queue/pr-7 --head "${1:-$S}" --result "${2:-success}" "${@:3}"; }

# ---------------------------------------------------------------- pick

case_halt() {
  setup
  local h m; h="$(mkpr 7 T7 1 pr-one)"; addrun 70 "$h" success; row 7 "$h" 70
  git -C "$FAKE_GH_GIT" update-ref refs/heads/factory-queue/pr-3 "$h"
  m="$(wfile factory/HALT 'halt: test' 'halt')"
  enq pick --apply
  check "HALT on origin/main: exit 0, halted, mode null, main named" eq "$RC:$OUT" "0:{\"mode\":null,\"result\":\"halted\",\"main\":\"$m\"}"
  check "  no gh call, tier-order never asked" eq "$(wc -l <"$FAKE_GH_LOG" | tr -d ' '):$(wc -l <"$STUB_LOG" | tr -d ' ')" 0:0
  check "  nothing pushed or deleted, no output" eq "$(qbranches)|$(command cat "$GITHUB_OUTPUT")" "factory-queue/pr-3 |"
}

case_mode() {
  setup
  local h; h="$(mkpr 7 T7 1 pr-one)"; addrun 70 "$h" success; row 7 "$h" 70
  enq pick --repo other/repo
  check "mergeQueue unreadable (GraphQL: no such repo): exit 1, no verdict" eq "$RC:$OUT" 1:
  check "  naming it" has "$ERR" "cannot read the merge queue of other/repo"
  check "  tier-order never asked" eq "$(wc -l <"$STUB_LOG" | tr -d ' ')" 0
  FAKE_GH_FAIL='^api graphql' enq pick
  check "mergeQueue read fails (HTTP 500): exit 1, no verdict, tier-order never asked" \
    eq "$RC:$OUT:$(wc -l <"$STUB_LOG" | tr -d ' ')" 1::0
  enq pick
  check "mergeQueue null: serial" eq "$RC:$(vd .mode)" '0:"serial"'
  check "  tier-order asked for --order at origin/main, this repo" \
    eq "$(command cat "$STUB_LOG")" "--order --base $(oref refs/heads/main) --repo test/repo"
  st '.merge_queue = {id: "MQ_1", entries: []}'
  enq pick
  check "mergeQueue an object: native" eq "$RC:$(vd .mode)" '0:"native"'
  STUB_RC=1 enq pick
  check "tier-order --order failing: exit 1, no verdict" eq "$RC:$OUT" 1:
  check "  naming it" has "$ERR" "tier-order.sh --order failed"
  check "unknown command: exit 1" eq "$(cd "$C" && "$SB/enqueue.sh" frob >/dev/null 2>&1; echo $?)" 1
  check "unknown flag: exit 1" eq "$(cd "$C" && "$SB/enqueue.sh" pick --bogus >/dev/null 2>&1; echo $?)" 1
}

case_empty() {
  setup
  local m; m="$(oref refs/heads/main)"
  enq pick --apply
  check "no candidate: exit 0, empty, ordered []" eq "$RC:$OUT" "0:{\"mode\":\"serial\",\"result\":\"empty\",\"main\":\"$m\",\"ordered\":[]}"
  check "  no output for enqueue.yml (no queue: land is skipped)" eq "$(command cat "$GITHUB_OUTPUT")" ""
  check "  no write" eq "$(fakegh_calls "$WRITES")" 0
}

case_skips() {
  setup
  local h7 h8 x; x="$(hex moved)"
  addpull 1 ticket/T1/node-1 "$(hex h1)" '{"isDraft": true}';             addrun 10 "$(hex h1)" success; row 1 "$(hex h1)" 10
  addpull 2 ticket/T2/node-2 "$(hex h2)" '{"labels": [{"name": "AutoRebase"}]}'; addrun 20 "$(hex h2)" success; row 2 "$(hex h2)" 20
  addpull 3 ticket/T3/node-3 "$x";                                          addrun 30 "$(hex h3)" success; row 3 "$(hex h3)" 30
  addpull 4 ticket/T4/node-4 "$(hex h4)";                                   addrun 40 "$(hex h4)" failure; row 4 "$(hex h4)" 40
  addpull 5 ticket/T5/node-5 "$(hex h5)";                                   addrun 50 "$(hex h5)" absent;  row 5 "$(hex h5)" 50
  addpull 6 ticket/T6/node-6 "$(hex h6)" '{"state": "CLOSED"}';            addrun 60 "$(hex h6)" success; row 6 "$(hex h6)" 60
  addpull 9 ticket/T9/node-9 "$(hex h9)";                                   addrun 90 "$(hex h9)" in_progress; row 9 "$(hex h9)" 90
  addpull 10 ticket/T10/node-10 "$(hex h10)" '{"baseRefName": "release/v1"}'; addrun 100 "$(hex h10)" success; row 10 "$(hex h10)" 100
  h7="$(mkpr 7 T7 1 pr-one)"; addrun 70 "$h7" success; row 7 "$h7" 70
  h8="$(mkpr 8 T8 2 pr-two)"; addrun 80 "$h8" success; row 8 "$h8" 80
  enq pick
  check "the first eligible row is #7: would-build" eq "$RC:$(vd '[.mode, .result, .pr, .pr_head]')" "0:[\"serial\",\"would-build\",7,\"$h7\"]"
  check "  skip #1: a draft" has "$ERR" "enqueue: skip #1: a draft"
  check "  skip #2: labeled autorebase (any case)" has "$ERR" "enqueue: skip #2: labeled autorebase"
  check "  skip #3: its head moved" has "$ERR" "enqueue: skip #3: its head moved since its gates run"
  check "  skip #4: tier-order red" has "$ERR" "enqueue: skip #4: its tier-order job (run 40) is not green"
  check "  skip #5: tier-order missing" has "$ERR" "enqueue: skip #5: its tier-order job (run 50) is not green"
  check "  skip #6: not open" has "$ERR" "enqueue: skip #6: not open"
  check "  skip #9: tier-order still running" has "$ERR" "enqueue: skip #9: its tier-order job (run 90) is not green"
  check "  skip #10: targets another branch" has "$ERR" "enqueue: skip #10: it targets release/v1, not main"
  check "  #8 (after the first eligible) is never read" eq "$(fakegh_calls '.[1] == "repos/test/repo/pulls/8" or any(.[]; test("runs/80/"))')" 0
  check "  the jobs of a skipped-by-state PR are never read" eq "$(fakegh_calls 'any(.[]; test("runs/(10|20|30|60)/"))')" 0
  # Only ineligible rows: empty, every row's PR in .ordered.
  : >"$STUB_ROWS"; row 1 "$(hex h1)" 10; row 4 "$(hex h4)" 40; row 6 "$(hex h6)" 60
  enq pick --apply
  check "no eligible row: empty, ordered [1,4,6]" eq "$RC:$(vd '[.result, .ordered]')" '0:["empty",[1,4,6]]'
  check "  nothing on origin, no output" eq "$(qbranches)|$(command cat "$GITHUB_OUTPUT")" "|"
  # A row whose run cannot be read: exit 1, never a guess.
  : >"$STUB_ROWS"; row 7 "$h7" 71
  enq pick
  check "a row's run unknown to the API: exit 1" eq "$RC:$OUT" 1:
  check "  naming the run" has "$ERR" "cannot read the jobs of run 71"
}

case_serial_build() {
  setup
  local h m s p
  git -C "$FAKE_GH_GIT" update-ref refs/heads/factory-queue/pr-3 "$(oref refs/heads/main)"
  git -C "$FAKE_GH_GIT" update-ref refs/heads/factory-queue/old "$(oref refs/heads/main)"
  h="$(mkpr 7 T7 1 pr-one)"; addrun 70 "$h" success; row 7 "$h" 70
  m="$(wmain 5 main-five "main: five")"
  # The dry run first (the default): nothing pushed or deleted, no output.
  enq pick
  check "dry run: would-build, base main, pr_head the PR's" \
    eq "$RC:$(vd '[.mode, .result, .pr, .queue, .base, .pr_head]')" "0:[\"serial\",\"would-build\",7,\"factory-queue/pr-7\",\"$m\",\"$h\"]"
  check "  stale branches kept, nothing pushed" eq "$(qbranches)" "factory-queue/old factory-queue/pr-3 "
  check "  no GITHUB_OUTPUT" eq "$(command cat "$GITHUB_OUTPUT")" ""
  check "  main unchanged" eq "$(oref refs/heads/main)" "$m"
  enq pick --apply
  s="$(jq -r .head <<<"$OUT")"
  check "--apply: built, the verdict" eq "$RC:$OUT" \
    "0:{\"mode\":\"serial\",\"result\":\"built\",\"pr\":7,\"queue\":\"factory-queue/pr-7\",\"base\":\"$m\",\"head\":\"$s\",\"pr_head\":\"$h\"}"
  check "  stale factory-queue/* deleted, factory-queue/pr-7 = S" eq "$(qbranches)|$(oref refs/heads/factory-queue/pr-7)" "factory-queue/pr-7 |$s"
  check "  stderr names the deleted branches" has "$ERR" "enqueue: deleted factory-queue/old"
  p="$(git -C "$FAKE_GH_GIT" rev-list --parents -n1 "$s")"
  check "  S's parents: [main, PR head]" eq "$p" "$s $m $h"
  check "  S's tree: git merge-tree --write-tree main head" eq "$(git -C "$FAKE_GH_GIT" rev-parse "$s^{tree}")" \
    "$(git -C "$FAKE_GH_GIT" merge-tree --write-tree "$m" "$h")"
  check "  the merge holds both sides" eq "$(git -C "$FAKE_GH_GIT" show "$s:a.txt" | tr '\n' ' ')" "pr-one two three four main-five "
  check "  author and committer github-actions[bot]" eq "$(git -C "$FAKE_GH_GIT" log -1 --format='%an <%ae>|%cn <%ce>' "$s")" "$BOT|$BOT"
  check "  the message: exactly the subject post-merge.sh parses" eq "$(git -C "$FAKE_GH_GIT" log -1 --format=%B "$s")" \
    "Merge pull request #7 from test/ticket/T7/node-7"
  check "  GITHUB_OUTPUT: queue, pr, base, head" eq "$(command cat "$GITHUB_OUTPUT")" \
    "queue=factory-queue/pr-7
pr=7
base=$m
head=$s"
  check "  main unchanged, the PR untouched, no gh write" \
    eq "$(oref refs/heads/main):$(sj '.pulls[] | select(.number == 7) | [.state, .labels]'):$(fakegh_calls "$WRITES")" "$m:[\"OPEN\",[]]:0"
  # A PR on the current main (main has not moved): still a two-parent merge commit.
  : >"$GITHUB_OUTPUT"; : >"$STUB_ROWS"
  st '(.pulls[] | select(.number == 7)).state = "CLOSED"'
  h="$(mkpr 8 T8 2 pr-two)"; addrun 80 "$h" success; row 8 "$h" 80
  enq pick --apply
  s="$(jq -r .head <<<"$OUT")"
  check "a PR on main's tip: built, parents [main, head]" eq "$RC:$(vd .result):$(git -C "$FAKE_GH_GIT" rev-list --parents -n1 "$s")" \
    "0:\"built\":$s $m $h"
  check "  the previous queue branch is gone, pr-8 = S" eq "$(qbranches)|$(oref refs/heads/factory-queue/pr-8)" "factory-queue/pr-8 |$s"
}

case_head_moved() {
  setup
  local h; h="$(mkpr 7 T7 1 pr-one)"; addrun 70 "$h" success; row 7 "$h" 70
  git -C "$FAKE_GH_GIT" update-ref refs/pull/7/head "$(oref refs/heads/main)"
  enq pick --apply
  check "refs/pull/7/head is not the row's head: head-moved" eq "$RC:$OUT" '0:{"mode":"serial","result":"head-moved","pr":7}'
  check "  nothing built, no output" eq "$(qbranches)|$(command cat "$GITHUB_OUTPUT")" "|"
}

case_conflict() {
  setup
  local h m e
  fakegh_issue 3 1761300000 in-review 'T7: work' 'Ticket: T7'
  h="$(mkpr 7 T7 2 pr-two)"; addrun 70 "$h" success; row 7 "$h" 70
  m="$(wmain 2 main-two "main: two")"
  enq pick
  check "a conflict, dry run: conflict, eject would-eject" eq "$RC:$(vd '[.mode, .result, .pr, .main, .eject.result]')" \
    "0:[\"serial\",\"conflict\",7,\"$m\",\"would-eject\"]"
  check "  the planned record: reason conflict, base main, head the PR's, no queue, strike 1" \
    eq "$(vd '.eject.record | [.pr, .ticket, .handle, .issue, .reason, .base, .head, .queue, .strike]')" \
    "[7,\"T7\",\"node-7\",3,\"conflict\",\"$m\",\"$h\",null,1]"
  check "  nothing written" eq "$(oref refs/heads/main):$(fakegh_calls "$WRITES"):$(qbranches)" "$m:0:"
  enq pick --apply
  check "--apply: conflict, ejected" eq "$RC:$(vd '[.result, .eject.result, .eject.actions]')" \
    '0:["conflict","ejected",["ledger-append","label-create autorebase","label-create rebase-strike","label-autorebase","close-pr","issue-ready-rebase-strike"]]'
  check "  no queue branch, no output" eq "$(qbranches)|$(command cat "$GITHUB_OUTPUT")" "|"
  check "  the PR closed, labeled autorebase, with a comment" \
    eq "$(sj '[(.pulls[] | select(.number == 7) | .state, [.labels[].name]), (.pr_comments | length)]')" '["CLOSED",["autorebase"],1]'
  check "  the Issue: ready and rebase-strike, in-review gone" eq "$(sj '.issues[] | select(.number == 3) | [.labels[].name]')" '["ready","rebase-strike"]'
  e="$(git -C "$FAKE_GH_GIT" show refs/heads/main:factory/ledger/ejections.jsonl)"
  check "  one ledger line on main: reason conflict, base, head" eq "$(jq -c '[.pr, .reason, .base, .head, .queue, .strike]' <<<"$e")" \
    "[7,\"conflict\",\"$m\",\"$h\",null,1]"
  check "  the ledger commit sits on main, parent the old main" eq "$(git -C "$FAKE_GH_GIT" rev-parse refs/heads/main^)" "$m"
}

case_native() {
  setup
  local h; h="$(mkpr 7 T7 1 pr-one)"; addrun 70 "$h" success; row 7 "$h" 70
  git -C "$FAKE_GH_GIT" update-ref refs/heads/factory-queue/pr-3 "$(oref refs/heads/main)"
  st '.merge_queue = {id: "MQ_1", entries: []}'
  enq pick --dry-run
  check "native, empty queue, dry run: would-enqueue" eq "$RC:$OUT" "0:{\"mode\":\"native\",\"result\":\"would-enqueue\",\"pr\":7,\"head\":\"$h\"}"
  check "  nothing enqueued" eq "$(sj '[.enqueued, .merge_queue.entries]')" '[null,[]]'
  FAKE_GH_FAIL='enqueuePullRequest' enq pick --apply
  check "the enqueuePullRequest call fails: exit 1, no verdict" eq "$RC:$OUT" 1:
  check "  naming it" has "$ERR" "enqueuePullRequest #7 failed"
  enq pick --apply
  check "native, empty queue, --apply: enqueued at position 1" eq "$RC:$OUT" \
    "0:{\"mode\":\"native\",\"result\":\"enqueued\",\"pr\":7,\"head\":\"$h\",\"position\":1}"
  check "  .enqueued holds exactly {7, head}" eq "$(sj .enqueued)" "[{\"pr\":7,\"head\":\"$h\"}]"
  check "  factory-queue/* untouched, nothing built, no output" eq "$(qbranches)|$(command cat "$GITHUB_OUTPUT")" "factory-queue/pr-3 |"
  enq pick --apply
  check "native, queue busy: queue-busy, entries 1" eq "$RC:$OUT" '0:{"mode":"native","result":"queue-busy","pr":7,"entries":1}'
  check "  nothing more enqueued" eq "$(sj '.enqueued | length')" 1
}

# The real tier-order.sh: main holds gates.yml and the store; #5 (tier 1) turned green first, #6 is
# tier 0: #6 goes first. #5's own tier-order job is red (it waits on #6).
case_real_tier_order() {
  setup
  local id h5 h6 jobs
  wfile .github/workflows/gates.yml "$(command cat "$REPO_ROOT/.github/workflows/gates.yml")" "gates" >/dev/null
  for id in T1:1 T0a:0; do
    wfile ".adlc/tickets/t-$(tr 'A-Z' 'a-z' <<<"${id%:*}")--$(printf '%s' "${id%:*}" | sha256sum | cut -d' ' -f1).json" \
      "$(jq -cn --arg id "${id%:*}" --arg b "weight: light"$'\n'"tier: ${id#*:}"$'\n\nprose' '{id: $id, completed: false, body: $b, edges: []}')" \
      "store: ${id%:*}" >/dev/null
  done
  jobs="$(git -C "$FAKE_GH_GIT" show refs/heads/main:.github/workflows/gates.yml | yq -o=json -I=0 '.jobs | keys')"
  realrun() {  # realrun <id> <head> <tier-order conclusion> <completed_at>: every gates.yml job green but tier-order
    st '.runs += [{id: $id, name: "gates", path: ".github/workflows/gates.yml", event: "pull_request", head_sha: $h,
                   head_branch: "x", created_at: "2026-10-27T07:00:00Z", run_attempt: 1,
                   jobs: [$jobs | to_entries[] | {id: ($id * 100 + .key), name: .value, status: "completed",
                          conclusion: (if .value == "tier-order" then $c else "success" end),
                          started_at: "2026-10-27T07:00:00Z", completed_at: $t}]}]' \
      --argjson id "$1" --arg h "$2" --arg c "$3" --arg t "$4" --argjson jobs "$jobs"
  }
  h5="$(mkpr 5 T1 1 pr-one '{"reviews": [{"author": {"login": "rev"}, "state": "APPROVED"}]}')"
  h6="$(mkpr 6 T0a 2 pr-two '{"reviews": [{"author": {"login": "rev"}, "state": "APPROVED"}]}')"
  realrun 50 "$h5" failure 2026-10-27T08:00:00Z
  realrun 60 "$h6" success 2026-10-27T09:00:00Z
  enq_real pick --apply
  check "the real --order: tier 0 first, #6 built" eq "$RC:$(vd '[.result, .pr, .pr_head]')" "0:[\"built\",6,\"$h6\"]"
  check "  factory-queue/pr-6 pushed" eq "$(qbranches)" "factory-queue/pr-6 "
  check "  #5 never read by enqueue (only the first eligible row is)" eq "$(fakegh_calls '.[1] == "repos/test/repo/pulls/5"')" 0
  st '(.pulls[] | select(.number == 6)).isDraft = true'
  : >"$GITHUB_OUTPUT"
  enq_real pick --apply
  check "#6 a draft, #5 waiting (its tier-order red): empty, ordered [6,5]" eq "$RC:$(vd '[.result, .ordered]')" '0:["empty",[6,5]]'
  check "  both skips named" eq "$(grep -c '^enqueue: skip #[56]: ' <<<"$ERR")" 2
  check "  the stale pr-6 deleted (every serial run cleans up first), no output" \
    eq "$(qbranches)|$(command cat "$GITHUB_OUTPUT")" "|"
  check "  stderr names it" has "$ERR" "enqueue: deleted factory-queue/pr-6"
}

# ---------------------------------------------------------------- land

case_land_success() {
  setup
  build7
  land7 "$S" success --apply
  check "success: landed, main S, merged_mark false (the fake marks merged only by state)" eq "$RC:$OUT" \
    "0:{\"mode\":\"serial\",\"pr\":7,\"queue\":\"factory-queue/pr-7\",\"head\":\"$S\",\"result\":\"landed\",\"main\":\"$S\",\"merged_mark\":false}"
  check "  origin main = S, a fast-forward from base" eq "$(oref refs/heads/main):$(git -C "$FAKE_GH_GIT" rev-parse refs/heads/main^1)" "$S:$M"
  check "  the queue branch deleted" eq "$(qbranches)" ""
  check "  the PR not closed or edited" eq "$(sj '.pulls[] | select(.number == 7) | .state'):$(fakegh_calls "$WRITES")" '"OPEN":0'
}

case_land_merged_mark() {
  setup
  build7
  PATH="$WORLD/shim:$PATH" SHIM_MODE=merge SHIM_S="$S" land7 "$S" success --apply
  check "GitHub marks the PR merged as S: merged_mark true" eq "$RC:$(vd '[.result, .merged_mark]')" '0:["landed",true]'
}

case_land_merged_mark_null() {
  setup
  build7
  PATH="$WORLD/shim:$PATH" SHIM_MODE=fail SHIM_S="$S" land7 "$S" success --apply
  check "the PR unreadable after landing: still landed, merged_mark null" eq "$RC:$(vd '[.result, .merged_mark]')" '0:["landed",null]'
  check "  main = S, the queue branch deleted" eq "$(oref refs/heads/main)|$(qbranches)" "$S|"
}

case_land_main_moved() {
  setup
  build7
  local m2; m2="$(wmain 3 main-three "main: three")"
  land7 "$S" success --apply
  check "main moved since base: main-moved, naming the new main" eq "$RC:$(vd '[.result, .main]')" "0:[\"main-moved\",\"$m2\"]"
  check "  main unchanged, the queue branch deleted" eq "$(oref refs/heads/main)|$(qbranches)" "$m2|"
}

# Main moves between the check and the push: the push is not forced, so it is refused.
case_land_race() {
  setup
  build7
  PATH="$WORLD/shim:$PATH" SHIM_MODE=race land7 "$S" success --apply
  local r; r="$(command cat "$FAKE_GH_GIT/racer")"
  check "main moves during the land: main-moved, naming the racer's main" eq "$RC:$(vd '[.result, .main]')" "0:[\"main-moved\",\"$r\"]"
  check "  main is the racer's commit (no force push), the queue branch deleted" eq "$(oref refs/heads/main)|$(qbranches)" "$r|"
}

case_land_pr_changed() {
  setup
  build7
  local x; x="$(hex pushed-again)"
  changed() {  # changed <name> <state jq> <detail>
    git -C "$FAKE_GH_GIT" update-ref refs/heads/factory-queue/pr-7 "$S"
    local saved; saved="$(command cat "$FAKE_GH_ISSUES")"
    st "$2"
    land7 "$S" success --apply
    check "$1: pr-changed" eq "$RC:$(vd '[.result, .detail]')" "0:[\"pr-changed\",\"$3\"]"
    check "  main unchanged, the queue branch deleted" eq "$(oref refs/heads/main)|$(qbranches)" "$M|"
    printf '%s\n' "$saved" >"$FAKE_GH_ISSUES"
  }
  changed "the PR pushed again" "(.pulls[] | select(.number == 7)).headRefOid = \"$x\"" "the PR was pushed again (head ${x:0:12})"
  changed "the PR closed" '(.pulls[] | select(.number == 7)).state = "CLOSED"' "the PR is closed"
  changed "the PR merged elsewhere" '(.pulls[] | select(.number == 7)).state = "MERGED"' "the PR is closed"
  changed "the PR labeled autorebase" '(.pulls[] | select(.number == 7)).labels = ["autorebase"]' "the PR is labeled autorebase"
  git -C "$FAKE_GH_GIT" update-ref refs/heads/factory-queue/pr-7 "$S"
  st '(.pulls[] | select(.number == 7)).state = "CLOSED"'
  land7 "$S" success --dry-run
  check "dry run, the PR closed: pr-changed, the queue branch kept" eq "$RC:$(vd .result):$(qbranches)" '0:"pr-changed":factory-queue/pr-7 '
}

case_land_refusals() {
  setup
  build7
  local x
  git -C "$FAKE_GH_GIT" update-ref refs/heads/factory-queue/pr-7 "$M"
  land7 "$S" success --apply
  check "the queue branch is not S: exit 1, no verdict" eq "$RC:$OUT" 1:
  check "  naming it" has "$ERR" "factory-queue/pr-7 is not $S any more; refusing to land"
  check "  main unchanged, no PR read" eq "$(oref refs/heads/main):$(fakegh_calls '.[0] == "api"')" "$M:0"
  git -C "$FAKE_GH_GIT" update-ref -d refs/heads/factory-queue/pr-7
  land7 "$S" success --apply
  check "the queue branch gone: exit 1" eq "$RC:$OUT:$(oref refs/heads/main)" "1::$M"
  # S of the wrong shape (the queue branch points at it, so only the shape refuses).
  mk() {  # mk <author> <committer> <subject> <parent...>: a commit on S's tree in the origin
    local a="$1" c="$2" s="$3"; shift 3
    local -a pa=(); local p; for p in "$@"; do pa+=(-p "$p"); done
    printf '%s\n' "$s" | GIT_AUTHOR_NAME="${a% <*}" GIT_AUTHOR_EMAIL="$(sed 's/.*<\(.*\)>/\1/' <<<"$a")" \
      GIT_COMMITTER_NAME="${c% <*}" GIT_COMMITTER_EMAIL="$(sed 's/.*<\(.*\)>/\1/' <<<"$c")" \
      git -C "$FAKE_GH_GIT" commit-tree "$S^{tree}" "${pa[@]}"
  }
  shape() {  # shape <name> <stderr> <mk args...>
    local name="$1" why="$2"; shift 2
    x="$(mk "$@")"
    git -C "$FAKE_GH_GIT" update-ref refs/heads/factory-queue/pr-7 "$x"
    land7 "$x" success --apply
    check "$name: exit 1, no verdict" eq "$RC:$OUT" 1:
    check "  $why" has "$ERR" "$why"
    check "  main unchanged" eq "$(oref refs/heads/main)" "$M"
  }
  local subj="Merge pull request #7 from test/ticket/T7/node-7" who='someone <someone@t.invalid>'
  shape "another author" "is not enqueue.sh's merge commit of #7" "$who" "$BOT" "$subj" "$M" "$H"
  shape "another committer" "is not enqueue.sh's merge commit of #7" "$BOT" "$who" "$subj" "$M" "$H"
  shape "another subject" "is not enqueue.sh's merge commit of #7" "$BOT" "$BOT" "Merge branch 'x'" "$M" "$H"
  shape "the subject of another PR" "is not enqueue.sh's merge commit of #7" "$BOT" "$BOT" "Merge pull request #70 from test/x" "$M" "$H"
  shape "one parent" "is not a queue commit on $M" "$BOT" "$BOT" "$subj" "$M"
  shape "parents not on base" "is not a queue commit on $M" "$BOT" "$BOT" "$subj" "$H" "$M"
  shape "three parents" "is not a queue commit on $M" "$BOT" "$BOT" "$subj" "$M" "$H" "$(git -C "$FAKE_GH_GIT" rev-parse "$M^")"
  check "no PR was ever read for a refused shape" eq "$(fakegh_calls '.[0] == "api"')" 0
}

case_land_failure() {
  setup
  fakegh_issue 3 1761300000 in-review 'T7: work' 'Ticket: T7'
  build7
  land7 "$S" failure --dry-run
  check "failure, dry run: red, eject would-eject" eq "$RC:$(vd '[.result, .eject.result]')" '0:["red","would-eject"]'
  check "  the planned record: red-queue-run, the queue branch, base, the PR head (S^2)" \
    eq "$(vd '.eject.record | [.reason, .queue, .base, .head]')" "[\"red-queue-run\",\"factory-queue/pr-7\",\"$M\",\"$H\"]"
  check "  nothing written, the queue branch kept" eq "$(oref refs/heads/main):$(fakegh_calls "$WRITES"):$(qbranches)" "$M:0:factory-queue/pr-7 "
  land7 "$S" failure --apply
  check "failure, --apply: red, ejected" eq "$RC:$(vd '[.mode, .pr, .queue, .head, .result, .eject.result]')" \
    "0:[\"serial\",7,\"factory-queue/pr-7\",\"$S\",\"red\",\"ejected\"]"
  check "  the ledger line on main: red-queue-run, queue, base, head" \
    eq "$(git -C "$FAKE_GH_GIT" show refs/heads/main:factory/ledger/ejections.jsonl | jq -c '[.pr, .reason, .queue, .base, .head, .strike]')" \
    "[7,\"red-queue-run\",\"factory-queue/pr-7\",\"$M\",\"$H\",1]"
  check "  the queue branch deleted; S never on main" eq "$(qbranches):$(git -C "$FAKE_GH_GIT" merge-base --is-ancestor "$S" refs/heads/main && echo yes || echo no)" ":no"
  check "  the PR closed and labeled autorebase" eq "$(sj '.pulls[] | select(.number == 7) | [.state, [.labels[].name]]')" '["CLOSED",["autorebase"]]'
}

case_land_failure_guards() {
  setup
  fakegh_issue 3 1761300000 in-review 'T7: work' 'Ticket: T7'
  build7
  local m2 before; before="$(sha256sum <"$FAKE_GH_ISSUES")"
  land7 "$(hex unknown)" failure --apply
  check "failure on a queue commit this checkout cannot read: exit 1, nothing ejected" eq "$RC:$OUT" 1:
  check "  naming why" has "$ERR" "cannot tell which PR head failed; nothing ejected"
  check "  main, the queue branch and the fake state unchanged" \
    eq "$(oref refs/heads/main)|$(qbranches)|$(sha256sum <"$FAKE_GH_ISSUES")" "$M|factory-queue/pr-7 |$before"
  m2="$(wfile factory/HALT 'halt: test' 'halt')"
  land7 "$S" failure --apply
  check "failure while HALT is on main: halted, nothing ejected" eq "$RC:$(vd '[.result, .gates]')" '0:["halted","failure"]'
  check "  main (the HALT commit), the queue branch and the fake state unchanged" \
    eq "$(oref refs/heads/main)|$(qbranches)|$(sha256sum <"$FAKE_GH_ISSUES")" "$m2|factory-queue/pr-7 |$before"
}

case_land_not_landed() {
  setup
  build7
  local r
  for r in cancelled skipped; do
    land7 "$S" "$r" --apply
    check "$r: not-landed" eq "$RC:$OUT" \
      "0:{\"mode\":\"serial\",\"pr\":7,\"queue\":\"factory-queue/pr-7\",\"head\":\"$S\",\"result\":\"not-landed\",\"gates\":\"$r\"}"
    check "  nothing read or written: main, the queue branch, no gh call" \
      eq "$(oref refs/heads/main)|$(qbranches)|$(wc -l <"$FAKE_GH_LOG" | tr -d ' ')" "$M|factory-queue/pr-7 |0"
  done
}

case_land_args() {
  setup
  build7
  bad() {  # bad <name> <stderr> <land args...>
    local name="$1" why="$2"; shift 2
    enq land "$@"
    check "$name: exit 1, no verdict" eq "$RC:$OUT" 1:
    check "  $why" has "$ERR" "$why"
  }
  bad "pr not a number" "--pr must be a PR number" --pr abc --base "$M" --queue factory-queue/pr-7 --head "$S" --result success
  bad "pr 0" "--pr must be a PR number" --pr 0 --base "$M" --queue factory-queue/pr-0 --head "$S" --result success
  bad "pr 07" "--pr must be a PR number" --pr 07 --base "$M" --queue factory-queue/pr-07 --head "$S" --result success
  bad "a short base" "--base and --head are full shas" --pr 7 --base "${M:0:12}" --queue factory-queue/pr-7 --head "$S" --result success
  bad "a short head" "--base and --head are full shas" --pr 7 --base "$M" --queue factory-queue/pr-7 --head "${S:0:12}" --result success
  bad "an uppercase sha" "--base and --head are full shas" --pr 7 --base "${M^^}" --queue factory-queue/pr-7 --head "$S" --result success
  bad "another PR's queue" "--queue must be factory-queue/pr-7" --pr 7 --base "$M" --queue factory-queue/pr-8 --head "$S" --result success
  bad "a queue outside factory-queue/" "--queue must be factory-queue/pr-7" --pr 7 --base "$M" --queue main --head "$S" --result success
  bad "an unknown result" "--result must be success, failure, cancelled or skipped" --pr 7 --base "$M" --queue factory-queue/pr-7 --head "$S" --result neutral
  bad "no result" "--result must be success, failure, cancelled or skipped" --pr 7 --base "$M" --queue factory-queue/pr-7 --head "$S"
  check "bad arguments changed nothing" eq "$(oref refs/heads/main)|$(qbranches)|$(wc -l <"$FAKE_GH_LOG" | tr -d ' ')" "$M|factory-queue/pr-7 |0"
}

case_land_halt() {
  setup
  build7
  local m2; m2="$(wfile factory/HALT 'halt: test' 'halt')"
  land7 "$S" success --apply
  check "HALT at land time: halted" eq "$RC:$OUT" \
    "0:{\"mode\":\"serial\",\"pr\":7,\"queue\":\"factory-queue/pr-7\",\"head\":\"$S\",\"result\":\"halted\"}"
  check "  main unchanged (the HALT commit), no PR read" eq "$(oref refs/heads/main):$(fakegh_calls '.[0] == "api"')" "$m2:0"
}

case_land_dry_run() {
  setup
  build7
  land7 "$S" success
  check "success, dry run (the default): would-land" eq "$RC:$OUT" \
    "0:{\"mode\":\"serial\",\"pr\":7,\"queue\":\"factory-queue/pr-7\",\"head\":\"$S\",\"result\":\"would-land\"}"
  check "  main unchanged, the queue branch kept, no gh write" eq "$(oref refs/heads/main)|$(qbranches)|$(fakegh_calls "$WRITES")" "$M|factory-queue/pr-7 |0"
  land7 "$S" success --dry-run
  check "  --dry-run: the same" eq "$RC:$(vd .result):$(oref refs/heads/main)" "0:\"would-land\":$M"
}

for c in halt mode empty skips serial-build head-moved conflict native real-tier-order \
         land-success land-merged-mark land-merged-mark-null land-main-moved land-race land-pr-changed land-refusals land-failure land-failure-guards \
         land-not-landed land-args land-halt land-dry-run; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
