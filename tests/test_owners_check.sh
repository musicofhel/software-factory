#!/usr/bin/env bash
# T29 (specs/factory-step3-v1 TB10): factory/bin/owners-check.sh, two code-owner approvals on the
# factory's own paths.
#   - a PR touching a protected path passes with two distinct approvals by that path's owners on the
#     PR head, and is short (exit 2, each path named with its count) with fewer;
#   - an approval counts only when it was given on the current head (a push voids it), when it is the
#     reviewer's latest decisive review (CHANGES_REQUESTED and DISMISSED void it, COMMENTED changes
#     nothing), and never when the reviewer is the PR's author;
#   - the owners are the BASE's CODEOWNERS (the head's own edit gains nothing), the last matching line,
#     read from .github/CODEOWNERS, then CODEOWNERS, then docs/CODEOWNERS; the CODEOWNERS files are
#     themselves protected; a team or e-mail owner is named as uncountable; logins match any case;
#   - a PR touching no protected path passes with protected []; a `halt` PR passes, and --only counts
#     one path whatever the class (halt-guard.sh's factory/HALT);
#   - the queue path (GATE_QUEUE_PR, a queue merge commit) counts the approvals on the PR's head as
#     GitHub has it, not on the queue commit;
#   - --rerun POSTs a re-run of the `owners` and `halt-guard` jobs of the head's latest gates.yml run,
#     does nothing when there is none, and fails without an event;
#   - an unreadable review list, PR or CODEOWNERS fails closed (exit 1, never 0).
# Offline; every repo is a temp dir, gh is the fake (pulls, reviews and Actions runs in FAKE_GH_ISSUES).
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
OC="$BIN/owners-check.sh"
EV="$REPO_ROOT/tests/fixtures/events"
FREPO=Codertocat/Hello-World   # the repository of GitHub's example payloads
AUTHOR=Codertocat              # the example payloads' PR author (PR 2)
CO_FACTORY=$'* @alice\n/factory/ @alice @bob'   # the CODEOWNERS most cases put on the base

