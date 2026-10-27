#!/usr/bin/env bash
# sim — the offline end-to-end pipeline simulation (`make sim`; specs/factory-step3-v1 TB1, ticket T20).
#
#   tests/sim/sim.sh [--adlc auto|real|fake] [--expected F] [--results F] [--keep DIR]
#
# Builds a scratch world (lib/world.sh: a bare origin seeded from this working tree, a desk clone,
# nodes dev-box and node-b, the stateful fake gh, runner shims), then walks the T-sim scenario: the
# desk writes T-sim-parent (tier 0) and T-sim-child (tier 1, depends on the parent); mirror; claim;
# build; node gates; push; PR; every workflow job on pull_request (lib/driver.sh plays GitHub
# Actions from the YAML); the hold; tier order; queue; merge_group; merge; post-merge; the Issue
# closes; the child repeats the path. Then the failure scenarios, each in the same world.
#
# Every stage checks the DESIRED behavior: `pass` means the pipeline did the right thing, `red` that
# it did not. A red stage is followed by a labeled stand-in (what a human or a later row does) so the
# later stages stay observable. Results: one `stage<TAB>pass|red<TAB>detail` line per stage, compared
# with tests/sim/EXPECTED.md by lib/compare.sh, in both directions (a stage going green before
# EXPECTED.md says so fails as much as a regression).
#
# --adlc auto (default) uses the real @adlc/cli 1.12.0 when the npx cache holds it (offline; it is
# never downloaded), else the fake's git-store mode; tests/test_sim.sh forces fake. Both reach the
# same EXPECTED.md. Exit 0 equal, 2 a stage differs, 1 a harness error. Never touches GitHub, the
# repo's own store, ~/.factory or the network.
set -euo pipefail
SIM_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIM_LIB="$SIM_ROOT/tests/sim/lib"
export SIM_LIB SIM_ROOT

ADLC_MODE=auto EXPECTED="$SIM_ROOT/tests/sim/EXPECTED.md" RESULTS="" KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --adlc) ADLC_MODE="$2"; shift ;;
    --expected) EXPECTED="$2"; shift ;;
    --results) RESULTS="$2"; shift ;;
    --keep) KEEP="$2"; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "sim: unknown argument $1" >&2; exit 1 ;;
  esac
  shift
done
die() { printf 'sim: %s\n' "$*" >&2; exit 1; }
for t in git jq yq; do command -v "$t" >/dev/null || die "$t is required"; done
[[ "$(yq --version 2>&1)" =~ version\ v?4\. ]] || die "yq must be mikefarah yq v4 (found: $(yq --version 2>&1))"
case "$ADLC_MODE" in
  auto) if command -v npx >/dev/null && [ "$(npm_config_offline=true npx -y @adlc/cli@1.12.0 --version 2>/dev/null)" = 1.12.0 ]
        then ADLC_MODE=real; else ADLC_MODE=fake; fi ;;
  real) [ "$(npm_config_offline=true npx -y @adlc/cli@1.12.0 --version 2>/dev/null)" = 1.12.0 ] ||
          die "--adlc real: @adlc/cli 1.12.0 is not in the npx cache" ;;
  fake) ;;
  *) die "--adlc must be auto, real or fake" ;;
esac

if [ -n "$KEEP" ]; then rm -rf "$KEEP"; mkdir -p "$KEEP"; SIM="$(cd "$KEEP" && pwd)"
else SIM="$(mktemp -d "${TMPDIR:-/tmp}/sim.XXXXXX")"; trap 'rm -rf "$SIM"' EXIT; fi
export SIM ORIGIN="$SIM/origin.git" REPO=sim-owner/factory
export SIM_VARS='{"JANITOR_DRY_RUN":"false"}' SIM_SECRETS='{}'
R="$SIM/results.tsv"; : >"$R"
LOG="$SIM/sim.log"; : >"$LOG"

# shellcheck source=tests/sim/lib/driver.sh
. "$SIM_LIB/driver.sh"
# shellcheck source=tests/sim/lib/world.sh
. "$SIM_LIB/world.sh"

