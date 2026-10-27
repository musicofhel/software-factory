#!/usr/bin/env bash
# T30 (specs/factory-step3-v1 TB11, acceptance 1): the gate manifest (the attest note, format
# factory-attest/1 under refs/notes/factory-attest; ADR-0007 decision 9): factory/bin/lib/attest.sh,
# factory/bin/attest-verify.sh and lib/run.sh run_push_attested.
#   - a matching note passes: on pull_request (a fresh CI clone holds no notes ref; it is fetched
#     from origin, and origin's note wins over whatever the checkout held), tamperguard on
#     merge-base...head (I17), a review verdict; on the node (--ticket: the local note, no fetch);
#   - every mismatch is exit 2 and named: adapter, node, ticket (against the gate context and the
#     commit's own trailers), head, base, tree, gate_commands, tests_run, outcome, each verdict
#     (rails-proof, scope, tamperguard verdict / score / findings), format, signing (the note's, and a
#     base store not in unsigned-fallback: another mode, a number, none, no config), a note lacking a
#     key, fleet / verdicts not objects, `{}`; two mismatches at once are both named; a recomputed
#     verdict that does not pass (tamper, scope fail) is named even when the note is honest;
#   - a rebased note (tests_run []) passes; rebased with tests run fails;
#   - a missing note, a non-JSON note, a JSON array, two objects, and an origin without the notes ref
#     are exit 2, each named;
#   - desk, human and halt PRs pass with no note (and no tamperguard call);
#   - merge_group and the first-party queue read the note from the queue commit's second parent; a
#     second parent that is not PR N's head, a squash shape and swapped parents are exit 2; gh failing
#     on that read is exit 1 (an operational error);
#   - a ticket missing from, completed in, or newer than the store at the merge-base is named; a
#     ticket without rails is refused (exit 2);
#   - attest_manifest: the fields it derives (tree, gate_commands at the base, tests_run, signing,
#     format) and that it fails on a base without a usable .adlc/config.json, or whose securityMode
#     is not unsigned-fallback ("signed", none, a number);
#   - run_push_attested: the first note lands with the branch; a second node's note keeps the first
#     (grown from origin's tip); a branch that moved under its lease moves neither ref and is not
#     retried; a notes ref that moves between the fetch and the push (a pre-push hook as the racer)
#     is retried from a fresh fetch and keeps the racer's note; 3 lost races give up; the slot's
#     scratch ref is gone after success and after failure, a stale one is never pushed, FETCH_HEAD is
#     not written;
#   - no tamperguard on PATH, or a tamperguard error: exit 1;
#   - gates.yml: attest-verify has no needs: and no if:, installs tamperguard on the tamper job's pin
#     and Python minor (lib/diff-gates.sh) and runs the base's attest-verify.sh; the header says no
#     w:heavy job is required until a self-hosted factory-node runner exists; skills-janitor.yml has
#     no merge_group and its job is not a required context (the desk note's branch-protection.json);
#     skills-scan.sh (a stub) exits non-zero.
# Offline; every repo is a temp dir, gh and tamperguard are the fakes (the real gh is never on PATH
# ahead of tests/fakes).
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
EV="$REPO_ROOT/tests/fixtures/events"
FREPO=Codertocat/Hello-World   # the repository of GitHub's example payloads
AV="$BIN/attest-verify.sh"
NREF=refs/notes/factory-attest
ADAPTER_ID=claude-code@2.1.0
TG_OK='{"verdict":"ok","score":0,"findings":0}'
BODY=$'Ticket: T-at\nIssue: #3\nNode: box-a'

sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
# put_ticket <id> <scope-json> <rails-json> [completed]: the store file adlc writes (slug--sha256 id), in S.
put_ticket() {
  local slug; slug="$(tr '[:upper:]' '[:lower:]' <<<"$1" | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//')"
  jq -n --arg id "$1" --argjson s "$2" --argjson r "$3" --argjson c "${4:-false}" \
    '{id: $id, title: "t", body: "", category: "feature", duration: 1, scope: $s, rails: $r, edges: []}
     + (if $c then {completed: true} else {} end)' >"$S/.adlc/tickets/$slug--$(sha "$1").json"
}

