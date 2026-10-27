#!/usr/bin/env bash
# T27 (specs/factory-step3-v1 TB8; intake:I3, node:G8, merge:G5): factory/bin/labeler.sh, the trusted
# labeler and the re-evaluation of held PRs, run from a checkout of main against the fake gh.
#   - label: `tier:<n>` from main's store is added and every other `tier:` label removed on --apply;
#     the default dry run writes nothing (the fake's state is byte-identical, no write call);
#   - a missing repo label is created first, once, before the PR edit that adds it;
#   - body: the display block (`<!-- factory:display` .. `<!-- /factory:display -->`) is written once,
#     below the node's own lines (kept verbatim): Tier, one Depends-on line per parent with its state
#     on main, Prosecuting adapter, Assisted-by from the head commit's trailer; a second run reports
#     `body: "same"` and makes no edit; a parent completing on main rewrites the one block;
#   - the store is read from HEAD (main), never from a PR head: a head that changes its own ticket's
#     tier, or adds a ticket, changes nothing;
#   - skipped: a ticket completed on main, an unknown ticket, a ticket with no tier (a JSON line
#     each, no write); a fork, a non-ticket or malformed head ref, a closed PR (no line at all);
#   - re-run: a failed `depends-on` whose parent completed on main is re-run (POST
#     actions/jobs/<id>/rerun), dry run reports it but posts nothing; a passing `tier-order` is re-run
#     when an approved lower-tier PR turns green;
#   - no re-run when today's answer equals the job's conclusion; only the latest gates.yml
#     pull_request run counts; a job not completed or concluded neither success nor failure is left;
#   - Assisted-by is display-safe: HTML or markdown or an over-long value is "unrecognized", an
#     accepted value (a URL, `x @someone`) is shown in a code span, never a link or a mention; no
#     trailer is "none on the head commit", an unreadable head commit is "unknown (...)";
#   - a PR whose runs or jobs cannot be read: its line carries `error`, it is still labeled, nothing
#     of it is re-run, every other PR is handled, and the run exits 1 at the end;
#   - origin/main ahead of the checkout: the label, the block and the re-run all read origin/main's
#     store (what depends-check.sh and tier-order.sh read); a diverged origin/main is ignored;
#   - a script that refuses rather than answers (a duplicate-id store, a PR body naming another
#     ticket, a head commit not in the checkout) re-runs nothing and is warned, naming the PR;
#   - an unterminated `<!-- factory:display` line of the node's is kept with everything after it,
#     on every run; a CRLF-only body difference is `same`; a stale CRLF block becomes one LF block;
#   - an existing repo label in other case (`Tier:1`) is never re-created.
# Offline; every repo is a temp dir, gh is the fake.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"

MARK_A="<!-- factory:display: written by factory/bin/labeler.sh from main's store; for people, no gate reads it -->"
MARK_Z='<!-- /factory:display -->'
PROSE='Prosecuting adapter: not recorded by the node (prosecution is build order 4; SPEC-v0.2 Prosecution)'
WRITES='(.[0] == "pr" and .[1] == "edit") or (.[0] == "label" and .[1] == "create") or (.[0] == "api" and index("POST") != null)'