say() { printf '%s\n' "$*" >>"$LOG"; }
stage() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$R"; say "stage $1: $2 ${3:-}"; }
judge() {  # judge <stage> <detail> <cmd...>: pass when the command (the desired behavior) holds
  local name="$1" detail="$2"; shift 2
  if "$@" >/dev/null; then stage "$name" pass "$detail"; else stage "$name" red "$detail"; fi
}
standin() { say "  stand-in: $*"; }

# ------------------------------------------------------------------ the world, read from the fake gh
ghq() { jq -r "$@" "$FAKE_GH_ISSUES"; }
main_sha() { git -C "$ORIGIN" rev-parse refs/heads/main; }
issue_of() { ghq --arg t "$1" '[.issues[] | select((.body // "") | test("(^|\n)Ticket: \($t)(\n|$)"))] | .[0].number // empty'; }
has_label() { ghq -e --argjson n "$1" --arg l "$2" 'any(.issues[] | select(.number == $n) | .labels[]; .name == $l)' >/dev/null; }
issue_state() { ghq --argjson n "$1" '.issues[] | select(.number == $n) | .state'; }
pr_of() { ghq --arg h "$1" '[.pulls[] | select(.headRefName == $h)] | last | .number // empty'; }
pr_field() { ghq --argjson n "$1" ".pulls[] | select(.number == \$n) | $2"; }
lock_of() { git -C "$ORIGIN" rev-parse -q --verify "refs/locks/issue-$1" 2>/dev/null || true; }
check_of() {  # check_of <name> <head-sha>: the latest conclusion of that check run on that sha, or empty
  ghq --arg n "$1" --arg h "$2" '[.checks[] | select(.name == $n and .head_sha == $h)] | last | .conclusion // empty'
}
job_log() {  # job_log <event> <head> <job>: the log file of the latest such job
  jq -r --arg e "$1" --arg h "$2" --arg j "$3" 'select(.event == $e and .head_sha == $h and .job == $j) | .log' "$SIM/jobs.jsonl" | tail -n1
}

# ------------------------------------------------------------------ the desk
adlc_desk() { local -a a; read -r -a a <<<"$ADLC"; (cd "$SIM/desk" && "${a[@]}" "$@"); }
desk_sync() { git -C "$SIM/desk" pull -q --ff-only origin main; }
push_event() {  # push_event <before> <after>: GitHub's push event on main, workflows from <after>
  jq -n --arg b "$1" --arg a "$2" '{ref: "refs/heads/main", before: $b, after: $a}' >"$SIM/ev-push.json"
  drive push "$SIM/ev-push.json" "$2"
}
desk_push() {  # desk_push <message>: commit what the desk changed, push main (a human push), run the workflows
  local before
  git -C "$SIM/desk" add -A
  git -C "$SIM/desk" commit -qm "$1"
  before="$(main_sha)"
  git -C "$SIM/desk" push -q origin HEAD:main
  push_event "$before" "$(main_sha)"
}
ticket_json() {  # ticket_json <id> <tier> <scope-dir> <edges-json>
  jq -n --arg id "$1" --arg tier "$2" --arg s "$3" --argjson e "$4" '
    {id: $id, title: "sim: \($id) adds \($s)/hello.sh",
     body: "weight: light\ntier: \($tier)\ncharter: C6\n\nAdd \($s)/hello.sh that prints hello. A make sim ticket.\n\nAcceptance criteria:\n1. \($s)/hello.sh exists. Verify: `test -f \($s)/hello.sh`.",
     category: "feature", duration: 1, scope: ["\($s)/**"], rails: ["factory/policy/**"], edges: $e}'
}
desk_ticket() {  # desk_ticket <id> <tier> <scope-dir> <edges-json>
  ticket_json "$@" >"$SIM/ticket-$1.json"
  adlc_desk ticket create --input "$SIM/ticket-$1.json" --write --allow-unsigned --json >>"$LOG" 2>&1 || die "adlc ticket create $1 failed"
}
records_standin() {  # what TB7's desk gates will write: spec-lint, coldstart, merge-forecast records
  local id h
  desk_sync
  for id in "$@"; do
    h="$(adlc_desk ticket show "$id" --json | jq -r .ticketHash)"
    adlc_desk gate-manifest record spec-lint --ticket "$id" --data '{"verified":true}' >>"$LOG" 2>&1
    adlc_desk gate-manifest record coldstart --ticket "$id" --data "$(jq -cn --arg h "$h" '{cache: {ticketHash: $h, gaps: []}}')" >>"$LOG" 2>&1
    adlc_desk gate-manifest record merge-forecast --ticket "$id" --data '{"verified":true,"certifiedWidth":1}' >>"$LOG" 2>&1
  done
  desk_push "desk: spec-lint, coldstart and merge-forecast records for $* (sim stand-in for TB7)"
}

