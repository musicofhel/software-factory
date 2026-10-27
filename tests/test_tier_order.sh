#!/usr/bin/env bash
# T27 (specs/factory-step3-v1 TB8): factory/bin/tier-order.sh, foundation first.
#   - a tier-n ticket PR waits (exit 2, naming #N) while an open, same-repo, approved, green ticket PR
#     of a lower tier exists; the ways a PR counts as approved (per reviewer, the latest decisive
#     review) and green (the latest gates.yml pull_request run on its head, every job of the BASE's
#     gates.yml but tier-order completed success/skipped/neutral, a re-run job's latest attempt);
#   - no wait on an unapproved, red, run-less, changes-requested, forked or completed lower-tier PR;
#     none within a tier, none on a higher tier, never for tier 0;
#   - --order: approved green open ticket PRs by tier, then first green (the latest completed_at of
#     the counted jobs), then PR number;
#   - the job list is the base's gates.yml (a head's own gates.yml does not count), and the script's
#     awk job parser equals `yq '.jobs | keys'` of the repo's gates.yml;
#   - the node call (--ticket --base, labeler.sh's re-run) answers as CI does;
#   - a ticket PR whose ticket has no tier (or is not open) is refused; desk and human PRs pass;
#   - an unreadable PR list, run list, job list, gates.yml or store is exit 1, never a pass.
# Offline; every repo is a temp dir, gh is the fake (pulls and Actions runs in FAKE_GH_ISSUES).
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
TO="$BIN/tier-order.sh"
EV="$REPO_ROOT/tests/fixtures/events"
WF="$REPO_ROOT/.github/workflows/gates.yml"
FREPO=Codertocat/Hello-World   # the repository of GitHub's example payloads

# The awk program of tier-order.sh's to_jobs, verbatim as awk sees it (bare or quoted keys);
# case_awk_job_list holds the script's single-quoted source of it ('"'"' for each ') to this text.
AWK_JOBS="$(command cat <<'EOF'
/^jobs:/ {in_j = 1; next} in_j && /^[^ #]/ {in_j = 0} in_j && /^  ["']?[A-Za-z0-9_-]+["']?:/ {sub(/^  ["']?/, ""); sub(/["']?:.*/, ""); print}
EOF
)"

hex() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }      # a stable 40-hex head sha for a name
at() { printf '2026-10-27T%s:00Z' "$1"; }                    # at 10:05 -> an ISO completed_at
st() { jq "$@" "$FAKE_GH_ISSUES" >"$WORLD/s" && mv "$WORLD/s" "$FAKE_GH_ISSUES"; }   # st [jq args] <program>

# ticket <id> <tier|-> [completed]: a store file .adlc/tickets/<slug>--<sha256>.json in R ("-": no
# tier header; its prose still says `tier: 0`, below the header's blank line, which never counts).
ticket() {
  local id="$1" body
  if [ "$2" = - ]; then body=$'weight: light\ncharter: C6\n\nprose\ntier: 0'
  else body="weight: light"$'\n'"tier: $2"$'\n'"charter: C6"$'\n\nprose'; fi
  jq -n --arg id "$id" --arg b "$body" --argjson c "${3:-false}" '{id: $id, completed: $c, body: $b, edges: []}' \
    >"$R/.adlc/tickets/t-$(tr 'A-Z' 'a-z' <<<"$id")--$(printf '%s' "$id" | sha256sum | cut -d' ' -f1).json"
}

# A repo with main (= origin/main = BASE): the real gates.yml and the store T0a, T0b (tier 0), T1,
# T1b (tier 1), T2 (tier 2), TN (no tier), TD (tier 0, completed). JOBS: the base's gates.yml job ids
# (by yq) but tier-order, the jobs a fake run carries.
setup() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export FAKE_GH_REPO="$FREPO" GITHUB_REPOSITORY="$FREPO" FACTORY_REPO="$FREPO"
  printf '{"labels":[],"issues":[],"pulls":[],"runs":[],"collaborators":["dev-box-owner"]}\n' >"$FAKE_GH_ISSUES"
  R="$WORLD/r"
  git init -q -b main "$R"
  git -C "$R" config user.name t; git -C "$R" config user.email t@t.invalid
  mkdir -p "$R/.adlc/tickets" "$R/.github/workflows"
  cp "$WF" "$R/.github/workflows/gates.yml"
  echo base >"$R/README.md"
  ticket T0a 0; ticket T0b 0; ticket T1 1; ticket T1b 1; ticket T2 2; ticket TN -; ticket TD 0 true
  git -C "$R" add -A; git -C "$R" commit -qm base
  BASE="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" update-ref refs/remotes/origin/main "$BASE"
  jobs_of_base
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH GH_TOKEN
}
jobs_of_base() { mapfile -t JOBS < <(git -C "$R" show "$BASE:.github/workflows/gates.yml" | yq -r '.jobs | keys | .[]' | grep -vx tier-order); }

