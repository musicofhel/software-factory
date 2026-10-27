#!/usr/bin/env bash
# T28 (specs/factory-step3-v1 TB9; ci:G21, merge:G7): factory/bin/eject.sh, a ticket PR leaving the
# queue, run from a clone of the fake origin's main against the fake gh.
#   - dry run (the default): `would-eject` with the planned record (strike 1), the actions and the
#     comment; nothing written (origin main, the fake's state byte-identical, no write call);
#   - --apply: one line {at, pr, ticket, handle, issue, head, base, queue, reason, strike} appended
#     to factory/ledger/ejections.jsonl on origin main (base/queue null when not given, set when
#     given) by one fast-forward commit of github-actions[bot] (author and committer, whatever the
#     caller's env says) whose trailers are exactly `Ejected: #<n>`, `Assisted-by: none`,
#     `Node: github-actions` (no `Ticket:`) and that touches only the ledger;
#   - the PR: `autorebase` and `rebase-strike` created when the repo lacks them (never re-created,
#     whatever their case), the PR labeled `autorebase` and closed with a comment of ids and codes
#     only (none of the PR's title or body); the Issue: `ready` + `rebase-strike` added, `in-review`
#     removed;
#   - the strike: 1 + the ticket's earlier lines (another ticket's lines do not count);
#   - idempotence: a line for the same PR and head already on main is not written twice
#     (`ledger-present`), whether seeded or left by a first run on a PR reopened since;
#   - not-open (closed, merged: `merged` true), stale (--head is not the PR's head): exit 0, nothing
#     written; refused (exit 2): a fork's PR, a non-ticket or malformed head ref; bad arguments: exit 1
#     before any gh call;
#   - no open Issue carrying `Ticket: <id>` (only near misses, a closed one): a warning, the PR still
#     ejected, no Issue edit, `issue` null;
#   - the write order: a failed `pr edit` closes nothing and edits no Issue, a failed `pr close` edits
#     no Issue;
#   - a main that moves under the push (origin's pre-receive hook moves main itself, then declines):
#     re-fetched and the line appended on top of the new main; when the winner already wrote the same
#     line, `ledger-present` and no second line; a push refused 3 times: exit 1, no PR or Issue write;
#   - --dequeued (GITHUB_EVENT_PATH, pull_request_target dequeued): MERGE_CONFLICT → conflict,
#     CI_FAILURE / CI_TIMEOUT → red-queue-run (any case), the line carries `dequeued_reason` in upper case; any other
#     reason (MANUAL, MERGE, empty, absent) → `ignored`, exit 0, no gh call; with --pr, without an
#     event, or on another action: exit 1.
# Offline; every repo is a temp dir, gh is the fake.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

LEDGER=factory/ledger/ejections.jsonl
BOT='github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'
NOW=1762000000
WRITES='(.[0] == "pr" and (.[1] == "edit" or .[1] == "close")) or (.[0] == "label" and .[1] == "create") or (.[0] == "issue" and .[1] == "edit")'
SECRET_TITLE='SECRET-TITLE-TEXT'
SECRET_BODY='SECRET-BODY-TEXT'