# ------------------------------------------------------------------ a node
node_run() {  # node_run <handle> [VAR=value...]: one run.sh --once on the node; RUN_RC, RUN_LAST
  local h="$1"; shift
  RUN_RC=0
  ( node_env "$h"
    git fetch -q origin && git checkout -q -B main origin/main
    env "$@" ./factory/bin/run.sh --slot 1 --apply --json --once ) >"$SIM/run.out" 2>>"$SIM/nodes/$h/err" || RUN_RC=$?
  RUN_LAST="$(tail -n1 "$SIM/run.out")"
  say "  run.sh on $h: rc $RUN_RC $RUN_LAST"
}

# ------------------------------------------------------------------ GitHub's side
pr_event() {  # pr_event <n> [action]: build refs/pull/<n>/merge on current main, run pull_request
  local n="$1" base head merge
  base="$(main_sha)"; head="$(pr_field "$n" .headRefOid)"
  merge="$(pr_merge_ref "$n" "$base" "$head")"
  [ -n "$merge" ] || { say "  PR #$n conflicts with main: GitHub runs no pull_request workflow"; return 0; }
  # .pull_request is GitHub's pull-request object (the fake gh's GET pulls/<n>), as the event carries it.
  jq -n --argjson n "$n" --arg a "${2:-opened}" --arg hs "$head" --arg bs "$base" \
    --argjson p "$(FAKE_GH_LOG=/dev/null "$SIM_FAKES/gh" api "repos/$REPO/pulls/$n")" \
    '{action: $a, number: $n, pull_request: ($p | .head.sha = $hs | .base.sha = $bs)}' >"$SIM/ev-pr.json"
  drive pull_request "$SIM/ev-pr.json" "$merge"
}
required_report() {  # required_report <base-sha> <head-sha>: the required contexts of the base policy that
                     # lack a success (or skipped) check run on head; empty = every one reports green
  local ctx c
  git -C "$ORIGIN" show "$1:factory/policy/branch-protection.json" |
    jq -r '[(.rulesets // [])[].rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]
           + [(.protection.required_status_checks.contexts // [])[]] | unique | .[]' |
    while IFS= read -r ctx; do
      c="$(check_of "$ctx" "$2")"
      case "$c" in success|skipped) ;; *) printf '%s=%s ' "$ctx" "${c:-absent}" ;; esac
    done
}
queue_standin() {  # build gh-readonly-queue/main/pr-<n>-<base> as GitHub's queue does, run merge_group; prints the group sha
  local n="$1" base head tree sha ref
  base="$(main_sha)"; head="$(pr_field "$n" .headRefOid)"
  tree="$(git -C "$ORIGIN" merge-tree --write-tree "$base" "$head")" || return 1
  sha="$(printf 'Merge pull request #%s from %s\n\n%s\n' "$n" "$(pr_field "$n" .headRefName)" "$(pr_field "$n" .title)" |
         GIT_AUTHOR_NAME=GitHub GIT_AUTHOR_EMAIL=noreply@github.com GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com \
         git -C "$ORIGIN" commit-tree "$tree" -p "$base" -p "$head")"
  ref="refs/heads/gh-readonly-queue/main/pr-$n-$base"
  git -C "$ORIGIN" update-ref "$ref" "$sha"
  jq -n --arg s "$sha" --arg r "$ref" --arg b "$base" \
    '{action: "checks_requested", merge_group: {head_sha: $s, head_ref: $r, base_sha: $b, base_ref: "refs/heads/main"}}' >"$SIM/ev-mg.json"
  drive merge_group "$SIM/ev-mg.json" "$sha"
  printf '%s\n' "$sha"
}
merge_standin() {  # merge_standin <n> <commit>: main fast-forwards to <commit> (the queue's merge), PR merged, push workflows
  local before; before="$(main_sha)"
  git -C "$ORIGIN" update-ref refs/heads/main "$2" "$before"
  gh_state '(.pulls[] | select(.number == $n)).state = "MERGED" | .merged += [{pr: $n, sha: $s}]' --argjson n "$1" --arg s "$2"
  push_event "$before" "$2"
}
jobs_on() {  # jobs_on <event> <head>: every job the driver ran for that event and head, in run order
  jq -r --arg e "$1" --arg h "$2" 'select(.event == $e and .head_sha == $h) | .job' "$SIM/jobs.jsonl" | awk '!seen[$0]++'
}
ctx_of() {  # ctx_of <event> <head>: the JSON the `context` job printed (lib/gate-context.sh), or {}
  local log; log="$(job_log "$1" "$2" context)"
  { [ -n "$log" ] && grep -h '^{"event":' "$log" | tail -n1; } || echo '{}'
}
ctx_is() {  # ctx_is <event> <head> <jq condition on the context>
  ctx_of "$1" "$2" | jq -e "$3" >/dev/null
}
job_stages() {  # job_stages <prefix> <event> <head>: one stage per job run, pass = success
  local j c
  while IFS= read -r j; do
    [ -n "$j" ] || continue
    c="$(jq -r --arg e "$2" --arg h "$3" --arg j "$j" 'select(.event == $e and .head_sha == $h and .job == $j) | .conclusion' "$SIM/jobs.jsonl" | tail -n1)"
    if [ "$c" = success ]; then stage "$1.$j" pass "$c"; else stage "$1.$j" red "$c: $(grep -v '^##' "$(job_log "$2" "$3" "$j")" | tail -n1 | cut -c1-160)"; fi
  done < <(jobs_on "$2" "$3")
}

