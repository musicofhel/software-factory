#!/usr/bin/env bash
# T21 (specs/factory-step3-v1 TB2): factory/bin/lib/gate-context.sh, the gate context and ticket identity.
#   - the event shapes: pull_request (opened, synchronize) and merge_group, from GitHub's own example
#     payloads (tests/fixtures/events, sources in its README), and the node's call;
#   - the queue-ref parse gh-readonly-queue/<base>/pr-<N>-<sha>;
#   - each PR class (ticket, desk, halt, human) and every refusal (a malformed ticket ref, a fork's
#     ticket ref, a stranger's PR, a body or trailer naming another ticket);
#   - the serial queue (TB9, ticket T28): gates.yml called by enqueue.yml (workflow_call) under the
#     caller's event (push, workflow_run, schedule, workflow_dispatch; GATE_QUEUE_PR wins over a
#     pull_request event too) resolves as `queue`: PR GATE_QUEUE_PR read through gh api, base GATE_BASE,
#     head GATE_HEAD, GC_BASE_BRANCH main (a PR targeting another branch is refused); the head must be the queue commit [GATE_BASE,
#     PR head] (every other parent shape, and a GATE_QUEUE_PR that is no number, is refused); an
#     unreadable PR or a base/head outside the checkout is exit 1; identity and the classes as on
#     merge_group (a desk PR stays desk on a main that moved);
#   - common.sh's id validator refuses `/`;
#   - the remaining gate stub (attest-verify) resolves the context first, and keeps run.sh's `not
#     built` contract (rails-proof and scope-check are built: tests/test_diff_gates.sh; commit-check:
#     tests/test_commit_check.sh);
#   - gates.yml runs every factory/bin script from the base checkout ./.base (I16), and takes the queue's
#     pr, base and head as workflow_call inputs (GATE_QUEUE_PR, GATE_BASE, GATE_HEAD).
# Offline; every repo is a temp dir, gh is the fake.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
GC="$BIN/lib/gate-context.sh"
EV="$REPO_ROOT/tests/fixtures/events"
FREPO=Codertocat/Hello-World   # the repository of GitHub's example payloads