# setup: a fresh world; $R is a clone of the fake origin on main (README only, no ledger); the branch
# ticket/T9/dev-box holds one ticket commit ($HEAD9) on the origin; PR #5 is open from it (this repo,
# a title and body that must never reach the comment); Issue #3 is open with `Ticket: T9` and
# `in-review`. The repo labels lack autorebase and rebase-strike. Pinned clock; the caller's git
# identity is someone else's.
setup() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FACTORY_NOW="$NOW"
  export GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@fake GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@fake
  unset GITHUB_REPOSITORY GH_TOKEN
  st '.labels += ["in-review"] | .pulls = []'
  R="$WORLD/repo"
  git clone -q "$FAKE_GH_GIT" "$R" 2>/dev/null
  git -C "$R" checkout -q main
  git -C "$R" checkout -q -b ticket/T9/dev-box
  echo work >"$R/work.txt"
  git -C "$R" add -A; git -C "$R" commit -qm "T9: the work" -m "Ticket: T9"
  HEAD9="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" push -q origin ticket/T9/dev-box 2>/dev/null
  git -C "$R" checkout -q main
  add_pr 5 ticket/T9/dev-box "$HEAD9"
  fakegh_issue 3 1761300000 in-review "T9: the issue" $'The mirror\'s text.\n\nTicket: T9\n'
  MAIN0="$(origin_main)"
}
st() {  # st <jq program> [jq args...]: rewrite the fake's state (FAKE_GH_ISSUES)
  local tmp; tmp="$(mktemp)"
  jq "${@:2}" "$1" "$FAKE_GH_ISSUES" >"$tmp" && mv "$tmp" "$FAKE_GH_ISSUES"
}
add_pr() {  # add_pr <n> <head-ref> <head-sha> [head-repo]: an open PR (a fork when head-repo is given)
  st '.pulls += [{number: $n, headRefName: $h, headRefOid: $s, state: "OPEN", title: $t, body: $b, labels: [],
                  createdAt: "2026-10-25T12:00:00Z"} + (if $f == "" then {} else {headRepository: $f} end)]' \
    --argjson n "$1" --arg h "$2" --arg s "$3" --arg f "${4:-}" --arg t "$SECRET_TITLE" \
    --arg b "Ticket: T9"$'\n\n'"$SECRET_BODY, the node's summary."
}
set_pr() { st "(.pulls[] | select(.number == \$n)) |= ($2)" --argjson n "$1" "${@:3}"; }   # set_pr <n> <jq update> [jq args...]
ej() {  # ej [flags]: run eject in the clone; RC, OUT (the JSON line), ERR
  RC=0
  OUT="$(cd "$R" && "$BIN/eject.sh" "$@" 2>"$WORLD/err")" || RC=$?
  # shellcheck disable=SC2034  # ERR is read inside the eval strings passed to check
  ERR="$(command cat "$WORLD/err")"
}
v() { jq -c "$1" <<<"$OUT"; }                       # v <jq>: a field of the verdict
origin_main() { git -C "$FAKE_GH_GIT" rev-parse refs/heads/main; }
ledger() { git -C "$FAKE_GH_GIT" show "refs/heads/main:$LEDGER" 2>/dev/null || true; }
nledger() { ledger | /usr/bin/grep -c . || true; }
writes() { fakegh_calls "$WRITES"; }
pr_state() { jq -c --argjson n "$1" '.pulls[] | select(.number == $n) | [.state, ([.labels[].name] | sort)]' "$FAKE_GH_ISSUES"; }
issue_labels() { jq -c --argjson n "$1" '.issues[] | select(.number == $n) | [.labels[].name] | sort' "$FAKE_GH_ISSUES"; }
comments() { jq -c '.pr_comments // []' "$FAKE_GH_ISSUES"; }
iso() { jq -nr --argjson e "$1" '$e | todate'; }
has() { [[ "$1" == *"$2"* ]] || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }
lacks() { [[ "$1" != *"$2"* ]] || { printf '      [%s] has [%s]\n' "$1" "$2"; return 1; }; }
# rec <pr> <ticket> <head> <strike>: a ledger line as an earlier ejection left it
rec() {
  jq -cn --argjson pr "$1" --arg t "$2" --arg h "$3" --argjson k "$4" \
    '{at: "2026-10-20T00:00:00Z", pr: $pr, ticket: $t, handle: "dev-box", issue: null, head: $h, base: null,
      queue: null, reason: "conflict", strike: $k}'
}
# mk_commit <path> <line> <message>: a commit on origin main's tip appending <line> to <path>, made in
# the bare origin by plumbing; prints its sha and moves no ref.
mk_commit() {
  local tip blob idx="$WORLD/mk.idx" tree
  tip="$(origin_main)"
  blob="$( { git -C "$FAKE_GH_GIT" show "$tip:$1" 2>/dev/null || true; printf '%s\n' "$2"; } | git -C "$FAKE_GH_GIT" hash-object -w --stdin)"
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git -C "$FAKE_GH_GIT" read-tree "$tip"
  GIT_INDEX_FILE="$idx" git -C "$FAKE_GH_GIT" update-index --add --cacheinfo "100644,$blob,$1"
  tree="$(GIT_INDEX_FILE="$idx" git -C "$FAKE_GH_GIT" write-tree)"
  _fakegh_commit "$tree" 1761400000 "$3" "$tip"
}
seed() { git -C "$FAKE_GH_GIT" update-ref refs/heads/main "$(mk_commit "$@")"; }   # seed <path> <line> <message>
# race_hook <sha>: origin's pre-receive; on its first run only it moves main to <sha> itself (another
# writer winning the race; the quarantine env is dropped so the ref update is allowed) and declines
# the push. Every run is counted in $WORLD/hook.count.
race_hook() {
  printf '%s\n' "$1" >"$WORLD/race"
  : >"$WORLD/hook.count"
  printf '%s\n' '#!/usr/bin/env bash' \
    "echo run >>'$WORLD/hook.count'" \
    "[ -s '$WORLD/race' ] || exit 0" \
    "sha=\"\$(command cat '$WORLD/race')\"; rm -f '$WORLD/race'" \
    'env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES git update-ref refs/heads/main "$sha" || exit 3' \
    'echo "main moved under the push" >&2; exit 1' >"$FAKE_GH_GIT/hooks/pre-receive"
  chmod +x "$FAKE_GH_GIT/hooks/pre-receive"
}
refuse_hook() {  # refuse_hook: origin's pre-receive declines every push, counted in $WORLD/hook.count
  : >"$WORLD/hook.count"
  printf '%s\n' '#!/usr/bin/env bash' "echo run >>'$WORLD/hook.count'" 'echo "declined" >&2; exit 1' >"$FAKE_GH_GIT/hooks/pre-receive"
  chmod +x "$FAKE_GH_GIT/hooks/pre-receive"
}
hook_runs() { /usr/bin/grep -c . "$WORLD/hook.count" || true; }
event() {  # event <json>: GITHUB_EVENT_PATH holds <json>
  printf '%s\n' "$1" >"$WORLD/event.json"
  export GITHUB_EVENT_PATH="$WORLD/event.json"
}
want_comment() {  # want_comment <reason> <strike> [base]: the comment eject must post for PR #5
  local b=""; [ -z "${3:-}" ] || b=", base \`${3:0:12}\`"
  printf 'Ejected from the queue: reason `%s`, rebase strike %s, head `%s`%s. Ticket `T9` returns to ready with `rebase-strike`; the next claim rebases its commit onto main.' \
    "$1" "$2" "${HEAD9:0:12}" "$b"
}