# A repo R whose root commit (ROOT) has a README; each case builds its main (BASE) with `base`.
setup() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export FAKE_GH_REPO="$FREPO" GITHUB_REPOSITORY="$FREPO" FACTORY_REPO="$FREPO"
  printf '{"labels":[],"issues":[],"pulls":[],"runs":[],"collaborators":["dev-box-owner"]}\n' >"$FAKE_GH_ISSUES"
  R="$WORLD/r"
  git init -q -b main "$R"
  git -C "$R" config user.name t; git -C "$R" config user.email t@t.invalid
  echo root >"$R/README.md"; git -C "$R" add -A; git -C "$R" commit -qm root
  ROOT="$(git -C "$R" rev-parse HEAD)"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH GH_TOKEN GATE_QUEUE_PR GATE_BASE GATE_HEAD
}
# edit <change>...: in R's work tree, +path appends a line, -path deletes, path=content writes content
edit() {
  local a p
  for a in "$@"; do
    case "$a" in
      -*) git -C "$R" rm -q -- "${a#-}" ;;
      *=*) p="${a%%=*}"; mkdir -p "$R/$(dirname "$p")"; printf '%s\n' "${a#*=}" >"$R/$p"; git -C "$R" add -- "$p" ;;
      *) p="${a#+}"; mkdir -p "$R/$(dirname "$p")"; echo change >>"$R/$p"; git -C "$R" add -- "$p" ;;
    esac
  done
}
# base <change>...: main reset to ROOT plus these changes, committed; sets BASE (= origin/main)
base() {
  git -C "$R" checkout -q -B main "$ROOT"
  edit "$@"; git -C "$R" commit -q --allow-empty -m base
  BASE="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" update-ref refs/remotes/origin/main "$BASE"
}
# work <ref> <change>...: branch <ref> from BASE with one commit; prints its sha (R stays on the branch)
work() { git -C "$R" checkout -q -B "$1" "$BASE"; shift; more "$@"; }
# more <change>...: one more commit on the current branch; prints its sha
more() { edit "$@"; git -C "$R" commit -q --allow-empty -m "work $*"; git -C "$R" rev-parse HEAD; }
# pr_event <head-sha> [head-ref] [body] [event]: GitHub's example pull_request payload (PR 2 by
# Codertocat, OWNER) with this world's base (BASE, branch main), head, ref and body. Defaults: the ticket
# branch ticket/T29/dev-box whose body names T29 (as run.sh writes it).
pr_event() {
  PR_REF="${2:-ticket/T29/dev-box}"
  jq --arg b "$BASE" --arg h "$1" --arg r "$PR_REF" --arg body "${3:-Ticket: T29}" --arg hr "$FREPO" \
    '.pull_request.base.sha = $b | .pull_request.base.ref = "main" | .pull_request.head.sha = $h | .pull_request.head.ref = $r
     | .pull_request.body = $body | .pull_request.author_association = "OWNER" | .pull_request.head.repo.full_name = $hr' \
    "$EV/pull_request-opened.json" >"$WORLD/event.json"
  export GITHUB_EVENT_NAME="${4:-pull_request}" GITHUB_EVENT_PATH="$WORLD/event.json"
}
# rv <login> <state> [commit oid]: one review as the fake's pulls entries hold it (no oid: on the PR's
# head, as the fake answers commit_id)
rv() { jq -cn --arg u "$1" --arg s "$2" --arg o "${3:-}" '{author: {login: $u}, state: $s} + (if $o == "" then {} else {commit: {oid: $o}} end)'; }
# pull <n> <head> <ref> <author> [review...]: PR n in the fake's store (GET pulls/<n>, GET
# pulls/<n>/reviews), replacing any entry n
pull() {
  local n="$1" h="$2" ref="$3" who="$4"; shift 4
  jq --argjson n "$n" --arg h "$h" --arg r "$ref" --arg who "$who" --argjson rv "$(jq -cn '$ARGS.positional' --jsonargs "$@")" \
    '.pulls = [.pulls[] | select(.number != $n)] + [{number: $n, headRefName: $r, headRefOid: $h, baseRefName: "main",
       state: "OPEN", title: "T29", body: "Ticket: T29\nNode: dev-box", author: {login: $who}, reviews: $rv}]' \
    "$FAKE_GH_ISSUES" >"$WORLD/s" && mv "$WORLD/s" "$FAKE_GH_ISSUES"
}
# reviews <head> [review...]: the event's PR 2 in the fake's store, with these reviews
reviews() { local h="$1"; shift; pull 2 "$h" "${PR_REF:-ticket/T29/dev-box}" "$AUTHOR" "$@"; }
oc() {  # oc [flags]: run owners-check.sh in R; OUT (stdout), ERR (stderr), RC
  RC=0
  OUT="$(cd "$R" && "$OC" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
field() { jq -r "$1" <<<"$OUT"; }
has() { /usr/bin/grep -qF -- "$1" <<<"$ERR"; }
hasnt() { ! /usr/bin/grep -qF -- "$1" <<<"$ERR"; }

case_pass() {
  setup
  local h
  base ".github/CODEOWNERS=$CO_FACTORY"
  h="$(work ticket/T29/dev-box +factory/bin/x.sh +sim/a.txt)"
  pr_event "$h"
  reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)" "$(rv carol APPROVED)"
  check "the script is executable (gates.yml runs ./.base/factory/bin/owners-check.sh)" test -x "$OC"
  oc
  check "exit 0, result pass" eq "$RC:$(field .result)" 0:pass
  check "stdout: pr 2, head, class ticket" eq "$(field '[.pr, .head, .class] | join(" ")')" "2 $h ticket"
  check "  the one protected path, its base owners and their approvals (sim/ is not protected)" \
    eq "$(field '.protected | tojson')" '[{"path":"factory/bin/x.sh","owners":["@alice","@bob"],"approvals":["alice","bob"],"uncountable":[]}]'
  check "  approvers: every approval on the head, an owner's or not" eq "$(field '.approvers | join(",")')" alice,bob,carol
  check "stderr: pass, naming the head and the approvers" \
    has "owners-check: pass: #2: every protected path has 2 or more distinct code-owner approvals on ${h:0:12} (alice, bob, carol)"
  check "  the base's copy of the gate ran, class ticket" has "owners-check: ticket gate from $REPO_ROOT on"
  check "one gh call: the PR's reviews (the head is the event's)" \
    eq "$(jq -c . "$FAKE_GH_LOG")" "[\"api\",\"--paginate\",\"repos/$FREPO/pulls/2/reviews\"]"
}

