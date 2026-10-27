# shellcheck shell=bash
# The failure scenarios of `make sim` (tests/sim/sim.sh sources this after the walk; never executed).
#
# Each scenario builds the one PR or state it needs by hand in the walk's world, lets GitHub's side
# run (lib/driver.sh), and judges ONE stage `S.<name>` on the desired behavior: the gate that should
# stop the PR stops it, for its own reason (the log names the offending path or commit). The order
# matters: the PR-only scenarios first, then the ones that merge (they complete tickets), the
# janitor sweeps, and the HALT pair last (a HALT on main halts every later step).
#
# The desk adds the scenario tickets first, child before parent (an edge target must exist):
#   T-sim-s, T-sim-q   tier 0, both scoped sim/s/** (two tickets racing for one file: the conflict)
#   T-sim-t1           tier 1, sim/t1/**            (the tier jump; the foreign trailer's carrier)
#   T-sim-victim       tier 0, sim/victim/**        (named by the foreign trailer; must stay open)
#   T-sim-c2 ← T-sim-p2   tier 1 / tier 0, edge p2 → c2 (the child before its parent; p2 is held 24 h)
#   T-sim-b1, T-sim-b2 tier 0                       (node-b: a built PR plus a new claim)

SCN="$SIM/scn"
clone_of "$SCN"
git -C "$SCN" config user.name dev-box-owner; git -C "$SCN" config user.email dev-box-owner@sim.invalid

trailers() {  # trailers <ticket> <handle>: the one trailer paragraph a node commit carries (RULES.md)
  printf 'Assisted-by: claude-code\nTicket: %s\nNode: %s\nSigned-off-by: dev-box-owner <dev-box-owner@sim.invalid>\n' "$1" "$2"
}
scn_start() {  # scn_start <branch>: a fresh branch from origin/main in the scratch clone
  git -C "$SCN" fetch -q origin
  git -C "$SCN" checkout -q -B "$1" origin/main
}
scn_put() {  # scn_put <path> <content>
  mkdir -p "$SCN/$(dirname "$1")"; printf '%s\n' "$2" >"$SCN/$1"; git -C "$SCN" add -A -- "$1"
}
scn_commit() {  # scn_commit <ticket|-> [subject]: commit the index; `-` = no trailers at all. `Node:` is
               # the branch's handle (ticket/<id>/<handle>), as commit-check requires, so a scenario
               # commit carries only the defect its scenario names
  local msg="${2:-sim: scenario change}" br
  br="$(git -C "$SCN" symbolic-ref --short HEAD)"
  [ "$1" = - ] || msg="$(printf '%s\n\n%s' "$msg" "$(trailers "$1" "${br##*/}")")"
  git -C "$SCN" commit -qm "$msg"
}
scn_pr() {  # scn_pr <branch> <ticket|-> [author]: push the branch, open its PR; prints the PR number
  local body="Ticket: $2\nNode: dev-box"
  [ "$2" != - ] || body="A human PR."
  git -C "$SCN" push -q -f origin "HEAD:refs/heads/$1"
  FAKE_GH_USER="${3:-dev-box-owner}" "$SIM_FAKES/gh" pr create --repo "$REPO" --base main --head "$1" \
    --title "sim scenario: $1" --body "$(printf '%b' "$body")" >>"$LOG"
  pr_of "$1"
}
scn_desk_ticket() {  # scn_desk_ticket <id> <scope-dir>: a tier-0 ticket in the scratch clone's store. Its scope
                     # also names README.md (adlc's forecast calls a scope matching no file `unscoped`, and
                     # ticket-check refuses that) and its body declares <scope-dir>/hello.sh a new path
  ticket_json "$1" 0 "$2" '[]' | jq --arg s "$2" '.scope += ["README.md"] | .body += "\n\nNew paths: `\($s)/hello.sh`."' >"$SIM/ticket-$1.json"
  ( read -r -a a <<<"$ADLC"; cd "$SCN" && "${a[@]}" ticket create --input "$SIM/ticket-$1.json" --write --allow-unsigned --json ) >>"$LOG" 2>&1 ||
    die "adlc ticket create $1 failed"
}
desk_commit() {  # desk_commit <what>: commit the scratch clone's .adlc/ as the desk does (DCO, no Ticket:)
  git -C "$SCN" add -A .adlc
  git -C "$SCN" commit -qm "$(printf 'desk: %s\n\nSigned-off-by: sim-owner <sim-owner@sim.invalid>' "$1")"
}
check_fails_naming() {  # check_fails_naming <job> <head> <regex>: the job failed and its log matches
  local log
  [ "$(check_of "$1" "$2")" = failure ] || return 1
  log="$(job_log pull_request "$2" "$1")"
  [ -n "$log" ] && grep -v '^##' "$log" | grep -qE "$3"
}
scn_detail() {  # scn_detail <job> <head>: the job's conclusion and the last line of its log
  local log; log="$(job_log pull_request "$2" "$1")"
  printf '%s: %s %s' "$1" "$(check_of "$1" "$2")" \
    "$( [ -z "$log" ] || grep -v '^##' "$log" | tail -n1 | cut -c1-120)"
}
mk_lock() {  # mk_lock <issue> <handle> <epoch>: a lock as lib/lock.sh writes it, committed at <epoch>
  local tip tree payload sha
  tip="$(git -C "$ORIGIN" rev-parse refs/heads/nodes)"; tree="$(git -C "$ORIGIN" rev-parse "$tip^{tree}")"
  payload="$(jq -cn --arg h "$2" --arg at "$(jq -nr --argjson e "$3" '$e | todate')" \
    '{handle: $h, run_id: "sim-\($h)", slots: 1, claimed_at: $at}')"
  sha="$(printf 'lock issue-%s: %s\n\n%s\n' "$1" "$2" "$payload" |
    GIT_AUTHOR_NAME="$2" GIT_AUTHOR_EMAIL="$2@sim.invalid" GIT_COMMITTER_NAME="$2" GIT_COMMITTER_EMAIL="$2@sim.invalid" \
    GIT_AUTHOR_DATE="@$3" GIT_COMMITTER_DATE="@$3" git -C "$ORIGIN" commit-tree "$tree" -p "$tip")"
  git -C "$ORIGIN" update-ref "refs/locks/issue-$1" "$sha"
}
janitor_sweep() {
  drive schedule "$SIM/ev-sched.json" "$(main_sha)" .github/workflows/janitor.yml
}