# ------------------------------------------------------------------ one ticket's path
walk() {  # walk <X> <ticket> <scope-dir> [skip-ready]
  local X="$1" id="$2" dir="$3" n pr head base group lock
  n="$(issue_of "$id")"
  [ -n "$n" ] || die "no Issue for $id"
  if [ -n "${4:-}" ]; then :
  elif has_label "$n" ready; then stage "$X.mirror-ready" pass "#$n ready"
  else
    stage "$X.mirror-ready" red "#$n: $(ghq --argjson n "$n" '.issues[] | select(.number == $n) | [.labels[].name] | join(",")')"
    standin "records for $id"; records_standin "$id"
    has_label "$n" ready || die "$id is not ready even with its records"
  fi

  # The node: claim, fleet, the node's gates, push, PR.
  node_run dev-box FAKE_FLEET_CHECK_CONFIG=1 FAKE_FLEET_FILE="$dir/hello.sh"
  judge "$X.claim" "claim comments by dev-box-owner on #$n" \
    ghq -e --argjson n "$n" 'any(.issues[] | select(.number == $n) | .comments[]; .author.login == "dev-box-owner")'
  if grep -q '"preflight"' <<<"$RUN_LAST"; then
    stage "$X.fleet-preflight" red "fleet refused: no fleet block in main's .adlc/config.json"
    standin "fleet without its config preflight (main's fleet block is TB5)"
    node_run dev-box FAKE_FLEET_CHECK_CONFIG=0 FAKE_FLEET_FILE="$dir/hello.sh"
  else stage "$X.fleet-preflight" pass ""; fi
  if [ "$(jq -r '.reason // .outcome // empty' <<<"$RUN_LAST")" = tamper ]; then stage "$X.node-tamper" red "$RUN_LAST"
  else stage "$X.node-tamper" pass "tamperguard ok"; fi
  # The node's diff gates on GATE_BASE...GATE_HEAD (run.sh on_success), from its ledger line.
  local nrun ngb ngh
  nrun="$(jq -r '.run_id // empty' <<<"$RUN_LAST")"; ngb="$(jq -r '.gate_base // empty' <<<"$RUN_LAST")"; ngh="$(jq -r '.gate_head // empty' <<<"$RUN_LAST")"
  judge "$X.node-rails" "rails_proof: $(jq -r '.rails_proof // "absent"' <<<"$RUN_LAST") on ${ngb:0:12}...${ngh:0:12}$(node_gate_err "$nrun" rails)" \
    jq -e '.rails_proof == "pass"' <<<"$RUN_LAST"
  judge "$X.node-scope" "scope_check: $(jq -r '.scope_check // "absent"' <<<"$RUN_LAST") on ${ngb:0:12}...${ngh:0:12}$(node_gate_err "$nrun" scope)" \
    jq -e '.scope_check == "pass"' <<<"$RUN_LAST"
  local ntg; ntg="$(tail -n1 "$SIM/nodes/dev-box/tg.log")"
  pr="$(pr_of "ticket/$id/dev-box")"
  [ -n "$pr" ] || die "no PR for $id after the node ran: $RUN_LAST"
  head="$(pr_field "$pr" .headRefOid)"; base="$(git -C "$ORIGIN" merge-base "$(main_sha)" "$head")"
  local commits; commits="$(git -C "$ORIGIN" rev-list "$base..$head" | wc -l | tr -d ' ')"
  judge "$X.commit-shape" "$commits commit(s) over the merge-base" one_trailered_commit "$base" "$head" "$id"
  stage "$X.pr-open" pass "PR #$pr"
  lock="$(lock_of "$n")"
  judge "$X.claim-released" "lock ${lock:+kept }${lock:-released}; Issue labels $(ghq --argjson n "$n" '.issues[] | select(.number == $n) | [.labels[].name] | join(",")')" \
    claim_handed_to_pr "$n"
  judge "$X.tier-label" "PR labels: $(pr_field "$pr" '[.labels[].name] | join(",")')" \
    ghq -e --argjson n "$pr" 'any(.pulls[] | select(.number == $n) | .labels[]; .name | startswith("tier:"))'

  # Every workflow job on pull_request; the gate context names this PR, its ticket and class.
  local pbase tgn; pbase="$(main_sha)"
  tgn="$(wc -l <"$FAKE_TAMPERGUARD_LOG" | tr -d ' ')"
  pr_event "$pr"
  job_stages "$X.pr" pull_request "$head"
  # I17: the node ran the same helper with the same argv as CI's three diff gates on this PR. The node
  # pushes exactly GATE_HEAD, so CI's head is that sha and CI's base (the PR's base, main now) is its
  # merge-base when main has not moved since; each gate's `diff-gates:` trace lines and tamperguard's
  # own argv must then be equal, line for line.
  judge "$X.i17-argv" "$(i17_detail "$nrun" "$ngb" "$ngh" "$pbase" "$head" "$ntg" "$tgn")" \
    i17_same "$nrun" "$ngb" "$ngh" "$pbase" "$head" "$ntg" "$tgn"
  judge "$X.pr.identity" "context: $(ctx_of pull_request "$head")" ctx_is pull_request "$head" \
    ".event == \"pull_request\" and .pr == $pr and .ticket == \"$id\" and .handle == \"dev-box\" and .class == \"ticket\"
     and .base == \"$pbase\" and .head == \"$head\""
  local miss; miss="$(required_report "$(main_sha)" "$head")"
  judge "$X.pr.required-checks" "${miss:-every required context reports green}" test -z "$miss"
  judge "$X.hold" "depends-on: $(check_of depends-on "$head")" test "$(check_of depends-on "$head")" = success
  judge "$X.tier-order" "tier-order: $(check_of tier-order "$head")" test "$(check_of tier-order "$head")" = success

  # The queue, merge_group, the merge.
  judge "$X.enqueue" "nothing enqueues a green PR" enqueued "$pr"
  standin "hand-enqueue #$pr: gh-readonly-queue/main/pr-$pr-<base>"
  pbase="$(main_sha)"
  group="$(queue_standin "$pr")"
  job_stages "$X.mg" merge_group "$group"
  # On merge_group the PR number comes from gh-readonly-queue/main/pr-<N>-<sha>, the ticket from PR N's head ref.
  judge "$X.mg.identity" "context: $(ctx_of merge_group "$group")" ctx_is merge_group "$group" \
    ".event == \"merge_group\" and .pr == $pr and .ticket == \"$id\" and .class == \"ticket\" and .base == \"$pbase\" and .head == \"$group\""
  miss="$(required_report "$(main_sha)" "$group")"
  judge "$X.mg.required-checks" "${miss:-every required context reports green}" test -z "$miss"
  stage "$X.merge" red "no queue merges it (no merge queue on a user-owned repo; no first-party queue)"
  standin "main fast-forwards to the merge group $group"
  merge_standin "$pr" "$group"
  desk_sync
  judge "$X.complete" "post-merge" test "$(adlc_desk ticket show "$id" --json | jq -r .ticket.completed)" = true
  judge "$X.issue-closed" "#$n $(issue_state "$n")" test "$(issue_state "$n")" = closed
  judge "$X.lock-released" "refs/locks/issue-$n ${lock:+still there}" test -z "$(lock_of "$n")"
}
node_gate_err() {  # node_gate_err <run-id> <rails|scope>: `; <last line>` of the gate's stderr on the node, or nothing
  local f="$SIM/nodes/dev-box/fh/run/logs/$1.$2.err"
  [ -n "$1" ] && [ -s "$f" ] || return 0
  printf '; %s' "$(grep -v '^diff-gates: ' "$f" | tail -n1 | cut -c1-120)"
}
node_trace() {  # node_trace <run-id> <gate>: the node's `diff-gates:` lines for rails-proof, scope or tamper
  local f
  case "$2" in rails-proof) f=rails ;; scope) f=scope ;; tamper) f=diff-gates ;; esac
  grep -h '^diff-gates: ' "$SIM/nodes/dev-box/fh/run/logs/$1.$f.err" 2>/dev/null || true
}
ci_trace() {  # ci_trace <head> <job>: the `diff-gates:` lines that job printed on pull_request
  local log; log="$(job_log pull_request "$1" "$2")"
  [ -n "$log" ] || return 0
  grep -h '^diff-gates: ' "$log" || true
}
ci_tg_argv() {  # ci_tg_argv <lines-before>: tamperguard's argv as CI called it since then (one JSON array per call)
  tail -n +"$(($1 + 1))" "$FAKE_TAMPERGUARD_LOG"
}
i17_same() {  # i17_same <run-id> <gate-base> <gate-head> <pr-base> <pr-head> <node tg argv> <ci tg lines before>
  local g n
  [ -n "$1" ] && [ "$2" = "$4" ] && [ "$3" = "$5" ] || return 1
  for g in rails-proof scope tamper; do
    n="$(node_trace "$1" "$g")"
    [ -n "$n" ] && [ "$n" = "$(ci_trace "$5" "$g")" ] || return 1
  done
  [ -n "$6" ] && [ "$6" = "$(ci_tg_argv "$7")" ] &&
    [ "$6" = "$(jq -cn --arg r "$4...$5" '["--range", $r, "--json"]')" ]
}
i17_detail() {
  local g d="" n c
  if [ "$2" != "$4" ] || [ "$3" != "$5" ]; then
    printf 'node gated %s...%s, CI %s...%s' "${2:0:12}" "${3:0:12}" "${4:0:12}" "${5:0:12}"; return
  fi
  for g in rails-proof scope tamper; do
    n="$(node_trace "$1" "$g" | wc -l | tr -d ' ')"; c="$(ci_trace "$5" "$g" | wc -l | tr -d ' ')"
    if [ "$(node_trace "$1" "$g")" = "$(ci_trace "$5" "$g")" ]; then d+="$g $n=$c; "; else d+="$g node $n != CI $c; "; fi
  done
  printf '%son %s...%s; tamperguard node %s, CI %s' "$d" "${4:0:12}" "${5:0:12}" "${6:-none}" "$(ci_tg_argv "$7" | tr '\n' ' ')"
}
one_trailered_commit() {  # <base> <head> <id>: exactly one commit, carrying the four trailers
  local c; c="$(git -C "$ORIGIN" rev-list "$1..$2")"
  [ "$(wc -l <<<"$c" | tr -d ' ')" = 1 ] || return 1
  [ "$(git -C "$ORIGIN" log -1 --format='%(trailers:key=Ticket,valueonly)' "$c" | sed '/^$/d')" = "$3" ] &&
    git -C "$ORIGIN" log -1 --format='%(trailers:key=Signed-off-by,valueonly)%(trailers:key=Assisted-by,valueonly)' "$c" | grep -q .
}
claim_handed_to_pr() { [ -z "$(lock_of "$1")" ] && has_label "$1" in-review && ! has_label "$1" ready; }
enqueued() {
  ghq -e --argjson n "$1" 'any(.queue[]?; .pr == $n)' >/dev/null ||
    git -C "$ORIGIN" for-each-ref --format=x "refs/heads/factory-queue/pr-$1" | grep -q x
}

