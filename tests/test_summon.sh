#!/usr/bin/env bash
# T2 acceptance 3 and 4: summon.sh posts exactly one Discord-webhook message (one human, the ticket
# id, the decision needed, a link) for halt|needs-approval|needs-acceptance and refuses any other
# kind with exit 2; the fake curl captures the payload. Plus the summoner workflow's triggers and
# the fake curl itself. Offline: the webhook is the fake.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

HOOK="https://discord.test/api/webhooks/123/secret-token"
OWNER="$(awk '$1 == "factory/HALT" { print $2; exit }' "$REPO_ROOT/CODEOWNERS")"; OWNER="${OWNER#@}"
GATE_OWNER="$(awk '$1 == "factory/**" { print $2; exit }' "$REPO_ROOT/CODEOWNERS")"; GATE_OWNER="${GATE_OWNER#@}"
WF="$REPO_ROOT/.github/workflows/summoner.yml"

sm() {      # sm <args>: run summon.sh in $WORLD/repo; sets RC, OUT, ERR
  RC=0
  OUT="$(cd "$WORLD/repo" && "$BIN/summon.sh" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
posts() { jq -s 'length' "$FAKE_CURL_LOG"; }
content() { jq -sr '.[-1].body | fromjson | .content' "$FAKE_CURL_LOG"; }
has() { [[ "$1" == *"$2"* ]] || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }

summon_setup() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=desk GIT_AUTHOR_EMAIL=desk@fake GIT_COMMITTER_NAME=desk GIT_COMMITTER_EMAIL=desk@fake
  git init -q -b main "$WORLD/repo"
  mkdir -p "$WORLD/repo/factory"
  echo 1.0.0 >"$WORLD/repo/factory/VERSION"
  git -C "$WORLD/repo" add -A
  git -C "$WORLD/repo" commit -q -m "root"
}
issue_event() {  # issue_event <file> <issue|pull_request> <n> <label> <title> <body>
  jq -n --arg k "$2" --argjson n "$3" --arg l "$4" --arg t "$5" --arg b "$6" \
    '{action: "labeled", label: {name: $l}, sender: {login: "someone"},
      ($k): {number: $n, title: $t, body: $b,
             html_url: "https://github.com/test/repo/\(if $k == "issue" then "issues" else "pull" end)/\($n)"}}' >"$1"
}
push_event() {   # push_event <file> <sha> <message>
  jq -n --arg s "$2" --arg m "$3" \
    '{ref: "refs/heads/main", before: "0000000000000000000000000000000000000000", after: $s,
      head_commit: {id: $s, message: $m, url: "https://github.com/test/repo/commit/\($s)"},
      compare: "https://github.com/test/repo/compare/x...y"}' >"$1"
}

# ---------------------------------------------------------------------------------------------
case_fake_curl_semantics() {
  fakegh_setup
  local rc
  printf '{"a":1}' | curl -fsS -X POST -H 'Content-Type: application/json' --data-binary @- https://x.test/1
  printf 'from-file' >"$WORLD/body"
  curl -d @"$WORLD/body" https://x.test/2
  curl --data-raw literal https://x.test/3
  check "three calls logged" eq "$(posts)" 3
  check "@- reads stdin, method and header kept" \
    eq "$(jq -sc '.[0] | [.method, .headers[0], .body, .url]' "$FAKE_CURL_LOG")" '["POST","Content-Type: application/json","{\"a\":1}","https://x.test/1"]'
  check "@file reads the file; a body means POST" eq "$(jq -sc '.[1] | [.method, .body]' "$FAKE_CURL_LOG")" '["POST","from-file"]'
  check "a literal body is sent as is" eq "$(jq -sr '.[2].body' "$FAKE_CURL_LOG")" literal
  rc=0; FAKE_CURL_FAIL='x\.test/4' curl -fsS -d x https://x.test/4 2>"$WORLD/err" || rc=$?
  check "FAKE_CURL_FAIL: exit 22 like curl -f on HTTP 500, still logged" \
    eq "$rc:$(command cat "$WORLD/err"):$(posts)" "22:curl: (22) The requested URL returned error: 500 (https://x.test/4):4"
  rc=0; curl --unknown-flag https://x.test/5 2>/dev/null || rc=$?
  check "an unsupported flag fails loudly (exit 2) and is not logged" eq "$rc:$(posts)" "2:4"
}

case_halt() {
  summon_setup
  printf 'drill: stop all claims while the queue is rebuilt\n' >"$WORLD/repo/factory/HALT"
  git -C "$WORLD/repo" add factory/HALT
  git -C "$WORLD/repo" commit -q -m "halt the factory" -m "Ticket: T9"
  local sha; sha="$(git -C "$WORLD/repo" rev-parse HEAD)"
  push_event "$WORLD/push.json" "$sha" "$(git -C "$WORLD/repo" log -1 --format=%B)"
  DISCORD_WEBHOOK="$HOOK" sm --kind halt --apply --event "$WORLD/push.json"
  check "halt on push: exit 0" eq "$RC" 0
  check "exactly one POST, to the webhook, as JSON" \
    eq "$(posts):$(jq -sr '.[0] | [.method, .url, .headers[0]] | join(" ")' "$FAKE_CURL_LOG")" "1:POST $HOOK Content-Type: application/json"
  local c; c="$(content)"
  check "names one human: the CODEOWNERS owner of factory/HALT" has "$c" "for @$OWNER"
  check "names the ticket: the head commit's Ticket: trailer" has "$c" "Ticket: T9"
  check "names the decision needed" has "$c" "Decision needed: the factory is halted: decide when to lift it"
  check "says why: the first line of factory/HALT" has "$c" "Why: factory/HALT landed on main at ${sha:0:12}: drill: stop all claims"
  check "ends with the link to the commit" eq "$(tail -n1 <<<"$c")" "https://github.com/test/repo/commit/$sha"
  check "no mention can ping anyone" eq "$(jq -sc '.[0].body | fromjson | .allowed_mentions' "$FAKE_CURL_LOG")" '{"parse":[]}'
  check "the webhook URL is never printed" eval '! grep -q secret-token <<<"$OUT$ERR"'

  # Lifting the halt also touches factory/HALT, so the workflow fires; that push is not a summons.
  git -C "$WORLD/repo" rm -q factory/HALT
  git -C "$WORLD/repo" commit -q -m "lift the halt" -m "Ticket: T9"
  push_event "$WORLD/lift.json" "$(git -C "$WORLD/repo" rev-parse HEAD)" "lift"
  DISCORD_WEBHOOK="$HOOK" sm --kind halt --apply --event "$WORLD/lift.json"
  check "a push without factory/HALT: exit 0 and no POST" eq "$RC:$(posts)" "0:1"
  check "and says the halt was lifted" has "$OUT" "the halt was lifted"

  # The factory:halt label on an Issue is the other halt trigger.
  issue_event "$WORLD/label.json" issue 41 factory:halt "Node bravo retired with open claims" ""
  DISCORD_WEBHOOK="$HOOK" sm --kind halt --apply --event "$WORLD/label.json"
  check "halt on label: exit 0, one more POST" eq "$RC:$(posts)" "0:2"
  c="$(content)"
  check "label halt: ticket is the Issue, link is the Issue, reason is the title" \
    eval 'has "$c" "Ticket: #41" && has "$c" "Why: factory:halt set on #41: Node bravo retired" && [ "$(tail -n1 <<<"$c")" = https://github.com/test/repo/issues/41 ]'
}

case_needs_approval() {
  summon_setup
  issue_event "$WORLD/ev.json" issue 12 needs-approval 'Spec: rail charter @everyone' $'Draft by intake.\nTicket: T-01KABC\n'
  DISCORD_WEBHOOK="$HOOK" sm --kind needs-approval --apply --event "$WORLD/ev.json"
  check "exit 0, exactly one POST" eq "$RC:$(posts)" "0:1"
  local c; c="$(content)"
  check "a gate ask (P1) to one human: the factory/** code owner" has "$c" "**Gate ask: spec approval (P1)** for @$GATE_OWNER"
  check "the ticket id from the Issue's Ticket: line, not the Issue number" has "$c" "Ticket: T-01KABC"
  check "the decision needed" has "$c" "Decision needed: approve or reject this spec"
  check "the link" eq "$(tail -n1 <<<"$c")" "https://github.com/test/repo/issues/12"
  check "@everyone in a title is inert (allowed_mentions.parse = [])" \
    eq "$(jq -sc '.[0].body | fromjson | .allowed_mentions' "$FAKE_CURL_LOG")" '{"parse":[]}'
  SUMMONER_TO=desk-alice DISCORD_WEBHOOK="$HOOK" sm --kind needs-approval --apply --event "$WORLD/ev.json"
  check "SUMMONER_TO names the human when set" has "$(content)" "for @desk-alice"
  DISCORD_WEBHOOK="$HOOK" sm --kind needs-approval --apply --to @bob --ticket T7 --link https://x.test/7 --event "$WORLD/ev.json"
  check "flags win over the event" eval 'c="$(content)"; has "$c" "for @bob" && has "$c" "Ticket: T7" && [ "$(tail -n1 <<<"$c")" = https://x.test/7 ]'
  check "three runs, three POSTs (one each)" eq "$(posts)" 3
}

case_needs_acceptance() {
  summon_setup
  issue_event "$WORLD/ev.json" pull_request 88 needs-acceptance "Add the janitor" "no ticket line here"
  DISCORD_WEBHOOK="$HOOK" sm --kind needs-acceptance --apply --event "$WORLD/ev.json" --json
  check "exit 0, exactly one POST" eq "$RC:$(posts)" "0:1"
  check "--json reports what was sent" \
    eq "$(jq -c '[.mode, .kind, .to, .ticket, .link, .posted]' <<<"$OUT")" \
       "[\"apply\",\"needs-acceptance\",\"$GATE_OWNER\",\"#88\",\"https://github.com/test/repo/pull/88\",true]"
  local c; c="$(content)"
  check "a gate ask (P6) naming the decision" \
    eval 'has "$c" "**Gate ask: acceptance (P6)**" && has "$c" "Decision needed: accept or reject this change" && has "$c" "Ticket: #88"'
}

case_refuses_other_kinds() {
  summon_setup
  issue_event "$WORLD/ev.json" issue 3 needs-desk "x" ""
  local k
  for k in factory:halt needs-desk digest HALT "" "halt "; do
    DISCORD_WEBHOOK="$HOOK" sm --kind "$k" --apply --event "$WORLD/ev.json"
    check "kind [$k]: exit 2" eq "$RC" 2
  done
  check "no kind other than the three ever posts" eq "$(posts)" 0
  check "the refusal says where the rest goes" has "$ERR" "goes to the digest"
}

case_never_more_than_one_human() {
  summon_setup
  issue_event "$WORLD/ev.json" issue 3 needs-approval "x" ""
  local who
  for who in "alice,bob" "alice bob" "@alice @bob" "-x"; do
    DISCORD_WEBHOOK="$HOOK" sm --kind needs-approval --apply --to "$who" --event "$WORLD/ev.json"
    check "--to [$who]: exit 1" eq "$RC" 1
  done
  check "nothing was posted" eq "$(posts)" 0
}

case_dry_run_and_failures() {
  summon_setup
  issue_event "$WORLD/ev.json" issue 5 needs-approval "x" ""
  sm --kind needs-approval --event "$WORLD/ev.json"
  check "dry run (the default): exit 0, no POST, needs no webhook" eq "$RC:$(posts)" "0:0"
  check "dry run prints the message and says it was not sent" \
    eval 'has "$OUT" "Decision needed: approve or reject this spec" && has "$OUT" "dry run: not sent"'
  sm --kind needs-approval --apply --event "$WORLD/ev.json"
  check "--apply without DISCORD_WEBHOOK: exit 1, no POST" eq "$RC:$(posts)" "1:0"
  FAKE_CURL_FAIL='discord' DISCORD_WEBHOOK="$HOOK" sm --kind needs-approval --apply --event "$WORLD/ev.json"
  check "a failed POST: exit 1, attempted once" eq "$RC:$(posts)" "1:1"
  check "the failure does not leak the webhook URL" eval '! grep -q secret-token <<<"$OUT$ERR"'
  DISCORD_WEBHOOK="$HOOK" sm --kind needs-approval --apply
  check "no event and no flags: exit 1 (a summons needs a ticket and a link)" eq "$RC:$(posts)" "1:1"
  DISCORD_WEBHOOK="$HOOK" sm --kind halt --apply --ticket T1 --link https://x.test/1
  check "a halt with no event needs a --reason" eq "$RC" 1
  DISCORD_WEBHOOK="$HOOK" sm --kind halt --apply --ticket T1 --link https://x.test/1 --reason "janitor: node retired with open claims"
  check "a halt from the janitor with flags only: one POST" eq "$RC:$(posts)" "0:2"
}

# Criterion 4 is a property of YAML, checked with grep (no YAML parser on the node path, I2).
# Each assertion names the line it pins; actionlint (make lint) checks the file parses.
case_workflow_triggers() {
  local on
  on="$(sed -n '/^on:/,/^[a-z]/p' "$WF")"
  next_line() { grep -x -A1 -- "$1" <<<"$on" | sed -n 2p; }   # the line under a trigger key
  check "on: issues labeled" eq "$(next_line '  issues:')" "    types: [labeled]"
  check "on: pull_request labeled" eq "$(next_line '  pull_request:')" "    types: [labeled]"
  check "on: push to main only" eq "$(next_line '  push:')" "    branches: [main]"
  check "on: push only when factory/HALT is touched" eval 'grep -Eq "^    paths: \[\"factory/HALT\"\]$" <<<"$on"'
  check "push has no other path filter" eq "$(grep -c 'paths' <<<"$on")" 1
  check "no other trigger (schedule, dispatch, pull_request_target, ...)" \
    eq "$(grep -E '^  [a-z_]+:' <<<"$on" | tr -d ' :' | sort | paste -sd,)" "issues,pull_request,push"
  check "the job runs on a push, or on one of the three summons labels" \
    eval 'grep -Fq "contains(fromJSON('"'"'[\"needs-approval\",\"needs-acceptance\",\"factory:halt\"]'"'"'), github.event.label.name)" "$WF"'
  check "the factory:halt label and the push both map to --kind halt" \
    eval 'grep -Fq "KIND: \${{ (github.event_name == '"'"'push'"'"' || github.event.label.name == '"'"'factory:halt'"'"') && '"'"'halt'"'"' || github.event.label.name }}" "$WF"'
  check "the job posts (--apply) with the SUMMONER_WEBHOOK secret" \
    eval 'grep -Fq "run: ./factory/bin/summon.sh --apply --kind \"\$KIND\"" "$WF" && grep -Fq "DISCORD_WEBHOOK: \${{ secrets.SUMMONER_WEBHOOK }}" "$WF"'
  check "read-only token: the summoner never writes to the repo" \
    eq "$(sed -n '/^permissions:/,/^[a-z]/p' "$WF" | grep -c ': write')" 0
}

echo "test_summon"
for c in fake-curl-semantics halt needs-approval needs-acceptance refuses-other-kinds never-more-than-one-human \
         dry-run-and-failures workflow-triggers; do
  run_case "$c"
done
exit "$FAILED"