# mine <ticket> [handle]: a commit (trailer Ticket: <id>) on ticket/<id>/<handle> from BASE; prints it.
mine() {
  git -C "$R" checkout -q -B "ticket/$1/${2:-dev-box}" "$BASE"
  mkdir -p "$R/sim"; echo "$1" >>"$R/sim/$1.txt"; git -C "$R" add -A
  git -C "$R" commit -qm "$(printf 'work\n\nTicket: %s' "$1")"
  git -C "$R" rev-parse HEAD
}
# pr_event <head-sha> <head-ref> <body> [assoc] [head-repo]: GitHub's example pull_request payload (PR
# #2), with only what this world decides rewritten (shas onto R, base ref main, head ref, body, author).
pr_event() {
  jq --arg b "$BASE" --arg h "$1" --arg r "$2" --arg body "$3" --arg a "${4:-OWNER}" --arg hr "${5:-$FREPO}" \
    '.pull_request.base.sha = $b | .pull_request.base.ref = "main" | .pull_request.head.sha = $h | .pull_request.head.ref = $r
     | .pull_request.body = $body | .pull_request.author_association = $a | .pull_request.head.repo.full_name = $hr' \
    "$EV/pull_request-opened.json" >"$WORLD/event.json"
  export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$WORLD/event.json"
}
# rv <login=STATE>...: a reviews array, oldest first (as gh answers it).
rv() { jq -cn '$ARGS.positional | map(split("=") | {author: {login: .[0]}, state: .[1]})' --args "$@"; }
APPROVED="$(rv rev1=APPROVED)"
# add_pr <n> <ticket> <head-sha> <reviews> [head-repo]: an open PR from ticket/<ticket>/node-<n>.
add_pr() {
  st --argjson n "$1" --arg r "ticket/$2/node-$1" --arg h "$3" --argjson rv "$4" --arg hr "${5:-}" \
    '.pulls += [{number: $n, headRefName: $r, headRefOid: $h, state: "OPEN", createdAt: "2026-10-20T00:00:00Z", reviews: $rv}
                + (if $hr == "" then {} else {headRepository: $hr} end)]'
}
job_json() {  # job_json <jobs> <id> <name> <conclusion|in_progress> <completed_at>
  jq -c --argjson id "$2" --arg n "$3" --arg c "$4" --arg t "$5" '. + [if $c == "in_progress"
    then {id: $id, name: $n, status: "in_progress", conclusion: null, started_at: "2026-10-27T07:00:00Z", completed_at: null}
    else {id: $id, name: $n, status: "completed", conclusion: $c, started_at: "2026-10-27T07:00:00Z", completed_at: $t} end]' <<<"$1"
}
# add_run <run id> <head-sha> <completed_at> [override...]: a gates run on the head with one job per
# id of JOBS, all success at <completed_at>. Overrides: job=<conclusion|in_progress>, -job (absent),
# job@<completed_at>, +job=<conclusion> (another attempt, a higher job id). RUN_EVENT / RUN_PATH
# override pull_request / .github/workflows/gates.yml.
add_run() {
  local id="$1" head="$2" t0="$3" j o c t k=0 jobs='[]'; shift 3
  for j in "${JOBS[@]}"; do
    c=success t="$t0"
    for o in "$@"; do
      case "$o" in "-$j") continue 2 ;; "$j="*) c="${o#*=}" ;; "$j@"*) t="${o#*@}" ;; esac
    done
    k=$((k + 1)); jobs="$(job_json "$jobs" $((id * 100 + k)) "$j" "$c" "$t")"
  done
  k=50
  for o in "$@"; do
    case "$o" in +*) k=$((k + 1)); j="${o#+}"; jobs="$(job_json "$jobs" $((id * 100 + k)) "${j%%=*}" "${j#*=}" "$t0")" ;; esac
  done
  st --argjson id "$id" --arg h "$head" --arg ev "${RUN_EVENT:-pull_request}" --arg p "${RUN_PATH:-.github/workflows/gates.yml}" \
    --argjson jobs "$jobs" \
    '.runs += [{id: $id, name: "gates", path: $p, event: $ev, head_sha: $h, head_branch: "x", created_at: "2026-10-27T07:00:00Z",
                run_attempt: 1, jobs: $jobs}]'
}
to() {  # to [flags]: run tier-order.sh in R; OUT (stdout), ERR (stderr), RC
  RC=0
  OUT="$(cd "$R" && "$TO" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
# verdict <name> <rc> <result> <blocking json>: exit code, .result and .blocking (as printed) of stdout.
verdict() {
  check "$1: exit $2, $3, blocking $4" eq "$RC:$(jq -c '[.result, .blocking]' <<<"$OUT" 2>/dev/null || echo "[$OUT]")" "$2:[\"$3\",$4]"
}
reset_prs() { st '.pulls = [] | .runs = []'; }

case_waits() {
  setup
  local h a b; h="$(mine T1)"; a="$(hex a)"; b="$(hex b)"
  pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  add_pr 2 T1 "$h" "$APPROVED"; add_run 9 "$h" "$(at 09:00)"   # the PR itself, approved and green
  add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)"
  to
  check "tier 1 waits on an approved green tier-0 PR: exit 2, the JSON" \
    eq "$RC:$OUT" '2:{"ticket":"T1","tier":1,"pr":2,"blocking":[5],"result":"wait"}'
  check "  stderr names #5 and when it turned green" \
    grep -qF 'tier-order: WAIT: T1 (tier 1) waits on #5 (T0a, tier 0, approved, green since 2026-10-27T10:00:00Z)' <<<"$ERR"
  check "  only reads: pr list and the Actions API, never a write" \
    eq "$(fakegh_calls '.[0] == "pr" and .[1] == "list"'):$(fakegh_calls 'index("-X") != null or index("POST") != null')" 1:0
  check "  the PR's own runs are never read (it cannot block itself)" eq "$(fakegh_calls "any(.[]; contains(\"$h\"))")" 0

  # A tier-2 PR waits on every lower tier at once.
  st 'del(.pulls[] | select(.number == 2))'   # the event's PR number is #2: now T2's
  h="$(mine T2)"; pr_event "$h" ticket/T2/dev-box 'Ticket: T2'
  add_pr 6 T1b "$b" "$APPROVED"; add_run 2 "$b" "$(at 10:30)"
  to
  verdict "tier 2 waits on a tier-0 and a tier-1 PR (blocking by number; gh lists #6 first)" 2 wait '[5,6]'
  check "  WAIT lines for both" eq "$(grep -c '^tier-order: WAIT: T2 (tier 2) waits on #[56] ' <<<"$ERR")" 2

  # The ways a lower-tier PR is still approved and green.
  h="$(mine T1)"; pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  waits() {  # waits <name> <reviews> [run overrides...]
    local name="$1" r="$2"; shift 2
    reset_prs; add_pr 5 T0a "$a" "$r"; add_run 1 "$a" "$(at 10:00)" "$@"
    to; verdict "$name" 2 wait '[5]'
  }
  waits "changes requested, then the same reviewer approves" "$(rv rev1=CHANGES_REQUESTED rev1=APPROVED)"
  waits "approved, then the same reviewer only comments" "$(rv rev1=APPROVED rev1=COMMENTED)"
  waits "one reviewer's changes request dismissed, another approves" "$(rv rev1=CHANGES_REQUESTED rev1=DISMISSED rev2=APPROVED)"
  waits "two approvals" "$(rv rev1=APPROVED rev2=APPROVED)"
  waits "skipped and neutral jobs count as green" "$APPROVED" "${JOBS[0]}=skipped" "${JOBS[1]}=neutral"
  waits "a failed job re-run to success (the latest attempt counts)" "$APPROVED" "${JOBS[2]}=failure" "+${JOBS[2]}=success"
  waits "a job the base does not name may fail" "$APPROVED" "+lint-extra=failure"
  # The latest gates pull_request run: an older red run is superseded by a newer green one.
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 09:00)" "${JOBS[0]}=failure"; add_run 3 "$a" "$(at 10:00)"
  to; verdict "an older red run, a newer green one" 2 wait '[5]'
  check "  green since the newer run" grep -qF 'green since 2026-10-27T10:00:00Z' <<<"$ERR"
}