case_short() {
  setup
  local h
  base ".github/CODEOWNERS=$CO_FACTORY"
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  pr_event "$h"
  reviews "$h" "$(rv alice APPROVED)"
  oc
  check "one approval: exit 2, result short" eq "$RC:$(field .result)" 2:short
  check "  stdout still names the path and its one approval" eq "$(field '.protected[] | "\(.path) \(.approvals | join(","))"')" "factory/bin/x.sh alice"
  check "  stderr names the path, its owners, the head and 'it has 1'" \
    has "owners-check: SHORT: factory/bin/x.sh needs 2 distinct approvals by its code owners (@alice @bob) on the PR head ${h:0:12}; it has 1 (alice)"
  check "  no pass line" hasnt "owners-check: pass"
  # The same owner approving twice is one approval.
  reviews "$h" "$(rv alice APPROVED)" "$(rv alice APPROVED)"
  oc
  check "the same owner approving twice: still short, it has 1" eq "$RC:$(field '.protected[0].approvals | join(",")')" 2:alice
  # No review at all.
  reviews "$h"
  oc
  check "no review: exit 2, it has 0" eq "$RC:$(field '.protected[0].approvals | length')" 2:0
  check "  stderr: it has 0" has "on the PR head ${h:0:12}; it has 0"
  # Two protected paths, one with its two owners' approvals and one without: only the short one is named.
  base ".github/CODEOWNERS=$CO_FACTORY"$'\n/.claude/ @carol @dave'
  h="$(work ticket/T29/dev-box +factory/bin/x.sh +.claude/settings.json)"
  pr_event "$h"
  reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  oc
  check "two paths, one short: exit 2" eq "$RC:$(field '[.protected[] | "\(.path)=\(.approvals | length)"] | join(" ")')" \
    "2:.claude/settings.json=0 factory/bin/x.sh=2"
  check "  stderr names .claude/settings.json with its owners" \
    has "SHORT: .claude/settings.json needs 2 distinct approvals by its code owners (@carol @dave) on the PR head ${h:0:12}; it has 0"
  check "  and not factory/bin/x.sh" hasnt "SHORT: factory/bin/x.sh"
}

case_stale_approval() {
  setup
  local h1 h2
  base ".github/CODEOWNERS=$CO_FACTORY"
  h1="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  h2="$(more +factory/bin/x.sh)"
  pr_event "$h2"
  # alice approved h1, then the branch moved to h2; bob approved h2.
  reviews "$h2" "$(rv alice APPROVED "$h1")" "$(rv bob APPROVED)"
  oc
  check "an approval of an older commit does not count: exit 2" eq "$RC:$(field .result)" 2:short
  check "  approvers: bob only" eq "$(field '.approvers | join(",")')" bob
  check "  stderr: it has 1 (bob) on the new head" has "on the PR head ${h2:0:12}; it has 1 (bob)"
  # alice approves again, on h2.
  reviews "$h2" "$(rv alice APPROVED "$h1")" "$(rv bob APPROVED)" "$(rv alice APPROVED "$h2")"
  oc
  check "re-approved on the head: pass" eq "$RC:$(field '.protected[0].approvals | join(",")')" 0:alice,bob
  # Both approvals on h1, the event at h2: nothing counts.
  reviews "$h2" "$(rv alice APPROVED "$h1")" "$(rv bob APPROVED "$h1")"
  oc
  check "both approvals before the push: exit 2, no approvers" eq "$RC:$(field '.approvers | length')" 2:0
}