# ------------------------------------------------------------------ the desk writes the scenario tickets
# Each scope dir gets a placeholder first: real adlc 1.12.0's forecast calls a ticket whose scope
# globs match no path `unscoped` and sequences it behind every other ticket (mirror: needs-desk), a
# rule the fake does not model (intake:I7, TB7). The walk's tickets keep their empty dirs.
desk_sync
for d in s t1 victim c2 p2 b1 b2 r n1 n2; do mkdir -p "$SIM/desk/sim/$d"; : >"$SIM/desk/sim/$d/.keep"; done
desk_ticket T-sim-s 0 sim/s '[]'
desk_ticket T-sim-q 0 sim/s '[]'
desk_ticket T-sim-t1 1 sim/t1 '[]'
desk_ticket T-sim-victim 0 sim/victim '[]'
desk_ticket T-sim-c2 1 sim/c2 '[]'
desk_ticket T-sim-p2 0 sim/p2 '[{"to":"T-sim-c2"}]'
desk_ticket T-sim-b1 0 sim/b1 '[]'
desk_ticket T-sim-b2 0 sim/b2 '[]'
desk_ticket T-sim-r 0 sim/r '[]'
desk_ticket T-sim-n1 0 sim/n1 '[]'
desk_ticket T-sim-n2 0 sim/n2 '[]'
desk_records
desk_push "desk: the failure-scenario tickets, and their records (factory/bin/desk-gates.sh --write)"

# ------------------------------------------------------------------ PR-only scenarios
# A file outside the ticket's scope: scope fails and names it.
scn_start ticket/T-sim-s/scn-scope
scn_put sim/s/hello.sh 'echo hello'; scn_put docs/outside.md 'outside the scope'
scn_commit T-sim-s; pr="$(scn_pr ticket/T-sim-s/scn-scope T-sim-s)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.out-of-scope "$(scn_detail scope "$h")" check_fails_naming scope "$h" 'docs/outside\.md'

# A new skip marker: tamper fails on a parsed `tamper` verdict.
scn_start ticket/T-sim-s/scn-tamper
scn_put sim/s/test_hello.sh "it.skip('hello prints hello')"
scn_commit T-sim-s; pr="$(scn_pr ticket/T-sim-s/scn-tamper T-sim-s)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.tamper-skip "$(scn_detail tamper "$h")" check_fails_naming tamper "$h" '"verdict": *"tamper"'

# A rail path edited: rails-proof fails and names it.
scn_start ticket/T-sim-s/scn-rail
scn_put sim/s/hello.sh 'echo hello'; scn_put factory/policy/sim-rail.json '{}'
scn_commit T-sim-s; pr="$(scn_pr ticket/T-sim-s/scn-rail T-sim-s)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.rail-edit "$(scn_detail rails-proof "$h")" check_fails_naming rails-proof "$h" 'factory/policy/sim-rail\.json'

# A commit without trailers: commit-check fails and names the commit.
scn_start ticket/T-sim-s/scn-trailer
scn_put sim/s/hello.sh 'echo hello'
scn_commit -; pr="$(scn_pr ticket/T-sim-s/scn-trailer T-sim-s)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.no-trailer "$(scn_detail commit-check "$h")" check_fails_naming commit-check "$h" 'FAIL: [0-9a-f]{12} .*no Signed-off-by trailer'

# I16: the head rewrites the scope gate to `exit 0` and adds an out-of-scope file. The base's gate
# runs, so scope still fails, and names the file.
scn_start ticket/T-sim-s/scn-gate
printf '#!/usr/bin/env bash\nexit 0\n' >"$SCN/factory/bin/scope-check.sh"; git -C "$SCN" add factory/bin/scope-check.sh
scn_put docs/outside.md 'outside the scope'
scn_commit T-sim-s; pr="$(scn_pr ticket/T-sim-s/scn-gate T-sim-s)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.head-edits-gate "$(scn_detail scope "$h")" check_fails_naming scope "$h" 'docs/outside\.md'
# The rule itself: the job ran the BASE's scope-check.sh from ./.base (its gate-context line says so)
# and failed; the head's `exit 0` copy never ran.
judge S.base-script "$(scn_detail scope "$h")" check_fails_naming scope "$h" 'gate from /.*/\.base on '