# setup: a fresh world; $R is a checkout of main holding the real gates.yml and an empty store; the
# fake state has no PRs and no runs.
setup() {
  fakegh_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  unset GITHUB_EVENT_NAME GITHUB_REPOSITORY GH_TOKEN
  st '. + {pulls: [], runs: []}'
  R="$WORLD/r"
  git init -q -b main "$R"
  git -C "$R" config user.name t; git -C "$R" config user.email t@t.invalid
  mkdir -p "$R/.github/workflows" "$R/.adlc/tickets"
  command cp "$REPO_ROOT/.github/workflows/gates.yml" "$R/.github/workflows/gates.yml"
  echo base >"$R/README.md"
  commit "main: base" >/dev/null
}
st() {  # st <jq program> [jq args...]: rewrite the fake's state (FAKE_GH_ISSUES)
  local tmp; tmp="$(mktemp)"
  jq "${@:2}" "$1" "$FAKE_GH_ISSUES" >"$tmp" && mv "$tmp" "$FAKE_GH_ISSUES"
}
# ticket <id> <tier|-> [edge-targets,csv] [completed]: (re)write the ticket's store file in $R's tree
# (`-`: no tier header).
ticket() {
  local slug="${1,,}" hdr json
  hdr=$'weight: light\n'; [ "$2" = - ] || hdr+="tier: $2"$'\n'
  json="$(jq -cn --arg id "$1" --arg b "${hdr}charter: C6"$'\n\n'"prose of $1" --arg e "${3:-}" --argjson c "${4:-false}" \
    '{id: $id, completed: $c, body: $b, edges: ($e | split(",") | map(select(. != "")) | map({to: .}))}')"
  rm -f "$R/.adlc/tickets/$slug--"*.json
  printf '%s\n' "$json" >"$R/.adlc/tickets/$slug--$(printf '%s\n' "$json" | sha256sum | cut -d' ' -f1).json"
}
commit() { git -C "$R" add -A; git -C "$R" commit -qm "$1"; git -C "$R" rev-parse HEAD; }
msg() {  # msg <ticket> [assisted-by|-]: a ticket commit message with run.sh's trailers (`-`: no Assisted-by)
  local m; m="$1: the work"$'\n\n'"Signed-off-by: dev <dev@t.invalid>"$'\n'
  [ "${2:-}" = - ] || m+="Assisted-by: ${2:-claude-code@2.1.0}"$'\n'
  printf '%sTicket: %s\nNode: dev-box' "$m" "$1"
}
# head_commit <branch> <message> [cmd...]: one commit on <branch> from main (cmd runs first, in the
# branch's tree), pushed to the fake origin; prints its sha. $R is back on main afterwards.
head_commit() {
  local b="$1" m="$2" sha; shift 2
  git -C "$R" checkout -q -b "$b" main
  [ $# = 0 ] || "$@"
  echo "$b" >>"$R/work.txt"
  git -C "$R" add -A; git -C "$R" commit -qm "$m"
  sha="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" push -q "$FAKE_GH_GIT" "$b" 2>/dev/null
  git -C "$R" checkout -q main
  printf '%s\n' "$sha"
}
# add_pr <n> <head-ref> <head-sha> [labels,csv] [body]: an open PR from this repo (the body defaults
# to the node's `Ticket: <id>` line and a summary).
add_pr() {
  local id="${2#ticket/}" b; id="${id%%/*}"
  b="Ticket: $id"$'\n\n'"The node's summary."
  [ $# -lt 5 ] || b="$5"
  st '.pulls += [{number: $n, headRefName: $h, headRefOid: $s, state: "OPEN", body: $b, reviews: [],
                  labels: ($l | split(",") | map(select(. != "")) | map({name: .})), createdAt: "2026-10-25T12:00:00Z"}]' \
    --argjson n "$1" --arg h "$2" --arg s "$3" --arg l "${4:-}" --arg b "$b"
}
set_pr() { st "(.pulls[] | select(.number == \$n)) |= ($2)" --argjson n "$1"; }   # set_pr <n> <jq update>
approve() { set_pr "$1" '.reviews = [{author: {login: "reviewer"}, state: "APPROVED"}]'; }
# add_run <run-id> <head-sha> <job=conclusion>...: a gates run on the head; RUN_PATH / RUN_EVENT override
# the workflow path and event; a conclusion `in_progress` is a job not completed. Job ids: run*100+i.
add_run() {
  local id="$1" sha="$2" jobs='[]' i=0 a; shift 2
  for a in "$@"; do
    i=$((i + 1))
    jobs="$(jq -c --arg n "${a%%=*}" --arg c "${a#*=}" --argjson id $((id * 100 + i)) --argjson i "$i" \
      '. + [{id: $id, name: $n, status: (if $c == "in_progress" then "in_progress" else "completed" end),
             conclusion: (if $c == "in_progress" then null else $c end), started_at: "2026-10-25T12:00:00Z",
             completed_at: (if $c == "in_progress" then null else "2026-10-25T12:\(10 + $i):00Z" end)}]' <<<"$jobs")"
  done
  st '.runs += [{id: $id, name: "gates", path: $p, event: $e, head_sha: $s, head_branch: "x", created_at: "2026-10-25T12:00:00Z",
                 run_attempt: 1, jobs: $j}]' \
    --argjson id "$id" --arg p "${RUN_PATH:-.github/workflows/gates.yml}" --arg e "${RUN_EVENT:-pull_request}" --arg s "$sha" --argjson j "$jobs"
}
job_id() { jq --argjson r "$1" --arg n "$2" '.runs[] | select(.id == $r) | .jobs[] | select(.name == $n) | .id' "$FAKE_GH_ISSUES"; }
# green_jobs: `<job>=success` for every job of main's gates.yml except tier-order (tier-order.sh's "green").
green_jobs() {
  sed -n '/^jobs:/,$p' "$R/.github/workflows/gates.yml" | sed -n 's/^  \([A-Za-z0-9_-]*\):.*/\1/p' |
    /usr/bin/grep -vx tier-order | sed 's/$/=success/'
}
lab() {  # lab [flags]: run the labeler in the checkout of main; RC, OUT (JSON lines), ERR
  RC=0
  OUT="$(cd "$R" && "$BIN/labeler.sh" "$@" 2>"$WORLD/err")" || RC=$?
  # shellcheck disable=SC2034  # ERR is read inside the eval strings passed to check
  ERR="$(command cat "$WORLD/err")"
}
line() { jq -c --argjson n "$1" "select(.pr == \$n) | $2" <<<"$OUT"; }   # line <pr> <jq>
nlines() { if [ -z "$OUT" ]; then echo 0; else jq -c "select($1)" <<<"$OUT" | wc -l | tr -d ' '; fi; }
labels() { jq -c --argjson n "$1" '.pulls[] | select(.number == $n) | [.labels[].name] | sort' "$FAKE_GH_ISSUES"; }
body() { jq -r --argjson n "$1" '.pulls[] | select(.number == $n) | .body' "$FAKE_GH_ISSUES"; }
writes() { fakegh_calls "$WRITES"; }
edits() { fakegh_calls '.[0] == "pr" and .[1] == "edit"'; }
reruns() { jq -c '.reruns // []' "$FAKE_GH_ISSUES"; }
blocks() { /usr/bin/grep -c '^<!-- factory:display' <<<"$1" || true; }
has() { [[ "$1" == *"$2"* ]] || { printf '      [%s] lacks [%s]\n' "$1" "$2"; return 1; }; }
lacks() { [[ "$1" != *"$2"* ]] || { printf '      [%s] has [%s]\n' "$1" "$2"; return 1; }; }