case_decisive_review() {
  setup
  local h
  base ".github/CODEOWNERS=$CO_FACTORY"
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  pr_event "$h"
  reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)" "$(rv alice CHANGES_REQUESTED)"
  oc
  check "a later CHANGES_REQUESTED voids alice's approval: exit 2, approvers bob" eq "$RC:$(field '.approvers | join(",")')" 2:bob
  check "  stderr: it has 1 (bob)" has "it has 1 (bob)"
  reviews "$h" "$(rv alice CHANGES_REQUESTED)" "$(rv bob APPROVED)" "$(rv alice APPROVED)"
  oc
  check "an APPROVED after CHANGES_REQUESTED counts: pass" eq "$RC:$(field '.approvers | join(",")')" 0:alice,bob
  reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)" "$(rv alice DISMISSED)"
  oc
  check "a later DISMISSED voids alice's approval: exit 2, approvers bob" eq "$RC:$(field '.approvers | join(",")')" 2:bob
  reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)" "$(rv alice COMMENTED)"
  oc
  check "a later COMMENTED leaves alice's approval standing: pass" eq "$RC:$(field '.approvers | join(",")')" 0:alice,bob
  reviews "$h" "$(rv alice CHANGES_REQUESTED)" "$(rv bob APPROVED)" "$(rv alice COMMENTED)"
  oc
  check "a later COMMENTED does not lift a CHANGES_REQUESTED: exit 2" eq "$RC:$(field '.approvers | join(",")')" 2:bob
  reviews "$h" "$(rv alice COMMENTED)" "$(rv bob COMMENTED)"
  oc
  check "COMMENTED alone is no approval: exit 2, it has 0" eq "$RC:$(field '.approvers | length')" 2:0
}

case_author_never_counts() {
  setup
  local h
  base ".github/CODEOWNERS=* @alice"$'\n'"/factory/ @$AUTHOR @alice"
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  pr_event "$h"
  reviews "$h" "$(rv "$AUTHOR" APPROVED)" "$(rv alice APPROVED)"
  oc
  check "the author's own approval does not count: exit 2" eq "$RC:$(field .result)" 2:short
  check "  the author is not among the approvers" eq "$(field '.approvers | join(",")')" alice
  check "  stderr: it has 1 (alice)" has "(@$AUTHOR @alice) on the PR head ${h:0:12}; it has 1 (alice)"
  # Another owner makes two without the author.
  base ".github/CODEOWNERS=* @alice"$'\n'"/factory/ @$AUTHOR @alice @bob"
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  pr_event "$h"
  reviews "$h" "$(rv "$AUTHOR" APPROVED)" "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  oc
  check "two other owners: pass, the author still not counted" eq "$RC:$(field '.protected[0].approvals | join(",")')" 0:alice,bob
}

case_codeowners() {
  setup
  local h
  # The last matching line wins: a later broader line overrides an earlier narrower one.
  base $'.github/CODEOWNERS=/factory/bin/ @alice @bob\n/factory/ @carol @dave'
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  pr_event "$h"
  reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  oc
  check "a later broader line wins: owners carol, dave; exit 2" eq "$RC:$(field '.protected[0].owners | join(" ")')" "2:@carol @dave"
  check "  alice and bob's approvals are not the owners'" has "SHORT: factory/bin/x.sh needs 2 distinct approvals by its code owners (@carol @dave)"
  base $'.github/CODEOWNERS=/factory/ @carol @dave\n/factory/bin/ @alice @bob'
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  pr_event "$h"
  reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  oc
  check "the narrower line last: owners alice, bob; pass" eq "$RC:$(field '.protected[0].owners | join(" ")')" "0:@alice @bob"
  # The head adds an owner in .github/CODEOWNERS: the base's file is read, and the edit is protected.
  base ".github/CODEOWNERS=$CO_FACTORY"$'\n/.github/ @alice @bob'
  h="$(work ticket/T29/dev-box +factory/bin/x.sh $'.github/CODEOWNERS=* @alice @mallory')"
  pr_event "$h"
  reviews "$h" "$(rv alice APPROVED)" "$(rv mallory APPROVED)"
  oc
  check "a head naming mallory an owner gains nothing: exit 2" eq "$RC:$(field .result)" 2:short
  check "  both paths protected, owned per the base, each with alice only" \
    eq "$(field '[.protected[] | "\(.path)=\(.owners | join("+"))=\(.approvals | join("+"))"] | join(" ")')" \
       ".github/CODEOWNERS=@alice+@bob=alice factory/bin/x.sh=@alice+@bob=alice"
  check "  stderr names the CODEOWNERS file itself" has "SHORT: .github/CODEOWNERS needs 2 distinct approvals by its code owners (@alice @bob)"
  reviews "$h" "$(rv alice APPROVED)" "$(rv mallory APPROVED)" "$(rv bob APPROVED)"
  oc
  check "  with bob (a base owner): pass" eq "$RC:$(field .result)" 0:pass
  # The root and docs/ CODEOWNERS files are protected paths too.
  base ".github/CODEOWNERS=$CO_FACTORY"
  h="$(work ticket/T29/dev-box +CODEOWNERS +docs/CODEOWNERS +docs/notes.md)"
  pr_event "$h"
  reviews "$h"
  oc
  check "CODEOWNERS and docs/CODEOWNERS are protected (docs/notes.md is not): exit 2" \
    eq "$RC:$(field '[.protected[].path] | join(" ")')" "2:CODEOWNERS docs/CODEOWNERS"
  # GitHub's order: .github/CODEOWNERS, then CODEOWNERS, then docs/CODEOWNERS.
  base $'.github/CODEOWNERS=* @gh1 @gh2' $'CODEOWNERS=* @root1 @root2' $'docs/CODEOWNERS=* @docs1 @docs2'
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"; pr_event "$h"; reviews "$h" "$(rv gh1 APPROVED)" "$(rv gh2 APPROVED)"
  oc
  check "all three: .github/CODEOWNERS is read, pass" eq "$RC:$(field '.protected[0].owners | join(" ")')" "0:@gh1 @gh2"
  base $'CODEOWNERS=* @root1 @root2' $'docs/CODEOWNERS=* @docs1 @docs2'
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"; pr_event "$h"; reviews "$h" "$(rv gh1 APPROVED)" "$(rv gh2 APPROVED)"
  oc
  check "no .github/CODEOWNERS: the root CODEOWNERS, exit 2" eq "$RC:$(field '.protected[0].owners | join(" ")')" "2:@root1 @root2"
  base $'docs/CODEOWNERS=* @docs1 @docs2'
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"; pr_event "$h"; reviews "$h" "$(rv docs1 APPROVED)" "$(rv docs2 APPROVED)"
  oc
  check "only docs/CODEOWNERS: it is read, pass" eq "$RC:$(field '.protected[0].owners | join(" ")')" "0:@docs1 @docs2"
  base
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"; pr_event "$h"; reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  oc
  check "no CODEOWNERS at the base: no owners, exit 2" eq "$RC:$(field '.protected[0] | [(.owners | length), (.approvals | length)] | join(" ")')" "2:0 0"
  check "  stderr: none in CODEOWNERS" has "SHORT: factory/bin/x.sh needs 2 distinct approvals by its code owners (none in CODEOWNERS)"
}

