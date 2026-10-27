#!/usr/bin/env bash
# T23 acceptance 2 (specs/factory-step3-v1 TB4): factory/bin/commit-check.sh passes the node's commit
# and fails an untrailered commit, a foreign `Ticket:` and a fake post-merge shape.
#   - the node's form (--ticket --base --head) on the ONE commit lib/run.sh's run_ticket_commit
#     writes, and on the fleet-shaped branch it replaces (which fails);
#   - every class: ticket (Signed-off-by, Assisted-by, Ticket and Node equal to the branch's), desk,
#     halt and human (the DCO only); trailers are the message's last paragraph only;
#   - the post-merge exemption: the commit the real post-merge.sh --apply lands passes unsigned, and
#     every near miss of its shape fails; CC_PM_IDENT is post-merge's identity;
#   - merge_group: GitHub's queue merge commit is skipped in exactly its measured shape, else checked;
#   - the serial queue (event `queue`, TB9 ticket T28: gates.yml called by enqueue.yml with
#     GATE_QUEUE_PR, GATE_BASE, GATE_HEAD): enqueue.sh's queue commit (parents [base, PR head],
#     github-actions[bot] author and committer, subject `Merge pull request #<N> from `) is skipped and
#     the PR's own commits are still checked; a wrong identity or subject is checked (so it fails), a
#     wrong parent shape is refused by gate-context first; neither event skips the other's shape;
#   - every commit of the range counts (a merge commit inside a PR too), and the range is BASE..HEAD.
# Offline; every repo is a temp dir, gh and adlc are the fakes, the events GitHub's example payloads.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
CC="$BIN/commit-check.sh"
EV="$REPO_ROOT/tests/fixtures/events"
FREPO=Codertocat/Hello-World   # the repository of GitHub's example payloads
FREPO_OWNER="${FREPO%/*}"
SOB='Signed-off-by: dev <dev@fake>'
NODE_TR=('Assisted-by: claude-code@2.1.280' 'Ticket: T20' 'Node: dev-box' 'Signed-off-by: node <node@fake>')
PM_IDENT='github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'