# The head commits its own `.base/factory/bin/scope-check.sh` (`exit 0`): the base checkout wipes it,
# so the base's gate still runs.
scn_start ticket/T-sim-s/scn-plant
mkdir -p "$SCN/.base/factory/bin"; printf '#!/usr/bin/env bash\nexit 0\n' >"$SCN/.base/factory/bin/scope-check.sh"
chmod +x "$SCN/.base/factory/bin/scope-check.sh"; git -C "$SCN" add .base
scn_put docs/outside.md 'outside the scope'
scn_commit T-sim-s; pr="$(scn_pr ticket/T-sim-s/scn-plant T-sim-s)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.head-plants-base "$(scn_detail scope "$h")" check_fails_naming scope "$h" 'gate from /.*/\.base on '

# A ticket branch whose PR body names another ticket: the context and every ticket gate refuse it.
scn_start ticket/T-sim-s/scn-body
scn_put sim/s/hello.sh 'echo hello'
scn_commit T-sim-s; pr="$(scn_pr ticket/T-sim-s/scn-body T-sim-victim)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.foreign-body "$(scn_detail context "$h"); $(scn_detail scope "$h")" \
  eval 'check_fails_naming context "$h" "body says .Ticket: T-sim-victim" && check_fails_naming scope "$h" "body says .Ticket: T-sim-victim"'

# A branch under ticket/ that is not ticket/<id>/<handle> (an id never holds a `/`): refused, not
# read as a human PR.
scn_start ticket/T-sim-s/scn/deep
scn_put sim/s/hello.sh 'echo hello'
scn_commit T-sim-s; pr="$(scn_pr ticket/T-sim-s/scn/deep T-sim-s)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.ticket-ref-malformed "$(scn_detail context "$h")" check_fails_naming context "$h" 'is under ticket/ but is not ticket/<id>/<handle>'

# A fork's PR from a branch named like a ticket: never a ticket PR.
scn_start ticket/T-sim-s/fork
scn_put sim/s/hello.sh 'echo hello'
scn_commit T-sim-s; pr="$(scn_pr ticket/T-sim-s/fork T-sim-s stranger)"
gh_state '(.pulls[] | select(.number == $n)).headRepository = "stranger/factory"' --argjson n "$pr"
pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.fork-ticket-ref "$(scn_detail context "$h")" check_fails_naming context "$h" 'a fork is never a ticket PR'

# A collaborator's PR off a ticket branch, past the desk's paths: class human.
scn_start human/scn-docs
scn_put docs/sim-note.md 'a note'
git -C "$SCN" commit -qm "$(printf 'docs: a note\n\nSigned-off-by: dev-box-owner <dev-box-owner@sim.invalid>')"
pr="$(scn_pr human/scn-docs - dev-box-owner)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.class-human "context: $(ctx_of pull_request "$h")" ctx_is pull_request "$h" \
  '.class == "human" and .author_association == "COLLABORATOR" and .ticket == null'

# A stranger's PR (from a fork, not a ticket branch): no class, refused.
scn_start stranger/scn-docs
scn_put docs/sim-stranger.md 'a stranger note'
git -C "$SCN" commit -qm "$(printf 'docs: a stranger note\n\nSigned-off-by: stranger <stranger@sim.invalid>')"
pr="$(scn_pr stranger/scn-docs - stranger)"
gh_state '(.pulls[] | select(.number == $n)).headRepository = "stranger/factory"' --argjson n "$pr"
pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.stranger-refused "$(scn_detail context "$h")" check_fails_naming context "$h" 'not a collaborator'

# A ticket PR touching .adlc/**: scope fails and names it.
scn_start ticket/T-sim-s/scn-adlc
jq '. + {sim: true}' "$SCN/.adlc/config.json" >"$SCN/.adlc/config.json.n" && mv "$SCN/.adlc/config.json.n" "$SCN/.adlc/config.json"
git -C "$SCN" add .adlc/config.json
scn_commit T-sim-s; pr="$(scn_pr ticket/T-sim-s/scn-adlc T-sim-s)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.ticket-adlc "$(scn_detail scope "$h")" check_fails_naming scope "$h" '\.adlc/config\.json'

# I16 for build-test (TB5): the head rewrites fleet.gate to commands that cannot fail. build-test runs
# the BASE's list (`make lint`, then `make test`, build-test.sh's trace lines), never the head's.
base_gate_ran() {  # base_gate_ran <head>: build-test's trace is exactly the base's list, no head command
  local log; log="$(job_log pull_request "$1" build-test)"
  [ -n "$log" ] && [ "$(grep -E '^build-test: (build|test): ' "$log" | tr '\n' '|')" = \
    "build-test: build: /bin/sh -c make lint|build-test: test: /bin/sh -c make test|" ] && ! grep -q head-gate "$log"
}
scn_start ticket/T-sim-s/scn-gate-config
jq '.fleet.gate = {build: "echo head-gate", test: "echo head-gate"}' "$SCN/.adlc/config.json" >"$SCN/.adlc/config.json.n" &&
  mv "$SCN/.adlc/config.json.n" "$SCN/.adlc/config.json"