# The world: origin (bare, the fake gh's repo) whose main BASE holds the config and the store (T-at,
# T-b, T-done completed, T-nr without rails); W, the node's clone; C, the CI checkout (cloned on first use).
setup() {
  fakegh_setup
  export FAKE_GH_REPO="$FREPO" GITHUB_REPOSITORY="$FREPO" FAKE_TAMPERGUARD_LOG="$WORLD/tamperguard.log"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
  printf '{"labels":[],"issues":[],"pulls":[],"collaborators":["dev-box-owner"]}\n' >"$FAKE_GH_ISSUES"
  : >"$FAKE_TAMPERGUARD_LOG"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH GH_TOKEN GATE_QUEUE_PR GATE_BASE GATE_HEAD FAKE_TAMPERGUARD_VERDICT TRAILERS TGV RAILS SCOPE
  S="$WORLD/seed"
  git init -q -b main "$S"
  mkdir -p "$S/.adlc/tickets" "$S/factory/policy" "$S/sim/at"
  echo base >"$S/README.md"; echo '{}' >"$S/factory/policy/p.json"; echo keep >"$S/sim/at/keep"
  printf '%s\n' '{"securityMode": "unsigned-fallback", "fleet": {"gate": {"build": "true", "test": "true"}}}' >"$S/.adlc/config.json"
  put_ticket T-at '["sim/at/**"]' '["factory/policy/**"]'
  put_ticket T-b '["sim/b/**"]' '["factory/policy/**"]'
  put_ticket T-done '["**"]' '["factory/policy/**"]' true
  put_ticket T-nr '["**"]' '[]'
  git -C "$S" add -A; git -C "$S" commit -qm base
  BASE="$(git -C "$S" rev-parse HEAD)"
  git -C "$S" push -q -f "$FAKE_GH_GIT" main
  git -C "$FAKE_GH_GIT" symbolic-ref HEAD refs/heads/main
  W="$WORLD/work" C="$WORLD/ci"
  git clone -q "$FAKE_GH_GIT" "$W"
}
# work <dir> <ticket> <handle> <base> <op:path>...: a ticket commit on <base> (+ add a line, - delete),
# its trailers Assisted-by, Ticket, Node (or $TRAILERS); prints its sha.
work() {
  local d="$1" t="$2" h="$3" b="$4" a; shift 4
  git -C "$d" checkout -q --detach "$b"
  for a in "$@"; do
    case "$a" in
      +*) mkdir -p "$d/$(dirname "${a#+}")"; echo "$t $h $RANDOM" >>"$d/${a#+}"; git -C "$d" add -- "${a#+}" ;;
      -*) git -C "$d" rm -q -- "${a#-}" ;;
    esac
  done
  git -C "$d" commit -q --allow-empty -m "$(printf '%s: work\n\n%s' "$t" "${TRAILERS:-$(printf 'Assisted-by: %s\nTicket: %s\nNode: %s' "$ADAPTER_ID" "$t" "$h")}")"
  git -C "$d" rev-parse HEAD
}
pub() { git -C "$1" push -q -f origin "$2:refs/heads/$3"; }   # pub <dir> <sha> <branch>
# facts <ticket> <node> <head> [outcome] [base]: the facts run.sh's gate_push builds ($TGV, $RAILS,
# $SCOPE override the verdicts).
facts() {
  jq -cn --arg t "$1" --arg n "$2" --arg a "$ADAPTER_ID" --arg o "${4:-built}" --arg b "${5:-$BASE}" --arg h "$3" \
    --argjson tg "${TGV:-$TG_OK}" --arg rails "${RAILS:-pass}" --arg scope "${SCOPE:-pass}" \
    '{ticket: $t, node: $n, adapter: $a, outcome: $o, base: $b, head: $h,
      fleet: {run: "fleet-run-1", strikes: 1, doc_sha256: (if $o == "built" then "ab" * 32 else null end)},
      verdicts: {tamperguard: $tg, "rails-proof": $rails, scope: $scope},
      hashes: {tamperguard_json: ("cd" * 32)}}'
}
# manifest <facts> [dir]: attest_manifest run in <dir> (default W), as gate_push runs it in CLONE.
manifest() {
  (
    cd "${2:-$W}"
    PROG=run
    # shellcheck source=factory/bin/lib/common.sh
    . "$BIN/lib/common.sh"
    # shellcheck source=factory/bin/lib/diff-gates.sh
    . "$BIN/lib/diff-gates.sh"
    # shellcheck source=factory/bin/lib/attest.sh
    . "$BIN/lib/attest.sh"
    attest_manifest "$1"
  )
}
note_for() { manifest "$(facts "$@")"; }   # note_for <ticket> <node> <head> [outcome] [base]
# put_note <sha> <text>: <text> as the attest note on <sha> in W, and W's notes ref pushed to origin.
put_note() {
  printf '%s\n' "$2" >"$WORLD/note.txt"
  git -C "$W" notes --ref="$NREF" add -f -F "$WORLD/note.txt" "$1" 2>/dev/null
  git -C "$W" push -q -f origin "$NREF:$NREF"
}
ci_clone() { [ -d "$C" ] || git clone -q "$FAKE_GH_GIT" "$C"; git -C "$C" fetch -q --prune origin; }
# av: attest-verify in C as a runner runs it (every head fetched, notes only as it fetches
# them); OUT, ERR, RC.
av() {
  ci_clone
  RC=0
  OUT="$(cd "$C" && "$AV" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
# av_node <flags>: run.sh's call, in the node's clone W, outside any runner.
av_node() {
  RC=0
  OUT="$(cd "$W" && env -u GITHUB_EVENT_NAME -u GITHUB_EVENT_PATH -u GATE_QUEUE_PR "$AV" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
# mm: the keys of the `mismatch:` lines attest-verify reported, joined by |.
mm() { sed -n 's/^  mismatch: \([^:]*\):.*/\1/p' <<<"$ERR" | paste -sd'|' -; }
# pr_event <head-sha> <head-ref> <body> [base-sha] [assoc]: GitHub's example pull_request payload with
# the world's shas, ref, body and author association.
pr_event() {
  jq --arg b "${4:-$BASE}" --arg h "$1" --arg r "$2" --arg body "$3" --arg a "${5:-OWNER}" --arg hr "$FREPO" \
    '.pull_request.base.sha = $b | .pull_request.head.sha = $h | .pull_request.head.ref = $r | .pull_request.body = $body
     | .pull_request.author_association = $a | .pull_request.head.repo.full_name = $hr' "$EV/pull_request-opened.json" >"$WORLD/event.json"
  unset GATE_QUEUE_PR GATE_BASE GATE_HEAD
  export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$WORLD/event.json"
}
has() { [[ "$1" == *"$2"* ]] || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }
jqeq() { eq "$(jq -cS . <<<"$1")" "$(jq -cS . <<<"$2")"; }
oref() { git -C "$FAKE_GH_GIT" rev-parse -q --verify "$1" 2>/dev/null || true; }   # origin's sha for a ref, or empty
onote() { git -C "$FAKE_GH_GIT" notes --ref="$NREF" show "$1" 2>/dev/null || true; }  # origin's note on a commit
# ticket_at: the T-at commit of node box-a on BASE, pushed as ticket/T-at/box-a, with its matching note.
ticket_at() {
  H="$(work "$W" T-at box-a "$BASE" +sim/at/a.sh)"
  pub "$W" "$H" ticket/T-at/box-a
  N="$(note_for T-at box-a "$H")"
  put_note "$H" "$N"
}

case_pass() {
  setup
  ticket_at
  ci_clone
  check "a fresh CI clone holds no $NREF" eq "$(git -C "$C" show-ref "$NREF" || true)" ""
  pr_event "$H" ticket/T-at/box-a "$BODY"
  av
  check "pull_request, a matching note: exit 0" eq "$RC" 0
  check "  stdout is the note" jqeq "$OUT" "$N"
  check "  stderr: the pass line, with outcome and verdicts" has "$ERR" \
    "attest-verify: pass: the note on $H agrees with what CI recomputes (built, rails-proof pass, scope pass, tamperguard ok)"
  check "  the notes ref was fetched from origin into the clone" eq "$(git -C "$C" rev-parse "$NREF")" "$(oref "$NREF")"
  check "  tamperguard ran on merge-base...head (I17)" eq "$(tail -n1 "$FAKE_TAMPERGUARD_LOG")" "[\"--range\",\"$BASE...$H\",\"--json\"]"
  # A note the checkout held already is replaced by origin's (the fetch is forced).
  git -C "$C" notes --ref="$NREF" add -f -m '{"stale": true}' "$H" 2>/dev/null
  av
  check "origin's note wins over a note the checkout held: exit 0" eq "$RC" 0
  # A review verdict the note records honestly passes.
  N="$(TGV='{"verdict":"review","score":4,"findings":1}' note_for T-at box-a "$H")"
  put_note "$H" "$N"
  FAKE_TAMPERGUARD_VERDICT=review av
  check "tamperguard review (score 4, 1 finding), recorded as such: exit 0" eq "$RC" 0
  N="$(note_for T-at box-a "$H")"; put_note "$H" "$N"
  # The node: the local note, nothing fetched (origin's notes ref is gone).
  git -C "$FAKE_GH_GIT" update-ref -d "$NREF"
  av_node --ticket T-at --base "$BASE" --head "$H"
  check "node (--ticket --base --head), the local note: exit 0" eq "$RC" 0
  check "  stdout is the note" jqeq "$OUT" "$N"
  check "  with no notes ref on origin: nothing was fetched" eq "$(oref "$NREF")" ""
  git -C "$W" checkout -q --detach "$H"
  av_node --ticket T-at
  check "node (--ticket only: base = merge-base with origin/main, head = HEAD): exit 0" eq "$RC" 0
}

case_mismatches() {
  setup
  ticket_at
  pr_event "$H" ticket/T-at/box-a "$BODY"
  mut() {  # mut <label> <jq filter on the note> <want mm>
    put_note "$H" "$(jq -c --arg B "$BASE" "$2" <<<"$N")"
    av
    check "$1: exit 2, naming $3" eq "$RC|$(mm)" "2|$3"
  }
  mut "another adapter" '.adapter = "codex@0.1.0"' "adapter (its Assisted-by trailer)"
  check "  the FAIL header, and both sides quoted" eq "$(has "$ERR" "attest-verify: FAIL: the note on $H does not agree with CI:" &&
    has "$ERR" "the note says \"codex@0.1.0\", CI recomputes \"$ADAPTER_ID\"" && echo both)" both
  mut "another node" '.node = "box-z"' "node|node (its Node trailer)"
  mut "another ticket" '.ticket = "T-b"' "ticket|ticket (its Ticket trailer)"
  mut "another head" '.head = $B' "head"
  mut "another base" '.base = .head' "base (the merge-base with the base)"
  mut "another tree" '.tree = ("0" * 40)' "tree"
  mut "another gate command list" '.gate_commands |= .[:1]' "gate_commands (fleet.gate at the merge-base)"
  mut "tests_run is not the gate commands (built)" '.tests_run = []' "tests_run (fleet ran the gate commands)"
  mut "an outcome neither built nor rebased" '.outcome = "skipped"' "outcome"
  mut "verdicts.rails-proof fail" '.verdicts["rails-proof"] = "fail"' "verdicts.rails-proof"
  mut "verdicts.scope fail" '.verdicts.scope = "fail"' "verdicts.scope"
  mut "tamperguard verdict review" '.verdicts.tamperguard.verdict = "review"' "verdicts.tamperguard"
  mut "tamperguard score 3" '.verdicts.tamperguard.score = 3' "verdicts.tamperguard"
  mut "tamperguard findings 2" '.verdicts.tamperguard.findings = 2' "verdicts.tamperguard"
  mut "another format" '.format = "factory-attest/2"' "format"
  mut "the note says signed" '.signing = "ssh"' "signing"
  mut "a note without fleet" 'del(.fleet)' "keys"
  check "  naming the missing key and the format" has "$ERR" "mismatch: keys: the note lacks fleet (format factory-attest/1)"
  mut "a note without hashes" 'del(.hashes)' "keys"
  mut "fleet is not an object" '.fleet = "fleet-run-1"' "fleet"
  mut "two at once (adapter and tree)" '.adapter = "codex@0.1.0" | .tree = ("0" * 40)' "adapter (its Assisted-by trailer)|tree"
  put_note "$H" '{}'
  av
  check "an empty object: exit 2, keys first" eq "$RC|$(mm | cut -d'|' -f1)" "2|keys"
  # verdicts that is not an object: named like fleet, never an operational error.
  put_note "$H" "$(jq -c '.verdicts = "pass"' <<<"$N")"
  av
  check "verdicts is not an object: exit 2 (never 1), naming it" \
    eq "$RC:$(has "$ERR" 'mismatch: verdicts: the note holds "pass", not an object' >/dev/null && echo named || echo unnamed)" 2:named
  # The node's call has no handle: the Node trailer still pins the node.
  put_note "$H" "$(jq -c '.node = "box-z"' <<<"$N")"
  av_node --ticket T-at --base "$BASE" --head "$H"
  check "node call, another node: exit 2, naming the Node trailer" eq "$RC|$(mm)" "2|node (its Node trailer)"
  # The commit's own trailers against an honest note.
  local h2
  h2="$(TRAILERS=$'Assisted-by: claude-code@2.1.0\nTicket: T-at\nNode: box-z' work "$W" T-at box-a "$BASE" +sim/at/b.sh)"
  pub "$W" "$h2" ticket/T-at/box-a
  put_note "$h2" "$(note_for T-at box-a "$h2")"
  pr_event "$h2" ticket/T-at/box-a "$BODY"; av
  check "a commit whose Node trailer is box-z (branch and note box-a): exit 2" eq "$RC|$(mm)" "2|node (its Node trailer)"
  h2="$(TRAILERS=$'Ticket: T-at\nNode: box-a' work "$W" T-at box-a "$BASE" +sim/at/c.sh)"
  pub "$W" "$h2" ticket/T-at/box-a
  put_note "$h2" "$(note_for T-at box-a "$h2")"
  pr_event "$h2" ticket/T-at/box-a "$BODY"; av
  check "a commit with no Assisted-by trailer: exit 2" eq "$RC|$(mm)" "2|adapter (its Assisted-by trailer)"
}

case_signing() {
  setup
  ticket_at
  local b
  # bstore <securityMode json | absent | nocfg>: a main commit on BASE whose config differs only in it
  bstore() {
    git -C "$W" checkout -q --detach "$BASE"
    case "$1" in
      nocfg) git -C "$W" rm -q .adlc/config.json ;;
      absent) jq 'del(.securityMode)' "$S/.adlc/config.json" >"$W/.adlc/config.json" ;;
      *) jq --argjson m "$1" '.securityMode = $m' "$S/.adlc/config.json" >"$W/.adlc/config.json" ;;
    esac
    git -C "$W" commit -qam "store: $1"
    b="$(git -C "$W" rev-parse HEAD)"
    pub "$W" "$b" "main-$RANDOM"
  }
  local m want
  for m in '"strict"' 5 absent nocfg; do
    case "$m" in absent|nocfg) want=none ;; *) want="$(jq -r 'tostring' <<<"$m")" ;; esac
    bstore "$m"
    pr_event "$H" ticket/T-at/box-a "$BODY" "$b"
    av
    check "a base store with securityMode $m: exit 2, naming signing only" eq "$RC|$(mm)" "2|signing"
    check "  naming the store's mode \"$want\"" has "$ERR" "the store at the base is securityMode \"$want\""
  done
}