# A repo whose main is ROOT then BASE (both unsigned; origin/main = BASE), holding README, the store,
# the gate manifest, the findings ledger and an ADR. PR 2 (pull_request) and PR 104 (merge_group) are
# GitHub's example payloads, rewritten onto it.
setup() {
  fakegh_setup
  export FAKE_GH_REPO="$FREPO" GITHUB_REPOSITORY="$FREPO" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  printf '{"labels":[],"issues":[],"pulls":[],"collaborators":["dev-box-owner"]}\n' >"$FAKE_GH_ISSUES"
  R="$WORLD/r"
  git init -q -b main "$R"
  git -C "$R" config user.name t; git -C "$R" config user.email t@t.invalid
  echo root >"$R/README.md"; git -C "$R" add -A; git -C "$R" commit -qm root
  ROOT="$(git -C "$R" rev-parse HEAD)"
  mkdir -p "$R/.adlc" "$R/factory/ledger" "$R/docs/adr"
  echo '[{"id":"T20","title":"twenty"}]' >"$R/.adlc/store.json"; : >"$R/.adlc/manifest.jsonl"
  : >"$R/factory/ledger/findings.jsonl"; echo adr >"$R/docs/adr/0001.md"
  git -C "$R" add -A; git -C "$R" commit -qm base
  BASE="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" update-ref refs/remotes/origin/main "$BASE"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH GH_TOKEN GATE_QUEUE_PR GATE_BASE GATE_HEAD
}
# msg <subject> <trailer>...: a message whose last paragraph is the trailers
msg() { printf '%s\n\n' "$1"; printf '%s\n' "${@:2}"; }
# change <branch> <msg> <+path>...: a commit on a new branch from BASE; prints its sha
change() {
  local b="$1" m="$2"; shift 2
  git -C "$R" checkout -q -B "$b" "$BASE"
  more "$m" "$@"
}
# more <msg> <+path>...: a commit on the current branch; prints its sha
more() {
  local m="$1" a; shift
  for a in "$@"; do mkdir -p "$R/$(dirname "${a#+}")"; echo "$m" >>"$R/${a#+}"; git -C "$R" add -- "${a#+}"; done
  git -C "$R" commit -q --allow-empty -m "$m"
  git -C "$R" rev-parse HEAD
}
# ct <author ident> <committer ident> <tree-ish> <msg> <parent>...: commit-tree as given; prints its sha
ct() {
  local an="${1% <*}" ae="${1##*<}" cn="${2% <*}" ce="${2##*<}" tree="$3" m="$4" p; shift 4
  local -a ps=(); for p in "$@"; do ps+=(-p "$p"); done
  printf '%s\n' "$m" | GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="${ae%>}" GIT_COMMITTER_NAME="$cn" GIT_COMMITTER_EMAIL="${ce%>}" \
    git -C "$R" commit-tree "$tree^{tree}" "${ps[@]}"
}
# pr_event <fixture> <head-sha> <head-ref> <body> [assoc]: GitHub's example pull_request payload with
# the fields this world decides rewritten (base BASE, head, ref, body, author association).
pr_event() {
  jq --arg b "$BASE" --arg h "$2" --arg r "$3" --arg body "$4" --arg a "${5:-OWNER}" --arg hr "$FREPO" \
    '.pull_request.base.sha = $b | .pull_request.head.sha = $h | .pull_request.head.ref = $r | .pull_request.body = $body
     | .pull_request.author_association = $a | .pull_request.head.repo.full_name = $hr' "$EV/$1" >"$WORLD/event.json"
  export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$WORLD/event.json"
}
# ticket_pr <head>: a pull_request from ticket/T20/dev-box whose body names T20 (as run.sh writes it)
ticket_pr() { pr_event pull_request-opened.json "$1" ticket/T20/dev-box $'Ticket: T20\nNode: dev-box'; }
cc() {  # cc [flags]: run commit-check in R; RC, OUT (stdout), ERR (stderr)
  RC=0
  OUT="$(cd "$R" && "$CC" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
has() { [[ "$1" == *"$2"* ]] || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }
lacks() { [[ "$1" != *"$2"* ]] || { printf '      [%s] has [%s]\n' "$1" "$2"; return 1; }; }
fails() {  # fails <name> <commit> <why>: exit 2, that commit named with that reason, nothing on stdout
  check "$1: exit 2" eq "$RC:$OUT" 2:
  check "  names ${2:0:12}: $3" has "$ERR" "FAIL: ${2:0:12} "
  check "  why" grep -qF -- "$3" <<<"$(grep -F "FAIL: ${2:0:12} " <<<"$ERR")"
}

case_node_commit() {
  setup
  local tip node want
  # fleet's shape: a worker commit, then its --no-ff merge into the integration branch; neither trailered.
  git -C "$R" checkout -q -b fleet/integration "$BASE"
  git -C "$R" checkout -q -b fleet/worker
  more "worker: T-x" +sim/tx/hello.sh >/dev/null
  git -C "$R" checkout -q fleet/integration
  git -C "$R" merge -q --no-ff fleet/worker -m "Merge fleet/worker into fleet/integration"
  tip="$(git -C "$R" rev-parse HEAD)"
  cc --ticket T-x --base "$BASE" --head "$tip"
  check "fleet's own branch (worker commit + --no-ff merge): exit 2" eq "$RC" 2
  check "  both commits fail for want of Signed-off-by" eq "$(grep -c 'FAIL: .*no Signed-off-by' <<<"$ERR")" 2
  check "  the summary counts 2 of 2" has "$ERR" "FAIL: 2 of 2 commit(s)"
  # The node's real output: lib/run.sh's run_ticket_commit, as run.sh's on_success calls it.
  node="$(
    # shellcheck source=factory/bin/lib/common.sh
    . "$BIN/lib/common.sh"
    # shellcheck source=factory/bin/lib/run.sh
    . "$BIN/lib/run.sh"
    # shellcheck disable=SC2034  # read by run_ticket_commit
    CLONE="$R" ADAPTER=claude-code ADAPTER_VERSION=2.1.280 TICKET=T-x HANDLE=dev-box
    export GIT_AUTHOR_NAME=node GIT_AUTHOR_EMAIL=node@fake GIT_COMMITTER_NAME=node GIT_COMMITTER_EMAIL=node@fake
    run_ticket_commit "$BASE" "$tip" "factory: T-x built on dev-box" "Factory-Outcome: built" "Fleet-Run: fr-1" "Fleet-Strikes: 1"
  )"
  want="$(msg "factory: T-x built on dev-box" "Factory-Outcome: built" "Fleet-Run: fr-1" "Fleet-Strikes: 1" \
    "Assisted-by: claude-code@2.1.280" "Ticket: T-x" "Node: dev-box" "Signed-off-by: node <node@fake>")"
  check "the node's commit: one parent, the merge-base" eq "$(git -C "$R" rev-list --parents -n1 "$node")" "$node $BASE"
  check "  fleet's final tree" eq "$(git -C "$R" rev-parse "$node^{tree}")" "$(git -C "$R" rev-parse "$tip^{tree}")"
  check "  the subject and one trailer paragraph" eq "$(git -C "$R" log -1 --format=%B "$node")" "$want"
  cc --ticket T-x --base "$BASE" --head "$node"
  check "commit-check on it (node form): exit 0" eq "$RC:$OUT" 0:
  check "  the ticket gate passes 1 commit" has "$ERR" "commit-check: pass: 1 commit(s) in ${BASE:0:12}..${node:0:12} carry the ticket trailers"
  cc --ticket T-x --head "$node"
  check "without --base: the merge-base with origin/main, exit 0" eq "$RC" 0
  cc --ticket T-y --base "$BASE" --head "$node"
  check "the same commit gated as T-y: refused (exit 2)" eq "$RC:$OUT" 2:
  check "  naming T-x" has "$ERR" "ticket branch for T-y, but commit ${node:0:12} has the trailer 'Ticket: T-x'"
}

case_untrailered() {
  setup
  local h
  h="$(change ticket/T20/dev-box "work" +sim/t20/a.sh)"
  cc --ticket T20 --base "$BASE" --head "$h"
  fails "node form, a commit with no trailers" "$h" "no Signed-off-by trailer (the DCO)"
  ticket_pr "$h"; cc
  fails "ticket PR, a commit with no trailers" "$h" "no Signed-off-by trailer (the DCO)"
  h="$(change ticket/T20/dev-box "$(msg work 'Assisted-by: claude-code@2.1.280' 'Ticket: T20' 'Node: dev-box')" +sim/t20/a.sh)"
  ticket_pr "$h"; cc
  fails "ticket PR, every trailer but Signed-off-by" "$h" "no Signed-off-by trailer"
  # Only the last paragraph is the trailer block (git's parser): trailers followed by prose do not count.
  h="$(change ticket/T20/dev-box "$(msg work "${NODE_TR[@]}"; printf '\nand a closing remark.')" +sim/t20/a.sh)"
  ticket_pr "$h"; cc
  fails "trailers above a prose paragraph" "$h" "no Signed-off-by trailer"
}

case_ticket_class() {
  setup
  local h h2
  h="$(change ticket/T20/dev-box "$(msg work "${NODE_TR[@]}")" +sim/t20/a.sh)"
  ticket_pr "$h"; cc
  check "all four trailers, Ticket and Node the branch's: exit 0" eq "$RC:$OUT" 0:
  check "  ok, the ticket rule" eval 'has "$ERR" "${h:0:12} ok" && has "$ERR" "carry the ticket trailers"'
  h="$(change ticket/T20/dev-box "$(msg work 'Ticket: T20' 'Node: dev-box' "$SOB")" +sim/t20/a.sh)"
  ticket_pr "$h"; cc
  fails "no Assisted-by" "$h" "no Assisted-by trailer"
  h="$(change ticket/T20/dev-box "$(msg work 'Assisted-by: claude-code@2.1.280' 'Node: dev-box' "$SOB")" +sim/t20/a.sh)"
  ticket_pr "$h"; cc
  fails "no Ticket:" "$h" "no Ticket: trailer (the branch's is T20)"
  h="$(change ticket/T20/dev-box "$(msg work 'Assisted-by: claude-code@2.1.280' 'Ticket: T20' "$SOB")" +sim/t20/a.sh)"
  ticket_pr "$h"; cc
  fails "no Node:" "$h" "no Node: trailer (the branch's handle is dev-box)"
  h="$(change ticket/T20/dev-box "$(msg work 'Assisted-by: claude-code@2.1.280' 'Ticket: T20' 'Node: other-box' "$SOB")" +sim/t20/a.sh)"
  ticket_pr "$h"; cc
  fails "Node: other-box on dev-box's branch" "$h" "'Node: other-box', not the branch's dev-box"
  # A foreign Ticket: gate_identity (lib/gate-context.sh) refuses it before the body runs; either way
  # exit 2, naming the other id.
  h="$(change ticket/T20/dev-box "$(msg work 'Assisted-by: claude-code@2.1.280' 'Ticket: T21' 'Node: dev-box' "$SOB")" +sim/t20/a.sh)"
  ticket_pr "$h"; cc
  check "a foreign Ticket: T21: exit 2" eq "$RC:$OUT" 2:
  check "  naming T21" has "$ERR" "has the trailer 'Ticket: T21'"
  h="$(change ticket/T20/dev-box "$(msg work 'Assisted-by: claude-code@2.1.280' 'Ticket: T20' 'Ticket: T21' 'Node: dev-box' "$SOB")" +sim/t20/a.sh)"
  ticket_pr "$h"; cc
  check "T20 and a second Ticket: T21 on one commit: exit 2, naming T21" eval '[ "$RC" = 2 ] && has "$ERR" "T21"'
  # One bad commit among good ones fails the PR, and only it is named.
  h="$(change ticket/T20/dev-box "$(msg work "${NODE_TR[@]}")" +sim/t20/a.sh)"
  h2="$(more "$(msg more 'Ticket: T20' 'Node: dev-box' "$SOB")" +sim/t20/b.sh)"
  more "$(msg again "${NODE_TR[@]}")" +sim/t20/c.sh >/dev/null
  ticket_pr "$(git -C "$R" rev-parse HEAD)"; cc
  fails "three commits, the middle one without Assisted-by" "$h2" "no Assisted-by trailer"
  check "  only it fails: 1 of 3" eval 'has "$ERR" "FAIL: 1 of 3 commit(s)" && has "$ERR" "${h:0:12} ok"'
}

case_desk_halt_human() {
  setup
  local h
  dhh() {  # dhh <class> <ref> <path>: a signed commit without Assisted-by passes, an unsigned one fails
    h="$(change "$2" "$(msg "$1 work" 'Ticket: T30' "$SOB")" "+$3")"
    pr_event pull_request-opened.json "$h" "$2" "" COLLABORATOR; cc
    check "$1: Signed-off-by only (no Assisted-by, a Ticket: naming T30): exit 0" eq "$RC:$OUT" 0:
    check "  the $1 rule" has "$ERR" "carry the $1 trailers"
    h="$(change "$2" "$1 work" "+$3")"
    pr_event pull_request-opened.json "$h" "$2" "" COLLABORATOR; cc
    fails "$1: unsigned" "$h" "no Signed-off-by trailer"
    check "  the $1 rule" has "$ERR" "fail the $1 rule"
  }
  dhh desk desk/t30 .adlc/tickets/t30.json
  dhh halt halt/stop factory/HALT
  dhh human docs/guide docs/guide.md
  # git's own -s writes the DCO the same way.
  git -C "$R" checkout -q -B docs/s "$BASE"; echo s >"$R/s.md"; git -C "$R" add s.md; git -C "$R" commit -qs -m "with -s"
  pr_event pull_request-opened.json "$(git -C "$R" rev-parse HEAD)" docs/s "" MEMBER; cc
  check "human: git commit -s: exit 0" eq "$RC" 0
}

# pm_world: setup, then main merges PR #7 from ticket/T20/dev-box (M) and the real post-merge.sh
# --apply completes T20 and lands its commit (P) on main, with a developer's identity in the env.
pm_world() {
  setup
  local h out
  git -C "$R" remote add origin "$FAKE_GH_GIT"
  h="$(change ticket/T20/dev-box "$(msg work "${NODE_TR[@]}")" +sim/t20/a.sh)"
  git -C "$R" checkout -q main
  git -C "$R" merge -q --no-ff ticket/T20/dev-box -m "Merge pull request #7 from o/ticket/T20/dev-box"
  M="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" push -qf origin main 2>/dev/null
  jq --arg h "$h" --arg m "$M" '.pulls += [{number: 7, headRefName: "ticket/T20/dev-box", headRefOid: $h, baseRefName: "main",
      state: "MERGED", mergeCommitOid: $m, title: "T20", body: "Ticket: T20", author: {login: "dev-box-owner"}}]' \
    "$FAKE_GH_ISSUES" >"$WORLD/s" && mv "$WORLD/s" "$FAKE_GH_ISSUES"
  RC=0
  out="$(cd "$R" && FACTORY_ADLC="$FAKES_DIR/adlc" FAKE_ADLC_STORE="$R/.adlc/store.json" RUNNER_ENVIRONMENT=github-hosted \
    FACTORY_NOW=1762000000 GIT_AUTHOR_NAME=dev GIT_AUTHOR_EMAIL=dev@fake GIT_COMMITTER_NAME=dev GIT_COMMITTER_EMAIL=dev@fake \
    "$BIN/post-merge.sh" --apply 2>"$WORLD/pm.err")" || RC=$?
  PM_OUT="$(jq -sc '[.[] | [.action, .ticket // .through, .result]]' <<<"$out")"
  P="$(git -C "$R" rev-parse HEAD)"
  BASE="$M"   # the PRs below are against main as it was before post-merge landed
}