git -C "$SCN" add .adlc/config.json
scn_commit T-sim-s; pr="$(scn_pr ticket/T-sim-s/scn-gate-config T-sim-s)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.head-edits-gate-config "$(scn_detail build-test "$h")" base_gate_ran "$h"

# A desk PR (only .adlc/**), written as the desk runbook says (factory/RULES.md): the ticket and its
# records in one commit. The `desk` check runs the desk gates and passes.
scn_start desk/scn-desk
scn_desk_ticket T-sim-desk sim/desk; desk_records "$SCN"; desk_commit T-sim-desk
pr="$(scn_pr desk/scn-desk - sim-owner)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.desk-pr "desk: $(check_of desk "$h")" test "$(check_of desk "$h")" = success
judge S.class-desk "context: $(ctx_of pull_request "$h")" ctx_is pull_request "$h" '.class == "desk" and .ticket == null'

# Two desk PRs cut from one main, joined: B's manifest lines were chained on the old main, after
# A's. The desk check fails on the broken hash chain, before anything reaches main. (Nothing here
# merges: one more open ticket on main would change node-b's claims below.)
scn_start desk/scn-race-b
scn_desk_ticket T-sim-rb sim/rb; desk_records "$SCN"; desk_commit T-sim-rb
git -C "$SCN" show HEAD:.adlc/manifest.jsonl | tail -n +"$(( $(git -C "$SCN" show origin/main:.adlc/manifest.jsonl | wc -l) + 1 ))" >"$SIM/race-b.lines"
scn_start desk/scn-race
scn_desk_ticket T-sim-ra sim/ra; desk_records "$SCN"; desk_commit T-sim-ra
command cat "$SIM/race-b.lines" >>"$SCN/.adlc/manifest.jsonl"; desk_commit "T-sim-rb's manifest lines, written on the old main"
pr="$(scn_pr desk/scn-race - sim-owner)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.desk-chain-race "$(scn_detail desk "$h")" check_fails_naming desk "$h" 'chain broken'

# A desk PR from an older main (its manifest is not main's plus new lines): it fails until rebased.
git -C "$SCN" checkout -q -B desk/scn-stale "$SEED_SHA"
scn_put .adlc/specs/sim-note.md 'a desk note'; desk_commit "a note, from the seed's main"
pr="$(scn_pr desk/scn-stale - sim-owner)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.desk-stale-base "$(scn_detail desk "$h")" check_fails_naming desk "$h" 'does not extend the base'

# A ticket written without its records: the desk check names the missing record.
scn_start desk/scn-norec
scn_desk_ticket T-sim-nr sim/nr; desk_commit T-sim-nr
pr="$(scn_pr desk/scn-norec - sim-owner)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.desk-no-records "$(scn_detail desk "$h")" check_fails_naming desk "$h" 'T-sim-nr.*missing record'

# The child before its parent: T-sim-c2's PR while T-sim-p2 is open. depends-on fails.
scn_start ticket/T-sim-c2/scn-early
scn_put sim/c2/hello.sh 'echo hello'
scn_commit T-sim-c2; pr="$(scn_pr ticket/T-sim-c2/scn-early T-sim-c2)"; approve "$pr"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.child-before-parent "$(scn_detail depends-on "$h")" check_fails_naming depends-on "$h" 'T-sim-p2'
C2_PR="$pr" C2_HEAD="$h"   # S.child-released: the parent merges and this held job is re-run

# A tier-1 PR while an approved tier-0 PR is open: tier-order holds the tier-1 one.
scn_start ticket/T-sim-s/scn-a
scn_put sim/s/conflict.txt 'a'
scn_commit T-sim-s; PR_A="$(scn_pr ticket/T-sim-s/scn-a T-sim-s)"; approve "$PR_A"; pr_event "$PR_A"
scn_start ticket/T-sim-t1/scn-t1
scn_put sim/t1/hello.sh 'echo hello'
scn_commit T-sim-t1; pr="$(scn_pr ticket/T-sim-t1/scn-t1 T-sim-t1)"; approve "$pr"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.tier-jump "$(scn_detail tier-order "$h")" check_fails_naming tier-order "$h" "#$PR_A"

# ------------------------------------------------------------------ the queue (enqueue.yml, eject.sh)
# GitHub's view of the attest-verify stub is the walk's labeled stand-in again, so a PR can be green.
# PRs from the PR-only scenarios stay red: their runs were recorded without it.
export SIM_STANDIN_GREEN="attest-verify"
# claim.sh skips a ticket with any open ticket/<id>/* PR, and S.rebase-strike claims T-sim-s: its
# earlier scenario PRs (PR_A among them) are closed first.
for n in $(ghq '.pulls[] | select(.state == "OPEN" and (.headRefName | startswith("ticket/T-sim-s/"))) | .number'); do
  gh_state '(.pulls[] | select(.number == $n)).state = "CLOSED"' --argjson n "$n"