case_rebased() {
  setup
  H="$(work "$W" T-at box-a "$BASE" +sim/at/a.sh)"
  pub "$W" "$H" ticket/T-at/box-a
  N="$(note_for T-at box-a "$H" rebased)"
  put_note "$H" "$N"
  pr_event "$H" ticket/T-at/box-a "$BODY"
  av
  check "a rebased note (tests_run []): exit 0" eq "$RC" 0
  check "  the pass line says rebased" has "$ERR" "CI recomputes (rebased, rails-proof pass"
  put_note "$H" "$(jq -c '.tests_run = .gate_commands' <<<"$N")"
  av
  check "rebased with tests run: exit 2" eq "$RC|$(mm)" "2|tests_run (a rebase strike runs no fleet)"
}

case_missing() {
  setup
  H="$(work "$W" T-at box-a "$BASE" +sim/at/a.sh)"
  pub "$W" "$H" ticket/T-at/box-a
  pr_event "$H" ticket/T-at/box-a "$BODY"
  av
  check "origin has no $NREF: exit 2" eq "$RC" 2
  check "  naming it" has "$ERR" "attest-verify: FAIL: origin has no $NREF, so $H carries no attest note"
  local miss="attest-verify: FAIL: no attest note ($NREF) on $H, or it is not one JSON object" t
  put_note "$BASE" "$(note_for T-at box-a "$BASE")"
  av
  check "a notes ref without a note on the head: exit 2, naming it" eq "$RC:$(has "$ERR" "$miss" >/dev/null && echo named || echo unnamed)" 2:named
  for t in 'not json' '[1, 2]' '"a string"'; do
    put_note "$H" "$t"
    av
    check "a note '$t': exit 2, naming it" eq "$RC:$(has "$ERR" "$miss" >/dev/null && echo named || echo unnamed)" 2:named
  done
  N="$(note_for T-at box-a "$H")"
  put_note "$H" "$N"$'\n'"$N"
  av
  check "a note of two JSON objects is not one object: exit 2, naming it" eq "$RC:$(has "$ERR" "$miss" >/dev/null && echo named || echo unnamed)" 2:named
  # After a pass, origin loses the ref: the checkout's leftover is never read.
  put_note "$H" "$N"; av
  check "  (the honest note passes)" eq "$RC" 0
  git -C "$FAKE_GH_GIT" update-ref -d "$NREF"
  av
  check "origin's ref deleted after the clone fetched it: exit 2" eq "$RC:$(has "$ERR" "origin has no $NREF" >/dev/null && echo named || echo unnamed)" 2:named
}