case_post_merge_exempt() {
  pm_world
  check "post-merge.sh --apply: exit 0, T20 done, landed" eq "$RC $PM_OUT" "0 [[\"complete\",\"T20\",\"done\"],[\"land\",\"$M\",\"done\"]]"
  check "its commit sits on M and is pushed" eval '[ "$(git -C "$R" rev-parse "$P^")" = "$M" ] && [ "$(fakegh_ref refs/heads/main)" = "$P" ]'
  check "its author and committer are CC_PM_IDENT, the developer's env notwithstanding" \
    eq "$(git -C "$R" log -1 --format='%an <%ae>|%cn <%ce>' "$P")" "$PM_IDENT|$PM_IDENT"
  check "commit-check.sh's CC_PM_IDENT is that identity" \
    eq "$(sed -n "s/^CC_PM_IDENT='\(.*\)'$/\1/p" "$CC")" "$PM_IDENT"
  check "post-merge.sh exports that identity" \
    eq "$(sed -n "s/^export GIT_AUTHOR_NAME='\([^']*\)' GIT_AUTHOR_EMAIL='\([^']*\)'$/\1 <\2>/p" "$BIN/post-merge.sh")" "$PM_IDENT"
  check "it carries no Signed-off-by" eq "$(git -C "$R" log -1 --format='%(trailers:key=Signed-off-by)' "$P")" ""
  local h
  git -C "$R" checkout -q -B docs/notes "$P"
  h="$(more "$(msg notes "$SOB")" +docs/notes.md)"
  pr_event pull_request-opened.json "$h" docs/notes "" COLLABORATOR; cc
  check "a human PR bringing post-merge's commit and a signed one: exit 0" eq "$RC:$OUT" 0:
  check "  post-merge's commit is ok unsigned, both counted" \
    eval 'has "$ERR" "${P:0:12} ok" && has "$ERR" "${h:0:12} ok" && has "$ERR" "pass: 2 commit(s)"'
  pr_event pull_request-opened.json "$P" docs/pm "" COLLABORATOR; cc
  check "post-merge's commit alone: exit 0" eq "$RC" 0
}

case_post_merge_fakes() {
  pm_world
  local m tree f human='dev <dev@fake>'
  m="$(git -C "$R" log -1 --format=%B "$P")"
  pm_fake() {  # pm_fake <name> <commit> <why>: a human PR whose head is the fake
    pr_event pull_request-opened.json "$2" docs/pm-fake "" COLLABORATOR; cc
    fails "$1" "$2" "says 'Ticket: post-merge' but is not post-merge's commit: $3"
  }
  f="$(ct "$PM_IDENT" "$PM_IDENT" "$P" "$m" "$M")"
  pr_event pull_request-opened.json "$f" docs/pm-fake "" COLLABORATOR; cc
  check "control: post-merge's shape rebuilt by hand: exit 0" eq "$RC" 0
  pm_fake "authored by a human" "$(ct "$human" "$PM_IDENT" "$P" "$m" "$M")" "it is not authored and committed by $PM_IDENT"
  pm_fake "committed by a human" "$(ct "$PM_IDENT" "$human" "$P" "$m" "$M")" "it is not authored and committed by $PM_IDENT"
  pm_fake "github-actions without [bot]" \
    "$(ct 'github-actions <41898282+github-actions[bot]@users.noreply.github.com>' "$PM_IDENT" "$P" "$m" "$M")" "it is not authored and committed by"
  pm_fake "an extra trailer (Signed-off-by)" "$(ct "$PM_IDENT" "$PM_IDENT" "$P" "$m"$'\n'"$SOB" "$M")" \
    "its trailer paragraph is not exactly the four post-merge trailers"
  pm_fake "a trailer missing (Node)" "$(ct "$PM_IDENT" "$PM_IDENT" "$P" "$(grep -v '^Node:' <<<"$m")" "$M")" \
    "its trailer paragraph is not exactly the four post-merge trailers"
  pm_fake "Through: not a sha" "$(ct "$PM_IDENT" "$PM_IDENT" "$P" "$(sed 's/^Through: .*/Through: main/' <<<"$m")" "$M")" \
    "its trailers are not Through: <sha>, Assisted-by: none"
  pm_fake "Assisted-by: claude-code" "$(ct "$PM_IDENT" "$PM_IDENT" "$P" "$(sed 's/^Assisted-by: none$/Assisted-by: claude-code/' <<<"$m")" "$M")" \
    "its trailers are not Through: <sha>, Assisted-by: none"
  # Its tree plus README.md: a file outside .adlc/ and factory/ledger/.
  tree="$(GIT_INDEX_FILE="$WORLD/idx" git -C "$R" read-tree "$P" && GIT_INDEX_FILE="$WORLD/idx" git -C "$R" update-index --add \
    --cacheinfo "100644,$(echo pwned | git -C "$R" hash-object -w --stdin),README.md" && GIT_INDEX_FILE="$WORLD/idx" git -C "$R" write-tree)"
  pm_fake "a file outside .adlc/ and factory/ledger/" "$(ct "$PM_IDENT" "$PM_IDENT" "$tree" "$m" "$M")" \
    "it touches README.md, outside .adlc/ and factory/ledger/"
  pm_fake "changes nothing" "$(ct "$PM_IDENT" "$PM_IDENT" "$M" "$m" "$M")" "it changes nothing"
  # Two parents: post-merge's tree on M, merged with the ticket commit M already holds (so the range is
  # the fake alone).
  pm_fake "two parents" "$(ct "$PM_IDENT" "$PM_IDENT" "$P" "$m" "$M" "$M^2")" "it has 2 parents, not one"
  # A human's commit that says `Ticket: post-merge` and signs off: still not the exemption's shape.
  git -C "$R" checkout -q -B docs/pm-fake "$M"
  f="$(more "$(msg 'post-merge: complete T20' 'Ticket: post-merge' "$SOB")" +.adlc/store.json)"
  pm_fake "a signed-off human commit saying Ticket: post-merge" "$f" "its trailer paragraph is not exactly the four"
}

case_merge_group() {
  setup
  local h h2 g
  h="$(change ticket/T20/dev-box "$(msg work "${NODE_TR[@]}")" +sim/t20/a.sh)"
  h2="$(more "$(msg more "${NODE_TR[@]}")" +sim/t20/b.sh)"
  jq --arg h "$h" '.pulls += [{number: 104, headRefName: "ticket/T20/dev-box", headRefOid: $h, baseRefName: "main",
      state: "OPEN", title: "T20", body: "Ticket: T20\nNode: dev-box", author: {login: "dev-box-owner"}}]' \
    "$FAKE_GH_ISSUES" >"$WORLD/s" && mv "$WORLD/s" "$FAKE_GH_ISSUES"
  queue() {  # queue <committer ident> <parent>...: GitHub's queue merge commit of PR 104's tree; prints its sha
    ct 'owner <owner@fake>' "$1" "$h" "Merge pull request #104 from o/ticket/T20/dev-box" "${@:2}"
  }
  mg_event() {  # mg_event <head>: GitHub's example merge_group payload, base BASE, head <head>
    jq --arg b "$BASE" --arg g "$1" '.merge_group.base_sha = $b | .merge_group.head_sha = $g' \
      "$EV/merge_group-checks_requested.json" >"$WORLD/event.json"
    export GITHUB_EVENT_NAME=merge_group GITHUB_EVENT_PATH="$WORLD/event.json" GH_TOKEN=ghs_readonly
  }
  g="$(queue 'GitHub <noreply@github.com>' "$BASE" "$h")"
  mg_event "$g"; cc
  check "GitHub's queue commit (committer GitHub, parents base and PR head): exit 0" eq "$RC:$OUT" 0:
  check "  skipped, saying so" has "$ERR" "${g:0:12} skipped: GitHub's queue merge commit of PR #104"
  check "  the PR's own commit checked: 1 commit" eval 'has "$ERR" "${h:0:12} ok" && has "$ERR" "pass: 1 commit(s)"'
  check "  PR 104 read through gh api" eq "$(fakegh_calls ". == [\"api\",\"repos/$FREPO/pulls/104\"] or . == [\"api\",\"repos/$FREPO/pulls/104\",\"--jq\",\".head.sha\"]")" 2
  g="$(queue 'owner <owner@fake>' "$BASE" "$h")"
  mg_event "$g"; cc
  fails "the same commit committed by the human" "$g" "no Signed-off-by trailer"
  check "  not skipped" lacks "$ERR" "skipped"
  g="$(queue 'GitHub <noreply@github.com>' "$BASE" "$h2")"
  mg_event "$g"; cc
  fails "second parent not the PR's head sha" "$g" "no Signed-off-by trailer"
  check "  only it fails: 1 of 3" has "$ERR" "FAIL: 1 of 3 commit(s)"
  g="$(queue 'GitHub <noreply@github.com>' "$ROOT" "$h")"
  mg_event "$g"; cc
  fails "first parent not the group's base_sha" "$g" "no Signed-off-by trailer"
  g="$(queue 'GitHub <noreply@github.com>' "$BASE")"
  mg_event "$g"; cc
  fails "one parent (a squash shape)" "$g" "no Signed-off-by trailer"
  g="$(queue 'GitHub <noreply@github.com>' "$BASE" "$h")"
  ticket_pr "$g"; cc
  fails "the queue shape on a pull_request event is never skipped" "$g" "no Signed-off-by trailer"
}