# ---------------------------------------------------------------------------------------------
case_dry_run() {
  setup
  local before; before="$(sha256sum <"$FAKE_GH_ISSUES")"
  ej --pr 5 --reason conflict
  check "exit 0" eq "$RC" 0
  check "would-eject PR #5 of T9, Issue #3" eq "$(v '[.result, .pr, .ticket, .issue]')" '["would-eject",5,"T9",3]'
  check "the planned record, strike 1" eq "$(v .record)" \
    "$(jq -cn --arg at "$(iso "$NOW")" --arg h "$HEAD9" '{at: $at, pr: 5, ticket: "T9", handle: "dev-box", issue: 3, head: $h,
         base: null, queue: null, reason: "conflict", strike: 1}')"
  check "the planned actions" eq "$(v .actions)" '["ledger-append","label-autorebase","close-pr","issue-ready-rebase-strike"]'
  check "the comment it would post" eq "$(jq -r .comment <<<"$OUT")" "$(want_comment conflict 1)"
  check "origin main unchanged, no ledger" eq "$(origin_main)/$(nledger)" "$MAIN0/0"
  check "the fake's state is byte-identical (PR open, no label, no comment)" eq "$(sha256sum <"$FAKE_GH_ISSUES")" "$before"
  check "no write call" eq "$(writes)" 0
  ej --pr 5 --reason red-queue-run --dry-run
  check "--dry-run says the same, nothing written" \
    eq "$RC $(v '[.result, .record.reason]') $(writes) $(origin_main)" "0 [\"would-eject\",\"red-queue-run\"] 0 $MAIN0"
}