# ---------------------------------------------------------------------------------------------
case_labels_and_dry_run() {
  setup
  ticket T1 1; ticket T2 0; commit "store" >/dev/null
  local h1 h2 before
  h1="$(head_commit ticket/T1/dev-box "$(msg T1)")"; h2="$(head_commit ticket/T2/dev-box "$(msg T2)")"
  add_pr 1 ticket/T1/dev-box "$h1" "tier:0,in-review,tier:2"
  add_pr 2 ticket/T2/dev-box "$h2" "tier:0"
  before="$(sha256sum <"$FAKE_GH_ISSUES")"
  lab
  check "dry run: exit 0" eq "$RC" 0
  check "dry run: one line per ticket PR" eq "$(nlines true)" 2
  check "dry run: #1 adds tier:1 and removes every other tier: label (tier is a number)" \
    eq "$(line 1 '[.tier, .label, .applied]')" '[1,{"add":["tier:1"],"remove":["tier:0","tier:2"]},false]'
  check "dry run: #2 already right" eq "$(line 2 '.label')" '{"add":[],"remove":[]}'
  check "dry run: the body would change" eq "$(line 1 .body)" '"changed"'
  check "dry run: the fake's state is byte-identical" eq "$(sha256sum <"$FAKE_GH_ISSUES")" "$before"
  check "dry run: no write call (pr edit, label create, POST)" eq "$(writes)" 0
  lab --apply
  check "apply: exit 0" eq "$RC" 0
  check "apply: #1 labels are tier:1 and the rest untouched" eq "$(labels 1)" '["in-review","tier:1"]'
  check "apply: #2 keeps tier:0 alone" eq "$(labels 2)" '["tier:0"]'
  check "apply: lines say applied" eq "$(jq -sc 'map(.applied)' <<<"$OUT")" '[true,true]'
  check "apply: #1's edit adds and removes in one call" \
    eq "$(fakegh_calls '.[0:3] == ["pr","edit","1"] and index("--add-label") != null and (indices("--remove-label") | length) == 2')" 1
  check "apply: #2's edit never touches a label" \
    eq "$(fakegh_calls '.[0:3] == ["pr","edit","2"] and (index("--add-label") // index("--remove-label")) != null')" 0
  check "apply: no label created (tier:0 and tier:1 exist)" eq "$(fakegh_calls '.[0] == "label" and .[1] == "create"')" 0
  before="$(writes)"
  lab --apply
  check "second apply: nothing to add or remove" eq "$(jq -sc 'map(.label)' <<<"$OUT")" '[{"add":[],"remove":[]},{"add":[],"remove":[]}]'
  check "second apply: no write call" eq "$(writes)" "$before"
  # A label-only change: the edit carries no --body-file (the body is unchanged).
  set_pr 2 '.labels += [{name: "tier:1"}]'
  lab --apply
  check "label-only change: #2's edit removes tier:1 and sends no body" \
    eq "$(fakegh_calls '.[0:3] == ["pr","edit","2"] and index("--remove-label") != null and index("--body-file") == null')" 1
  check "label-only change: the line says body same" eq "$(line 2 '[.label.remove, .body]')" '[["tier:1"],"same"]'
}

case_label_created() {
  setup
  st '.labels = ["in-review"]'
  ticket T1 3; ticket T2 3; commit "store" >/dev/null
  add_pr 1 ticket/T1/dev-box "$(head_commit ticket/T1/dev-box "$(msg T1)")"
  add_pr 2 ticket/T2/dev-box "$(head_commit ticket/T2/dev-box "$(msg T2)")"
  lab
  check "dry run: no label created" eq "$(fakegh_calls '.[0] == "label" and .[1] == "create"')" 0
  check "dry run: the repo still lacks tier:3" eq "$(jq -c '.labels' "$FAKE_GH_ISSUES")" '["in-review"]'
  lab --apply
  check "apply: exit 0" eq "$RC" 0
  check "apply: tier:3 created once for both PRs" eq "$(fakegh_calls '.[0:3] == ["label","create","tier:3"]')" 1
  check "apply: the repo label exists" eq "$(jq -c '.labels' "$FAKE_GH_ISSUES")" '["in-review","tier:3"]'
  check "apply: the label is created before any pr edit" \
    eq "$(jq -sc 'to_entries | [(map(select(.value[0:2] == ["label","create"])) | first.key),
                                (map(select(.value[0:2] == ["pr","edit"])) | first.key)] | .[0] < .[1]' "$FAKE_GH_LOG")" true
  check "apply: both PRs carry tier:3" eq "$(labels 1)$(labels 2)" '["tier:3"]["tier:3"]'
}