done
ej_line() {  # ej_line <pr>: the ejection record of PR <n> on main (factory/ledger/ejections.jsonl), or {}
  local l; l="$(git -C "$ORIGIN" show "$(main_sha):factory/ledger/ejections.jsonl" 2>/dev/null | jq -c --argjson n "$1" 'select(.pr == $n)' | tail -n1)"
  [ -n "$l" ] || l='{}'
  printf '%s\n' "$l"
}
ejected() {  # ejected <pr> <reason>: closed, labeled autorebase, and its ejection record says <reason>
  [ "$(pr_field "$1" .state)" = CLOSED ] &&
    ghq -e --argjson n "$1" 'any(.pulls[] | select(.number == $n) | .labels[]; .name == "autorebase")' >/dev/null &&
    jq -e --arg r "$2" '.reason == $r' <<<"$(ej_line "$1")" >/dev/null
}
pr_labels() { pr_field "$1" '[.labels[].name] | join(",")'; }
issue_labels() { ghq --argjson n "$1" '.issues[] | select(.number == $n) | [.labels[].name] | join(",")'; }
enqueue_tick() {  # the queue's schedule (enqueue.yml from main; GitHub's clock, not a stand-in)
  printf '{"schedule":"*/15 * * * *"}\n' >"$SIM/ev-sched-enqueue.json"
  drive schedule "$SIM/ev-sched-enqueue.json" "$(main_sha)" .github/workflows/enqueue.yml
}

# Two tickets race for one file. X is green but not approved, so the queue passes it by; Y is
# approved and lands. X approved later conflicts with the new main: the queue ejects it (closed,
# autorebase, a record on main, the ticket's Issue ready with rebase-strike).
scn_start ticket/T-sim-s/scn-x
scn_put sim/s/conflict.txt 'x'
scn_commit T-sim-s; PR_X="$(scn_pr ticket/T-sim-s/scn-x T-sim-s)"; pr_event "$PR_X"
scn_start ticket/T-sim-q/scn-y
scn_put sim/s/conflict.txt 'y'
scn_commit T-sim-q; PR_Y="$(scn_pr ticket/T-sim-q/scn-y T-sim-q)"; approve "$PR_Y"; pr_event "$PR_Y"
desk_sync
approve "$PR_X"; enqueue_tick
S_ISSUE="$(issue_of T-sim-s)"
judge S.queue-conflict "#$PR_Y $(queue_line land "$PR_Y" | jq -r .result); #$PR_X pick $(queue_line pick "$PR_X" | jq -c '{result, eject: .eject.result}'), $(pr_field "$PR_X" .state) [$(pr_labels "$PR_X")], record $(ej_line "$PR_X" | jq -c '{reason, strike}'); #$S_ISSUE [$(issue_labels "$S_ISSUE")]" \
  eval '[ "$(queue_line land "$PR_Y" | jq -r .result)" = landed ] && [ "$(queue_line pick "$PR_X" | jq -r .result)" = conflict ] &&
        ejected "$PR_X" conflict && has_label "$S_ISSUE" ready && has_label "$S_ISSUE" rebase-strike && ! has_label "$S_ISSUE" in-review'