case_apply() {
  setup
  ej --pr 5 --reason conflict --apply
  check "exit 0" eq "$RC" 0
  check "ejected PR #5 of T9, Issue #3" eq "$(v '[.result, .pr, .ticket, .issue]')" '["ejected",5,"T9",3]'
  check "the actions, in order" eq "$(v .actions)" \
    '["ledger-append","label-create autorebase","label-create rebase-strike","label-autorebase","close-pr","issue-ready-rebase-strike"]'
  check "the ledger on origin main has exactly one line" eq "$(nledger)" 1
  check "its fields, in the header's order" eq "$(ledger | jq -c keys_unsorted)" \
    '["at","pr","ticket","handle","issue","head","base","queue","reason","strike"]'
  check "its values (base and queue null when not given)" eq "$(ledger)" \
    "$(jq -cn --arg at "$(iso "$NOW")" --arg h "$HEAD9" '{at: $at, pr: 5, ticket: "T9", handle: "dev-box", issue: 3, head: $h,
         base: null, queue: null, reason: "conflict", strike: 1}')"
  check "the verdict's record is the line" eq "$(v .record)" "$(ledger)"
  local c; c="$(origin_main)"
  check "one commit on top of the old main (a fast-forward)" eq "$(git -C "$FAKE_GH_GIT" log --format=%P -1 "$c")" "$MAIN0"
  check "author and committer are github-actions[bot], whatever the caller's env says" \
    eq "$(git -C "$FAKE_GH_GIT" log -1 --format='%an <%ae>|%cn <%ce>' "$c")" "$BOT|$BOT"
  check "trailers exactly Ejected, Assisted-by none, Node github-actions (no Ticket:)" \
    eq "$(git -C "$FAKE_GH_GIT" log -1 --format=%B "$c" | git interpret-trailers --parse)" \
       $'Ejected: #5\nAssisted-by: none\nNode: github-actions'
  check "the commit touches only the ledger" eq "$(git -C "$FAKE_GH_GIT" diff --name-only "$MAIN0" "$c")" "$LEDGER"
  check "the repo labels gained autorebase and rebase-strike, each created once" \
    eq "$(jq -c '.labels | map(select(. == "autorebase" or . == "rebase-strike"))' "$FAKE_GH_ISSUES") $(fakegh_calls '.[0:2] == ["label","create"]')" \
       '["autorebase","rebase-strike"] 2'
  check "the PR is labeled autorebase and closed" eq "$(pr_state 5)" '["CLOSED",["autorebase"]]'
  check "one comment on the close, ids and codes only" eq "$(comments)" \
    "$(jq -cn --arg b "$(want_comment conflict 1)" '[{pr: 5, body: $b}]')"
  check "the comment carries none of the PR's title or body" \
    eval 'lacks "$(comments)" "$SECRET_TITLE" && lacks "$(comments)" "$SECRET_BODY" && lacks "$(comments)" "summary"'
  check "the Issue: ready and rebase-strike added, in-review removed" eq "$(issue_labels 3)" '["ready","rebase-strike"]'
  check "the Issue is edited in one call" eq "$(fakegh_calls '.[0:3] == ["issue","edit","3"]')" 1
  check "the clone's work tree is untouched" eq "$(git -C "$R" status --porcelain)" ""
}

case_base_and_queue() {
  setup
  ej --pr 5 --reason red-queue-run --base "$MAIN0" --head "$HEAD9" --queue factory-queue/pr-5 --apply
  check "exit 0, ejected" eq "$RC $(v .result)" '0 "ejected"'
  check "the line carries base, queue and the reason" eq "$(ledger | jq -c '[.base, .queue, .reason, .head]')" \
    "[\"$MAIN0\",\"factory-queue/pr-5\",\"red-queue-run\",\"$HEAD9\"]"
  check "no dequeued_reason on a serial-queue line" eq "$(ledger | jq -c 'has("dequeued_reason")')" false
  check "the comment names the short base" eq "$(jq -r '.[0].body' <<<"$(comments)")" "$(want_comment red-queue-run 1 "$MAIN0")"
}

case_labels_present() {
  setup
  st '.labels += ["Autorebase", "rebase-strike"]'
  ej --pr 5 --reason conflict --apply
  check "exit 0" eq "$RC" 0
  check "no label created (present, whatever the case)" eq "$(fakegh_calls '.[0:2] == ["label","create"]')" 0
  check "no label-create action" eq "$(v '[.actions[] | select(startswith("label-create"))]')" '[]'
  check "the PR carries the repo's own label" eq "$(pr_state 5)" '["CLOSED",["Autorebase"]]'
  check "the Issue is relabeled" eq "$(issue_labels 3)" '["ready","rebase-strike"]'
}