case_body_block() {
  setup
  ticket T1 0 T2 true; ticket T2 1; ticket T3 0 T2; ticket T4 2; commit "store" >/dev/null
  local own want block n
  own=$'Ticket: T2\n\nThe node\'s summary, *as written*.\n\n  - an indented item\nDepends-on: T99 (the node\'s own line)'
  add_pr 1 ticket/T2/dev-box "$(head_commit ticket/T2/dev-box "$(msg T2 claude-code@2.1.0)")" "" "$own"$'\n'
  # #2 carries a stale block between its own lines.
  add_pr 2 ticket/T4/dev-box "$(head_commit ticket/T4/dev-box "$(msg T4)")" "" \
    $'Ticket: T4\n\n<!-- factory:display -->\nTier: 9\nAssisted-by: stale\n<!-- /factory:display -->\n\nafter the block'
  lab --apply
  check "first apply: exit 0" eq "$RC" 0
  check "first apply: body changed" eq "$(line 1 .body)" '"changed"'
  block="$MARK_A"$'\nTier: 1\nDepends-on: T1 (completed on main)\nDepends-on: T3 (open on main)\n'"$PROSE"$'\nAssisted-by: `claude-code@2.1.0`\n'"$MARK_Z"
  want="$own"$'\n\n'"$block"
  check "the node's lines verbatim, a blank line, then the block" eq "$(body 1)" "$want"
  check "exactly one block" eq "$(blocks "$(body 1)")" 1
  check "#2: the stale block replaced by one block at the end" eq "$(blocks "$(body 2)")$(body 2 | tail -n1)" "1$MARK_Z"
  check "#2: its own lines kept, the stale values gone" eval \
    '[[ "$(body 2)" == "Ticket: T4"$'"'"'\n'"'"'*"after the block"*"Tier: 2"* ]] && [[ "$(body 2)" != *"Tier: 9"* && "$(body 2)" != *stale* ]]'
  check "#2: no parents: Depends-on: none" has "$(body 2)" $'\nDepends-on: none\n'
  n="$(edits)"
  lab --apply
  check "second apply: body same for both" eq "$(jq -sc 'map(.body)' <<<"$OUT")" '["same","same"]'
  check "second apply: no further pr edit" eq "$(edits)" "$n"
  # A parent completes on main: the one block is rewritten, the node's lines stay.
  ticket T3 0 T2 true; commit "T3 completed" >/dev/null
  lab --apply
  check "after T3 completes: body changed" eq "$(line 1 .body)" '"changed"'
  check "after T3 completes: T3 is completed on main, still one block, own lines kept" eval \
    '[ "$(blocks "$(body 1)")" = 1 ] && [[ "$(body 1)" == "$own"$'"'"'\n\n'"'"'"$MARK_A"* ]] && [[ "$(body 1)" == *"Depends-on: T3 (completed on main)"* ]]'
  check "the body's Ticket: line is still the node's" eq "$(body 1 | sed -n 's/^Ticket: //p')" T2
}

case_store_from_head() {
  setup
  ticket T1 1; commit "store" >/dev/null
  # The PR head makes its own ticket tier 0, gives it an open parent T7, and adds T8: none of it counts.
  local h1 h2
  h1="$(head_commit ticket/T1/dev-box "$(msg T1)" eval 'ticket T1 0; ticket T7 0 T1; ticket T8 0')"
  h2="$(head_commit ticket/T8/dev-box "$(msg T8)" ticket T8 0)"
  add_pr 1 ticket/T1/dev-box "$h1" "tier:0"
  add_pr 2 ticket/T8/dev-box "$h2"
  add_run 10 "$h1" depends-on=success tier-order=success
  check "the head's store does say tier 0 (the fixture is real)" eval \
    '[ "$(git -C "$R" show "$h1:$(git -C "$R" ls-tree --name-only "$h1" .adlc/tickets/ | /usr/bin/grep /t1--)" | jq -r .body | sed -n "s/^tier: //p")" = 0 ]'
  lab --apply
  check "exit 0" eq "$RC" 0
  check "the label is main's tier:1, the head's tier:0 removed" eq "$(labels 1)" '["tier:1"]'
  check "the block says main's tier and no parent" eval '[[ "$(body 1)" == *$'"'"'\nTier: 1\nDepends-on: none\n'"'"'* ]]'
  check "no re-run: depends-on answers from main, where T1 has no parent" eq "$(reruns)" '[]'
  check "a ticket only on PR heads is unknown: skipped" eq "$(line 2 .skipped)" "\"not open with a tier in main's store\""
  check "and left untouched" eq "$(labels 2)" '[]'
}

case_skipped() {
  setup
  ticket T1 1; ticket T9 1 "" true; ticket T6 -; commit "store" >/dev/null
  local h main before
  h="$(head_commit ticket/T1/dev-box "$(msg T1)")"; main="$(git -C "$R" rev-parse main)"
  add_pr 1 ticket/T1/dev-box "$h"
  add_pr 2 ticket/T9/dev-box "$main"
  add_pr 3 ticket/TX/dev-box "$main"
  add_pr 4 ticket/T1/forker "$main"; set_pr 4 '.headRepository = "evil/repo"'
  add_pr 5 feature/readme "$main" "" "Ticket: T1"
  add_pr 6 ticket/T1/a/b "$main"
  add_pr 7 ticket/T6/dev-box "$main"
  add_pr 8 ticket/T1/old "$main"; set_pr 8 '.state = "CLOSED"'
  before="$(jq -c '[.pulls[] | select(.number != 1)]' "$FAKE_GH_ISSUES")"
  lab --apply
  check "exit 0" eq "$RC" 0
  check "lines: #1 labeled; #2, #3, #7 skipped; no line for the fork, the other refs, the closed PR" \
    eq "$(jq -sc 'sort_by(.pr) | map([.pr, (.skipped != null)])' <<<"$OUT")" '[[1,false],[2,true],[3,true],[7,true]]'
  check "completed on main: skipped" eq "$(line 2 '[.ticket, .skipped]')" "[\"T9\",\"not open with a tier in main's store\"]"
  check "unknown ticket: skipped" eq "$(line 3 .ticket)" '"TX"'
  check "no tier header: skipped" eq "$(line 7 .ticket)" '"T6"'
  check "each skip is warned on stderr" eq "$(/usr/bin/grep -c 'nothing to label' <<<"$ERR")" 3
  check "every other PR is untouched" eq "$(jq -c '[.pulls[] | select(.number != 1)]' "$FAKE_GH_ISSUES")" "$before"
  check "one pr edit, for #1" eq "$(edits)/$(fakegh_calls '.[0:3] == ["pr","edit","1"]')" 1/1
  check "the control PR is labeled" eq "$(labels 1)" '["tier:1"]'
  check "only #1's head is asked for runs and its commit" \
    eq "$(jq -c --arg h "$h" 'select(.[0] == "api" and (.[1] | test("actions/runs\\?|git/commits/")) and (.[1] | contains($h) | not))' "$FAKE_GH_LOG" | wc -l | tr -d ' ')" 0
}