case_teams_and_case() {
  setup
  local h
  base $'.github/CODEOWNERS=* @alice\n/factory/ @Alice @org/team ops@example.com @BOB'
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  pr_event "$h"
  reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  oc
  check "@Alice and @BOB match the logins alice and bob: pass" eq "$RC:$(field '.protected[0].approvals | join(",")')" 0:alice,bob
  check "  the team and the e-mail are uncountable" eq "$(field '.protected[0].uncountable | join(" ")')" "@org/team ops@example.com"
  check "  stderr names them" \
    has "owners-check: factory/bin/x.sh: owner(s) @org/team, ops@example.com cannot be counted from a review (a team or an e-mail)"
  # A path owned by a team alone can never reach two.
  base $'.github/CODEOWNERS=/factory/ @org/team'
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  pr_event "$h"
  reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  oc
  check "a team-owned path: exit 2, no approval counts" eq "$RC:$(field '.protected[0].approvals | length')" 2:0
  check "  stderr names the team as uncountable" has "factory/bin/x.sh: owner(s) @org/team cannot be counted from a review"
  check "  and the path as short" has "SHORT: factory/bin/x.sh needs 2 distinct approvals by its code owners (@org/team)"
}

case_no_protected_path() {
  setup
  local h
  base ".github/CODEOWNERS=$CO_FACTORY"
  h="$(work ticket/T29/dev-box +sim/a.txt +docs/adr/0001.md +src/factory/y.sh)"
  pr_event "$h"
  oc
  check "no protected path: exit 0" eq "$RC" 0
  check "  stdout: protected [], pass" eq "$OUT" '{"pr":2,"class":"ticket","protected":[],"result":"pass"}'
  check "  stderr says so" has "owners-check: pass: #2 touches no protected path"
  check "  no review read (no gh call)" eq "$(fakegh_calls true)" 0
}