case_no_wait() {
  setup
  local h a; h="$(mine T1)"; a="$(hex a)"
  pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  passes() {  # passes <name> <stderr fixed string|''> <reviews> [head-repo] -- [run overrides...|none]
    local name="$1" why="$2" r="$3" hr=""; shift 3
    if [ "${1:-}" != -- ]; then hr="$1"; shift; fi
    shift
    reset_prs; add_pr 5 T0a "$a" "$r" "$hr"
    if [ "${1:-}" != none ]; then add_run 1 "$a" "$(at 10:00)" "$@"; fi
    to
    check "$name: exit 0, the pass JSON" eq "$RC:$OUT" '0:{"ticket":"T1","tier":1,"pr":2,"blocking":[],"result":"pass"}'
    [ -z "$why" ] || check "  stderr: $why" grep -qF -- "$why" <<<"$ERR"
  }
  passes "no review" "" '[]' --
  passes "only a comment" "" "$(rv rev1=COMMENTED)" --
  passes "a pending review" "" "$(rv rev1=PENDING)" --
  passes "red: one job failed" "not waiting on #5 (T0a, tier 0, approved): not green (${JOBS[1]}=failure)" "$APPROVED" -- "${JOBS[1]}=failure"
  passes "red: one job cancelled" "not green (${JOBS[0]}=cancelled)" "$APPROVED" -- "${JOBS[0]}=cancelled"
  passes "red: one job still running" "not green (${JOBS[3]}=in_progress)" "$APPROVED" -- "${JOBS[3]}=in_progress"
  passes "red: the latest attempt of a re-run job failed" "not green (${JOBS[2]}=failure)" "$APPROVED" -- "+${JOBS[2]}=failure"
  passes "no run at all" "not green (${JOBS[0]}=absent, ${JOBS[1]}=absent" "$APPROVED" -- none
  passes "approved, then the same reviewer requests changes" "" "$(rv rev1=APPROVED rev1=CHANGES_REQUESTED)" --
  passes "a standing changes request is not outvoted by another approval" "" \
    "$(rv rev1=APPROVED rev1=CHANGES_REQUESTED rev2=APPROVED)" --
  passes "changes requested after another's approval" "" "$(rv rev2=APPROVED rev1=CHANGES_REQUESTED)" --
  passes "an approval dismissed" "" "$(rv rev1=APPROVED rev1=DISMISSED)" --
  passes "a fork (headRepository another repo's)" "" "$APPROVED" stranger/Hello-World --
  # A run the API answers with no jobs: every job absent.
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"
  st --arg h "$a" '.runs += [{id: 1, name: "gates", path: ".github/workflows/gates.yml", event: "pull_request", head_sha: $h,
                              head_branch: "x", created_at: "2026-10-27T07:00:00Z", run_attempt: 1}]'
  to; verdict "a run with no jobs" 0 pass '[]'
  check "  every job absent" grep -qF "not green (${JOBS[0]}=absent" <<<"$ERR"

  # Only the latest gates.yml pull_request run counts.
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 09:00)"; add_run 3 "$a" "$(at 10:00)" "${JOBS[0]}=failure"
  to; verdict "an older green run, a newer red one" 0 pass '[]'
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"; RUN_EVENT=merge_group add_run 1 "$a" "$(at 10:00)"
  to; verdict "green only on merge_group, no pull_request run" 0 pass '[]'
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"; RUN_PATH=.github/workflows/other.yml add_run 1 "$a" "$(at 10:00)"
  to; verdict "green only in another workflow" 0 pass '[]'
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$(hex other)" "$(at 10:00)"
  to; verdict "a green run on another head" 0 pass '[]'
  # Not a lower-tier ticket PR at all.
  reset_prs; add_pr 5 TD "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)"
  to; verdict "a completed tier-0 ticket's PR" 0 pass '[]'
  reset_prs; add_pr 5 TN "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)"
  to; verdict "a PR of a ticket with no tier" 0 pass '[]'
  reset_prs; st --arg h "$a" --argjson rv "$APPROVED" \
    '.pulls += [{number: 5, headRefName: "desk/T0a", headRefOid: $h, state: "OPEN", createdAt: "2026-10-20T00:00:00Z", reviews: $rv}]'
  add_run 1 "$a" "$(at 10:00)"
  to; verdict "a non-ticket branch" 0 pass '[]'
  reset_prs; st --arg h "$a" --argjson rv "$APPROVED" \
    '.pulls += [{number: 5, headRefName: "ticket/T0a/node-5", headRefOid: $h, state: "MERGED", createdAt: "2026-10-20T00:00:00Z", reviews: $rv}]'
  add_run 1 "$a" "$(at 10:00)"
  to; verdict "a merged (not open) tier-0 PR" 0 pass '[]'
}