# The next claim of T-sim-s is the rebase strike: the worktree is cut from main, X's one commit is
# cherry-picked onto it (a conflict here: main holds Y's line), so fleet builds the ticket anew from
# main; the strike does not count toward --max-strikes (factory/policy/budget.json), and the new PR
# takes rebase-strike off the Issue.
# claim.sh takes the oldest ready Issue, and the mirror numbers the scenario Issues by ticket id:
# the other ready Issues are held back for this one claim (a labeled stand-in), then put back.
HELD="$(ghq --argjson s "$S_ISSUE" '[.issues[] | select(.number != $s and any(.labels[]; .name == "ready")) | .number]')"
standin "the ready Issues $(jq -c . <<<"$HELD") are held back so the node claims #$S_ISSUE"
gh_state '.issues |= map(if (.number | IN($h[])) then .labels -= [{name: "ready"}] else . end)' --argjson h "$HELD"
node_run dev-box FAKE_FLEET_FILE=sim/s/hello.sh
gh_state '.issues |= map(if (.number | IN($h[])) and (any(.labels[]; .name == "ready") | not) then .labels += [{name: "ready"}] else . end)' --argjson h "$HELD"
RB_PR="$(pr_of ticket/T-sim-s/dev-box)"
judge S.rebase-strike "rc $RUN_RC: rebase $(jq -c '.rebase // null' <<<"$RUN_LAST"), base $(jq -c '.base.kind // null' <<<"$RUN_LAST"), budget $(jq -c '.budget.max_strikes // null' <<<"$RUN_LAST"); PR ${RB_PR:-none}; #$S_ISSUE [$(issue_labels "$S_ISSUE")]" \
  eval 'jq -e --argjson x "$PR_X" --arg m "$(main_sha)" ".rebase.pr == \$x and .rebase.result == \"conflict\" and .base.kind == \"origin-main\" and .base.sha == \$m
          and (.actions | index(\"rebase-conflict\")) != null and (.actions | index(\"fleet-run\")) != null and .budget.max_strikes == 2" <<<"$RUN_LAST" >/dev/null &&
        [ -n "$RB_PR" ] && ! has_label "$S_ISSUE" rebase-strike && has_label "$S_ISSUE" in-review'

# Green apart, red merged: `make test` fails only with both sim/r files in the tree (lib/world.sh).
# R is green on the PR; main gains sim/r/main-side; the queue's gates on the merge fail, and `land`
# ejects R as a red queue run.
scn_start ticket/T-sim-r/scn-r
scn_put sim/r/pr-side 'pr'
scn_commit T-sim-r; PR_R="$(scn_pr ticket/T-sim-r/scn-r T-sim-r)"; pr_event "$PR_R"; R_HEAD="$(pr_field "$PR_R" .headRefOid)"
desk_sync; printf 'main\n' >"$SIM/desk/sim/r/main-side"
desk_push "desk: sim/r/main-side (S.queue-red)"
approve "$PR_R"; enqueue_tick
judge S.queue-red "#$PR_R PR build-test $(check_of build-test "$R_HEAD"); land $(queue_line land "$PR_R" | jq -c '{result, gates, eject: .eject.result}'), $(pr_field "$PR_R" .state) [$(pr_labels "$PR_R")], record $(ej_line "$PR_R" | jq -c '{reason}')" \
  eval '[ "$(check_of build-test "$R_HEAD")" = success ] && jq -e ".result == \"red\" and .eject.result == \"ejected\"" <<<"$(queue_line land "$PR_R")" >/dev/null &&
        ejected "$PR_R" red-queue-run'

# The native mode: GitHub's merge queue is on for main (the fake gh's .merge_queue). enqueue.sh
# enqueues the head of the order through GraphQL; GitHub's queue (stand-in) builds the group and
# runs merge_group, and its removal of a PR for a failed check reaches `dequeued`, which ejects.
gh_state '.merge_queue = {id: "MQ_sim", entries: []}'
scn_start ticket/T-sim-n1/scn-n1
scn_put sim/n1/hello.sh 'echo hello'
scn_commit T-sim-n1; PR_N1="$(scn_pr ticket/T-sim-n1/scn-n1 T-sim-n1)"; approve "$PR_N1"; pr_event "$PR_N1"
judge S.native-enqueue "pick $(queue_line pick "$PR_N1" | jq -c '{mode, result}'); enqueued $(ghq -c '.enqueued // []')" \
  ghq -e --argjson n "$PR_N1" --arg h "$(pr_field "$PR_N1" .headRefOid)" '.enqueued == [{pr: $n, head: $h}]'
standin "GitHub's merge queue builds the group of #$PR_N1 and runs merge_group"
group="$(queue_standin "$PR_N1")"
miss="$(required_report "$(main_sha)" "$group")"
judge S.native-merge "${miss:-every required context reports green}" test -z "$miss"
standin "GitHub's merge queue merges #$PR_N1 (the group, size 1)"
gh_state '.merge_queue.entries -= [$n]' --argjson n "$PR_N1"
merge_standin "$PR_N1" "$group"; desk_sync
scn_start ticket/T-sim-n2/scn-n2
scn_put sim/n2/hello.sh 'echo hello'
scn_commit T-sim-n2; PR_N2="$(scn_pr ticket/T-sim-n2/scn-n2 T-sim-n2)"; approve "$PR_N2"; pr_event "$PR_N2"
standin "GitHub's merge queue removes #$PR_N2 for a failed check (pull_request_target dequeued, CI_FAILURE)"
gh_state '.merge_queue.entries -= [$n]' --argjson n "$PR_N2"
jq -n --argjson n "$PR_N2" --argjson p "$(FAKE_GH_LOG=/dev/null "$SIM_FAKES/gh" api "repos/$REPO/pulls/$PR_N2")" \
  '{action: "dequeued", number: $n, reason: "CI_FAILURE", pull_request: $p}' >"$SIM/ev-dq.json"
drive pull_request_target "$SIM/ev-dq.json" "$(main_sha)"
judge S.native-dequeue "enqueued $(ghq -c --argjson n "$PR_N2" '[(.enqueued // [])[] | select(.pr == $n)] | length'); #$PR_N2 $(pr_field "$PR_N2" .state) [$(pr_labels "$PR_N2")], record $(ej_line "$PR_N2" | jq -c '{reason, dequeued_reason}')" \
  eval 'ghq -e --argjson n "$PR_N2" "any((.enqueued // [])[]; .pr == \$n)" >/dev/null && ejected "$PR_N2" red-queue-run &&
        [ "$(ej_line "$PR_N2" | jq -r .dequeued_reason)" = CI_FAILURE ]'
gh_state '.merge_queue = null'
unset SIM_STANDIN_GREEN

# A T-sim-t1 PR whose second commit names T-sim-victim. Merged: post-merge completes T-sim-t1 (its
# head branch's ticket) and reports T-sim-victim `foreign`, never completing it (merge:G11).
scn_start ticket/T-sim-t1/scn-foreign
scn_put sim/t1/foreign.sh 'echo one'; scn_commit T-sim-t1
scn_put sim/t1/foreign2.sh 'echo two'; scn_commit T-sim-victim
pr="$(scn_pr ticket/T-sim-t1/scn-foreign T-sim-t1)"; approve "$pr"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
# The ticket gates refuse it on the PR already, so no queue takes it: a repo admin's merge button does
# (a labeled stand-in, as every merge here that is no queue's).
judge S.foreign-trailer-refused "$(scn_detail context "$h"); $(scn_detail commit-check "$h")" \
  eval 'check_fails_naming context "$h" "trailer .Ticket: T-sim-victim" && check_fails_naming commit-check "$h" "trailer .Ticket: T-sim-victim"'
standin "admin merge #$pr"
admin_merge "$pr"
pm_line() {  # pm_line <merge-sha> <ticket>: post-merge's JSON line for <ticket> on the push of <merge-sha>
  local log; log="$(jq -r --arg h "$1" 'select(.event == "push" and .head_sha == $h and .job == "complete") | .log' "$SIM/jobs.jsonl" | tail -n1)"
  [ -z "$log" ] || { grep -h '^{"mode":' "$log" || true; } | jq -c --arg t "$2" 'select(.ticket == $t)' | tail -n1
}
done_of() { adlc_desk ticket show "$1" --json | jq -r '.ticket.completed // false'; }
m="$(ghq --argjson n "$pr" '[.merged[] | select(.pr == $n)] | last | .sha')"; pm="$(pm_line "$m" T-sim-victim)"
judge S.foreign-trailer "T-sim-victim completed: $(done_of T-sim-victim), post-merge: ${pm:-no line}; T-sim-t1 completed: $(done_of T-sim-t1)" \
  eval 'test "$(done_of T-sim-victim)" != true && test "$(done_of T-sim-t1)" = true &&
        jq -e --argjson n "$pr" ".result == \"foreign\" and .pr == \$n" <<<"$pm" >/dev/null'

# ------------------------------------------------------------------ the janitor sweeps
# T-sim-p2 was built 25 h ago and its PR is held open (by its child's order or the queue). After the
# hourly sweep, no second node may pick it up: its Issue is not `ready`, and not `needs-desk` either
# (the PR holds it; it is not a dead letter).
P2="$(issue_of T-sim-p2)"; old=$((T0 - 25 * 3600))
scn_start ticket/T-sim-p2/dev-box
scn_put sim/p2/hello.sh 'echo hello'
GIT_COMMITTER_DATE="@$old" GIT_AUTHOR_DATE="@$old" scn_commit T-sim-p2
scn_pr ticket/T-sim-p2/dev-box T-sim-p2 >/dev/null
mk_lock "$P2" dev-box "$old"
janitor_sweep
judge S.held-24h "#$P2 labels $(ghq --argjson n "$P2" '.issues[] | select(.number == $n) | [.labels[].name] | join(",")'); lock ${P2:+$( [ -n "$(lock_of "$P2")" ] && echo kept || echo released)}" \
  eval '! has_label "$P2" ready && ! has_label "$P2" needs-desk'

# The parent merges. post-merge completes T-sim-p2; on post-merge's completion (workflow_run) the
# labeler finds T-sim-c2's held depends-on answering otherwise against main now and re-runs it; the
# re-run replays the PR's event and reads the store at main's tip (lib/gate-context.sh gc_store_sha).
standin "admin merge #$(pr_of ticket/T-sim-p2/dev-box)"
admin_merge "$(pr_of ticket/T-sim-p2/dev-box)"
rerun_of() {  # rerun_of <job> <head>: the conclusion of the driver's latest re-run of that job, or empty
  jq -r --arg j "$1" --arg h "$2" 'select(.rerun == true and .job == $j and .head_sha == $h) | .conclusion' "$SIM/jobs.jsonl" | tail -n1
}
judge S.child-released "T-sim-p2 completed: $(done_of T-sim-p2); #$C2_PR $(scn_detail depends-on "$C2_HEAD"); re-run: $(rerun_of depends-on "$C2_HEAD")" \
  eval 'test "$(done_of T-sim-p2)" = true && test "$(rerun_of depends-on "$C2_HEAD")" = success &&
        test "$(check_of depends-on "$C2_HEAD")" = success'

# node-b (1 slot) has T-sim-b1 built an hour ago with its PR open, and claimed T-sim-b2 10 min ago.
# The sweep must leave the new claim alone (the built ticket's PR is the claim, not a slot).
B1="$(issue_of T-sim-b1)"; B2="$(issue_of T-sim-b2)"
scn_start ticket/T-sim-b1/node-b
scn_put sim/b1/hello.sh 'echo hello'
GIT_COMMITTER_DATE="@$((T0 - 3600))" GIT_AUTHOR_DATE="@$((T0 - 3600))" scn_commit T-sim-b1
scn_pr ticket/T-sim-b1/node-b T-sim-b1 node-b-owner >/dev/null
mk_lock "$B1" node-b "$((T0 - 3600))"
mk_lock "$B2" node-b "$((T0 - 600))"
janitor_sweep
judge S.built-plus-claim "#$B2 lock $( [ -n "$(lock_of "$B2")" ] && echo kept || echo released); #$B1 lock $( [ -n "$(lock_of "$B1")" ] && echo kept || echo released)" \
  test -n "$(lock_of "$B2")"

# ------------------------------------------------------------------ HALT (last: it halts the factory)
# A collaborator halts the line with zero approvals: the `factory:halt` label on a PR fires halt.yml
# (pull_request_target labeled), which commits factory/HALT onto main on the App token (ADR-0004 C + D;
# merge:G17). The PR that carries the label passes its own required checks with no approval either,
# with attest-verify, still the ci:G6 stub until TB11, under the walk's stand-in (SIM_STANDIN_GREEN).
scn_start human/halt-add
scn_put factory/HALT 'sim: stop the line'
git -C "$SCN" commit -qm "$(printf 'halt: stop the line\n\nSigned-off-by: sim-owner <sim-owner@sim.invalid>')"
pr="$(scn_pr human/halt-add - sim-owner)"; SIM_STANDIN_GREEN="attest-verify" pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.class-halt-add "context: $(ctx_of pull_request "$h")" ctx_is pull_request "$h" '.class == "halt" and .author_association == "OWNER"'
miss="$(required_report "$(main_sha)" "$h")"
approvals="$(git -C "$ORIGIN" show "$(main_sha):factory/policy/branch-protection.json" |
  jq '[.rulesets[]?.rules[]? | select(.type == "pull_request") | .parameters.required_approving_review_count] | max // 0')"
gh_state '(.pulls[] | select(.number == $n)).labels += [{name: "factory:halt"}]' --argjson n "$pr"
jq -n --argjson n "$pr" --argjson p "$(FAKE_GH_LOG=/dev/null "$SIM_FAKES/gh" api "repos/$REPO/pulls/$pr")" \
  '{action: "labeled", number: $n, label: {name: "factory:halt"}, sender: {login: "sim-owner"}, pull_request: $p}' >"$SIM/ev-halt.json"
drive pull_request_target "$SIM/ev-halt.json" "$(main_sha)"
halt_commit="$(git -C "$ORIGIN" log -1 --format='%an|%s' main -- factory/HALT)"
judge S.halt-add "${miss:-every required check green}; $approvals approval(s) required; HALT on main by: ${halt_commit:-nobody}" \
  eval 'test -z "$miss" && test "$approvals" = 0 && git -C "$ORIGIN" cat-file -e main:factory/HALT &&
        test "$halt_commit" = "github-actions[bot]|halt: stop the line (@sim-owner)"'

# HALT is on main. A PR removing it (by a collaborator, so its author's review could not count) with
# ONE owner approval (@musicofhel, factory/HALT's one owner in the seed's CODEOWNERS): halt-guard fails,
# counting that one approval.
if ! git -C "$ORIGIN" cat-file -e main:factory/HALT 2>/dev/null; then
  standin "halt.yml did not halt: the desk pushes factory/HALT for the removal scenarios"
  desk_sync; printf 'sim: stop the line\n' >"$SIM/desk/factory/HALT"; desk_push "desk: factory/HALT"
fi
scn_start human/halt-remove
git -C "$SCN" rm -q factory/HALT
git -C "$SCN" commit -qm "$(printf 'halt: resume\n\nSigned-off-by: node-b-owner <node-b-owner@sim.invalid>')"
pr="$(scn_pr human/halt-remove - node-b-owner)"; approve "$pr" musicofhel; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.class-halt-remove "context: $(ctx_of pull_request "$h")" ctx_is pull_request "$h" '.class == "halt"'
judge S.halt-remove "$(scn_detail halt-guard "$h")" check_fails_naming halt-guard "$h" '"approvals":\["musicofhel"\].*"result":"short"'

# The same removal with TWO owner approvals. The desk names a second owner of factory/HALT in
# CODEOWNERS (the sim's owners: the seed's CODEOWNERS names the real repo's owner); the PR's first run
# is short, then each review fires reviews.yml (pull_request_review), which re-runs halt-guard, and
# the re-run counts both approvals on the head.
desk_sync; printf '\nfactory/HALT @sim-owner @desk\n' >>"$SIM/desk/CODEOWNERS"
desk_push "desk: a second owner of factory/HALT (sim)"
scn_start human/halt-remove-two
git -C "$SCN" rm -q factory/HALT
git -C "$SCN" commit -qm "$(printf 'halt: resume\n\nSigned-off-by: node-b-owner <node-b-owner@sim.invalid>')"
pr="$(scn_pr human/halt-remove-two - node-b-owner)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
first="$(check_of halt-guard "$h")"
for who in sim-owner desk; do
  approve "$pr" "$who"
  jq -n --argjson p "$(FAKE_GH_LOG=/dev/null "$SIM_FAKES/gh" api "repos/$REPO/pulls/$pr")" --arg u "$who" --arg h "$h" \
    '{action: "submitted", review: {user: {login: $u}, state: "approved", commit_id: $h}, pull_request: $p}' >"$SIM/ev-review.json"
  drive pull_request_review "$SIM/ev-review.json" "$(git -C "$ORIGIN" rev-parse "refs/pull/$pr/merge")"
done
judge S.halt-remove-two "first run: halt-guard $first; after two approvals, re-run: $(rerun_of halt-guard "$h"); check now $(check_of halt-guard "$h")" \
  eval 'test "$first" = failure && test "$(rerun_of halt-guard "$h")" = success && test "$(check_of halt-guard "$h")" = success'