case_strike_count() {
  setup
  seed "$LEDGER" "$(rec 1 T9 "$MAIN0" 1)" "earlier ejection 1"
  seed "$LEDGER" "$(rec 2 T4 "$MAIN0" 1)" "another ticket's ejection"
  seed "$LEDGER" "$(rec 4 T9 "$MAIN0" 2)" "earlier ejection 2"
  local tip; tip="$(origin_main)"
  ej --pr 5 --reason conflict
  check "dry run: strike 3" eq "$(v .record.strike)" 3
  check "dry run: the comment says strike 3" has "$(jq -r .comment <<<"$OUT")" "rebase strike 3"
  ej --pr 5 --reason conflict --apply
  check "exit 0" eq "$RC" 0
  check "four lines, the earlier three kept as they were" eq "$(nledger) $(ledger | head -n3 | jq -sc 'map([.pr, .ticket, .strike])')" \
    '4 [[1,"T9",1],[2,"T4",1],[4,"T9",2]]'
  check "the new line's strike is 3 (two earlier T9 lines; T4's does not count)" eq "$(ledger | tail -n1 | jq -c '[.pr, .strike]')" '[5,3]'
  check "on top of the seeded main" eq "$(git -C "$FAKE_GH_GIT" log --format=%P -1 "$(origin_main)")" "$tip"
  check "the comment says strike 3" eq "$(jq -r '.[0].body' <<<"$(comments)")" "$(want_comment conflict 3)"
}

case_idempotent_seeded() {
  setup
  seed "$LEDGER" "$(rec 5 T9 "$HEAD9" 1)" "this PR's ejection, already on main"
  local tip; tip="$(origin_main)"
  ej --pr 5 --reason conflict
  check "dry run: the line already on main, nothing to write" eq "$RC $(v '[.result, .actions[0]]') $(v .record)" "0 [\"would-eject\",\"ledger-present\"] $(ledger)"
  ej --pr 5 --reason conflict --apply
  check "exit 0, ejected" eq "$RC $(v .result)" '0 "ejected"'
  check "actions start with ledger-present, then the PR and the Issue" eq "$(v .actions)" \
    '["ledger-present","label-create autorebase","label-create rebase-strike","label-autorebase","close-pr","issue-ready-rebase-strike"]'
  check "no commit: origin main unchanged, one line" eq "$(origin_main) $(nledger)" "$tip 1"
  check "the verdict's record is the line already on main" eq "$(v .record)" "$(ledger)"
  check "the PR is closed and labeled, the Issue relabeled" eq "$(pr_state 5) $(issue_labels 3)" '["CLOSED",["autorebase"]] ["ready","rebase-strike"]'
  check "the comment carries the recorded strike" eq "$(jq -r '.[0].body' <<<"$(comments)")" "$(want_comment conflict 1)"
  # A line for the same PR but another head (the PR was pushed again since) is a new ejection.
  local h2
  git -C "$R" checkout -q ticket/T9/dev-box
  echo again >>"$R/work.txt"; git -C "$R" commit -qam "T9: again" -m "Ticket: T9"
  h2="$(git -C "$R" rev-parse HEAD)"; git -C "$R" checkout -q main
  set_pr 5 '.state = "OPEN" | .headRefOid = $h' --arg h "$h2"
  ej --pr 5 --reason conflict --apply
  check "a new head: a second line, strike 2" eq "$RC $(nledger) $(ledger | tail -n1 | jq -c '[.head == "'"$h2"'", .strike]')" '0 2 [true,2]'
}

case_idempotent_rerun() {
  setup
  ej --pr 5 --reason conflict --apply
  check "first run: exit 0, one line" eq "$RC $(nledger)" "0 1"
  local tip; tip="$(origin_main)"
  set_pr 5 '.state = "OPEN"'
  ej --pr 5 --reason conflict --apply
  check "second run on the reopened PR: exit 0, ejected" eq "$RC $(v .result)" '0 "ejected"'
  check "ledger-present, labels not re-created" eq "$(v .actions)" \
    '["ledger-present","label-autorebase","close-pr","issue-ready-rebase-strike"]'
  check "no second line, no new commit" eq "$(nledger) $(origin_main)" "1 $tip"
  check "label create ran only in the first run" eq "$(fakegh_calls '.[0:2] == ["label","create"]')" 2
  check "the PR is closed again" eq "$(pr_state 5)" '["CLOSED",["autorebase"]]'
}