case_same_tier() {
  setup
  local h a b c; a="$(hex a)"; b="$(hex b)"; c="$(hex c)"
  h="$(mine T1)"; pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  add_pr 6 T1b "$b" "$APPROVED"; add_run 2 "$b" "$(at 09:00)"
  add_pr 7 T2 "$c" "$APPROVED"; add_run 3 "$c" "$(at 09:00)"
  to
  check "tier 1 beside an approved green tier-1 and tier-2 PR: pass" \
    eq "$RC:$OUT" '0:{"ticket":"T1","tier":1,"pr":2,"blocking":[],"result":"pass"}'
  check "  no Actions read for PRs that cannot block" eq "$(fakegh_calls '.[0] == "api"')" 0
  add_pr 8 T1 "$(hex d)" "$APPROVED"; add_run 4 "$(hex d)" "$(at 08:00)"
  to; verdict "another approved green PR of the same ticket (another handle)" 0 pass '[]'
  h="$(mine T0a)"; pr_event "$h" ticket/T0a/dev-box 'Ticket: T0a'
  add_pr 5 T0b "$a" "$APPROVED"; add_run 1 "$a" "$(at 08:00)"
  to
  check "tier 0 never waits (approved green tier-0, 1 and 2 PRs open)" \
    eq "$RC:$OUT" '0:{"ticket":"T0a","tier":0,"pr":2,"blocking":[],"result":"pass"}'
}