case_classes() {
  setup
  local h
  cls() {  # cls <label> <class> <ref> <op:path>...
    local l="$1" want="$2" r="$3"; shift 3
    h="$(TRAILERS='Signed-off-by: t <t@t.invalid>' work "$W" x x "$BASE" "$@")"
    pub "$W" "$h" "$r"
    pr_event "$h" "$r" "" "$BASE" COLLABORATOR
    av
    check "$l, no notes ref anywhere: exit 0" eq "$RC" 0
    check "  class $want, said so" has "$ERR" "attest-verify: class $want: no node built it, so no attest note"
  }
  cls "a desk PR (.adlc only)" desk desk/t +.adlc/tickets/new.json
  cls "a human PR (docs)" human docs/x +docs/guide.md
  cls "a halt PR (adds factory/HALT)" halt halt/add +factory/HALT
  check "no tamperguard call for any of them" eq "$(wc -l <"$FAKE_TAMPERGUARD_LOG" | tr -d ' ')" 0
  check "origin never grew a notes ref" eq "$(oref "$NREF")" ""
}

# queue_pr <n> <head-sha>: PR n from ticket/T-at/box-a onto main in the fake's store (GET pulls/<n>).
queue_pr() {
  jq --argjson n "$1" --arg h "$2" \
    '.pulls = [.pulls[] | select(.number != $n)] + [{number: $n, headRefName: "ticket/T-at/box-a", headRefOid: $h,
      baseRefName: "main", state: "OPEN", title: "T-at", body: "Ticket: T-at\nNode: box-a", author: {login: "dev-box-owner"}}]' \
    "$FAKE_GH_ISSUES" >"$WORLD/s" && mv "$WORLD/s" "$FAKE_GH_ISSUES"
}
# qcommit <tree-ish> <parent>...: a queue commit in W, pushed to origin; prints its sha
qcommit() {
  local t="$1" p q; shift
  local -a ps=(); for p in "$@"; do ps+=(-p "$p"); done
  q="$(printf 'Merge pull request #5 from Codertocat/ticket/T-at/box-a\n' | git -C "$W" commit-tree "$t^{tree}" "${ps[@]}")"
  pub "$W" "$q" "gh-readonly-queue/main/pr-5-$q"
  printf '%s\n' "$q"
}
mg_event() {  # mg_event <base> <head> <pr-head>: GitHub's merge_group payload for PR 5
  jq --arg b "$1" --arg g "$2" --arg r "refs/heads/gh-readonly-queue/main/pr-5-$3" \
    '.merge_group.base_sha = $b | .merge_group.head_sha = $g | .merge_group.head_ref = $r' \
    "$EV/merge_group-checks_requested.json" >"$WORLD/event.json"
  unset GATE_QUEUE_PR GATE_BASE GATE_HEAD
  export GITHUB_EVENT_NAME=merge_group GITHUB_EVENT_PATH="$WORLD/event.json" GH_TOKEN=ghs_readonly
}
queue_env() {  # queue_env <base> <head>: gates.yml called by enqueue.yml on a push, for PR 5
  jq -n --arg b "$1" '{ref: "refs/heads/main", before: ("0" * 40), after: $b}' >"$WORLD/event.json"
  export GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$WORLD/event.json" GATE_QUEUE_PR=5 GATE_BASE="$1" GATE_HEAD="$2" GH_TOKEN=ghs_readonly
}