case_halt() {
  setup
  local h
  base ".github/CODEOWNERS=$CO_FACTORY"
  h="$(work stop +factory/HALT)"
  pr_event "$h" stop 'stop the line'
  oc
  check "a halt PR (adds factory/HALT) passes without approvals" eq "$RC:$OUT" '0:{"pr":2,"class":"halt","result":"pass"}'
  check "  stderr: class halt" has "owners-check: pass: class halt: adding factory/HALT needs no approval"
  check "  no review read" eq "$(fakegh_calls true)" 0
  # factory/HALT plus another file is not the halt class: a human PR, counted.
  h="$(work stop +factory/HALT +factory/bin/x.sh)"
  pr_event "$h" stop 'stop and more'
  reviews "$h"
  oc
  check "factory/HALT and factory/bin/x.sh: class human, exit 2" eq "$RC:$(field '[.class, ([.protected[].path] | join(","))] | join(" ")')" \
    "2:human factory/HALT,factory/bin/x.sh"
  # The halt removal: the class passes; --only factory/HALT counts that path (halt-guard.sh's call).
  base ".github/CODEOWNERS=$CO_FACTORY" +factory/HALT
  h="$(work resume -factory/HALT)"
  pr_event "$h" resume 'resume the line'
  reviews "$h" "$(rv alice APPROVED)"
  oc
  check "removing factory/HALT: the halt class passes here (halt-guard's to count)" eq "$RC:$(field .class)" 0:halt
  oc --only factory/HALT
  check "--only factory/HALT, one approval: exit 2" eq "$RC:$(field '[.class, .result] | join(" ")')" "2:halt short"
  check "  the one path, its owners" eq "$(field '.protected | map({path, owners}) | tojson')" '[{"path":"factory/HALT","owners":["@alice","@bob"]}]'
  check "  stderr: it has 1" has "SHORT: factory/HALT needs 2 distinct approvals by its code owners (@alice @bob) on the PR head ${h:0:12}; it has 1 (alice)"
  reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  oc --only factory/HALT
  check "--only factory/HALT, two owners: pass" eq "$RC:$(field '.protected[0].approvals | join(",")')" 0:alice,bob
  # --only counts its path whatever the PR touches.
  base ".github/CODEOWNERS=$CO_FACTORY"
  h="$(work ticket/T29/dev-box +sim/a.txt)"
  pr_event "$h"
  reviews "$h" "$(rv alice APPROVED)"
  oc --only factory/HALT
  check "--only on a ticket PR that does not touch the path: still counted, exit 2" \
    eq "$RC:$(field '[.class, .protected[0].path] | join(" ")')" "2:ticket factory/HALT"
  oc --only
  check "--only without a path: exit 1" eq "$RC:$OUT" 1:
  check "  saying so" has "owners-check: --only needs a path"
}

case_queue() {
  setup
  local h s h2
  base ".github/CODEOWNERS=$CO_FACTORY"
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  # enqueue.sh's queue commit of PR 7 onto BASE; gates.yml as enqueue.yml calls it.
  s="$(git -C "$R" commit-tree "$h^{tree}" -p "$BASE" -p "$h" -m "Merge pull request #7 from ticket/T29/dev-box")"
  jq -n --arg b "$BASE" '{ref: "refs/heads/main", after: $b}' >"$WORLD/event.json"
  export GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$WORLD/event.json" GATE_QUEUE_PR=7 GATE_BASE="$BASE" GATE_HEAD="$s" GH_TOKEN=ghs_readonly
  pull 7 "$h" ticket/T29/dev-box dev-box-owner "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  oc
  check "queue: two approvals on PR 7's head: pass" eq "$RC:$(field .result)" 0:pass
  check "  .pr 7, .head the PR's head (not the queue commit)" eq "$(field '[.pr, .head] | join(" ")')" "7 $h"
  check "  the paths of the PR (BASE...queue commit)" eq "$(field '[.protected[].path] | join(",")')" factory/bin/x.sh
  check "  the head and the reviews came from GitHub" \
    eq "$(fakegh_calls '. == ["api","repos/'"$FREPO"'/pulls/7","--jq",".head.sha"]'):$(fakegh_calls '. == ["api","--paginate","repos/'"$FREPO"'/pulls/7/reviews"]')" 1:1
  check "  stderr: pass on the PR head" has "on ${h:0:12} (alice, bob)"
  # Approvals given on the queue commit's sha are not on the PR head.
  pull 7 "$h" ticket/T29/dev-box dev-box-owner "$(rv alice APPROVED "$s")" "$(rv bob APPROVED "$s")"
  oc
  check "approvals on the queue commit: exit 2, it has 0 on the PR head" eq "$RC:$(field '.approvers | length')" 2:0
  check "  stderr names the PR head" has "on the PR head ${h:0:12}; it has 0"
  # The PR's author (GitHub's, not the event's) never counts.
  pull 7 "$h" ticket/T29/dev-box dev-box-owner "$(rv alice APPROVED)" "$(rv dev-box-owner APPROVED)"
  oc
  check "the PR author's approval on the queue: exit 2, approvers alice" eq "$RC:$(field '.approvers | join(",")')" 2:alice
  # The PR moved on GitHub after the queue commit was built: gate-context refuses the run.
  h2="$(more +factory/bin/x.sh)"
  pull 7 "$h2" ticket/T29/dev-box dev-box-owner "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  oc
  check "a queue commit not of PR 7's current head: refused (exit 2, no stdout)" eq "$RC:$OUT" 2:
}