case_order() {
  setup
  # Inserted out of number order (gh lists newest first); first green and tier decide, not the list.
  local p
  for p in 14:T1b 9:T2 12:T0b 11:T0a 13:T1 16:T2 17:T1 18:T0a 19:TD; do add_pr "${p%%:*}" "${p#*:}" "$(hex "pr${p%%:*}")" "$APPROVED"; done
  st '(.pulls[] | select(.number == 16)).reviews = []'              # unapproved
  st '(.pulls[] | select(.number == 18)).headRepository = "stranger/Hello-World"'   # a fork
  add_pr 20 T0b "$(hex pr20)" "$(rv rev1=APPROVED rev2=CHANGES_REQUESTED)"
  add_pr 21 TN "$(hex pr21)" "$APPROVED"
  add_run 1 "$(hex pr11)" "$(at 10:01)" "${JOBS[1]}@$(at 10:09)"   # T0a: first green 10:09 (its last job)
  add_run 2 "$(hex pr12)" "$(at 10:05)"                           # T0b: 10:05, before #11 despite its number
  add_run 3 "$(hex pr13)" "$(at 09:00)"                           # T1: 09:00, ties #14: by number
  add_run 4 "$(hex pr14)" "$(at 09:00)"
  add_run 5 "$(hex pr9)" "$(at 08:00)"                            # T2: earliest green, last tier
  add_run 6 "$(hex pr16)" "$(at 07:00)"                           # unapproved
  add_run 7 "$(hex pr17)" "$(at 07:00)" "${JOBS[0]}=failure"      # red
  add_run 8 "$(hex pr18)" "$(at 07:00)"                           # fork
  add_run 10 "$(hex pr19)" "$(at 07:00)"                          # completed ticket
  add_run 11 "$(hex pr20)" "$(at 07:00)"                          # changes requested
  add_run 12 "$(hex pr21)" "$(at 07:00)"                          # no tier
  to --order --base "$BASE"
  check "--order: exit 0" eq "$RC" 0
  check "--order: by tier, then first green, then number; unapproved, red, fork, completed, no-tier out" \
    eq "$(jq -r '[.position, .pr, .ticket, .tier, .first_green] | join(" ")' <<<"$OUT")" \
       "1 12 T0b 0 $(at 10:05)
2 11 T0a 0 $(at 10:09)
3 13 T1 1 $(at 09:00)
4 14 T1b 1 $(at 09:00)
5 9 T2 2 $(at 08:00)"
  check "--order: every line approved and green, with its head and run" \
    eq "$(jq -s -c 'map(.approved and .green and (.head | test("^[0-9a-f]{40}$")) and (.run | type == "number")) | unique' <<<"$OUT")" '[true]'
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  to --order
  check "--order without --base: the checkout's HEAD, the same order" eq "$(jq -r .pr <<<"$OUT" | tr '\n' ' ')" "12 11 13 14 9 "
  pr_event "$(git -C "$R" rev-parse HEAD)" ticket/T1/dev-box 'Ticket: T1'
  to --order --base "$BASE"
  check "--order ignores a runner's event" eq "$RC:$(jq -r .pr <<<"$OUT" | tr '\n' ' ')" "0:12 11 13 14 9 "
  to --order --ticket T1
  check "--order takes only --base and --repo (exit 1)" eq "$RC:$OUT" 1:
  to --order --base "$(hex nowhere)"
  check "--order with a base that is not a commit here: exit 1" eq "$RC:$OUT" 1:
  reset_prs
  to --order --base "$BASE"
  check "--order with no ticket PR: exit 0, no line" eq "$RC:$OUT" 0:
}