case_not_open() {
  setup
  set_pr 5 '.state = "CLOSED"'
  local before; before="$(sha256sum <"$FAKE_GH_ISSUES")"
  ej --pr 5 --reason conflict --apply
  check "closed: exit 0, not-open, merged false" eq "$RC $(v '[.result, .pr, .state, .merged]')" '0 ["not-open",5,"closed",false]'
  check "closed: nothing written" eq "$(writes) $(origin_main) $(sha256sum <"$FAKE_GH_ISSUES")" "0 $MAIN0 $before"
  set_pr 5 '.state = "MERGED"'
  before="$(sha256sum <"$FAKE_GH_ISSUES")"
  ej --pr 5 --reason red-queue-run --apply
  check "merged: exit 0, not-open, merged true" eq "$RC $(v '[.result, .state, .merged]')" '0 ["not-open","closed",true]'
  check "merged: nothing written" eq "$(writes) $(origin_main) $(nledger) $(sha256sum <"$FAKE_GH_ISSUES")" "0 $MAIN0 0 $before"
  ej --pr 77 --reason conflict --apply
  check "an unknown PR: exit 1, the error names it" eval '[ "$RC" = 1 ] && has "$ERR" "cannot read PR #77"'
}

case_stale() {
  setup
  local before; before="$(sha256sum <"$FAKE_GH_ISSUES")"
  ej --pr 5 --reason red-queue-run --head "$MAIN0" --apply
  check "exit 0, stale, both heads named" eq "$RC $(v '[.result, .pr, .head, .pr_head]')" "0 [\"stale\",5,\"$MAIN0\",\"$HEAD9\"]"
  check "nothing written" eq "$(writes) $(origin_main) $(nledger) $(sha256sum <"$FAKE_GH_ISSUES")" "0 $MAIN0 0 $before"
  ej --pr 5 --reason red-queue-run --head "$HEAD9"
  check "--head equal to the PR head: would-eject" eq "$RC $(v .result)" '0 "would-eject"'
}

case_refused() {
  setup
  add_pr 6 ticket/T9/dev-box "$HEAD9" other/repo
  add_pr 7 feature/x "$HEAD9"
  add_pr 8 ticket/T9/a/b "$HEAD9"
  local before n; before="$(sha256sum <"$FAKE_GH_ISSUES")"
  ej --pr 6 --reason conflict --apply
  check "a fork's PR: exit 2, named" eval '[ "$RC" = 2 ] && [ -z "$OUT" ] && has "$ERR" "PR #6 is from another repo"'
  for n in 7 8; do
    ej --pr "$n" --reason conflict --apply
    check "#$n (not ticket/<id>/<handle>): exit 2, named" eval '[ "$RC" = 2 ] && [ -z "$OUT" ] && has "$ERR" "PR #$n: head ref"'
  done
  check "nothing written" eq "$(writes) $(origin_main) $(nledger) $(sha256sum <"$FAKE_GH_ISSUES")" "0 $MAIN0 0 $before"
}

case_bad_args() {
  setup
  local short="${HEAD9:0:12}" a
  local -a bad=(
    "--pr abc --reason conflict" "--pr 0 --reason conflict" "--pr --reason conflict"
    "--pr 5 --reason merge" "--pr 5" "--pr 5 --reason CONFLICT"
    "--pr 5 --reason conflict --head $short" "--pr 5 --reason conflict --base $short"
    "--pr 5 --reason conflict --head ${HEAD9^^}"
    "--pr 5 --reason conflict --queue main" "--pr 5 --reason conflict --queue factory-queue/pr-0"
    "--pr 5 --reason conflict --queue factory-queue/pr-5/x" "--pr 5 --reason conflict --bogus"
  )
  for a in "${bad[@]}"; do
    # shellcheck disable=SC2086  # the words of each argument list split on purpose
    ej $a --apply
    check "[$a]: exit 1, no verdict" eval '[ "$RC" = 1 ] && [ -z "$OUT" ]'
  done
  check "no gh call at all" eq "$(fakegh_calls true)" 0
  check "nothing written" eq "$(origin_main) $(nledger)" "$MAIN0 0"
}

case_no_issue() {
  setup
  st '.issues = []'
  fakegh_issue 3 1761300000 in-review "near miss" $'Ticket: T99\n'
  fakegh_issue 4 1761300001 in-review "near miss" $'Ticket: T9 and more\n'
  fakegh_issue 10 1761300002 in-review "closed" $'Ticket: T9\n'
  fakegh_close 10
  ej --pr 5 --reason conflict --apply
  check "exit 0, ejected, issue null" eq "$RC $(v '[.result, .issue, .record.issue]')" '0 ["ejected",null,null]'
  check "a warning names the ticket" has "$ERR" "no open Issue carries 'Ticket: T9'"
  check "no Issue edit, no Issue action" eq "$(fakegh_calls '.[0:2] == ["issue","edit"]') $(v '.actions | index("issue-ready-rebase-strike")')" "0 null"
  check "the PR is still ejected: one line, closed and labeled" eq "$(nledger) $(pr_state 5)" '1 ["CLOSED",["autorebase"]]'
  check "the Issues keep their labels" eq "$(issue_labels 3)$(issue_labels 4)$(issue_labels 10)" '["in-review"]["in-review"]["in-review"]'
}