case_queue() {
  setup
  ticket_at
  local m2 tree q qs qx other
  # main moved since the PR's base; the queue commit is [m2, PR head].
  git -C "$W" checkout -q --detach "$BASE"; echo moved >>"$W/README.md"; git -C "$W" commit -qam "main moves"
  m2="$(git -C "$W" rev-parse HEAD)"
  git -C "$W" push -q origin "$m2:refs/heads/main"
  tree="$(git -C "$W" merge-tree --write-tree "$m2" "$H")"
  q="$(qcommit "$tree" "$m2" "$H")"
  queue_pr 5 "$H"
  mg_event "$m2" "$q" "$H"; : >"$FAKE_GH_LOG"
  av
  check "merge_group: the note on the queue commit's second parent: exit 0" eq "$RC" 0
  check "  read on the PR head" has "$ERR" "attest-verify: pass: the note on $H agrees"
  check "  PR 5's head read through gh api (gate-context, then attest_target)" \
    eq "$(fakegh_calls ".[1] == \"repos/$FREPO/pulls/5\"")" 2
  check "  tamperguard on merge-base(main, head)...head" eq "$(tail -n1 "$FAKE_TAMPERGUARD_LOG")" "[\"--range\",\"$BASE...$H\",\"--json\"]"
  queue_env "$m2" "$q"
  av
  check "the first-party queue (GATE_QUEUE_PR/GATE_BASE/GATE_HEAD): exit 0" eq "$RC:$(has "$ERR" "the note on $H agrees" >/dev/null && echo ok || echo unnamed)" 0:ok
  # PR 5's head is another commit than the queue commit's second parent.
  other="$(work "$W" T-at box-a "$BASE" +sim/at/other.sh)"
  pub "$W" "$other" ticket/T-at/other-box
  queue_pr 5 "$other"
  mg_event "$m2" "$q" "$H"
  av
  check "merge_group, second parent is not PR 5's head: exit 2" eq "$RC" 2
  check "  naming the shape" has "$ERR" "attest-verify: FAIL: the merge_group commit $q is not [base $m2, PR #5's head]"
  queue_env "$m2" "$q"
  av
  check "queue, second parent is not PR 5's head: exit 2 (gate-context refuses it)" eq "$RC" 2
  queue_pr 5 "$H"
  qs="$(qcommit "$tree" "$m2")"
  mg_event "$m2" "$qs" "$H"; av
  check "merge_group, a squash shape (one parent): exit 2" eq "$RC:$(has "$ERR" "is not [base $m2, PR #5's head]" >/dev/null && echo named || echo unnamed)" 2:named
  qx="$(qcommit "$tree" "$H" "$m2")"
  mg_event "$m2" "$qx" "$H"; av
  check "merge_group, parents swapped [PR head, base]: exit 2" eq "$RC:$(has "$ERR" "is not [base $m2, PR #5's head]" >/dev/null && echo named || echo unnamed)" 2:named
  # gh fails on attest_target's own read (the one with --jq): an operational error, not a refusal.
  mg_event "$m2" "$q" "$H"
  FAKE_GH_FAIL='--jq' av
  check "merge_group, gh failing on the PR head read: exit 1 (operational), never 0 or a refusal" eq "$RC" 1
}

case_ticket_store() {
  setup
  local h m3 t
  for t in T-gone T-done; do
    h="$(work "$W" "$t" box-a "$BASE" +sim/at/a.sh)"
    pub "$W" "$h" "ticket/$t/box-a"
    put_note "$h" "$(note_for "$t" box-a "$h")"
    pr_event "$h" "ticket/$t/box-a" "Ticket: $t"
    av
    check "$t (not open at the merge-base): exit 2, named as such" eq "$RC|$(mm)" "2|ticket"
    check "  the line" has "$ERR" "mismatch: ticket: $t is not an open ticket in the store at the merge-base ${BASE:0:12}"
  done
  # A ticket main gained after the branch's base: the store read is the merge-base's, not the base's.
  git -C "$W" checkout -q --detach "$BASE"
  jq -n '{id: "T-new", title: "t", body: "", category: "feature", duration: 1, scope: ["**"], rails: ["factory/policy/**"], edges: []}' \
    >"$W/.adlc/tickets/t-new--$(sha T-new).json"
  git -C "$W" add -A; git -C "$W" commit -qm "store: T-new"
  m3="$(git -C "$W" rev-parse HEAD)"
  git -C "$W" push -q origin "$m3:refs/heads/main"
  h="$(work "$W" T-new box-a "$BASE" +sim/new/a.sh)"
  pub "$W" "$h" ticket/T-new/box-a
  put_note "$h" "$(note_for T-new box-a "$h")"
  pr_event "$h" ticket/T-new/box-a "Ticket: T-new" "$m3"
  av
  check "T-new, in the base's store but not the merge-base's: exit 2, named" eq "$RC|$(mm)" "2|ticket"
  # A ticket without rails: rails-proof refuses it (exit 2), so attest-verify fails it, not errors.
  h="$(work "$W" T-nr box-a "$BASE" +sim/nr/a.sh)"
  pub "$W" "$h" ticket/T-nr/box-a
  put_note "$h" "$(note_for T-nr box-a "$h")"
  pr_event "$h" ticket/T-nr/box-a "Ticket: T-nr"
  av
  check "T-nr (no rails declared): exit 2, never 0 or 1" eq "$RC" 2
}

case_verdicts_recomputed() {
  setup
  ticket_at
  pr_event "$H" ticket/T-at/box-a "$BODY"
  # An honest note of a tamper verdict: it agrees, but a node pushes only a passing commit.
  put_note "$H" "$(TGV='{"verdict":"tamper","score":10,"findings":1}' note_for T-at box-a "$H")"
  FAKE_TAMPERGUARD_VERDICT=tamper av
  check "tamper, recorded honestly: exit 2, naming the failing recompute" \
    eq "$RC|$(mm)" "2|the recomputed verdicts do not pass (rails-proof pass, scope pass, tamperguard tamper)"
  # Out of scope (README.md): the honest note says scope fail; one that says pass is named too.
  local h
  h="$(work "$W" T-at box-a "$BASE" +sim/at/a.sh +README.md)"
  pub "$W" "$h" ticket/T-at/box-a
  put_note "$h" "$(SCOPE=fail note_for T-at box-a "$h")"
  pr_event "$h" ticket/T-at/box-a "$BODY"; av
  check "out of scope, recorded honestly: exit 2, naming the failing recompute" \
    eq "$RC|$(mm)" "2|the recomputed verdicts do not pass (rails-proof pass, scope fail, tamperguard ok)"
  put_note "$h" "$(note_for T-at box-a "$h")"
  av
  check "out of scope, the note says pass: exit 2, naming verdicts.scope too" \
    eq "$RC|$(mm)" "2|verdicts.scope|the recomputed verdicts do not pass (rails-proof pass, scope fail, tamperguard ok)"
  h="$(work "$W" T-at box-a "$BASE" +sim/at/a.sh +factory/policy/p.json)"
  pub "$W" "$h" ticket/T-at/box-a
  put_note "$h" "$(note_for T-at box-a "$h")"
  pr_event "$h" ticket/T-at/box-a "$BODY"; av
  check "a rail touched, the note says pass: exit 2, naming verdicts.rails-proof and scope" \
    eq "$RC|$(mm)" "2|verdicts.rails-proof|verdicts.scope|the recomputed verdicts do not pass (rails-proof fail, scope fail, tamperguard ok)"
}

case_tamperguard() {
  setup
  ticket_at
  pr_event "$H" ticket/T-at/box-a "$BODY"
  local d np="" nogh="$WORLD/nogh"
  local -a dirs
  IFS=: read -r -a dirs <<<"$PATH"
  for d in "${dirs[@]}"; do [ -x "$d/tamperguard" ] || np+="${np:+:}$d"; done
  mkdir -p "$nogh"
  printf '%s\n' '#!/bin/sh' 'echo "gh: not in this test" >&2' 'exit 1' >"$nogh/gh"; chmod +x "$nogh/gh"
  check "the trimmed PATH holds no tamperguard" eq "$(PATH="$nogh:$np"; command -v tamperguard || echo none)" none
  PATH="$nogh:$np" av
  check "no tamperguard on PATH: exit 1" eq "$RC" 1
  check "  naming it" has "$ERR" "attest-verify: tamperguard not found on PATH"
  FAKE_TAMPERGUARD_VERDICT=error av
  check "a tamperguard error: exit 1" eq "$RC" 1
  check "  saying the verdicts could not be recomputed" has "$ERR" "attest-verify: could not recompute the note's verdicts on $H"
}

case_manifest() {
  setup
  local h f m gates
  h="$(work "$W" T-at box-a "$BASE" +sim/at/a.sh)"
  m="$(note_for T-at box-a "$h")"
  gates='[{"key":"build","command":"true","argv":["/bin/sh","-c","true"]},{"key":"test","command":"true","argv":["/bin/sh","-c","true"]}]'
  check "one compact JSON line" eq "$(wc -l <<<"$m" | tr -d ' '):$(jq -c . <<<"$m")" "1:$m"
  check "exactly the 14 keys of factory-attest/1" eq "$(jq -c 'keys' <<<"$m")" \
    '["adapter","base","fleet","format","gate_commands","hashes","head","node","outcome","signing","tests_run","ticket","tree","verdicts"]'
  check "format factory-attest/1, signing unsigned-fallback" eq "$(jq -r '"\(.format) \(.signing)"' <<<"$m")" "factory-attest/1 unsigned-fallback"
  check "tree is the head's tree" eq "$(jq -r .tree <<<"$m")" "$(git -C "$W" rev-parse "$h^{tree}")"
  check "gate_commands: build-test --list of the base's fleet.gate" jqeq "$(jq -c .gate_commands <<<"$m")" "$gates"
  check "tests_run = gate_commands when built" jqeq "$(jq -c .tests_run <<<"$m")" "$gates"
  f="$(facts T-at box-a "$h")"
  check "the facts carried through unchanged" jqeq "$(jq -c '{ticket, node, adapter, outcome, base, head, fleet, verdicts, hashes}' <<<"$m")" "$f"
  check "rebased: tests_run []" eq "$(note_for T-at box-a "$h" rebased | jq -c .tests_run)" '[]'
  # The gate commands are the base's: a head that edits the config does not change them.
  git -C "$W" checkout -q --detach "$h"
  jq '.fleet.gate.test = "make test"' "$S/.adlc/config.json" >"$W/.adlc/config.json"; git -C "$W" commit -qam "edit config"
  h="$(git -C "$W" rev-parse HEAD)"
  check "a head editing fleet.gate: gate_commands still the base's" jqeq "$(note_for T-at box-a "$h" | jq -c .gate_commands)" "$gates"
  # A base without a usable config: no note.
  local b rc
  usable() {  # usable <label> <config text | -> : a base commit with that config (- = none); attest_manifest must fail
    git -C "$W" checkout -q --detach "$BASE"
    if [ "$2" = - ]; then git -C "$W" rm -q .adlc/config.json; else printf '%s\n' "$2" >"$W/.adlc/config.json"; fi
    git -C "$W" commit -qam "config: $1"
    b="$(git -C "$W" rev-parse HEAD)"
    rc=0; note_for T-at box-a "$h" built "$b" >/dev/null 2>&1 || rc=$?
    check "a base with $1: attest_manifest fails" eq "$([ "$rc" != 0 ] && echo failed || echo "rc 0")" failed
  }
  usable "no .adlc/config.json" -
  usable "a config that is not JSON" 'not json'
  usable "no fleet.gate commands" '{"securityMode": "unsigned-fallback"}'
  usable "a fleet.gate.test that is not a string" '{"securityMode": "unsigned-fallback", "fleet": {"gate": {"test": 5}}}'
  # The note is unsigned: a store that is not in unsigned-fallback gets none.
  usable 'securityMode "signed"' '{"securityMode": "signed", "fleet": {"gate": {"build": "true", "test": "true"}}}'
  usable "no securityMode" '{"fleet": {"gate": {"build": "true", "test": "true"}}}'
  usable "securityMode 5 (not a string)" '{"securityMode": 5, "fleet": {"gate": {"build": "true", "test": "true"}}}'
  rc=0; note_for T-at box-a "$(printf 'ef%.0s' {1..20})" >/dev/null 2>&1 || rc=$?
  check "a head that is not in the repo: attest_manifest fails" eq "$([ "$rc" != 0 ] && echo failed || echo "rc 0")" failed
}

# rpa <clone> <ticket> <handle> <sha> <note-file> <slot>: run_push_attested as run.sh's push_attested
# calls it (LOGBASE $WORLD/log-<ticket>); RC.
rpa() {
  RC=0
  : >"$WORLD/log-$2.git.err"
  (
    # shellcheck disable=SC2034  # read by lib/run.sh run_push_attested
    CLONE="$1" TICKET="$2" HANDLE="$3" LOGBASE="$WORLD/log-$2" PROG=run
    # shellcheck source=factory/bin/lib/common.sh
    . "$BIN/lib/common.sh"
    # shellcheck source=factory/bin/lib/attest.sh
    . "$BIN/lib/attest.sh"
    # shellcheck source=factory/bin/lib/run.sh
    . "$BIN/lib/run.sh"
    run_push_attested "$4" "$5" "refs/notes/factory-run/slot-$6"
  ) || RC=$?
}
tries() { grep -c '^run_push_attested: try ' "$WORLD/log-$1.git.err" 2>/dev/null || true; }
scratch() { git -C "$1" for-each-ref --format='%(refname)' refs/notes/factory-run/; }
# racer <clone> <once|always>: a pre-push hook in <clone> that moves origin's notes ref (another
# node's note on BASE) after git read origin's refs and before the push lands.
racer() {
  export RACE_ORIGIN="$FAKE_GH_GIT" RACE_BASE="$BASE" RACE_MODE="$2" RACE_MARK="$WORLD/raced"
  rm -f "$RACE_MARK"
  # shellcheck disable=SC2016  # the hook expands them
  printf '%s\n' '#!/usr/bin/env bash' 'command cat >/dev/null' \
    '[ "$RACE_MODE" = always ] || { [ ! -e "$RACE_MARK" ] || exit 0; : >"$RACE_MARK"; }' \
    'env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$RACE_ORIGIN" notes --ref=refs/notes/factory-attest add -f -m "{\"racer\": $RANDOM$RANDOM}" "$RACE_BASE" >/dev/null 2>&1' \
    'exit 0' >"$1/.git/hooks/pre-push"
  chmod +x "$1/.git/hooks/pre-push"
}

case_push() {
  setup
  local h h2 h3 h4 h5 w2="$WORLD/work2" t1 t0 x
  h="$(work "$W" T-at box-a "$BASE" +sim/at/a.sh)"
  note_for T-at box-a "$h" >"$WORLD/n1.json"
  # A scratch ref a crashed run left behind is never pushed.
  git -C "$W" notes --ref=refs/notes/factory-run/slot-1 add -m '{"stale": true}' "$BASE"
  rpa "$W" T-at box-a "$h" "$WORLD/n1.json" 1
  check "the first note ever (origin had no notes ref): exit 0" eq "$RC" 0
  check "  the branch landed" eq "$(oref refs/heads/ticket/T-at/box-a)" "$h"
  check "  the note landed on it" jqeq "$(onote "$h")" "$(command cat "$WORLD/n1.json")"
  check "  a root notes commit holding that one note (the stale scratch note was dropped)" \
    eq "$(git -C "$FAKE_GH_GIT" rev-list --count "$NREF"):$(git -C "$FAKE_GH_GIT" notes --ref="$NREF" list | wc -l | tr -d ' ')" 1:1
  check "  the scratch ref is gone" eq "$(scratch "$W")" ""
  check "  no local $NREF and no FETCH_HEAD written" eq "$(git -C "$W" show-ref "$NREF" || true)$([ -e "$W/.git/FETCH_HEAD" ] && echo FETCH_HEAD || true)" ""
  check "  no refused try" eq "$(tries T-at)" 0
  pr_event "$h" ticket/T-at/box-a "$BODY"; av
  check "  and attest-verify passes on what was pushed" eq "$RC" 0
  t1="$(oref "$NREF")"
  # A second node, another ticket, its own slot.
  git clone -q "$FAKE_GH_GIT" "$w2"
  h2="$(work "$w2" T-b box-b "$BASE" +sim/b/a.sh)"
  manifest "$(facts T-b box-b "$h2")" "$w2" >"$WORLD/n2.json"
  rpa "$w2" T-b box-b "$h2" "$WORLD/n2.json" 2
  check "a second node's note on another ticket: exit 0" eq "$RC" 0
  check "  its branch and note landed" eq "$(oref refs/heads/ticket/T-b/box-b):$(onote "$h2" | jq -r .ticket)" "$h2:T-b"
  check "  the first note is kept" jqeq "$(onote "$h")" "$(command cat "$WORLD/n1.json")"
  check "  grown from origin's tip" eq "$(git -C "$FAKE_GH_GIT" rev-parse "$NREF^")" "$t1"
  check "  its scratch ref is gone, and no FETCH_HEAD written" eq "$(scratch "$w2")$([ -e "$w2/.git/FETCH_HEAD" ] && echo FETCH_HEAD || true)" ""
  # The branch moves on origin under the node's lease: neither ref moves, no retry.
  git -C "$W" fetch -q origin
  check "  (W's tracking ref saw $h)" eq "$(git -C "$W" rev-parse refs/remotes/origin/ticket/T-at/box-a)" "$h"
  x="$(git -C "$FAKE_GH_GIT" commit-tree "$h^{tree}" -p "$h" -m "another node's push")"
  git -C "$FAKE_GH_GIT" update-ref refs/heads/ticket/T-at/box-a "$x"
  t0="$(oref "$NREF")"
  h3="$(work "$W" T-at box-a "$BASE" +sim/at/b.sh)"
  note_for T-at box-a "$h3" >"$WORLD/n3.json"
  rpa "$W" T-at box-a "$h3" "$WORLD/n3.json" 1
  check "a branch that moved under the lease: exit 1" eq "$RC" 1
  check "  the branch stays where the other push put it" eq "$(oref refs/heads/ticket/T-at/box-a)" "$x"
  check "  the notes ref did not move (atomic) and holds no note on the new head" eq "$(oref "$NREF"):$(onote "$h3")" "$t0:"
  check "  not retried: one refused try" eq "$(tries T-at)" 1
  check "  the scratch ref is gone after the failure" eq "$(scratch "$W")" ""
  # origin's notes ref moves between the fetch and the push: retried from a fresh fetch.
  racer "$w2" once
  h4="$(work "$w2" T-b box-b "$BASE" +sim/b/b.sh)"
  manifest "$(facts T-b box-b "$h4")" "$w2" >"$WORLD/n4.json"
  rpa "$w2" T-b box-b "$h4" "$WORLD/n4.json" 2
  check "a notes ref that moved between fetch and push: exit 0 after a retry" eq "$RC:$(tries T-b)" 0:1
  check "  the branch and the note landed" eq "$(oref refs/heads/ticket/T-b/box-b):$(onote "$h4" | jq -r .head)" "$h4:$h4"
  check "  the racer's note is kept, and every earlier one" \
    eq "$(onote "$BASE" | jq -r 'has("racer")'):$(git -C "$FAKE_GH_GIT" notes --ref="$NREF" list | wc -l | tr -d ' ')" true:4
  check "  the scratch ref is gone" eq "$(scratch "$w2")" ""
  # A racer on every try: 3 tries, then give up with nothing moved.
  racer "$w2" always
  h5="$(work "$w2" T-b box-b "$BASE" +sim/b/c.sh)"
  manifest "$(facts T-b box-b "$h5")" "$w2" >"$WORLD/n5.json"
  rpa "$w2" T-b box-b "$h5" "$WORLD/n5.json" 2
  check "a notes race lost 3 times: exit 1 after 3 tries" eq "$RC:$(tries T-b)" 1:3
  check "  the branch did not move and the note is not on origin" eq "$(oref refs/heads/ticket/T-b/box-b):$(onote "$h5")" "$h4:"
  check "  the scratch ref is gone" eq "$(scratch "$w2")" ""
}

case_gates_yml() {
  local wf="$REPO_ROOT/.github/workflows/gates.yml" sj="$REPO_ROOT/.github/workflows/skills-janitor.yml"
  local bp="$REPO_ROOT/tests/sim/desk/factory/policy/branch-protection.json" pin py runs req rc j
  pin="$(bash -c '. "$1"; echo "$DG_TAMPERGUARD_PIN"' _ "$BIN/lib/diff-gates.sh")"
  py="$(bash -c '. "$1"; echo "$DG_TAMPERGUARD_PYTHON"' _ "$BIN/lib/diff-gates.sh")"
  check "the pins read from lib/diff-gates.sh" eq "$([ -n "$pin" ] && [ -n "$py" ] && echo read)" read
  check "attest-verify: no needs: and no if: (it reports on every path, I18)" \
    eq "$(yq -r '.jobs["attest-verify"] | [has("needs"), has("if")] | map(tostring) | join(" ")' "$wf")" "false false"
  check "attest-verify: checkout head (fetch-depth 0), then base into .base" \
    eq "$(yq -o=json -I=0 '.jobs["attest-verify"].steps | map(select((.uses // "") | test("^actions/checkout@")) | .with)' "$wf")" \
       '[{"ref":"${{ env.GATE_HEAD }}","fetch-depth":0},{"ref":"${{ env.GATE_BASE }}","path":".base"}]'
  check "attest-verify: setup-python is the tamper job's minor ($py)" \
    eq "$(yq -r '.jobs["attest-verify"].steps[] | select((.uses // "") | test("^actions/setup-python@")) | .with."python-version"' "$wf"):$(
         yq -r '.jobs.tamper.steps[] | select((.uses // "") | test("^actions/setup-python@")) | .with."python-version"' "$wf")" "$py:$py"
  runs="$(yq -r '.jobs["attest-verify"].steps[] | select(has("run")) | .run' "$wf")"
  check "attest-verify: pipx installs tamperguard==$pin on python$py" \
    eq "$(grep -c "^pipx install --python python$py tamperguard==$pin\$" <<<"$runs" || true)" 1
  check "attest-verify: runs the base's attest-verify.sh" eq "$(grep -c '^\./\.base/factory/bin/attest-verify\.sh$' <<<"$runs" || true)" 1
  check "attest-verify: its step has GH_TOKEN (the merge_group / queue PR read)" \
    eq "$(yq -r '.jobs["attest-verify"].steps[] | select((.run // "") | test("attest-verify")) | .env.GH_TOKEN' "$wf")" '${{ github.token }}'
  check "the gates.yml header: no w:heavy job is required until a self-hosted runner exists" \
    has "$(sed -n '/^name:/q; s/^# \{0,1\}//p' "$wf" | tr '\n' ' ')" "No w:heavy job is required until a self-hosted factory-node runner exists"
  check "skills-janitor.yml: no merge_group trigger" eq "$(yq -r '.on | has("merge_group")' "$sj")" false
  req="$(jq -r '.rulesets[].rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' "$bp")"
  check "  (the desk note's required contexts read: attest-verify among them)" eq "$(grep -cx attest-verify <<<"$req" || true)" 1
  for j in $(yq -r '.jobs | keys | .[]' "$sj"); do
    check "skills-janitor.yml job '$j' is not a required context" eq "$(grep -cxF -- "$j" <<<"$req" || true)" 0
  done
  rc=0; (cd "${TMPDIR:-/tmp}" && "$BIN/skills-scan.sh" factory/skills) >/dev/null 2>&1 || rc=$?
  check "skills-scan.sh (a stub) exits non-zero" eq "$([ "$rc" != 0 ] && echo nonzero || echo 0)" nonzero
}

for c in pass mismatches signing rebased missing classes queue ticket-store verdicts-recomputed tamperguard manifest push gates-yml; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