case_rerun_depends_on() {
  setup
  ticket T1 0 T2; ticket T2 1; commit "store" >/dev/null
  local h jid
  h="$(head_commit ticket/T2/dev-box "$(msg T2)")"
  add_pr 1 ticket/T2/dev-box "$h"
  add_run 30 "$h" context=success depends-on=failure tier-order=success
  jid="$(job_id 30 depends-on)"
  lab --apply
  check "parent still open: no re-run" eq "$(line 1 .reruns)$(reruns)" '[][]'
  ticket T1 0 T2 true; commit "T1 completed" >/dev/null
  lab
  check "dry run: the re-run is reported" eq "$(line 1 .reruns)" '[{"job":"depends-on","was":"failure","now":"success"}]'
  check "dry run: nothing posted" eq "$(reruns)/$(fakegh_calls '.[0] == "api" and index("POST") != null')" '[]/0'
  lab --apply
  check "apply: exit 0" eq "$RC" 0
  check "apply: JSON reruns" eq "$(line 1 .reruns)" '[{"job":"depends-on","was":"failure","now":"success"}]'
  check "apply: the depends-on job id is re-run, nothing else" eq "$(reruns)" "[$jid]"
  check "apply: one POST actions/jobs/<id>/rerun" \
    eq "$(fakegh_calls '.[0:4] == ["api","-X","POST","repos/test/repo/actions/jobs/'"$jid"'/rerun"]')/$(fakegh_calls 'index("POST") != null')" 1/1
}

case_rerun_tier_order() {
  setup
  ticket T0 0; ticket T1 1; commit "store" >/dev/null
  local h0 h1 jid
  h0="$(head_commit ticket/T0/dev-a "$(msg T0)")"; h1="$(head_commit ticket/T1/dev-b "$(msg T1)")"
  add_pr 1 ticket/T0/dev-a "$h0"; approve 1
  add_pr 2 ticket/T1/dev-b "$h1"
  mapfile -t green < <(green_jobs)
  check "the green set is gates.yml's jobs without tier-order" eval \
    '[ "${#green[@]}" -ge 5 ] && printf "%s\n" "${green[@]}" | /usr/bin/grep -qx depends-on=success && ! printf "%s\n" "${green[@]}" | /usr/bin/grep -q "^tier-order="'
  # The tier-0 PR is approved but not green yet (attest-verify failed); the tier-1 PR passed tier-order.
  add_run 10 "$h0" "${green[@]/attest-verify=success/attest-verify=failure}" tier-order=success
  add_run 20 "$h1" depends-on=success tier-order=success
  jid="$(job_id 20 tier-order)"
  lab --apply
  check "lower tier not green: no re-run" eq "$(jq -sc 'map(.reruns)' <<<"$OUT")$(reruns)" '[[],[]][]'
  # The tier-0 PR turns green in a newer run.
  add_run 11 "$h0" "${green[@]}" tier-order=success
  lab --apply
  check "apply: exit 0" eq "$RC" 0
  check "the tier-1 PR's passing tier-order is re-run" eq "$(line 2 .reruns)" '[{"job":"tier-order","was":"success","now":"failure"}]'
  check "the tier-0 PR has nothing to re-run" eq "$(line 1 .reruns)" '[]'
  check "the re-run job id is run 20's tier-order" eq "$(reruns)" "[$jid]"
}

case_no_rerun_when_unchanged() {
  setup
  ticket T1 1 T2; ticket T2 1; ticket T3 1; ticket T4 1; ticket T5 1; commit "store" >/dev/null
  local h2 h3 h4 h5
  h2="$(head_commit ticket/T2/dev-box "$(msg T2)")"; h3="$(head_commit ticket/T3/dev-box "$(msg T3)")"
  h4="$(head_commit ticket/T4/dev-box "$(msg T4)")"; h5="$(head_commit ticket/T5/dev-box "$(msg T5)")"
  add_pr 2 ticket/T2/dev-box "$h2"; add_pr 3 ticket/T3/dev-box "$h3"
  add_pr 4 ticket/T4/dev-box "$h4"; add_pr 5 ticket/T5/dev-box "$h5"
  # #2: held, and still held (T1 open); tier-order passed and still passes.
  add_run 20 "$h2" depends-on=failure tier-order=success
  # #3: an older run failed, the latest passed: only the latest counts.
  add_run 30 "$h3" depends-on=failure tier-order=failure
  add_run 31 "$h3" depends-on=success tier-order=success
  # #4: the gates run passed; a newer run of another workflow and a newer push run failed: not gates runs.
  add_run 40 "$h4" depends-on=success tier-order=success
  RUN_PATH=.github/workflows/other.yml add_run 41 "$h4" depends-on=failure tier-order=failure
  RUN_EVENT=push add_run 42 "$h4" depends-on=failure tier-order=failure
  # #5: depends-on still running, tier-order cancelled: neither is re-run.
  add_run 50 "$h5" depends-on=in_progress tier-order=cancelled
  lab --apply
  check "exit 0" eq "$RC" 0
  check "no line reports a re-run" eq "$(jq -sc 'sort_by(.pr) | map([.pr, .reruns])' <<<"$OUT")" '[[2,[]],[3,[]],[4,[]],[5,[]]]'
  check "nothing posted" eq "$(reruns)/$(fakegh_calls 'index("POST") != null')" '[]/0'
}