# runs_state <json>: the fake's Actions runs (.runs of FAKE_GH_ISSUES), no re-runs yet
runs_state() { jq --argjson r "$1" '.runs = $r | del(.reruns)' "$FAKE_GH_ISSUES" >"$WORLD/s" && mv "$WORLD/s" "$FAKE_GH_ISSUES"; }
# run <id> <path> <head> <job id:name>...: one completed pull_request run with completed jobs
run() {
  local id="$1" p="$2" h="$3"; shift 3
  jq -cn --argjson id "$id" --arg p "$p" --arg h "$h" '{id: $id, name: ($p | split("/") | last), path: $p, event: "pull_request",
      head_sha: $h, head_branch: "ticket/T29/dev-box", jobs: [$ARGS.positional[] | split(":") | {id: (.[0] | tonumber), name: .[1],
      status: "completed", conclusion: "failure", started_at: "2026-10-27T10:00:00Z", completed_at: "2026-10-27T10:01:00Z"}]}' --args "$@"
}
reruns() { jq -c '.reruns // []' "$FAKE_GH_ISSUES"; }

case_rerun() {
  setup
  local h other gates=.github/workflows/gates.yml
  base ".github/CODEOWNERS=$CO_FACTORY"
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"; other="$(more +factory/bin/x.sh)"
  # reviews.yml's payload: a pull_request_review with the PR (2) and its head.
  pr_event "$h" ticket/T29/dev-box 'Ticket: T29' pull_request_review
  jq '.action = "submitted" | .review = {state: "approved", user: {login: "alice"}, commit_id: .pull_request.head.sha}' \
    "$WORLD/event.json" >"$WORLD/e" && mv "$WORLD/e" "$WORLD/event.json"
  runs_state "[$(run 100 "$gates" "$h" 1001:owners 1002:halt-guard 1003:commit-check),
               $(run 200 "$gates" "$h" 2001:owners 2002:diff-gates 2003:halt-guard),
               $(run 300 .github/workflows/reviews.yml "$h" 3001:owners),
               $(run 400 "$gates" "$other" 4001:owners 4002:halt-guard)]"
  oc --rerun
  check "--rerun: exit 0" eq "$RC" 0
  check "  stdout: pr, head, the latest gates run of the head, the jobs re-run" \
    eq "$OUT" "{\"pr\":2,\"head\":\"$h\",\"run\":200,\"rerun\":[\"owners\",\"halt-guard\"]}"
  check "  exactly owners and halt-guard of run 200 were re-run" eq "$(reruns)" '[2001,2003]'
  check "  stderr names each re-run" has "owners-check: re-ran halt-guard (job 2003 of gates run 200) for #2: a review changed its count"
  check "  the runs were asked for by head and event" \
    eq "$(fakegh_calls '. == ["api","repos/'"$FREPO"'/actions/runs?head_sha='"$h"'&event=pull_request"]')" 1
  check "  no review was read" eq "$(fakegh_calls 'any(.[]; test("/reviews$"))')" 0
  # A gates run whose path carries a ref (a called workflow) is the gates workflow too.
  runs_state "[$(run 200 "$gates" "$h" 2001:owners 2003:halt-guard), $(run 500 "$gates@refs/heads/main" "$h" 5001:halt-guard 5002:owners)]"
  oc --rerun
  check "gates.yml@<ref>, the newer run: its jobs re-run" eq "$RC:$(field .run):$(reruns)" '0:500:[5001,5002]'
  # No gates run for the head yet: nothing re-run.
  runs_state "[$(run 300 .github/workflows/reviews.yml "$h" 3001:owners), $(run 400 "$gates" "$other" 4001:owners)]"
  oc --rerun
  check "no gates run for the head: exit 0, run null, nothing re-run" eq "$RC:$OUT" "0:{\"pr\":2,\"head\":\"$h\",\"run\":null,\"rerun\":[]}"
  check "  no POST" eq "$(reruns)" '[]'
  check "  stderr says the jobs will read the reviews when they run" has "owners-check: no gates run for #2 at ${h:0:12} yet"
  # No event, an unreadable event, an argument: exit 1.
  unset GITHUB_EVENT_PATH
  oc --rerun
  check "no GITHUB_EVENT_PATH: exit 1, no stdout" eq "$RC:$OUT" 1:
  check "  saying so" has "owners-check: --rerun needs GITHUB_EVENT_PATH (a pull_request_review payload)"
  export GITHUB_EVENT_PATH="$WORLD/missing.json"
  oc --rerun
  check "a missing event file: exit 1" eq "$RC:$OUT" 1:
  echo '{"review": {}}' >"$WORLD/event.json"; export GITHUB_EVENT_PATH="$WORLD/event.json"
  oc --rerun
  check "an event without a pull_request: exit 1" eq "$RC:$OUT" 1:
  check "  saying so" has "the event carries no pull_request number and head sha"
  oc --rerun extra
  check "--rerun with an argument: exit 1" eq "$RC" 1
}

