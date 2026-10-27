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

trailers() {  # trailers <ticket>: the one trailer paragraph a node commit carries (RULES.md)
  printf 'Assisted-by: claude-code\nTicket: %s\nNode: dev-box\nSigned-off-by: dev-box-owner <dev-box-owner@sim.invalid>\n' "$1"
}
scn_start() {  # scn_start <branch>: a fresh branch from origin/main in the scratch clone
  git -C "$SCN" fetch -q origin
  git -C "$SCN" checkout -q -B "$1" origin/main
}
scn_put() {  # scn_put <path> <content>
  mkdir -p "$SCN/$(dirname "$1")"; printf '%s\n' "$2" >"$SCN/$1"; git -C "$SCN" add -A -- "$1"
}
scn_commit() {  # scn_commit <ticket|-> [subject]: commit the index; `-` = no trailers at all
  local msg="${2:-sim: scenario change}"
  [ "$1" = - ] || msg="$(printf '%s\n\n%s' "$msg" "$(trailers "$1")")"
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
approve() {  # approve <pr> [login]: one APPROVED review
  gh_state '(.pulls[] | select(.number == $n)).reviews += [{author: {login: $u}, state: "APPROVED"}]' \
    --argjson n "$1" --arg u "${2:-sim-owner}"
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
queue_and_merge() {  # the walk's stand-ins: GitHub's queue builds the group, main moves to it
  local g; g="$(queue_standin "$1")"
  merge_standin "$1" "$g"
  desk_sync
}

# ------------------------------------------------------------------ the desk writes the scenario tickets
# Each scope dir gets a placeholder first: real adlc 1.12.0's forecast calls a ticket whose scope
# globs match no path `unscoped` and sequences it behind every other ticket (mirror: needs-desk), a
# rule the fake does not model (intake:I7, TB7). The walk's tickets keep their empty dirs.
desk_sync
for d in s t1 victim c2 p2 b1 b2; do mkdir -p "$SIM/desk/sim/$d"; : >"$SIM/desk/sim/$d/.keep"; done
desk_ticket T-sim-s 0 sim/s '[]'
desk_ticket T-sim-q 0 sim/s '[]'
desk_ticket T-sim-t1 1 sim/t1 '[]'
desk_ticket T-sim-victim 0 sim/victim '[]'
desk_ticket T-sim-c2 1 sim/c2 '[]'
desk_ticket T-sim-p2 0 sim/p2 '[{"to":"T-sim-c2"}]'
desk_ticket T-sim-b1 0 sim/b1 '[]'
desk_ticket T-sim-b2 0 sim/b2 '[]'
desk_push "desk: the failure-scenario tickets"
records_standin T-sim-s T-sim-q T-sim-t1 T-sim-victim T-sim-c2 T-sim-p2 T-sim-b1 T-sim-b2

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
judge S.no-trailer "$(scn_detail commit-check "$h")" check_fails_naming commit-check "$h" 'Signed-off-by'

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

# A desk PR (only .adlc/**): a `desk` check runs the desk gates and passes.
scn_start desk/scn-desk
ticket_json T-sim-desk 0 sim/desk '[]' >"$SIM/ticket-T-sim-desk.json"
( read -r -a a <<<"$ADLC"; cd "$SCN" && "${a[@]}" ticket create --input "$SIM/ticket-T-sim-desk.json" --write --allow-unsigned --json ) >>"$LOG" 2>&1 ||
  die "adlc ticket create T-sim-desk failed"
git -C "$SCN" add -A .adlc
git -C "$SCN" commit -qm "$(printf 'desk: T-sim-desk\n\nSigned-off-by: sim-owner <sim-owner@sim.invalid>')"
pr="$(scn_pr desk/scn-desk - sim-owner)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.desk-pr "desk: $(check_of desk "$h")" test "$(check_of desk "$h")" = success
judge S.class-desk "context: $(ctx_of pull_request "$h")" ctx_is pull_request "$h" '.class == "desk" and .ticket == null'

# The child before its parent: T-sim-c2's PR while T-sim-p2 is open. depends-on fails.
scn_start ticket/T-sim-c2/scn-early
scn_put sim/c2/hello.sh 'echo hello'
scn_commit T-sim-c2; pr="$(scn_pr ticket/T-sim-c2/scn-early T-sim-c2)"; approve "$pr"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.child-before-parent "$(scn_detail depends-on "$h")" check_fails_naming depends-on "$h" 'T-sim-p2'

# A tier-1 PR while an approved tier-0 PR is open: tier-order holds the tier-1 one.
scn_start ticket/T-sim-s/scn-a
scn_put sim/s/conflict.txt 'a'
scn_commit T-sim-s; PR_A="$(scn_pr ticket/T-sim-s/scn-a T-sim-s)"; approve "$PR_A"; pr_event "$PR_A"
scn_start ticket/T-sim-t1/scn-t1
scn_put sim/t1/hello.sh 'echo hello'
scn_commit T-sim-t1; pr="$(scn_pr ticket/T-sim-t1/scn-t1 T-sim-t1)"; approve "$pr"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.tier-jump "$(scn_detail tier-order "$h")" check_fails_naming tier-order "$h" "#$PR_A"

# ------------------------------------------------------------------ scenarios that merge
# Two tickets race for one file. A merges; B conflicts with the new main and is ejected: labeled
# autorebase, with an ejection record on main.
scn_start ticket/T-sim-q/scn-b
scn_put sim/s/conflict.txt 'b'
scn_commit T-sim-q; PR_B="$(scn_pr ticket/T-sim-q/scn-b T-sim-q)"; approve "$PR_B"; pr_event "$PR_B"
queue_and_merge "$PR_A"
judge S.queue-conflict "#$PR_B labels: $(pr_field "$PR_B" '[.labels[].name] | join(",")'); ejections.jsonl $(git -C "$ORIGIN" cat-file -e "$(main_sha):factory/ledger/ejections.jsonl" 2>/dev/null && echo present || echo absent)" \
  eval 'ghq -e --argjson n "$PR_B" "any(.pulls[] | select(.number == \$n) | .labels[]; .name == \"autorebase\")" >/dev/null &&
        git -C "$ORIGIN" cat-file -e "$(main_sha):factory/ledger/ejections.jsonl" 2>/dev/null'

# A T-sim-t1 PR whose second commit names T-sim-victim. Merged: post-merge completes T-sim-t1 only.
scn_start ticket/T-sim-t1/scn-foreign
scn_put sim/t1/foreign.sh 'echo one'; scn_commit T-sim-t1
scn_put sim/t1/foreign2.sh 'echo two'; scn_commit T-sim-victim
pr="$(scn_pr ticket/T-sim-t1/scn-foreign T-sim-t1)"; approve "$pr"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
# The ticket gates refuse it on the PR already (the merge below is the stand-in's, not a gate's).
judge S.foreign-trailer-refused "$(scn_detail context "$h"); $(scn_detail commit-check "$h")" \
  eval 'check_fails_naming context "$h" "trailer .Ticket: T-sim-victim" && check_fails_naming commit-check "$h" "trailer .Ticket: T-sim-victim"'
queue_and_merge "$pr"
judge S.foreign-trailer "T-sim-victim completed: $(adlc_desk ticket show T-sim-victim --json | jq -r .ticket.completed)" \
  test "$(adlc_desk ticket show T-sim-victim --json | jq -r .ticket.completed)" != true

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
# A collaborator adds factory/HALT: it must not wait on approvals or ticket gates.
scn_start human/halt-add
scn_put factory/HALT 'sim: stop the line'
git -C "$SCN" commit -qm "$(printf 'halt: stop the line\n\nSigned-off-by: sim-owner <sim-owner@sim.invalid>')"
pr="$(scn_pr human/halt-add - sim-owner)"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.class-halt-add "context: $(ctx_of pull_request "$h")" ctx_is pull_request "$h" '.class == "halt" and .author_association == "OWNER"'
miss="$(required_report "$(main_sha)" "$h")"
approvals="$(git -C "$ORIGIN" show "$(main_sha):factory/policy/branch-protection.json" |
  jq '[.rulesets[]?.rules[]? | select(.type == "pull_request") | .parameters.required_approving_review_count] | max // 0')"
judge S.halt-add "${miss:-every required check green}; $approvals approval(s) required" eval 'test -z "$miss" && test "$approvals" = 0'

# HALT is on main (the desk pushed it); a PR removing it with ONE approval: halt-guard fails.
desk_sync; printf 'sim: stop the line\n' >"$SIM/desk/factory/HALT"
desk_push "desk: factory/HALT"
scn_start human/halt-remove
git -C "$SCN" rm -q factory/HALT
git -C "$SCN" commit -qm "$(printf 'halt: resume\n\nSigned-off-by: sim-owner <sim-owner@sim.invalid>')"
pr="$(scn_pr human/halt-remove - sim-owner)"; approve "$pr"; pr_event "$pr"; h="$(pr_field "$pr" .headRefOid)"
judge S.class-halt-remove "context: $(ctx_of pull_request "$h")" ctx_is pull_request "$h" '.class == "halt"'
judge S.halt-remove "$(scn_detail halt-guard "$h")" check_fails_naming halt-guard "$h" 'approv'