# q_world: setup, then PR 7 from ticket/T20/dev-box: the trailered commit H in the fake's store, and S,
# enqueue.sh's queue commit of it onto BASE.
q_world() {
  setup
  H="$(change ticket/T20/dev-box "$(msg work "${NODE_TR[@]}")" +sim/t20/a.sh)"
  q_pr 7 "$H"
  SUBJ="Merge pull request #7 from $FREPO_OWNER/ticket/T20/dev-box"
  S="$(ct "$PM_IDENT" "$PM_IDENT" "$H" "$SUBJ" "$BASE" "$H")"
}
# q_pr <n> <head>: PR n from ticket/T20/dev-box at <head> in the fake's store (GET pulls/<n>)
q_pr() {
  jq --argjson n "$1" --arg h "$2" '.pulls = [.pulls[] | select(.number != $n)] + [{number: $n, headRefName: "ticket/T20/dev-box",
      headRefOid: $h, baseRefName: "main", state: "OPEN", title: "T20", body: "Ticket: T20\nNode: dev-box", author: {login: "dev-box-owner"}}]' \
    "$FAKE_GH_ISSUES" >"$WORLD/s" && mv "$WORLD/s" "$FAKE_GH_ISSUES"
}
# q_event <head> [pr]: gates.yml as enqueue.yml calls it: a push caller's event, the inputs as env
q_event() {
  jq -n --arg b "$BASE" '{ref: "refs/heads/main", after: $b}' >"$WORLD/event.json"
  export GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$WORLD/event.json" GATE_QUEUE_PR="${2:-7}" GATE_BASE="$BASE" GATE_HEAD="$1" GH_TOKEN=ghs_readonly
}