case_write_order() {
  setup
  FAKE_GH_FAIL='^pr edit' ej --pr 5 --reason conflict --apply
  check "pr edit fails: exit 1" eq "$RC" 1
  check "the ledger line was written first" eq "$(nledger)" 1
  check "no close, no Issue edit" eq "$(fakegh_calls '.[0:2] == ["pr","close"] or .[0:2] == ["issue","edit"]') $(pr_state 5) $(issue_labels 3)" \
    '0 ["OPEN",[]] ["in-review"]'
  FAKE_GH_FAIL='^pr close' ej --pr 5 --reason conflict --apply
  check "pr close fails: exit 1, still one line (ledger-present)" eq "$RC $(nledger)" "1 1"
  check "labeled, still open, no Issue edit" eq "$(pr_state 5) $(fakegh_calls '.[0:2] == ["issue","edit"]')" '["OPEN",["autorebase"]] 0'
  ej --pr 5 --reason conflict --apply
  check "a clean re-run finishes the job" eq "$RC $(nledger) $(pr_state 5) $(issue_labels 3)" '0 1 ["CLOSED",["autorebase"]] ["ready","rebase-strike"]'
}

case_main_moved() {
  setup
  local winner
  winner="$(mk_commit other.txt "another writer" "another writer lands first")"
  race_hook "$winner"
  ej --pr 5 --reason conflict --apply
  check "exit 0, ejected, ledger-append" eq "$RC $(v '[.result, .actions[0]]')" '0 ["ejected","ledger-append"]'
  check "the push was tried twice (the first declined after main moved)" eq "$(hook_runs)" 2
  check "the line sits on top of the NEW main" eq "$(git -C "$FAKE_GH_GIT" log --format=%P -1 "$(origin_main)")" "$winner"
  check "the winner's file is kept, one line" eq "$(git -C "$FAKE_GH_GIT" show "refs/heads/main:other.txt") $(nledger)" "another writer 1"
  check "the new commit touches only the ledger" eq "$(git -C "$FAKE_GH_GIT" diff --name-only "$winner" "$(origin_main)")" "$LEDGER"
  check "the PR and the Issue are written" eq "$(pr_state 5) $(issue_labels 3)" '["CLOSED",["autorebase"]] ["ready","rebase-strike"]'
}

case_main_moved_same_line() {
  setup
  local winner
  winner="$(mk_commit "$LEDGER" "$(rec 5 T9 "$HEAD9" 1)" "another run ejected the same PR and head")"
  race_hook "$winner"
  ej --pr 5 --reason conflict --apply
  check "exit 0, ejected" eq "$RC $(v .result)" '0 "ejected"'
  check "the retry found the line: ledger-present" eq "$(v .actions[0])" '"ledger-present"'
  check "the push was tried once" eq "$(hook_runs)" 1
  check "no duplicate: origin main is the winner, one line" eq "$(origin_main) $(nledger)" "$winner 1"
  check "the verdict's record is the winner's line" eq "$(v .record)" "$(ledger)"
  check "the PR and the Issue are written" eq "$(pr_state 5) $(issue_labels 3)" '["CLOSED",["autorebase"]] ["ready","rebase-strike"]'
}

case_push_refused() {
  setup
  refuse_hook
  local before; before="$(sha256sum <"$FAKE_GH_ISSUES")"
  ej --pr 5 --reason conflict --apply
  check "exit 1, no verdict" eq "$RC $OUT" "1 "
  check "three tries" eq "$(hook_runs)" 3
  check "the error says so" has "$ERR" "in 3 tries"
  check "no PR or Issue write, nothing on main" eq "$(writes) $(origin_main) $(sha256sum <"$FAKE_GH_ISSUES")" "0 $MAIN0 $before"
}