case_base_job_list() {
  setup
  local a h base1="$BASE"; a="$(hex a)"
  # The base gains two jobs: `extra`, and `tier-order` (never required: two PRs would wait on each other).
  git -C "$R" checkout -q main
  printf '  extra:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n  tier-order:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' \
    >>"$R/.github/workflows/gates.yml"
  git -C "$R" commit -qam "gates: extra, tier-order"
  BASE="$(git -C "$R" rev-parse HEAD)"; git -C "$R" update-ref refs/remotes/origin/main "$BASE"
  jobs_of_base
  check "the base's gates.yml now names extra and tier-order" \
    eq "$(git -C "$R" show "$BASE:.github/workflows/gates.yml" | yq -r '.jobs | keys | .[-2:] | join(" ")')" "extra tier-order"
  h="$(mine T1)"; pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  add_pr 5 T0a "$a" "$APPROVED"
  add_run 1 "$a" "$(at 10:00)" -extra
  to
  verdict "a run without the base's job extra: not green" 0 pass '[]'
  check "  naming extra=absent" grep -qF 'not green (extra=absent)' <<<"$ERR"
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)" "+tier-order=failure"
  to; verdict "every base job green, its own tier-order job failed: green" 2 wait '[5]'
  # The head's own gates.yml is data: adding a job there, or removing extra, changes nothing.
  git -C "$R" checkout -q -B ticket/T1/dev-box "$BASE"
  printf '  head-only:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' >>"$R/.github/workflows/gates.yml"
  git -C "$R" commit -qam "$(printf 'gates: head-only\n\nTicket: T1')"
  h="$(git -C "$R" rev-parse HEAD)"; pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  to; verdict "a head adding a job to its own gates.yml: the base's list, still waits" 2 wait '[5]'
  git -C "$R" checkout -q -B ticket/T1/dev-box "$BASE"
  yq -i 'del(.jobs.extra)' "$R/.github/workflows/gates.yml"
  git -C "$R" commit -qam "$(printf 'gates: drop extra\n\nTicket: T1')"
  h="$(git -C "$R" rev-parse HEAD)"; pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)" -extra
  to; verdict "a head dropping extra from its gates.yml: a run without extra is still not green" 0 pass '[]'
  check "  naming extra=absent" grep -qF 'not green (extra=absent)' <<<"$ERR"
  # The old base (no extra): origin/main descends from it, so main's list (with extra) judges.
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)" -extra
  to --order --base "$base1"
  check "--order at the old base, origin/main descending: main's list, the run is not green" eq "$RC:$OUT" 0:
  to --order --base "$BASE"
  check "--order at the new base: not green" eq "$RC:$OUT" 0:
  git -C "$R" update-ref refs/remotes/origin/main "$base1"
  to --order --base "$base1"
  check "--order at the old base with origin/main there: its list (no extra), green" eq "$RC:$(jq -r .pr <<<"$OUT")" 0:5
}

# Tiers and the job list come from one commit: gc_store_sha (origin/main when it descends from the
# base, else the base), never a mix of the base's and main's.
case_one_commit() {
  setup
  local h a b0 m1 m2 d; a="$(hex a)"; b0="$BASE"
  h="$(mine T1)"; pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)"            # green on the base's jobs, no extra
  to; verdict "origin/main = the base: wait on #5" 2 wait '[5]'
  # M1: main gains the job extra.
  git -C "$R" checkout -q main
  printf '  extra:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' >>"$R/.github/workflows/gates.yml"
  git -C "$R" commit -qam "gates: extra"; m1="$(git -C "$R" rev-parse HEAD)"
  # M2: then T0a moves to tier 1.
  ticket T0a 1; git -C "$R" commit -qam "desk: T0a tier 1"; m2="$(git -C "$R" rev-parse HEAD)"
  # D: main's tree at M2 (extra, T0a tier 1) on a commit that does not descend from the base.
  d="$(git -C "$R" commit-tree "$m2^{tree}" -m "unrelated history")"
  git -C "$R" checkout -q ticket/T1/dev-box
  git -C "$R" update-ref refs/remotes/origin/main "$m1"
  to; verdict "origin/main = M1 (adds extra): main's job list, the run without extra is not green" 0 pass '[]'
  check "  naming extra=absent" grep -qF 'not green (extra=absent)' <<<"$ERR"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  to --ticket T1 --base "$b0"; verdict "  the node call (labeler.sh's) too" 0 pass '[]'
  to --order --base "$b0"; check "  --order too: #5 out" eq "$RC:$OUT" 0:
  pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)" "+extra=success"
  to; verdict "origin/main = M1, the run has extra: wait (M1's tiers: T0a tier 0)" 2 wait '[5]'
  git -C "$R" update-ref refs/remotes/origin/main "$m2"
  to; verdict "origin/main = M2 (T0a tier 1): main's tiers, no wait" 0 pass '[]'
  git -C "$R" update-ref refs/remotes/origin/main "$d"
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)"
  to; verdict "origin/main not descending from the base (extra, T0a tier 1 there): the base's jobs and tiers, wait" 2 wait '[5]'
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  to --ticket T1 --base "$b0"; verdict "  the node call too" 2 wait '[5]'
  to --order --base "$b0"
  check "  --order: #5 green on the base's list, tier 0 from the base" eq "$RC:$(jq -r '"\(.pr) \(.tier)"' <<<"$OUT")" "0:5 0"
}