case_queue_skip() {
  q_world
  local h2
  q_event "$S"; cc
  check "the serial queue's commit (enqueue.sh's shape): exit 0" eq "$RC:$OUT" 0:
  check "  skipped, saying so" has "$ERR" "${S:0:12} skipped: the serial queue's merge commit of PR #7 (parents base, PR head)"
  check "  never called GitHub's" lacks "$ERR" "GitHub's queue"
  check "  the PR's own commit checked: 1 commit, the ticket rule" \
    eval 'has "$ERR" "${H:0:12} ok" && has "$ERR" "pass: 1 commit(s) in ${BASE:0:12}..${S:0:12} carry the ticket trailers"'
  # The PR brings a second commit without Signed-off-by: the queue commit is still skipped, that one fails.
  git -C "$R" checkout -q ticket/T20/dev-box
  h2="$(more "$(msg more 'Assisted-by: claude-code@2.1.280' 'Ticket: T20' 'Node: dev-box')" +sim/t20/b.sh)"
  q_pr 7 "$h2"
  S="$(ct "$PM_IDENT" "$PM_IDENT" "$h2" "$SUBJ" "$BASE" "$h2")"
  q_event "$S"; cc
  fails "a PR commit without Signed-off-by, through the queue" "$h2" "no Signed-off-by trailer (the DCO)"
  check "  the queue commit still skipped, only the PR commit fails: 1 of 2" \
    eval 'has "$ERR" "${S:0:12} skipped: the serial queue'"'"'s" && has "$ERR" "FAIL: 1 of 2 commit(s)" && has "$ERR" "${H:0:12} ok"'
}