# A repo with main (origin/main) and the commits the cases diff: main has README and .adlc/tickets/.keep.
setup() {
  fakegh_setup
  export FAKE_GH_REPO="$FREPO" GITHUB_REPOSITORY="$FREPO"
  printf '{"labels":[],"issues":[],"pulls":[],"collaborators":["dev-box-owner"]}\n' >"$FAKE_GH_ISSUES"
  R="$WORLD/r"
  git init -q -b main "$R"
  git -C "$R" config user.name t; git -C "$R" config user.email t@t.invalid
  mkdir -p "$R/.adlc/tickets" "$R/docs/adr"; echo base >"$R/README.md"; : >"$R/.adlc/tickets/.keep"; echo adr >"$R/docs/adr/0001.md"
  git -C "$R" add -A; git -C "$R" commit -qm base
  BASE="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" update-ref refs/remotes/origin/main "$BASE"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH GH_TOKEN GATE_QUEUE_PR GATE_BASE GATE_HEAD
}
# change <branch> <msg> <op:path>...: a commit on a new branch from BASE; op is + (add/modify) or - (delete)
change() {
  local b="$1" msg="$2" a; shift 2
  git -C "$R" checkout -q -B "$b" "$BASE"
  for a in "$@"; do
    case "$a" in
      +*) mkdir -p "$R/$(dirname "${a#+}")"; echo "$b" >>"$R/${a#+}"; git -C "$R" add -- "${a#+}" ;;
      -*) git -C "$R" rm -q -- "${a#-}" ;;
    esac
  done
  git -C "$R" commit -qm "$msg"
  git -C "$R" rev-parse HEAD
}
# pr_event <fixture> <head-sha> <head-ref> <body> [assoc] [head-repo]: GitHub's example pull_request
# payload, with only the fields this repo's world decides rewritten (shas onto R, the ref, body, author).
pr_event() {
  jq --arg b "$BASE" --arg h "$2" --arg r "$3" --arg body "$4" --arg a "${5:-OWNER}" --arg hr "${6:-$FREPO}" \
    '.pull_request.base.sha = $b | .pull_request.head.sha = $h | .pull_request.head.ref = $r | .pull_request.body = $body
     | .pull_request.author_association = $a | .pull_request.head.repo.full_name = $hr' "$EV/$1" >"$WORLD/event.json"
  export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$WORLD/event.json"
}
ctx() {  # ctx [flags]: run gate-context.sh in R; OUT (stdout), ERR (stderr), RC
  RC=0
  OUT="$(cd "$R" && "$GC" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
field() { jq -r "$1" <<<"$OUT"; }
jqe() { jq -e "$@" >/dev/null; }

case_fixtures_are_githubs() {
  # The fixtures are GitHub's own example payloads, byte for byte (README: source and sha256).
  local f want
  for f in pull_request-opened.json pull_request-synchronize.json merge_group-checks_requested.json; do
    want="$(sed -n "s/^| \`$f\` | .* | \`\([0-9a-f]\{64\}\)\` |$/\1/p" "$EV/README.md")"
    check "$f matches the sha256 in the README" eq "$(sha256sum "$EV/$f" | cut -d' ' -f1)" "$want"
  done
  check "pull_request carries every field gate-context reads" jqe \
    '.pull_request | (.number | numbers) and (.base.sha | strings) and (.head.sha | strings) and (.head.ref | strings)
     and (.head.repo.full_name | strings) and (.user.login | strings) and (.author_association | strings) and has("body")' \
    "$EV/pull_request-opened.json"
  check "merge_group carries base_sha, head_sha and the queue head_ref" jqe \
    '.merge_group | (.base_sha | strings) and (.head_sha | strings) and (.head_ref | startswith("refs/heads/gh-readonly-queue/main/pr-"))' \
    "$EV/merge_group-checks_requested.json"
}

case_pull_request_ticket() {
  setup
  local h; h="$(change ticket/T20/dev-box "work" +sim/t20/hello.sh)"
  local fx
  for fx in pull_request-opened.json pull_request-synchronize.json; do
    pr_event "$fx" "$h" ticket/T20/dev-box $'Ticket: T20\nIssue: #3\nNode: dev-box'
    ctx
    check "$fx: exit 0" eq "$RC:$ERR" 0:
    check "$fx: event, base, head, PR number from the payload" \
      eq "$(field '[.event, .base, .head, .pr] | join(" ")')" "pull_request $BASE $h 2"
    check "$fx: ticket T20, handle dev-box, class ticket" eq "$(field '[.ticket, .handle, .class] | join(" ")')" "T20 dev-box ticket"
    check "$fx: author and association from the payload" eq "$(field '[.author, .author_association] | join(" ")')" "Codertocat OWNER"
  done
  check "pull_request makes no gh call" eq "$(wc -l <"$FAKE_GH_LOG" | tr -d ' ')" 0
}

case_merge_group() {
  setup
  local h g q
  h="$(change ticket/T20/dev-box "work" +sim/t20/hello.sh)"
  # GitHub's queue commit: a merge of the head onto main.
  g="$(git -C "$R" commit-tree "$h^{tree}" -p "$BASE" -p "$h" -m "Merge pull request #104 from ticket/T20/dev-box")"
  q="$(jq -r .merge_group.head_ref "$EV/merge_group-checks_requested.json")"
  jq --arg b "$BASE" --arg g "$g" '.merge_group.base_sha = $b | .merge_group.head_sha = $g' \
    "$EV/merge_group-checks_requested.json" >"$WORLD/event.json"
  git -C "$FAKE_GH_GIT" fetch -q "$R" "+$h:refs/heads/ticket/T20/dev-box" "+$BASE:refs/heads/main"
  jq --arg h "$h" '.pulls += [{number: 104, headRefName: "ticket/T20/dev-box", headRefOid: $h, baseRefName: "main",
      state: "OPEN", title: "T20", body: "Ticket: T20\nNode: dev-box", author: {login: "dev-box-owner"}}]' \
    "$FAKE_GH_ISSUES" >"$WORLD/s" && mv "$WORLD/s" "$FAKE_GH_ISSUES"
  export GITHUB_EVENT_NAME=merge_group GITHUB_EVENT_PATH="$WORLD/event.json" GH_TOKEN=ghs_readonly
  ctx
  check "exit 0" eq "$RC:$ERR" 0:
  check "PR 104 from the queue ref $q" eq "$(field .pr)" 104
  check "base and head are the group's" eq "$(field '[.event, .base, .head] | join(" ")')" "merge_group $BASE $g"
  check "ticket and class from PR 104's head ref" eq "$(field '[.head_ref, .ticket, .handle, .class] | join(" ")')" \
    "ticket/T20/dev-box T20 dev-box ticket"
  check "the author's association (a collaborator)" eq "$(field .author_association)" COLLABORATOR
  check "one read: gh api repos/<repo>/pulls/104" eq "$(jq -c . "$FAKE_GH_LOG")" "[\"api\",\"repos/$FREPO/pulls/104\"]"
  # A queue PR whose head is not the ticket's: the body still has to name it.
  jq '(.pulls[] | select(.number == 104)).body = "Ticket: T21"' "$FAKE_GH_ISSUES" >"$WORLD/s" && mv "$WORLD/s" "$FAKE_GH_ISSUES"
  ctx
  check "on merge_group too, a body naming another ticket is refused" eq "$RC" 2
  # A head_ref that is not the queue's.
  jq '.merge_group.head_ref = "refs/heads/feature/x"' "$WORLD/event.json" >"$WORLD/e2" && mv "$WORLD/e2" "$WORLD/event.json"
  ctx
  check "a merge_group head_ref outside gh-readonly-queue is refused" eq "$RC" 2
  check "  naming it" grep -q "head_ref 'refs/heads/feature/x' is not gh-readonly-queue" <<<"$ERR"
  # The PR cannot be read.
  jq --arg q "$q" '.merge_group.head_ref = ($q | sub("pr-104-"; "pr-999-"))' "$WORLD/event.json" >"$WORLD/e2" && mv "$WORLD/e2" "$WORLD/event.json"
  ctx
  check "an unreadable PR is an operational error (exit 1), never a pass" eq "$RC" 1
}

case_queue_ref_parse() {
  local sha=929f8209d40f77f4abc622a499c93a83babdbe64 r got bad=0
  # shellcheck source=factory/bin/lib/common.sh
  . "$BIN/lib/common.sh"
  # shellcheck source=factory/bin/lib/gate-context.sh
  . "$GC"
  while IFS=' ' read -r r want; do
    got="$(gc_queue_pr "$r" || echo none)"
    eq "$got" "$want" || { echo "      for $r"; bad=1; }
  done <<EOF
refs/heads/gh-readonly-queue/main/pr-104-$sha 104
gh-readonly-queue/main/pr-7-$sha 7
refs/heads/gh-readonly-queue/release/v1/pr-12-$sha 12
refs/heads/gh-readonly-queue/main/pr-0-$sha none
refs/heads/gh-readonly-queue/main/pr-12-929f8209 none
refs/heads/gh-readonly-queue/main/pr-12 none
refs/heads/gh-readonly-queue/main/pr-x-$sha none
refs/heads/ticket/T20/dev-box none
refs/heads/main none
EOF
  check "the queue ref table" eq "$bad" 0
}

case_classes() {
  setup
  local h
  cls() {  # cls <name> <want class> <head> <ref> [assoc]
    pr_event pull_request-opened.json "$3" "$4" "" "${5:-COLLABORATOR}"
    ctx
    check "$1: class $2" eq "$RC:$(field .class 2>/dev/null || true)" "0:$2"
  }
  h="$(change desk/t "desk" +.adlc/tickets/t21.json)"; cls "a desk PR (.adlc only)" desk "$h" desk/t
  h="$(change desk/a "desk" +.adlc/tickets/t22.json +docs/adr/0008.md)"; cls "a desk PR (.adlc and an ADR)" desk "$h" desk/a
  h="$(change halt/add "halt" +factory/HALT)"; cls "adding factory/HALT" halt "$h" halt/add
  git -C "$R" checkout -q -B with-halt "$BASE"; mkdir -p "$R/factory"; echo stop >"$R/factory/HALT"
  git -C "$R" add -A; git -C "$R" commit -qm "halt on main"
  local hb; hb="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" rm -q factory/HALT; git -C "$R" commit -qm resume
  h="$(git -C "$R" rev-parse HEAD)"
  local saved="$BASE"; BASE="$hb"
  cls "removing factory/HALT" halt "$h" halt/remove
  git -C "$R" checkout -q "$hb"; echo again >>"$R/factory/HALT"; git -C "$R" commit -qam "edit halt"
  cls "editing factory/HALT is not a halt PR" human "$(git -C "$R" rev-parse HEAD)" halt/edit
  BASE="$saved"
  h="$(change halt/more "halt plus" +factory/HALT +README.md)"; cls "HALT plus another file" human "$h" halt/more
  h="$(change docs/x "docs" +docs/guide.md)"; cls "a collaborator's docs PR" human "$h" docs/x
  h="$(change mixed "mixed" +.adlc/tickets/t23.json +factory/bin/x.sh)"; cls "a desk path plus factory/bin" human "$h" mixed
  git -C "$R" checkout -q -B empty "$BASE"; git -C "$R" commit -q --allow-empty -m empty
  cls "an empty diff" human "$(git -C "$R" rev-parse HEAD)" empty
  h="$(change desk/o "desk" +.adlc/tickets/t24.json)"; cls "the repo owner's desk PR" desk "$h" desk/o OWNER
  cls "an org member's desk PR" desk "$h" desk/o MEMBER
}

case_refusals() {
  setup
  local h
  refused() {  # refused <name> <head> <ref> <assoc> <head-repo> <stderr regex> [body]
    pr_event pull_request-opened.json "$2" "$3" "${7:-}" "$4" "$5"
    ctx
    check "$1: refused (exit 2)" eq "$RC:$OUT" 2:
    check "  naming why" grep -qE "$6" <<<"$ERR"
  }
  h="$(change desk/s "desk" +.adlc/tickets/t21.json)"
  refused "a stranger's desk-shaped PR" "$h" desk/s NONE stranger/Hello-World 'not a collaborator'
  refused "a contributor's docs PR" "$h" docs/c CONTRIBUTOR "$FREPO" 'CONTRIBUTOR\): not a ticket branch and not a collaborator'
  refused "a fork's ticket ref" "$h" ticket/T20/dev-box NONE stranger/Hello-World 'a fork is never a ticket PR' 'Ticket: T20'
  refused "a collaborator's fork with a ticket ref" "$h" ticket/T20/dev-box COLLABORATOR dev-box-owner/Hello-World 'a fork is never a ticket PR' 'Ticket: T20'
  local r
  for r in ticket/T20/dev-box/extra ticket/T20 ticket//dev-box ticket/-x/dev-box 'ticket/T20/bad_handle'; do
    refused "head ref $r" "$h" "$r" OWNER "$FREPO" 'is under ticket/ but is not ticket/<id>/<handle>' 'Ticket: T20'
  done
}

case_identity() {
  setup
  local h h2
  h="$(change ticket/T20/dev-box "$(printf 'work\n\nAssisted-by: claude-code\nTicket: T20\nNode: dev-box')" +sim/t20/a.sh)"
  pr_event pull_request-opened.json "$h" ticket/T20/dev-box $'Ticket: T20\r\nNode: dev-box'
  ctx
  check "body (CRLF) and trailers name T20: exit 0" eq "$RC:$ERR" 0:
  pr_event pull_request-opened.json "$h" ticket/T20/dev-box $'Ticket: T20\nTicket: T20 \nNode: dev-box'
  ctx
  check "two body lines both naming T20: exit 0" eq "$RC" 0
  pr_event pull_request-opened.json "$h" ticket/T20/dev-box $'Ticket: T21\nNode: dev-box'
  ctx
  check "a body naming T21 is refused" eq "$RC:$OUT" 2:
  check "  naming T21" grep -qF "ticket branch for T20, but the body says 'Ticket: T21'" <<<"$ERR"
  pr_event pull_request-opened.json "$h" ticket/T20/dev-box $'Ticket: T20\nTicket: T21'
  ctx
  check "a second body line naming T21 is refused" eq "$RC" 2
  pr_event pull_request-opened.json "$h" ticket/T20/dev-box 'Node: dev-box'
  ctx
  check "a ticket PR whose body has no Ticket: line is refused" eq "$RC" 2
  check "  saying so" grep -qF "the body has no 'Ticket:' line" <<<"$ERR"
  # A second commit whose trailer names another ticket.
  git -C "$R" checkout -q ticket/T20/dev-box; echo b >"$R/b.txt"; git -C "$R" add b.txt
  git -C "$R" commit -qm "$(printf 'more\n\nTicket: T-victim')"
  h2="$(git -C "$R" rev-parse HEAD)"
  pr_event pull_request-opened.json "$h2" ticket/T20/dev-box 'Ticket: T20'
  ctx
  check "a commit trailer naming T-victim is refused" eq "$RC" 2
  check "  naming the commit and the id" grep -qF "commit ${h2:0:12} has the trailer 'Ticket: T-victim'" <<<"$ERR"
  # A commit with no Ticket: trailer is commit-check's to judge (TB4), not identity's.
  h="$(change ticket/T20/dev-box "no trailers" +sim/t20/c.sh)"
  pr_event pull_request-opened.json "$h" ticket/T20/dev-box 'Ticket: T20'
  ctx
  check "no trailer at all: not an identity mismatch" eq "$RC" 0
  # Identity is a ticket PR's rule: a desk PR's commit may name the tickets it writes.
  h="$(change desk/w "$(printf 'desk: T30\n\nTicket: T30')" +.adlc/tickets/t30.json)"
  pr_event pull_request-opened.json "$h" desk/w 'desk: writes T30' COLLABORATOR
  ctx
  check "a desk PR naming tickets in trailers: class desk, exit 0" eq "$RC:$(field .class)" 0:desk
}

case_node() {
  setup
  local tip lapsed
  # A lapsed branch from an older main, then main moves on: the gate base is the merge-base with
  # origin/main, never the lapsed tip.
  lapsed="$(change ticket/T20/old "lapsed work" +sim/t20/a.sh)"
  git -C "$R" checkout -q -B main "$BASE"; echo moved >>"$R/README.md"; git -C "$R" commit -qam "main moves"
  git -C "$R" update-ref refs/remotes/origin/main "$(git -C "$R" rev-parse HEAD)"
  git -C "$R" checkout -q --detach "$lapsed"; echo more >"$R/sim/t20/b.sh"; git -C "$R" add -A; git -C "$R" commit -qm "new work"
  tip="$(git -C "$R" rev-parse HEAD)"
  ctx --ticket T20
  check "node: exit 0" eq "$RC:$ERR" 0:
  check "node: base = merge-base(origin/main, tip), head = HEAD" eq "$(field '[.event, .base, .head] | join(" ")')" "node $BASE $tip"
  check "node: ticket T20, class ticket, no PR" eq "$(field '[.ticket, .class, (.pr // "none")] | join(" ")')" "T20 ticket none"
  ctx --ticket T20 --base "$lapsed" --head "$tip"
  check "node: explicit --base/--head win (run.sh's call)" eq "$(field '[.base, .head] | join(" ")')" "$lapsed $tip"
  # Explicit flags are the node's call even inside a runner's env.
  pr_event pull_request-opened.json "$tip" ticket/T20/dev-box 'Ticket: T20'
  ctx --ticket T20 --base "$BASE" --head "$tip"
  check "node: flags win over GITHUB_EVENT_NAME" eq "$(field .event)" node
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  ctx
  check "node: no --ticket and no event is a usage error (exit 1)" eq "$RC" 1
  ctx --ticket T20/x
  check "node: an id with / is refused (exit 2)" eq "$RC" 2
  git -C "$R" commit -q --allow-empty -m "$(printf 'x\n\nTicket: T99')"
  ctx --ticket T20
  check "node: a trailer naming another ticket is refused" eq "$RC" 2
}

case_id_validator() {
  # shellcheck source=factory/bin/lib/common.sh
  . "$BIN/lib/common.sh"
  local id bad=0
  for id in T1 T20 T-01K8ABCDEF T-sim-parent 'gh:octo#12' T1.2; do valid_ticket_id "$id" || { echo "      refused $id"; bad=1; }; done
  for id in T20/x ticket/T20 'gh:owner/repo#12' / -T1 '' 'T 1'; do ! valid_ticket_id "$id" || { echo "      accepted [$id]"; bad=1; }; done
  check "valid ids pass, ids with / (and flags, blanks) are refused" eq "$bad" 0
}

case_gate_stubs() {
  setup
  local h s
  h="$(change ticket/T20/dev-box "$(printf 'work\n\nTicket: T20')" +sim/t20/a.sh)"
  # shellcheck disable=SC2043  # attest-verify is the last stub (TB11 builds it)
  for s in attest-verify; do
    pr_event pull_request-opened.json "$h" ticket/T20/dev-box 'Ticket: T20'
    RC=0; (cd "$R" && "$BIN/$s.sh") >/dev/null 2>"$WORLD/err" || RC=$?
    check "$s: exit 2, the context first, then 'not built'" \
      eq "$RC:$(sed -n '1s/^\([a-z-]*\): ticket gate from .* on {.*"ticket":"T20".*}$/\1/p' "$WORLD/err"):$(sed -n 2p "$WORLD/err")" \
         "2:$s:$s: not built"
    pr_event pull_request-opened.json "$h" ticket/T20/dev-box 'Ticket: T21'
    RC=0; (cd "$R" && "$BIN/$s.sh") >/dev/null 2>"$WORLD/err" || RC=$?
    check "$s: a body naming T21 is refused before the gate body" \
      eq "$RC:$(grep -c 'not built' "$WORLD/err" || true):$(grep -c "says 'Ticket: T21'" "$WORLD/err")" 2:0:1
    unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
    RC=0; (cd "$R" && "$BIN/$s.sh" --ticket T20 --base "$BASE" --head "$h") >/dev/null 2>"$WORLD/err" || RC=$?
    check "$s: run.sh's node call (--ticket --base --head) keeps exit 2 'not built'" eq "$RC:$(tail -n1 "$WORLD/err")" "2:$s: not built"
  done
}

# queue_pr <n> <head-sha> <head-ref> <body> [base-ref] [head-repo] [author]: PR n in the fake's store
# (GET pulls/<n>), by default from the repo, onto main, by dev-box-owner (a collaborator).
queue_pr() {
  jq --argjson n "$1" --arg h "$2" --arg r "$3" --arg body "$4" --arg b "${5:-main}" --arg hr "${6:-$FREPO}" --arg a "${7:-dev-box-owner}" \
    '.pulls = [.pulls[] | select(.number != $n)] + [{number: $n, headRefName: $r, headRefOid: $h, baseRefName: $b,
      headRepository: $hr, state: "OPEN", title: "queued", body: $body, author: {login: $a}}]' \
    "$FAKE_GH_ISSUES" >"$WORLD/s" && mv "$WORLD/s" "$FAKE_GH_ISSUES"
}
# qcommit <tree-ish> <subject> <parent>...: a commit in enqueue.sh's queue-commit identity
# (github-actions[bot] author and committer); prints its sha
qcommit() {
  local t="$1" m="$2" p; shift 2
  local -a ps=(); for p in "$@"; do ps+=(-p "$p"); done
  printf '%s\n' "$m" | GIT_AUTHOR_NAME='github-actions[bot]' GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
    GIT_COMMITTER_NAME='github-actions[bot]' GIT_COMMITTER_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
    git -C "$R" commit-tree "$t^{tree}" "${ps[@]}"
}
# queue_env <caller event> <pr> <base> <head>: gates.yml as enqueue.yml calls it (workflow_call): the
# caller's event name and a payload of its shape, the inputs as GATE_QUEUE_PR, GATE_BASE, GATE_HEAD.
queue_env() {
  case "$1" in
    push) jq -n --arg b "$3" '{ref: "refs/heads/main", before: ("0" * 40), after: $b, repository: {full_name: "Codertocat/Hello-World"}}' ;;
    workflow_run) jq -n '{action: "completed", workflow_run: {name: "gates", event: "pull_request", conclusion: "success",
                          pull_requests: [{number: 2}]}}' ;;
    schedule) jq -n '{schedule: "*/15 * * * *"}' ;;
    workflow_dispatch) jq -n '{ref: "refs/heads/main", inputs: {dry_run: "false"}}' ;;
  esac >"$WORLD/event.json"
  export GITHUB_EVENT_NAME="$1" GITHUB_EVENT_PATH="$WORLD/event.json" GATE_QUEUE_PR="$2" GATE_BASE="$3" GATE_HEAD="$4" GH_TOKEN=ghs_readonly
}
# base_branch: GC_BASE_BRANCH as gate_context sets it in R (it is not in the JSON).
base_branch() {
  (
    cd "$R"
    # shellcheck source=factory/bin/lib/common.sh
    . "$BIN/lib/common.sh"
    # shellcheck source=factory/bin/lib/gate-context.sh
    . "$GC"
    gate_context >/dev/null 2>&1
    printf '%s\n' "$GC_BASE_BRANCH"
  )
}

case_queue() {
  setup
  local h s ev
  h="$(change ticket/T20/dev-box "$(printf 'work\n\nTicket: T20')" +sim/t20/hello.sh)"
  queue_pr 7 "$h" ticket/T20/dev-box $'Ticket: T20\nNode: dev-box'
  # enqueue.sh's queue commit: parents [main, PR head], github-actions[bot], the merge subject.
  s="$(qcommit "$h" "Merge pull request #7 from Codertocat/ticket/T20/dev-box" "$BASE" "$h")"
  for ev in push workflow_run schedule workflow_dispatch; do
    queue_env "$ev" 7 "$BASE" "$s"; : >"$FAKE_GH_LOG"
    ctx
    check "$ev caller: exit 0" eq "$RC:$ERR" 0:
    check "$ev caller: event queue, PR 7, base GATE_BASE, head GATE_HEAD" \
      eq "$(field '[.event, .pr, .base, .head] | join(" ")')" "queue 7 $BASE $s"
    check "$ev caller: ticket and class from PR 7's head ref" \
      eq "$(field '[.head_ref, .ticket, .handle, .class, .author_association] | join(" ")')" "ticket/T20/dev-box T20 dev-box ticket COLLABORATOR"
    check "$ev caller: one read, gh api repos/<repo>/pulls/7" eq "$(jq -c . "$FAKE_GH_LOG")" "[\"api\",\"repos/$FREPO/pulls/7\"]"
  done
  check "GC_BASE_BRANCH is main" eq "$(base_branch)" main
  queue_pr 7 "$h" ticket/T20/dev-box $'Ticket: T20\nNode: dev-box' release/v1
  ctx
  check "  a queue PR that targets release/v1: refused (the queue merges into main only)" eq "$RC:$OUT" 2:
  check "  naming the branch" grep -q "PR #7 targets release/v1, and the queue merges into main only" <<<"$ERR"
  queue_pr 7 "$h" ticket/T20/dev-box $'Ticket: T20\nNode: dev-box'
  # The queue env wins over a pull_request event (GitHub's payload: PR 2, the PR head).
  pr_event pull_request-opened.json "$h" ticket/T20/other 'Ticket: T20'
  export GATE_QUEUE_PR=7 GATE_BASE="$BASE" GATE_HEAD="$s" GH_TOKEN=ghs_readonly
  ctx
  check "GATE_QUEUE_PR wins over a pull_request event of PR 2: queue, PR 7, PR 7's ref, the queue commit" \
    eq "$RC:$(field '[.event, .pr, .head_ref, .head] | join(" ")')" "0:queue 7 ticket/T20/dev-box $s"
  # gates.yml sets GATE_QUEUE_PR to '' (no inputs) on pull_request and merge_group: the event's own path.
  export GATE_QUEUE_PR='' GATE_BASE='' GATE_HEAD=''
  ctx
  check "an empty GATE_QUEUE_PR (gates.yml off the queue) leaves the pull_request event" \
    eq "$RC:$(field '[.event, .pr, .head] | join(" ")')" "0:pull_request 2 $h"
}

case_queue_refusals() {
  setup
  local h h2 o s n subj="Merge pull request #7 from Codertocat/ticket/T20/dev-box"
  o="$(change elsewhere "another line of main" +README.md)"
  h="$(change ticket/T20/dev-box "$(printf 'work\n\nTicket: T20')" +sim/t20/a.sh)"
  git -C "$R" commit -q --allow-empty -m "$(printf 'more\n\nTicket: T20')"
  h2="$(git -C "$R" rev-parse HEAD)"
  queue_pr 7 "$h" ticket/T20/dev-box 'Ticket: T20'
  queue_pr 8 "$h2" ticket/T21/dev-box 'Ticket: T21'
  qrefused() {  # qrefused <name> <pr> <head> <stderr regex>
    queue_env push "$2" "$BASE" "$3"; ctx
    check "$1: refused (exit 2)" eq "$RC:$OUT" 2:
    check "  naming why" grep -qE "$4" <<<"$ERR"
  }
  local why="queue: head [0-9a-f]{12} is not the merge of PR #[0-9]+'s head onto ${BASE:0:12}"
  qrefused "one parent (a squash shape)" 7 "$(qcommit "$h" "$subj" "$BASE")" "$why"
  qrefused "the PR head itself as GATE_HEAD" 7 "$h" "$why"
  qrefused "parents [another commit, PR head]" 7 "$(qcommit "$h" "$subj" "$o" "$h")" "$why \\(parents $o $h\\)"
  qrefused "parents [PR head, base] (swapped)" 7 "$(qcommit "$h" "$subj" "$h" "$BASE")" "$why"
  qrefused "parents [base, a commit that is not PR 7's head]" 7 "$(qcommit "$h2" "$subj" "$BASE" "$h2")" "$why"
  qrefused "three parents [base, PR head, another]" 7 "$(qcommit "$h" "$subj" "$BASE" "$h" "$o")" "$why"
  s="$(qcommit "$h" "$subj" "$BASE" "$h")"
  qrefused "PR 7's queue commit run as PR 8" 8 "$s" "merge of PR #8's head"
  for n in abc 0 07 -1 '#7' '7 ' 7x; do
    : >"$FAKE_GH_LOG"
    qrefused "GATE_QUEUE_PR '$n'" "$n" "$s" "GATE_QUEUE_PR '$n' is not a PR number"
    check "  no gh call" eq "$(wc -l <"$FAKE_GH_LOG" | tr -d ' ')" 0
  done
  # Operational errors: exit 1, never a pass and never a refusal.
  queue_env push 99 "$BASE" "$s"; ctx
  check "an unreadable PR (404): exit 1" eq "$RC" 1
  check "  saying so" grep -qF "cannot read PR #99 of $FREPO" <<<"$ERR"
  queue_env push 7 "$BASE" "$(printf 'ab%.0s' {1..20})"; ctx
  check "a head not in the checkout: exit 1" eq "$RC" 1
  check "  saying so" grep -qF "is not in this checkout" <<<"$ERR"
  queue_env push 7 "$(printf 'cd%.0s' {1..20})" "$s"; ctx
  check "a base not in the checkout: exit 1" eq "$RC" 1
  queue_env push 7 "$BASE" ""; ctx
  check "no GATE_HEAD: exit 1" eq "$RC" 1
  check "  saying so" grep -qF "the event has no base and head sha" <<<"$ERR"
}

case_queue_identity_classes() {
  setup
  local h s hd m2 tree
  # A PR commit whose trailer names another ticket: refused on the queue as on merge_group.
  h="$(change ticket/T20/dev-box "$(printf 'work\n\nTicket: T-victim')" +sim/t20/a.sh)"
  queue_pr 7 "$h" ticket/T20/dev-box 'Ticket: T20'
  s="$(qcommit "$h" "Merge pull request #7 from Codertocat/ticket/T20/dev-box" "$BASE" "$h")"
  queue_env push 7 "$BASE" "$s"; ctx
  check "a PR commit with 'Ticket: T-victim', via the queue: refused (exit 2)" eq "$RC:$OUT" 2:
  check "  naming the commit and the id" grep -qF "commit ${h:0:12} has the trailer 'Ticket: T-victim'" <<<"$ERR"
  h="$(change ticket/T20/dev-box "$(printf 'work\n\nTicket: T20')" +sim/t20/a.sh)"
  s="$(qcommit "$h" "Merge pull request #7 from Codertocat/ticket/T20/dev-box" "$BASE" "$h")"
  queue_pr 7 "$h" ticket/T20/dev-box 'Ticket: T21'
  queue_env push 7 "$BASE" "$s"; ctx
  check "a PR body naming T21, via the queue: refused" eq "$RC" 2
  check "  naming T21" grep -qF "the body says 'Ticket: T21'" <<<"$ERR"
  queue_pr 7 "$h" ticket/T20/dev-box 'Ticket: T20' main stranger/Hello-World
  queue_env push 7 "$BASE" "$s"; ctx
  check "a fork's ticket ref, via the queue: refused" eq "$RC" 2
  check "  a fork is never a ticket PR" grep -qF "a fork is never a ticket PR" <<<"$ERR"
  hd="$(change docs/s "docs" +docs/guide.md)"
  queue_pr 9 "$hd" docs/s '' main "$FREPO" stranger
  queue_env push 9 "$BASE" "$(qcommit "$hd" "Merge pull request #9 from Codertocat/docs/s" "$BASE" "$hd")"; ctx
  check "a stranger's PR, via the queue: refused" eq "$RC" 2
  check "  not a collaborator" grep -qF "not a ticket branch and not a collaborator" <<<"$ERR"
  # A desk PR through the queue is a desk PR.
  hd="$(change desk/t "desk" +.adlc/tickets/t21.json +docs/adr/0008.md)"
  queue_pr 8 "$hd" desk/t ''
  s="$(qcommit "$hd" "Merge pull request #8 from Codertocat/desk/t" "$BASE" "$hd")"
  queue_env schedule 8 "$BASE" "$s"; ctx
  check "a desk PR via the queue: class desk" eq "$RC:$(field '[.event, .class] | join(" ")')" "0:queue desk"
  # main moved (README) and the queue commit is built on the new main: BASE...HEAD is the PR's diff,
  # never main's change, so the class is still desk.
  git -C "$R" checkout -q -B main "$BASE"; echo moved >>"$R/README.md"; git -C "$R" commit -qam "main moves"
  m2="$(git -C "$R" rev-parse HEAD)"
  tree="$(git -C "$R" merge-tree --write-tree "$m2" "$hd")"
  s="$(qcommit "$tree" "Merge pull request #8 from Codertocat/desk/t" "$m2" "$hd")"
  queue_env workflow_run 8 "$m2" "$s"; ctx
  check "  on a main that moved since the PR's base: still desk" eq "$RC:$(field '[.base, .class] | join(" ")')" "0:$m2 desk"
  h="$(change halt/add "halt" +factory/HALT)"
  queue_pr 10 "$h" halt/add ''
  queue_env push 10 "$BASE" "$(qcommit "$h" "Merge pull request #10 from Codertocat/halt/add" "$BASE" "$h")"; ctx
  check "a halt PR via the queue: class halt" eq "$RC:$(field .class)" 0:halt
}

case_gates_yml_base_scripts() {
  local wf="$REPO_ROOT/.github/workflows/gates.yml" bad
  # Every run: step that calls a factory/bin script calls the base's copy, ./.base/factory/bin/...
  bad="$(yq -r '.jobs[].steps[] | select(has("run")) | .run' "$wf" | grep -E 'factory/bin/' | grep -vE '(^|[ ;&|])\./\.base/factory/bin/' || true)"
  check "no gate step runs the head's factory/bin" eq "$bad" ""
  check "context, rails-proof, scope, tamper, commit-check, attest-verify, build-test (T24), desk (T26), depends-on and tier-order (T27), owners and halt-guard (T29) run a base script" \
    eq "$(yq -r '.jobs | to_entries[] | select([.value.steps[] | select(has("run")) | .run] | join(" ") | test("\\./\\.base/factory/bin/")) | .key' "$wf" | sort | tr '\n' ' ')" \
       "attest-verify build-test commit-check context depends-on desk halt-guard owners rails-proof scope tamper tier-order "
  # Each such job: the head (full history) checked out first, then the base into .base.
  local j
  for j in context rails-proof scope tamper commit-check attest-verify build-test desk depends-on tier-order owners halt-guard; do
    check "$j: checkout head (fetch-depth 0), then base into .base" \
      eq "$(yq -o=json -I=0 ".jobs[\"$j\"].steps | map(select((.uses // \"\") | test(\"^actions/checkout@\")) | .with)" "$wf")" \
         '[{"ref":"${{ env.GATE_HEAD }}","fetch-depth":0},{"ref":"${{ env.GATE_BASE }}","path":".base"}]'
    check "$j: no if: (it reports on pull_request and merge_group)" eq "$(yq -r ".jobs[\"$j\"] | has(\"if\")" "$wf")" false
  done
  check "GATE_BASE / GATE_HEAD are the queue's inputs, else the event's base and head; GATE_QUEUE_PR the queue's pr" \
    eq "$(yq -r '.env.GATE_BASE + " | " + .env.GATE_HEAD + " | " + .env.GATE_QUEUE_PR' "$wf")" \
       '${{ inputs.base || github.event.pull_request.base.sha || github.event.merge_group.base_sha }} | ${{ inputs.head || github.event.pull_request.head.sha || github.event.merge_group.head_sha }} | ${{ inputs.pr }}'
  check "gates run on pull_request, merge_group and workflow_call (the serial queue, enqueue.yml)" \
    eq "$(yq -r '.on | keys | join(" ")' "$wf")" "pull_request merge_group workflow_call"
  check "workflow_call takes pr, base and head, required strings" \
    eq "$(yq -o=json -I=0 '.on.workflow_call.inputs | to_entries | map([.key, .value.type, .value.required])' "$wf")" \
       '[["pr","string",true],["base","string",true],["head","string",true]]'
}

for c in fixtures-are-githubs pull-request-ticket merge-group queue-ref-parse classes refusals identity node id-validator \
         gate-stubs queue queue-refusals queue-identity-classes gates-yml-base-scripts; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