case_assisted_by() {
  setup
  ticket T1 1; ticket T2 1; ticket T3 1; ticket T4 1; ticket T5 1; ticket T6 1; ticket T7 1; ticket T8 1
  commit "store" >/dev/null
  local n b long
  long="$(printf 'a%.0s' {1..81})"
  add_pr 1 ticket/T1/dev-box "$(head_commit ticket/T1/dev-box "$(msg T1 '<img src=x onerror=alert(1)>')")"
  add_pr 2 ticket/T2/dev-box "$(head_commit ticket/T2/dev-box "$(msg T2 '[click](javascript:alert(1))')")"
  add_pr 3 ticket/T3/dev-box "$(head_commit ticket/T3/dev-box "$(msg T3 -)")"
  add_pr 4 ticket/T4/dev-box "$(head_commit ticket/T4/dev-box "$(msg T4 claude-code@2.1.0)")"
  add_pr 5 ticket/T5/dev-box 1111111111111111111111111111111111111111
  add_pr 6 ticket/T6/dev-box "$(head_commit ticket/T6/dev-box "$(msg T6 "$long")")"
  add_pr 7 ticket/T7/dev-box "$(head_commit ticket/T7/dev-box "$(msg T7 https://evil.example/x)")"
  add_pr 8 ticket/T8/dev-box "$(head_commit ticket/T8/dev-box "$(msg T8 'x @octocat')")"
  check "the HTML trailer is a real trailer of the head commit (the fixture is real)" eval \
    '[ "$(git -C "$R" log -1 --format="%(trailers:key=Assisted-by,valueonly)" ticket/T1/dev-box | head -n1)" = "<img src=x onerror=alert(1)>" ]'
  lab --apply
  check "exit 0" eq "$RC" 0
  ab() { body "$1" | sed -n 's/^Assisted-by: //p'; }
  check "HTML: unrecognized" eq "$(ab 1)" unrecognized
  check "markdown link: unrecognized" eq "$(ab 2)" unrecognized
  check "no trailer: none on the head commit" eq "$(ab 3)" "none on the head commit"
  check "a plain adapter@version: shown in a code span" eq "$(ab 4)" '`claude-code@2.1.0`'
  check "an unreadable head commit: unknown" eq "$(ab 5)" "unknown (the head commit could not be read)"
  check "81 characters: unrecognized" eq "$(ab 6)" unrecognized
  check "a URL: in a code span, never a link" eq "$(ab 7)" '`https://evil.example/x`'
  check "a mention: in a code span, never a ping" eq "$(ab 8)" '`x @octocat`'
  for n in 1 2 3 4 5 6; do b+="$(body "$n")"; done
  check "no body carries the raw HTML or the link" eval 'lacks "$b" "<img" && lacks "$b" "javascript:"'
}

case_runs_unreadable() {
  setup
  ticket T1 0 T2,T3 true; ticket T2 1; ticket T3 1; commit "store" >/dev/null
  local h2 h3 j3
  h2="$(head_commit ticket/T2/dev-box "$(msg T2)")"; h3="$(head_commit ticket/T3/dev-box "$(msg T3)")"
  add_pr 2 ticket/T2/dev-box "$h2" "tier:0"; add_pr 3 ticket/T3/dev-box "$h3" "tier:0"
  set_pr 2 '.createdAt = "2026-10-25T13:00:00Z"'   # #2 is listed (and handled) first
  # Both are held on a parent completed on main: each would be re-run if its runs could be read.
  add_run 20 "$h2" depends-on=failure; add_run 30 "$h3" depends-on=failure
  j3="$(job_id 30 depends-on)"
  FAKE_GH_FAIL="head_sha=$h2" lab --apply
  check "runs unreadable: exit 1 at the end" eq "$RC" 1
  check "the PR's line carries the error and no re-run" \
    eq "$(line 2 '[.error, .reruns, .applied]')" "[\"cannot read the Actions runs of $h2\",[],true]"
  check "that PR is still labeled and its block written" eq "$(labels 2)$(blocks "$(body 2)")" '["tier:1"]1'
  check "nothing of it is re-run; the other PR's job is" eq "$(reruns)" "[$j3]"
  check "the other PR is handled in full, no error" eq "$(line 3 '[(.error // null), .reruns[0].job]')" '[null,"depends-on"]'
  check "stderr names the PR, and the final count" eval \
    '[[ "$ERR" == *"PR #2: cannot read the Actions runs of $h2: nothing of it is re-run"* && "$ERR" == *"1 PR(s) whose runs could not be read"* ]]'
  # The jobs of a run unreadable: the same.
  st '.reruns = []'
  FAKE_GH_FAIL="actions/runs/20/jobs" lab --apply
  check "jobs unreadable: exit 1, the error on the PR's line" eq "$RC/$(line 2 .error)" '1/"cannot read the jobs of run 20"'
  check "jobs unreadable: only the other PR is re-run" eq "$(reruns)" "[$j3]"
  check "jobs unreadable: dry run makes no write either" eval \
    'n="$(writes)"; FAKE_GH_FAIL="actions/runs/20/jobs" lab; [ "$RC" = 1 ] && [ "$(writes)" = "$n" ]'
}

case_origin_main_ahead() {
  setup
  ticket T1 0 T2; ticket T2 1; commit "store" >/dev/null
  local m h jid ahead
  m="$(git -C "$R" rev-parse HEAD)"
  h="$(head_commit ticket/T2/dev-box "$(msg T2)")"
  add_pr 1 ticket/T2/dev-box "$h"
  add_run 30 "$h" depends-on=failure tier-order=success
  jid="$(job_id 30 depends-on)"
  # origin/main is one commit ahead of the checkout: T1 completed there, T2 moved to tier 2.
  ticket T1 0 T2 true; ticket T2 2; ahead="$(commit "ahead")"
  git -C "$R" reset -q --hard "$m"; git -C "$R" update-ref refs/remotes/origin/main "$ahead"
  lab --apply
  check "exit 0" eq "$RC" 0
  check "the label is origin/main's tier" eq "$(line 1 .tier)$(labels 1)" '2["tier:2"]'
  check "the block says what the re-run sees: T1 completed" has "$(body 1)" $'\nTier: 2\nDepends-on: T1 (completed on main)\n'
  check "and the held depends-on is re-run" eq "$(line 1 .reruns)$(reruns)" "[{\"job\":\"depends-on\",\"was\":\"failure\",\"now\":\"success\"}][$jid]"
  # A diverged origin/main (not a descendant of the checkout) is ignored: the checkout's store.
  setup
  ticket T1 0 T2; ticket T2 1; commit "store" >/dev/null
  m="$(git -C "$R" rev-parse HEAD)"
  h="$(head_commit ticket/T2/dev-box "$(msg T2)")"
  add_pr 1 ticket/T2/dev-box "$h"
  add_run 30 "$h" depends-on=failure tier-order=success
  git -C "$R" checkout -q --orphan side; git -C "$R" rm -rq --cached .
  ticket T1 0 T2 true; ticket T2 2; ahead="$(commit "diverged")"
  git -C "$R" checkout -qf main; git -C "$R" update-ref refs/remotes/origin/main "$ahead"
  check "the fixture: HEAD is main at the store commit" eq "$(git -C "$R" rev-parse HEAD)" "$m"
  lab --apply
  check "diverged: exit 0, the checkout's tier" eq "$RC/$(labels 1)" '0/["tier:1"]'
  check "diverged: T1 open in the block, and no re-run" eval \
    '[[ "$(body 1)" == *"Depends-on: T1 (open on main)"* ]] && [ "$(reruns)" = "[]" ]'
}

case_refusal_no_rerun() {
  setup
  # A desk error: two store files with the id T1, the first completed, the second open. depends-check.sh
  # refuses (exit 2, no JSON verdict): that is no answer, never a `failure` to re-run toward.
  ticket T1 1
  printf '%s\n' '{"id":"T1","completed":true,"body":"weight: light\ntier: 1\ncharter: C6\n\nold","edges":[]}' \
    >"$R/.adlc/tickets/a-dup--$(printf '%064d' 0).json"
  commit "store" >/dev/null
  local h
  h="$(head_commit ticket/T1/dev-box "$(msg T1)")"
  add_pr 1 ticket/T1/dev-box "$h"
  add_run 30 "$h" depends-on=success tier-order=success
  check "the fixture: depends-check.sh refuses T1 (exit 2, no stdout)" eval \
    '(cd "$R" && "$BIN/depends-check.sh" --ticket T1 --base HEAD >"$WORLD/dc.out" 2>/dev/null); rc=$?; [ "$rc" = 2 ] && [ ! -s "$WORLD/dc.out" ]'
  lab --apply
  check "exit 0" eq "$RC" 0
  check "a refusal re-runs nothing" eq "$(line 1 .reruns)$(reruns)" '[][]'
  check "and is warned" has "$ERR" "PR #1: depends-check.sh gave no verdict (exit 2)"
}

case_unterminated_start() {
  setup
  ticket T1 1; commit "store" >/dev/null
  local own n
  own=$'Ticket: T1\n\n<!-- factory:display note by the node, never closed\n\nimportant node text'
  add_pr 1 ticket/T1/dev-box "$(head_commit ticket/T1/dev-box "$(msg T1)")" "" "$own"
  lab --apply
  check "exit 0" eq "$RC" 0
  check "the unterminated line and everything after it kept, then the block" \
    eq "$(body 1 | sed '/^<!-- factory:display: written/,$d')" "$own"
  check "the labeler's block is the last thing" eq "$(body 1 | tail -n1)" "$MARK_Z"
  n="$(edits)"
  lab --apply
  check "second apply: body same, the node's text still there" \
    eq "$(line 1 .body)/$(edits)/$(body 1 | /usr/bin/grep -c '^important node text$')" "\"same\"/$n/1"
}

case_crlf_body() {
  setup
  ticket T1 1; ticket T2 1; commit "store" >/dev/null
  local n
  add_pr 1 ticket/T1/dev-box "$(head_commit ticket/T1/dev-box "$(msg T1)")"
  add_pr 2 ticket/T2/dev-box "$(head_commit ticket/T2/dev-box "$(msg T2)")" "" $'Ticket: T2\r\n\r\nnode text\r\n'
  lab --apply
  check "a CRLF body without a block: changed, rewritten on LF lines" \
    eq "$(line 2 .body)/$(body 2 | tr -d -c '\r' | wc -c | tr -d ' ')/$(blocks "$(body 2)")" '"changed"/0/1'
  check "its own lines kept" has "$(body 2)" $'Ticket: T2\n\nnode text\n\n'"$MARK_A"
  # A person edits the bodies in GitHub's web editor: CRLF, nothing else changed.
  set_pr 1 '.body |= gsub("\n"; "\r\n")'; set_pr 2 '.body |= gsub("\n"; "\r\n")'
  n="$(edits)"
  lab --apply
  check "a CRLF-only difference is same: no edit" eq "$(jq -sc 'map(.body)' <<<"$OUT")/$(edits)" "[\"same\",\"same\"]/$n"
  # A stale block in a CRLF body is replaced by one LF block.
  set_pr 1 '.body |= sub("Tier: 1"; "Tier: 7")'
  lab --apply
  check "a stale CRLF block: changed, one block, no CR left" \
    eq "$(line 1 .body)/$(blocks "$(body 1)")/$(body 1 | tr -d -c '\r' | wc -c | tr -d ' ')" '"changed"/1/0'
}

case_label_case_insensitive() {
  setup
  st '.labels = ["Tier:1", "in-review"]'
  ticket T1 1; commit "store" >/dev/null
  add_pr 1 ticket/T1/dev-box "$(head_commit ticket/T1/dev-box "$(msg T1)")"
  lab --apply
  check "Tier:1 exists: no label create" eq "$(fakegh_calls '.[0] == "label" and .[1] == "create"')" 0
  check "the edit adds tier:1 (GitHub matches label names case-insensitively)" \
    eq "$(fakegh_calls '.[0:3] == ["pr","edit","1"] and index("tier:1") != null')" 1
  check "exit 0 (the fake's pr edit must match labels case-insensitively, as gh does)" eq "$RC" 0
  check "the repo labels are unchanged" eq "$(jq -c .labels "$FAKE_GH_ISSUES")" '["Tier:1","in-review"]'
}

case_identity_refusal() {
  setup
  ticket T1 0 T2 true; ticket T2 1; commit "store" >/dev/null
  local h
  h="$(head_commit ticket/T2/dev-box "$(msg T2)")"
  # The node's body names another ticket: the gates job refuses it (exit 2, no verdict) on every run,
  # so its failed depends-on must never be re-run, though T2's parent is completed on main.
  add_pr 1 ticket/T2/dev-box "$h" "" $'Ticket: T9\n\nwrong ticket line'
  add_run 30 "$h" depends-on=failure tier-order=failure
  lab --apply
  check "exit 0" eq "$RC" 0
  check "no re-run of either job" eq "$(line 1 .reruns)$(reruns)" '[][]'
  check "the PR is still labeled" eq "$(labels 1)" '["tier:1"]'
  check "the warning names the PR and the refusal" eval \
    '[[ "$ERR" == *"PR #1: depends-check.sh gave no verdict (exit 2)"*"says '"'"'Ticket: T9'"'"'"* ]]'
  # Control: the same PR with its own Ticket line is re-run.
  set_pr 1 '.body = "Ticket: T2\n\nright ticket line"'
  lab --apply
  check "control: with its own Ticket line both stale jobs are re-run" \
    eq "$(line 1 '.reruns | map(.job)')" '["depends-on","tier-order"]'
}

case_head_missing_locally() {
  setup
  ticket T1 0 T2 true; ticket T2 1; commit "store" >/dev/null
  local h
  # The head is on the fake origin but was never fetched into the labeler's checkout.
  git clone -q "$R" "$WORLD/elsewhere"
  git -C "$WORLD/elsewhere" config user.name t; git -C "$WORLD/elsewhere" config user.email t@t.invalid
  git -C "$WORLD/elsewhere" checkout -q -b ticket/T2/dev-box
  echo work >"$WORLD/elsewhere/work.txt"; git -C "$WORLD/elsewhere" add -A; git -C "$WORLD/elsewhere" commit -qm "$(msg T2)"
  h="$(git -C "$WORLD/elsewhere" rev-parse HEAD)"
  git -C "$WORLD/elsewhere" push -q "$FAKE_GH_GIT" ticket/T2/dev-box 2>/dev/null
  check "the fixture: the head is not in the checkout" eval '! git -C "$R" cat-file -e "$h^{commit}" 2>/dev/null'
  add_pr 1 ticket/T2/dev-box "$h"
  add_run 30 "$h" depends-on=failure tier-order=success
  lab --apply
  check "no crash: exit 0, one line" eq "$RC/$(nlines true)" 0/1
  check "no re-run" eq "$(line 1 .reruns)$(reruns)" '[][]'
  check "labeled, and Assisted-by read through the API" eq "$(labels 1)$(body 1 | sed -n 's/^Assisted-by: //p')" '["tier:1"]`claude-code@2.1.0`'
  check "the warning names the PR" has "$ERR" "PR #1: depends-check.sh gave no verdict"
}

for c in labels-and-dry-run label-created body-block store-from-head skipped rerun-depends-on rerun-tier-order \
         no-rerun-when-unchanged assisted-by runs-unreadable origin-main-ahead refusal-no-rerun unterminated-start \
         crlf-body label-case-insensitive identity-refusal head-missing-locally; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