case_queue_not_skipped() {
  q_world
  local s human='owner <owner@fake>'
  qns() {  # qns <name> <commit>: on the queue it is checked like any commit, so it fails unsigned
    q_event "$2"; cc
    fails "$1" "$2" "no Signed-off-by trailer"
    check "  not skipped" lacks "$ERR" "skipped"
  }
  qns "authored by a human" "$(ct "$human" "$PM_IDENT" "$H" "$SUBJ" "$BASE" "$H")"
  qns "committed by a human" "$(ct "$PM_IDENT" "$human" "$H" "$SUBJ" "$BASE" "$H")"
  qns "github-actions without [bot]" \
    "$(ct 'github-actions <41898282+github-actions[bot]@users.noreply.github.com>' "$PM_IDENT" "$H" "$SUBJ" "$BASE" "$H")"
  qns "GitHub's merge_group shape (committer GitHub) on the queue" \
    "$(ct "$human" 'GitHub <noreply@github.com>' "$H" "Merge pull request #7 from o/ticket/T20/dev-box" "$BASE" "$H")"
  qns "the subject names PR #8" "$(ct "$PM_IDENT" "$PM_IDENT" "$H" "Merge pull request #8 from $FREPO_OWNER/ticket/T20/dev-box" "$BASE" "$H")"
  qns "the subject names PR #70 (a prefix of the number is not it)" \
    "$(ct "$PM_IDENT" "$PM_IDENT" "$H" "Merge pull request #70 from $FREPO_OWNER/ticket/T20/dev-box" "$BASE" "$H")"
  qns "another subject" "$(ct "$PM_IDENT" "$PM_IDENT" "$H" "queue: PR 7" "$BASE" "$H")"
  # Parents other than [base, PR head]: gate-context refuses the queue run before this body.
  for s in "$(ct "$PM_IDENT" "$PM_IDENT" "$H" "$SUBJ" "$ROOT" "$H")" "$(ct "$PM_IDENT" "$PM_IDENT" "$H" "$SUBJ" "$BASE")" \
           "$(ct "$PM_IDENT" "$PM_IDENT" "$H" "$SUBJ" "$H" "$BASE")" "$(ct "$PM_IDENT" "$PM_IDENT" "$H" "$SUBJ" "$BASE" "$H" "$ROOT")"; do
    q_event "$s"; cc
    check "parents [$(git -C "$R" rev-list --parents -n1 "$s" | cut -d' ' -f2- | sed "s/$BASE/base/; s/$H/head/; s/$ROOT/root/")]: refused (exit 2), not skipped" \
      eval '[ "$RC:$OUT" = 2: ] && has "$ERR" "is not the merge of PR #7'"'"'s head" && lacks "$ERR" "skipped"'
  done
  # The PR was pushed again after S was built: S's second parent is no longer PR 7's head.
  git -C "$R" checkout -q ticket/T20/dev-box
  q_pr 7 "$(more "$(msg again "${NODE_TR[@]}")" +sim/t20/c.sh)"
  q_event "$S"; cc
  check "the PR moved past S's second parent: refused (exit 2), not skipped" \
    eval '[ "$RC" = 2 ] && has "$ERR" "is not the merge of PR #7'"'"'s head" && lacks "$ERR" "skipped"'
}