# ================================================================== the walk
say "sim: adlc $ADLC_MODE, world $SIM"
world_build
node_build dev-box; node_build node-b
stage world.seed pass "origin $(main_sha | cut -c1-12), adlc $ADLC_MODE"

# The hourly janitor before the nodes branch exists on a fresh repo (Aaron's kit merge:G15).
NODES="$(git -C "$ORIGIN" rev-parse refs/heads/nodes)"
git -C "$ORIGIN" update-ref -d refs/heads/nodes
printf '{"schedule":"17 * * * *"}\n' >"$SIM/ev-sched.json"
drive schedule "$SIM/ev-sched.json" "$(main_sha)" .github/workflows/janitor.yml
judge janitor.no-nodes "janitor: $(check_of janitor "$(main_sha)")" test "$(check_of janitor "$(main_sha)")" = success
standin "the nodes branch exists (apply-branch-protection.sh --bootstrap, Aaron's kit)"
git -C "$ORIGIN" update-ref refs/heads/nodes "$NODES"

# The desk writes the two tickets: the child first (an edge target must exist), then the parent
# with the edge parent → child.
desk_sync
desk_ticket T-sim-child 1 sim/child '[]'
desk_ticket T-sim-parent 0 sim/parent '[{"to":"T-sim-child"}]'
stage desk.write pass "T-sim-parent (tier 0) → T-sim-child (tier 1)"
desk_push "desk: T-sim-parent and T-sim-child"
judge push.mirror "mirror on the desk push: $(check_of mirror "$(main_sha)")" test "$(check_of mirror "$(main_sha)")" = success