case_awk_job_list() {
  check "tier-order.sh's to_jobs still holds this test's awk program" grep -qF "awk '${AWK_JOBS//\'/\'\"\'\"\'}'" "$TO"
  check "awk job ids == yq '.jobs | keys' of the repo's gates.yml (in order)" \
    eq "$(awk "$AWK_JOBS" "$WF")" "$(yq -r '.jobs | keys | .[]' "$WF")"
  check "  and there are jobs (not two empty lists)" test "$(awk "$AWK_JOBS" "$WF" | wc -l)" -ge 5
  # A top-level key after jobs, a column-0 comment and a blank line inside jobs, a flow-mapping job.
  local y; y="$(mktemp)"
  printf '%s\n' 'name: x' 'env:' '  notajob: 1' 'jobs:' '  a:' '    runs-on: x' '    steps:' '      - run: "b: c"' \
    '# a comment at column 0' '  b-c_2:' '    needs: [a]' '' '  d: {runs-on: x}' 'on:' '  push: {}' >"$y"
  check "a synthetic gates.yml: awk == yq" eq "$(awk "$AWK_JOBS" "$y" | tr '\n' ' ')" "$(yq -r '.jobs | keys | .[]' "$y" | tr '\n' ' ')"
  check "  = a b-c_2 d" eq "$(awk "$AWK_JOBS" "$y" | tr '\n' ' ')" "a b-c_2 d "
  # Quoted job keys, double and single (legal YAML; yq unquotes them).
  printf '%s\n' 'jobs:' '  "dq-job":' '    runs-on: x' "  'sq_job':" '    runs-on: x' '  bare:' '    runs-on: x' >"$y"
  check "quoted keys: awk == yq" eq "$(awk "$AWK_JOBS" "$y" | tr '\n' ' ')" "$(yq -r '.jobs | keys | .[]' "$y" | tr '\n' ' ')"
  check "  = dq-job sq_job bare" eq "$(awk "$AWK_JOBS" "$y" | tr '\n' ' ')" "dq-job sq_job bare "
  rm -f "$y"
}

case_help() {
  local out
  out="$("$TO" --help)"
  check "--help: the header, ending at the exit codes" eq "$(tail -n1 <<<"$out")" "# 1 operational error."
  check "  and no code" eq "$(grep -cvE '^#( |$)' <<<"$out" || true)" 0
  check "  from the first header line" grep -q '^# tier-order — foundation first' <<<"$out"
}

case_node_mode() {
  setup
  local h a ci node; a="$(hex a)"
  h="$(mine T1)"; pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)"
  to; ci="$RC:$(jq -c 'del(.pr)' <<<"$OUT")"
  check "CI: wait on #5" eq "$ci" '2:{"ticket":"T1","tier":1,"blocking":[5],"result":"wait"}'
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  to --ticket T1 --base "$BASE"
  node="$RC:$(jq -c 'del(.pr)' <<<"$OUT")"
  check "node (--ticket --base, on the PR's head): the same answer" eq "$node" "$ci"
  check "  with pr null" eq "$(jq -c .pr <<<"$OUT")" null
  git -C "$R" checkout -q main
  to --ticket T1 --base "$BASE"
  check "node from a checkout of main (labeler.sh's call): the same answer" eq "$RC:$(jq -c 'del(.pr)' <<<"$OUT")" "$ci"
  pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  to --ticket T1 --base "$BASE"
  check "node flags win over a runner's event: the same answer" eq "$RC:$(jq -c 'del(.pr)' <<<"$OUT")" "$ci"
  # Red now: both modes pass.
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)" "${JOBS[0]}=failure"
  git -C "$R" checkout -q ticket/T1/dev-box
  to; ci="$RC:$(jq -c 'del(.pr)' <<<"$OUT")"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  to --ticket T1 --base "$BASE"
  check "red #5: CI and node both pass" eq "$ci|$RC:$(jq -c 'del(.pr)' <<<"$OUT")" \
    '0:{"ticket":"T1","tier":1,"blocking":[],"result":"pass"}|0:{"ticket":"T1","tier":1,"blocking":[],"result":"pass"}'
  # main moves on and completes T0a: a re-run (same event, old base) reads main's store as it is now.
  reset_prs; add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)"
  git -C "$R" checkout -q main
  ticket T0a 0 true; git -C "$R" commit -qam "desk: T0a done"
  git -C "$R" update-ref refs/remotes/origin/main "$(git -C "$R" rev-parse HEAD)"
  git -C "$R" checkout -q ticket/T1/dev-box
  pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  to; ci="$RC:$(jq -c 'del(.pr)' <<<"$OUT")"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  to --ticket T1 --base "$BASE"
  check "T0a completed on origin/main (descending from the base): CI and node both pass" eq "$ci|$RC:$(jq -c 'del(.pr)' <<<"$OUT")" \
    '0:{"ticket":"T1","tier":1,"blocking":[],"result":"pass"}|0:{"ticket":"T1","tier":1,"blocking":[],"result":"pass"}'
}