case_queue_merge_group_apart() {
  q_world
  local s
  q_pr 104 "$H"
  # enqueue.sh's shape for PR 104 on a merge_group event: merge_group skips only GitHub's committer.
  s="$(ct "$PM_IDENT" "$PM_IDENT" "$H" "Merge pull request #104 from $FREPO_OWNER/ticket/T20/dev-box" "$BASE" "$H")"
  jq --arg b "$BASE" --arg g "$s" '.merge_group.base_sha = $b | .merge_group.head_sha = $g' \
    "$EV/merge_group-checks_requested.json" >"$WORLD/event.json"
  export GITHUB_EVENT_NAME=merge_group GITHUB_EVENT_PATH="$WORLD/event.json" GH_TOKEN=ghs_readonly
  cc
  fails "enqueue.sh's commit shape on merge_group" "$s" "no Signed-off-by trailer"
  check "  not skipped" lacks "$ERR" "skipped"
  # And on a pull_request event, never.
  ticket_pr "$S"; cc
  fails "enqueue.sh's commit shape on a pull_request event" "$S" "no Signed-off-by trailer"
  check "  not skipped" lacks "$ERR" "skipped"
}

case_merge_in_branch() {
  setup
  local mg
  change docs/b "$(msg b "$SOB")" +docs/b.md >/dev/null
  change docs/a "$(msg a "$SOB")" +docs/a.md >/dev/null
  git -C "$R" merge -q --no-ff docs/b -m "Merge branch docs/b into docs/a"
  mg="$(git -C "$R" rev-parse HEAD)"
  pr_event pull_request-opened.json "$mg" docs/a "" COLLABORATOR; cc
  fails "an unsigned merge commit inside a human PR" "$mg" "no Signed-off-by trailer"
  check "  its two signed parents pass: 1 of 3" has "$ERR" "FAIL: 1 of 3 commit(s)"
  git -C "$R" reset -q --hard HEAD^
  git -C "$R" merge -q --no-ff --signoff docs/b -m "Merge branch docs/b into docs/a"
  pr_event pull_request-opened.json "$(git -C "$R" rev-parse HEAD)" docs/a "" COLLABORATOR; cc
  check "the same merge with --signoff: exit 0, 3 commits" eval '[ "$RC" = 0 ] && has "$ERR" "pass: 3 commit(s)"'
}