P_ISSUE="$(issue_of T-sim-parent)"
[ -n "$P_ISSUE" ] || die "the mirror opened no Issue for T-sim-parent"
if has_label "$P_ISSUE" ready; then stage P.mirror-ready pass "#$P_ISSUE ready"; else
  stage P.mirror-ready red "#$P_ISSUE needs-desk: $(ghq --argjson n "$P_ISSUE" '.issues[] | select(.number == $n) | .body' | grep -E '^- ' | tr '\n' ' ' | cut -c1-200)"
  standin "records for both tickets"; records_standin T-sim-parent T-sim-child
fi
C_ISSUE="$(issue_of T-sim-child)"
judge C.mirror-blocked "#$C_ISSUE labels $(ghq --argjson n "$C_ISSUE" '.issues[] | select(.number == $n) | [.labels[].name] | join(",")')" \
  eval 'has_label "$C_ISSUE" blocked && ! has_label "$C_ISSUE" needs-desk'
judge C.depends-link "$(ghq --argjson n "$C_ISSUE" '.issues[] | select(.number == $n) | .body' | grep -m1 '^Depends-on:' || echo 'no Depends-on line')" \
  eval "ghq --argjson n \"\$C_ISSUE\" '.issues[] | select(.number == \$n) | .body' | grep -qE '^Depends-on: T-sim-parent \\(#$P_ISSUE\\)$'"

walk P T-sim-parent sim/parent skip-ready

# The child: the mirror on post-merge's run should make it ready.
walk C T-sim-child sim/child

# ================================================================== failure scenarios
. "$SIM_LIB/scenarios.sh"

[ ! -s "$FAKE_GH_UNKNOWN" ] || { say "fake gh refused forms:"; command cat "$FAKE_GH_UNKNOWN" >>"$LOG"; }
judge gh.forms "$(wc -l <"$FAKE_GH_UNKNOWN" | tr -d ' ') refused gh form(s)" test ! -s "$FAKE_GH_UNKNOWN"

[ -z "$RESULTS" ] || command cp "$R" "$RESULTS"
rc=0
"$SIM_LIB/compare.sh" "$EXPECTED" "$R" || rc=$?
[ "$rc" = 0 ] || printf 'sim: world kept for reading only with --keep; log: %s\n' "${KEEP:+$SIM/sim.log}" >&2
exit "$rc"