case_refusals_and_classes() {
  setup
  local h a; a="$(hex a)"
  add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)"
  h="$(mine TN)"; pr_event "$h" ticket/TN/dev-box 'Ticket: TN'
  to
  check "a ticket with no 'tier:' header (prose 'tier: 0' below it): refused, exit 2, no JSON" eq "$RC:$OUT" 2:
  check "  saying so" grep -qF "ticket TN has no 'tier: <n>' header in the store at ${BASE:0:12}" <<<"$ERR"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  to --ticket TN --base "$BASE"
  check "  the node call too" eq "$RC:$OUT" 2:
  h="$(mine TX)"; pr_event "$h" ticket/TX/dev-box 'Ticket: TX'
  to
  check "a ticket absent from the store: refused" eq "$RC:$OUT" 2:
  check "  not open in the store" grep -qF 'ticket TX is not open in the store' <<<"$ERR"
  h="$(mine TD)"; pr_event "$h" ticket/TD/dev-box 'Ticket: TD'
  to
  check "a completed ticket: refused" eq "$RC:$OUT" 2:
  h="$(mine T1)"; pr_event "$h" ticket/T1/dev-box 'Ticket: T1' NONE stranger/Hello-World
  to
  check "a fork's ticket ref: refused by the gate context" eq "$RC:$OUT" 2:
  pr_event "$h" ticket/T1/dev-box 'Ticket: T2'
  to
  check "a body naming another ticket: refused by the gate context" eq "$RC:$OUT" 2:
  # Desk and human PRs have no tier: pass at once, no gh call.
  git -C "$R" checkout -q -B desk/x "$BASE"; echo '{}' >"$R/.adlc/tickets/notes.txt"; git -C "$R" add -A; git -C "$R" commit -qm desk
  : >"$FAKE_GH_LOG"
  pr_event "$(git -C "$R" rev-parse HEAD)" desk/x 'desk' COLLABORATOR
  to
  check "a desk PR: exit 0, no JSON" eq "$RC:$OUT" 0:
  check "  pass: class desk" grep -qF 'tier-order: pass: class desk: no ticket, no tier' <<<"$ERR"
  git -C "$R" checkout -q -B docs/x "$BASE"; echo doc >"$R/README.md"; git -C "$R" commit -qam docs
  pr_event "$(git -C "$R" rev-parse HEAD)" docs/x 'docs' OWNER
  to
  check "a human PR: exit 0, pass: class human" eq "$RC:$(grep -c 'pass: class human' <<<"$ERR")" 0:1
  check "  neither made a gh call" eq "$(wc -l <"$FAKE_GH_LOG" | tr -d ' ')" 0
  pr_event "$(git -C "$R" rev-parse HEAD)" docs/x 'docs' NONE stranger/Hello-World
  to
  check "a stranger's PR: refused" eq "$RC:$OUT" 2:
}

case_unreadable() {
  setup
  local h a; a="$(hex a)"
  h="$(mine T1)"; pr_event "$h" ticket/T1/dev-box 'Ticket: T1'
  add_pr 5 T0a "$a" "$APPROVED"; add_run 1 "$a" "$(at 10:00)"
  FAKE_GH_FAIL='actions/runs/[0-9]+/jobs' to
  check "the jobs of a lower-tier run unreadable: exit 1, no verdict" eq "$RC:$OUT" 1:
  check "  naming the run" grep -qF 'cannot read the jobs of run 1' <<<"$ERR"
  check "  no pass line" eq "$(grep -c 'pass' <<<"$ERR" || true)" 0
  FAKE_GH_FAIL='actions/runs\?head_sha' to
  check "the runs of a lower-tier head unreadable: exit 1" eq "$RC:$OUT" 1:
  check "  naming the head" grep -qF "cannot read the Actions runs of $a" <<<"$ERR"
  FAKE_GH_FAIL='^pr list' to
  check "the PR list unreadable: exit 1" eq "$RC:$OUT" 1:
  FAKE_GH_FAIL='actions/runs/[0-9]+/jobs' to --order --base "$BASE"
  check "--order with an unreadable run: exit 1, no partial order" eq "$RC:$OUT" 1:
  # Also on the node.
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  FAKE_GH_FAIL='actions/runs' to --ticket T1 --base "$BASE"
  check "node: an unreadable lower-tier run is exit 1" eq "$RC:$OUT" 1:
  # A base without gates.yml, and a store file that is not a ticket.
  git -C "$R" checkout -q -B nogates "$BASE"; git -C "$R" rm -q .github/workflows/gates.yml; git -C "$R" commit -qm "no gates"
  to --order --base nogates
  check "a base with no gates.yml: exit 1" eq "$RC:$OUT" 1:
  git -C "$R" checkout -q -B badstore "$BASE"
  echo 'not json' >"$R/.adlc/tickets/t-bad--$(printf bad | sha256sum | cut -d' ' -f1).json"
  git -C "$R" add -A; git -C "$R" commit -qm "bad ticket"
  to --order --base badstore
  check "a store file that is not a ticket: exit 1 (fail closed)" eq "$RC:$OUT" 1:
}

for c in waits no-wait same-tier order base-job-list one-commit awk-job-list help node-mode refusals-and-classes unreadable; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