case_range() {
  setup
  local h m2
  # ROOT and BASE (main, unsigned) are not the PR's; nor is main's unsigned commit after the branch point.
  h="$(change docs/r "$(msg r "$SOB")" +docs/r.md)"
  git -C "$R" checkout -q main
  m2="$(more "main moves, unsigned" +README.md)"
  pr_event pull_request-opened.json "$h" docs/r "" COLLABORATOR; cc
  check "base = the branch point: exit 0, 1 commit" eval '[ "$RC" = 0 ] && has "$ERR" "pass: 1 commit(s) in ${BASE:0:12}..${h:0:12}"'
  local saved="$BASE"; BASE="$m2"
  pr_event pull_request-opened.json "$h" docs/r "" COLLABORATOR; cc
  check "base = main's tip past the branch point (GitHub's base.sha): exit 0, 1 commit" \
    eval '[ "$RC" = 0 ] && has "$ERR" "pass: 1 commit(s) in ${m2:0:12}..${h:0:12}"'
  check "  only the branch's commit is checked" eval '[ "$(grep -c " ok$" <<<"$ERR")" = 1 ] && has "$ERR" "${h:0:12} ok"'
  BASE="$saved"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  git -C "$R" update-ref refs/remotes/origin/main "$m2"
  git -C "$R" checkout -q -B ticket/T20/dev-box "$BASE"
  h="$(more "$(msg work "${NODE_TR[@]}")" +sim/t20/a.sh)"
  cc --ticket T20 --head "$h"
  check "node form after origin/main moved: the merge-base, exit 0, 1 commit" \
    eval '[ "$RC" = 0 ] && has "$ERR" "pass: 1 commit(s) in ${BASE:0:12}..${h:0:12}"'
}

for c in node-commit untrailered ticket-class desk-halt-human post-merge-exempt post-merge-fakes merge-group \
         queue-skip queue-not-skipped queue-merge-group-apart merge-in-branch range; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