case_dequeued() {
  setup
  local r
  for r in MERGE_CONFLICT merge_conflict; do
    event "{\"action\":\"dequeued\",\"pull_request\":{\"number\":5},\"reason\":\"$r\"}"
    ej --dequeued
    check "$r → conflict (dry run)" eq "$RC $(v '[.result, .record.reason, .record.dequeued_reason]')" "0 [\"would-eject\",\"conflict\",\"${r^^}\"]"
  done
  for r in CI_FAILURE CI_TIMEOUT ci_timeout Ci_Failure; do
    event "{\"action\":\"dequeued\",\"pull_request\":{\"number\":5},\"reason\":\"$r\"}"
    ej --dequeued --dry-run
    check "$r → red-queue-run (dry run)" eq "$RC $(v '[.result, .record.reason, .record.dequeued_reason]')" "0 [\"would-eject\",\"red-queue-run\",\"${r^^}\"]"
  done
  check "dry runs wrote nothing" eq "$(writes) $(origin_main)" "0 $MAIN0"
  event '{"action":"dequeued","pull_request":{"number":5,"head":{"sha":"x"}},"reason":"CI_TIMEOUT"}'
  ej --dequeued --apply
  check "CI_TIMEOUT --apply: exit 0, ejected" eq "$RC $(v .result)" '0 "ejected"'
  check "the line carries red-queue-run and dequeued_reason, last" eq "$(ledger | jq -c '[.reason, .dequeued_reason, .pr, .base, .queue, (keys_unsorted | last)]')" \
    '["red-queue-run","CI_TIMEOUT",5,null,null,"dequeued_reason"]'
  check "the PR is closed, the Issue relabeled" eq "$(pr_state 5) $(issue_labels 3)" '["CLOSED",["autorebase"]] ["ready","rebase-strike"]'
}

case_dequeued_ignored() {
  setup
  local r before; before="$(sha256sum <"$FAKE_GH_ISSUES")"
  for r in '"MANUAL"' '"MERGE"' '""' '"ALREADY_MERGED"' 'null'; do
    event "{\"action\":\"dequeued\",\"pull_request\":{\"number\":5},\"reason\":$r}"
    ej --dequeued --apply
    check "reason $r: exit 0, ignored" eq "$RC $(v '[.result, .pr, .dequeued_reason]')" "0 [\"ignored\",5,$(jq -c 'if . == null then "" else . end' <<<"$r")]"
  done
  event '{"action":"dequeued","pull_request":{"number":5}}'
  ej --dequeued --apply
  check "no reason at all: exit 0, ignored" eq "$RC $(v .result)" '0 "ignored"'
  check "no gh call, nothing written" eq "$(fakegh_calls true) $(origin_main) $(nledger) $(sha256sum <"$FAKE_GH_ISSUES")" "0 $MAIN0 0 $before"
}

case_dequeued_bad() {
  setup
  event '{"action":"dequeued","pull_request":{"number":5},"reason":"MERGE_CONFLICT"}'
  ej --dequeued --pr 5 --apply
  check "--dequeued with --pr: exit 1" eval '[ "$RC" = 1 ] && [ -z "$OUT" ] && has "$ERR" "takes no --pr"'
  ej --dequeued --reason conflict --apply
  check "--dequeued with --reason: exit 1" eq "$RC" 1
  unset GITHUB_EVENT_PATH
  ej --dequeued --apply
  check "no GITHUB_EVENT_PATH: exit 1" eval '[ "$RC" = 1 ] && has "$ERR" "needs GITHUB_EVENT_PATH"'
  export GITHUB_EVENT_PATH="$WORLD/missing.json"
  ej --dequeued --apply
  check "an unreadable event: exit 1" eq "$RC" 1
  event '{"action":"closed","pull_request":{"number":5},"reason":"MERGE_CONFLICT"}'
  ej --dequeued --apply
  check "another action: exit 1" eval '[ "$RC" = 1 ] && has "$ERR" "not a pull_request dequeued event"'
  event '{"action":"dequeued","pull_request":{"number":"5"},"reason":"MERGE_CONFLICT"}'
  ej --dequeued --apply
  check "a non-number PR: exit 1" eq "$RC" 1
  check "no gh call, nothing written" eq "$(fakegh_calls true) $(origin_main) $(nledger)" "0 $MAIN0 0"
}

for c in dry-run apply base-and-queue labels-present strike-count idempotent-seeded idempotent-rerun not-open stale \
         refused bad-args no-issue write-order main-moved main-moved-same-line push-refused dequeued dequeued-ignored \
         dequeued-bad; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