case_fail_closed() {
  setup
  local h s
  base ".github/CODEOWNERS=$CO_FACTORY"
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  pr_event "$h"
  # PR 2 is not in the fake's store: GET pulls/2/reviews answers 404.
  oc
  check "an unreadable review list (404): exit 1, no stdout" eq "$RC:$OUT" 1:
  check "  saying so" has "owners-check: cannot read the reviews of PR #2"
  reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  FAKE_GH_FAIL='pulls/2/reviews' oc
  check "a failing review list (500): exit 1, never a pass" eq "$RC:$OUT" 1:
  # A CODEOWNERS pattern the gate does not read stops it rather than guess.
  base $'.github/CODEOWNERS=* @alice\n/factory/[ab]/ @alice @bob'
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  pr_event "$h"; reviews "$h" "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  oc
  check "a CODEOWNERS with '[': exit 1, no stdout" eq "$RC:$OUT" 1:
  check "  naming the pattern" has "CODEOWNERS pattern /factory/[ab]/ uses syntax this gate does not read"
  check "  and the base" has "owners-check: cannot read the CODEOWNERS of ${BASE:0:12}"
  # The queue path with a PR the fake does not know.
  base ".github/CODEOWNERS=$CO_FACTORY"
  h="$(work ticket/T29/dev-box +factory/bin/x.sh)"
  s="$(git -C "$R" commit-tree "$h^{tree}" -p "$BASE" -p "$h" -m "Merge pull request #9 from ticket/T29/dev-box")"
  jq -n --arg b "$BASE" '{ref: "refs/heads/main", after: $b}' >"$WORLD/event.json"
  export GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$WORLD/event.json" GATE_QUEUE_PR=9 GATE_BASE="$BASE" GATE_HEAD="$s" GH_TOKEN=ghs_readonly
  oc
  check "queue: PR 9 unknown to GitHub: exit 1, no stdout" eq "$RC:$OUT" 1:
  check "  saying so" has "cannot read PR #9"
  # PR 9 readable, its reviews not.
  pull 9 "$h" ticket/T29/dev-box dev-box-owner "$(rv alice APPROVED)" "$(rv bob APPROVED)"
  FAKE_GH_FAIL='pulls/9/reviews' oc
  check "queue: an unreadable review list: exit 1" eq "$RC:$OUT" 1:
  check "  saying so" has "owners-check: cannot read the reviews of PR #9"
  oc
  check "  (the same world with the reviews readable passes)" eq "$RC:$(field .result)" 0:pass
}

for c in pass short stale-approval decisive-review author-never-counts codeowners teams-and-case no-protected-path \
         halt queue rerun fail-closed; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
