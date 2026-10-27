#!/usr/bin/env bash
# run — one factory run loop for one slot (SPEC-v0.2 "Run loop" as corrected by ADR-0005; ticket T9).
#
#   run.sh --slot N [--apply] [--once | --max-iterations K] [--json]
#
# Run from the node's clone; /factory:run starts one per slot. A shell script, not an agent. Without
# --apply it is a dry run: it asks the governor and claim.sh what they would do, prints the plan and
# writes nothing. With --apply, every iteration:
#
#   governor     governor.sh --json --apply (one at a time per node: its fetches share tracking
#                refs). refuse → the loop stops, exit 2; sleep → nap; claim → go on
#   claim        claim.sh --apply (capacity heavy when the manifest says heavy_gates). Nothing
#                claimable → nap governor.nothingClaimableSleepMinutes. The Issue's `Ticket: <id>`
#                line (mirror.sh) names the ticket
#   fetch        origin main and ticket/<id>/*
#   worktree     .worktrees/<id>, detached, at the newest lapsed origin/ticket/<id>/* branch (its
#                dead-end material goes to fleet's --dead-end-file) or at origin/main; agent.lock
#                rendered by lib/ralon-lock.sh
#   budget       maxStrikes and wallClockMinutes of the claim's weight (budget.json), each replaced
#                by the ticket's own `budget` object from `adlc ticket show` in the worktree when it
#                holds that key as a positive integer (SPEC-v0.2 L431, node:G14). adlc's `budget` is
#                a token ceiling when it is a number: that form is adlc's and left to it
#   fleet        ralon run -C <wt> -- fleet run --tickets <id> --concurrency 1 --no-pr --no-complete
#                --base <sha> --adapter <a> --max-strikes <n> --wall-clock-minutes <m>
#                --pre-strike-argv '["<abs>/factory/bin/quota-gate.sh"]' --pre-strike-env <json>
#                --model-plane-read bounded --model-plane-git mirror --model-plane-git-mirror <m>
#                --model-plane-egress allowlist [--dead-end-file <f>] --json   (vetto cannot wrap
#                fleet: ADR-0005 decision 2; it wraps the loop's own tamperguard step). <m> is a
#                disposable bare mirror, $FACTORY_HOME/run/mirrors/<run id>.git, holding only the
#                base commit (fleet's allowlist egress needs bounded reads, which need it; ADR-0005).
#                While the fleet pin is exactly 1.12.0, fleet runs as `env PATH=<shim dir>:$PATH
#                <fleet> …`: <shim dir> is $FACTORY_HOME/run/bwrap-shim/slot-<n>, holding `bwrap`
#                (a link to lib/bwrap-shim, which adds fleet's missing system roots read-only) and
#                `fleet-pin`. Only fleet's PATH changes, never the loop's or ralon's (ADR-0006, #1266)
#   case on fleet's reason (success = exitCode 0, reason null, a fleet/run-* branch, merged >= 1):
#     success                       the node gates exactly the commit it pushes: GATE_BASE = the
#                                   merge-base of fleet's tip with origin/main (never a lapsed tip,
#                                   node:G5) and GATE_HEAD = ONE commit of fleet's final tree on
#                                   GATE_BASE carrying the trailer paragraph (Assisted-by, Ticket,
#                                   Node, Signed-off-by; T23: fleet's untrailered commits stay local);
#                                   the three diff gates run on GATE_BASE...GATE_HEAD, through
#                                   lib/diff-gates.sh, the helper CI's gates call (I17, T22):
#                                   tamperguard (dg_tamper_argv, under vetto + the claim's render of
#                                   build.toml, $FACTORY_HOME/run/policy/<run id>.build.toml,
#                                   lib/policy-render.sh; dg_tamper_judge), rails-proof.sh, then
#                                   scope-check.sh. All pass → check this node still holds the
#                                   lock (heartbeat.sh dry run; gone or another node's →
#                                   lock-lost, no push, node:G13), push that same sha to
#                                   ticket/<id>/<handle>, open the PR, comment; then hand the claim
#                                   to the PR (T25): label the Issue in-review (ready and
#                                   in-progress removed), release the lock. The PR is the claim from
#                                   here: claim.sh and the mirror skip a ticket with an open PR, so
#                                   it neither holds a slot nor goes stale while it waits. A PR that
#                                   cannot be opened keeps the lock and the slot state
#                                   (pr_pending); the next iteration retries it once, then
#                                   pr-open-failed → comment, label needs-desk, release (node:G12).
#                                   tamper, a rail edit or a scope failure → comment, label
#                                   needs-desk, release, no push. A gate error → release, no push,
#                                   stop the slot (exit 1)
#     quota-paused | wall-clock     push the partial branch, heartbeat the lock, keep the worktree;
#                                   the next iteration (after the governor) re-runs the identical
#                                   fleet argv there, which resumes it. A fourth pause of one claim
#                                   is handled as strikes-exhausted
#     strikes-exhausted | flail     push the branch, comment, label needs-desk, release
#     review-unavailable            release, nap governor.reviewUnavailableSleepMinutes
#     lock-held | ticket-blocked | mirror-fetch-failed
#                                   release, comment the reason, nap nothingClaimableSleepMinutes
#     anything else (run-level: preflight, quarantined, ..., or unreadable output)
#                                   release, comment the reason, stop the slot (exit 1): fleet says
#                                   these need a human, and re-claiming would repeat them
#   then the worktree and its mirror are removed (except while paused). A mirror that cannot be
#   built → reason mirror-failed, release, comment, stop the slot (exit 1). Every push (success,
#   pause, desk) first checks the lock is still this node's; a lost lock is lock-lost: nothing
#   pushed, labeled or commented, the claim is someone else's now.
#
# Labeling needs-desk: the result comment ends in the needs-desk marker (lib/desk-marker.sh: ticket,
# the Issue's Ticket-Hash at claim time, reason, handle), written before the label, and the one
# `gh issue edit` adds needs-desk and removes ready, so no node claims the Issue in between. The
# mirror keeps that label until the ticket's store state changes (factory/RULES.md, step-2 Q3).
# A nap is at most governor.nodeHeartbeatMinutes; then the governor is asked again. A paused claim's
# lock is heartbeated (heartbeat.sh) when claim.heartbeatMinutes have passed. One JSON line per
# iteration goes to $FACTORY_HOME/run/ledger.jsonl and, with --json, to stdout: ids, reason codes,
# counts and shas only (I8). Transcripts and fleet's own output stay in $FACTORY_HOME/run/logs/.
#
# --once runs one iteration and exits without napping; --max-iterations K stops after K.
# Environment: FACTORY_HOME (default ~/.factory; its env file is sourced when FACTORY_MANIFEST is
# unset), FACTORY_MANIFEST, FACTORY_REPO, FACTORY_NOW, FACTORY_ADLC, FACTORY_FLEET (default
# `npx -y @adlc/cli@1.12.0 fleet`), FACTORY_FLEET_PIN (default: the <v> of `@adlc/cli@<v>` in
# FACTORY_FLEET, else none; the bwrap shim is on only at exactly 1.12.0), FACTORY_SLEEP (default
# sleep). adversarial-review (fleet's review step, SPEC-v0.2 L644) must be on PATH, or the loop does
# not start (exit 1, node:G16).
# Exit 0 done (--once, --max-iterations); 1 operational error or a run-level fleet failure; 2 the
# governor refused or the slot stopped at a gate.
set -euo pipefail
PROG=run
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/run.sh
. "$(dirname "$0")/lib/run.sh"
# shellcheck source=factory/bin/lib/desk-marker.sh
. "$(dirname "$0")/lib/desk-marker.sh"
# shellcheck source=factory/bin/lib/policy-render.sh
. "$(dirname "$0")/lib/policy-render.sh"
# shellcheck source=factory/bin/lib/diff-gates.sh
. "$(dirname "$0")/lib/diff-gates.sh"

usage() { sed -n '2,93p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

slot="" apply=0 once=0 max=0 json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) slot="${2:-}"; shift ;;
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --once) once=1 ;;
    --max-iterations) max="${2:-}"; shift ;;
    --json) json=1 ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
[[ "$slot" =~ ^[1-8]$ ]] || { warn "--slot must be 1..8"; usage; }
[[ "$max" =~ ^[0-9]+$ ]] || die "--max-iterations must be a whole number"

FH="${FACTORY_HOME:-$HOME/.factory}"
if [ -z "${FACTORY_MANIFEST:-}" ] && [ -f "$FH/env" ]; then
  # shellcheck source=/dev/null  # written by join.sh --apply
  . "$FH/env"
  FH="${FACTORY_HOME:-$FH}"
fi
need git jq gh
need adversarial-review
M="${FACTORY_MANIFEST:-}"
[ -n "$M" ] && [ -f "$M" ] || die "no manifest: set FACTORY_MANIFEST or run join.sh --apply (it writes $FH/env)"
CLONE="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run from the node's clone of the factory repo"
CLONE="$(cd "$CLONE" && pwd -P)"
REPO="$(resolve_repo "")"
HANDLE="$(jq -r '.handle // empty' "$M")"
valid_handle "$HANDLE" || die "manifest handle is missing or bad: '$HANDLE'"
SLOTS="$(jq -r '.slots // empty' "$M")"
[[ "$SLOTS" =~ ^[1-8]$ ]] || die "manifest slots must be 1..8, got '$SLOTS'"
[ "$slot" -le "$SLOTS" ] || refuse "slot $slot is beyond this node's $SLOTS slot(s)"
CAPACITY=light
[ "$(jq -r '.heavy_gates // false' "$M")" = true ] && CAPACITY=heavy
ADAPTER="$(jq -r '.adapters // {} | keys_unsorted[0] // empty' "$M")"
ADAPTER_VERSION="$(jq -r --arg a "$ADAPTER" '.adapters[$a] // empty' "$M")"
[[ "$ADAPTER" =~ ^[a-z][a-z-]*$ && "$ADAPTER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "manifest names no adapter with a version"
mins() {  # mins <budget path>: a positive integer from budget.json, in seconds
  local v; v="$(budget "$1")"; [[ "$v" =~ ^[1-9][0-9]*$ ]] || die "budget.json $1 must be a positive integer"; echo $((v * 60))
}
NOTHING_S="$(mins .governor.nothingClaimableSleepMinutes)"
REVIEW_S="$(mins .governor.reviewUnavailableSleepMinutes)"
UNKNOWN_S="$(mins .governor.unknownStateSleepMinutes)"
PIECE_S="$(mins .governor.nodeHeartbeatMinutes)"
LOCKBEAT_S="$(mins .claim.heartbeatMinutes)"
MAX_RESUMES=3
read -r -a FLEET <<<"${FACTORY_FLEET:-npx -y @adlc/cli@1.12.0 fleet}"
FLEET_PIN="${FACTORY_FLEET_PIN:-}"
if [ -z "$FLEET_PIN" ]; then
  for w in "${FLEET[@]}"; do [[ "$w" =~ ^@adlc/cli@(.+)$ ]] && FLEET_PIN="${BASH_REMATCH[1]}"; done
fi
read -r -a SLEEP <<<"${FACTORY_SLEEP:-sleep}"
read -r -a ADLC <<<"${FACTORY_ADLC:-npx -y @adlc/cli@1.12.0}"
B="$FACTORY_ROOT/factory/bin"
COMMON=(--repo "$REPO" --manifest "$M" --handle "$HANDLE")

# ------------------------------------------------------------------ dry run
if [ "$apply" = 0 ]; then
  g="$(cd "$CLONE" && "$B/governor.sh" --json --manifest "$M" 2>/dev/null)" || true
  c="$("$B/claim.sh" --json --capacity "$CAPACITY" --repo "$REPO" --manifest "$M" 2>/dev/null)" || true
  out="$(jq -cn --argjson s "$slot" --arg h "$HANDLE" --arg a "$ADAPTER@$ADAPTER_VERSION" --arg cap "$CAPACITY" \
          --arg g "$g" --arg c "$c" \
    '{mode: "dry-run", slot: $s, handle: $h, adapter: $a, capacity: $cap,
      governor: ($g | try fromjson catch null),
      would_claim: ($c | try (fromjson | .candidates[0].number // null) catch null)}')"
  if [ "$json" = 1 ]; then printf '%s\n' "$out"; else
    jq -r '"dry run, slot \(.slot) of \(.handle), adapter \(.adapter), capacity \(.capacity)",
           "  governor: \(if .governor then "\(.governor.action) \(.governor.reason) \(.governor.sleep_seconds)" else "unavailable" end)",
           "  would claim: \(if .would_claim then "#\(.would_claim)" else "nothing" end)",
           "  --apply to run the loop"' <<<"$out"
  fi
  exit 0
fi

# ------------------------------------------------------------------ the loop's own state
RUN_DIR="$FH/run"
mkdir -p "$RUN_DIR/logs"
STATE="$RUN_DIR/slot-$slot.json"
LEDGER="$RUN_DIR/ledger.jsonl"
SLOT_MUTEX="$RUN_DIR/slot-$slot.mutex"
NODE_MUTEX="$RUN_DIR/node.mutex"
run_mutex_take "$SLOT_MUTEX" 0 || refuse "slot $slot already has a run loop (pid $(command cat "$SLOT_MUTEX/pid" 2>/dev/null || echo '?'))"
trap 'run_mutex_drop "$SLOT_MUTEX"; [ "$(command cat "$NODE_MUTEX/pid" 2>/dev/null)" != "$$" ] || run_mutex_drop "$NODE_MUTEX"' EXIT
# fleet 1.12.0's sandboxes bind no system root (voodootikigod/adlc#1266): the bwrap shim, first on
# fleet's PATH only, and only at that exact pin (I13, ADR-0006). Any other pin: no shim directory.
SHIM_DIR="$RUN_DIR/bwrap-shim/slot-$slot"
FLEET_ENV=()
rm -rf "$SHIM_DIR"
if [ "$FLEET_PIN" = 1.12.0 ]; then
  mkdir -p "$SHIM_DIR"
  ln -s "$B/lib/bwrap-shim" "$SHIM_DIR/bwrap"
  printf '%s\n' "$FLEET_PIN" >"$SHIM_DIR/fleet-pin"
  FLEET_ENV=(env "PATH=$SHIM_DIR:$PATH")
fi
serial() {  # serial <cmd...>: one at a time per node (governor fetches, git fetch)
  local rc=0
  run_mutex_take "$NODE_MUTEX" 600 || { warn "node mutex $NODE_MUTEX held for 10 min"; return 1; }
  "$@" || rc=$?
  run_mutex_drop "$NODE_MUTEX"
  return "$rc"
}

# Per-iteration variables. REC accumulates the ledger line.
reset_iteration() {
  ISSUE="" TICKET="" TICKET_HASH="" WEIGHT="" WT="" BASE="" BASE_KIND="" LAPSED="" RUN_ID="" RESUMES=0 FLEET_ARGV='[]'
  MAX_STRIKES=0 WALL_MIN=0 STRIKES=0 FLEET_RUN=unknown REASON="" NEXT_SLEEP=0 STOP_RC="" LOGBASE="" DOC="" PR_PENDING=null
  REC="$(jq -cn --argjson s "$slot" --argjson i "$ITER" --arg at "$(epoch_to_iso "$(now_epoch)")" --arg h "$HANDLE" \
          --arg a "$ADAPTER@$ADAPTER_VERSION" \
    '{slot: $s, iteration: $i, at: $at, handle: $h, adapter: $a, tokens: null, actions: []}')"
}
rec() { REC="$(jq -c "$@" <<<"$REC")"; }
act() { rec --arg a "$1" '.actions += [$a]'; }
outcome() { rec --arg o "$1" '.outcome = $o'; }

state_save() {  # state_save <lock-beat-epoch>; PR_PENDING (null or the PR to retry) is saved with it
  jq -cn --argjson n "$ISSUE" --arg t "$TICKET" --arg th "$TICKET_HASH" --arg w "$WEIGHT" --arg wt "$WT" --arg b "$BASE" --arg bk "$BASE_KIND" \
         --arg l "$LAPSED" --arg r "$RUN_ID" --argjson res "$RESUMES" --argjson argv "$FLEET_ARGV" \
         --argjson ms "$MAX_STRIKES" --argjson beat "$1" --arg reason "$REASON" --argjson pr "$PR_PENDING" \
    '{issue: $n, ticket: $t, ticket_hash: $th, weight: $w, worktree: $wt, base: $b, base_kind: $bk, lapsed: $l, run_id: $r,
      resumes: $res, fleet_argv: $argv, max_strikes: $ms, lock_beat_at: $beat, paused_reason: $reason, pr_pending: $pr}' >"$STATE.tmp"
  mv -f "$STATE.tmp" "$STATE"
}
state_load() {
  local s; s="$(command cat "$STATE")"
  ISSUE="$(jq -r .issue <<<"$s")" TICKET="$(jq -r .ticket <<<"$s")" WEIGHT="$(jq -r .weight <<<"$s")"
  TICKET_HASH="$(jq -r '.ticket_hash // ""' <<<"$s")"
  WT="$(jq -r .worktree <<<"$s")" BASE="$(jq -r .base <<<"$s")" BASE_KIND="$(jq -r .base_kind <<<"$s")"
  LAPSED="$(jq -r .lapsed <<<"$s")" RUN_ID="$(jq -r .run_id <<<"$s")" RESUMES="$(jq -r .resumes <<<"$s")"
  FLEET_ARGV="$(jq -c .fleet_argv <<<"$s")" MAX_STRIKES="$(jq -r .max_strikes <<<"$s")"
  LOCK_BEAT_AT="$(jq -r .lock_beat_at <<<"$s")"
  PR_PENDING="$(jq -c '.pr_pending // null' <<<"$s")"
  valid_issue "$ISSUE" && valid_ticket_id "$TICKET" && [[ "$RESUMES" =~ ^[0-9]+$ && "$LOCK_BEAT_AT" =~ ^[0-9]+$ ]] ||
    die "slot state $STATE is unreadable; inspect it, then remove it"
  LOGBASE="$RUN_DIR/logs/$RUN_ID"
}

# ------------------------------------------------------------------ actions on the hub
release_lock() {
  if "$B/release.sh" "$ISSUE" --apply "${COMMON[@]}" >/dev/null 2>>"$LOGBASE.err"; then act release-lock
  else act release-lock-failed; warn "could not release the lock on #$ISSUE"; fi
}
lock_check() {  # heartbeat.sh dry run before a push: 0 this node holds the lock, 2 lost, 1 unknown
  local rc=0
  "$B/heartbeat.sh" "$ISSUE" --dry-run "${COMMON[@]}" >/dev/null 2>>"$LOGBASE.err" || rc=$?
  case "$rc" in 0) act lock-owned ;; 2) act lock-lost; return 2 ;; *) act lock-check-failed; return 1 ;; esac
}
lock_lost() { REASON=lock-lost; outcome lock-lost; wt_remove; rm -f "$STATE"; }
handoff() {  # the PR is the claim now (T25): the Issue goes in-review, then the lock is released
  if gh issue edit "$ISSUE" --repo "$REPO" --add-label in-review --remove-label ready,in-progress >/dev/null 2>>"$LOGBASE.err"; then
    act label-in-review
  else act label-in-review-failed; fi
  release_lock
}
heartbeat_lock() {  # exit 2 from heartbeat.sh = the lock is gone or another node's
  local rc=0
  "$B/heartbeat.sh" "$ISSUE" --apply "${COMMON[@]}" >/dev/null 2>>"$LOGBASE.err" || rc=$?
  case "$rc" in 0) act heartbeat-lock ;; 2) return 2 ;; *) act heartbeat-lock-failed ;; esac
}
facts() {  # the JSON every outbound text is rendered from (I8: ids, codes, counts, shas)
  jq -cn --arg h "$HANDLE" --arg t "$TICKET" --argjson n "$ISSUE" --arg r "$REASON" --argjson s "$STRIKES" \
         --argjson ms "$MAX_STRIKES" --arg a "$ADAPTER@$ADAPTER_VERSION" --arg run "$FLEET_RUN" --arg br "${1:-}" \
         --arg head "${2:-}" --arg base "$BASE" --arg bk "$BASE_KIND" --argjson pr "${3:-null}" \
    '{handle: $h, ticket: $t, issue: $n, reason: $r, strikes: $s, max_strikes: $ms, adapter: $a, fleet_run: $run,
      branch: (if $br == "" then null else $br end), head: $head, base: $base, base_kind: $bk, pr: $pr, tokens: null}'
}
comment() {  # comment <kind> [branch head pr]; a desk comment ends in the needs-desk marker
  local body m; body="$(run_comment "$1" "$(facts "${2:-}" "${3:-}" "${4:-null}")")"
  if [ "$1" = desk ]; then
    if m="$(desk_marker "$TICKET" "$TICKET_HASH" "$REASON" "$HANDLE")"; then body+=$'\n\n'"$m"; else act desk-marker-failed; fi
  fi
  if gh issue comment "$ISSUE" --repo "$REPO" --body "$body" >/dev/null 2>>"$LOGBASE.err"; then act comment
  else act comment-failed; fi
}
label_desk() {
  if gh issue edit "$ISSUE" --repo "$REPO" --add-label needs-desk --remove-label ready >/dev/null 2>>"$LOGBASE.err"; then act label-needs-desk
  else act label-needs-desk-failed; fi
}
record_commit() {  # record_commit <parent> <outcome> [trailers...]: prints the record commit's sha
  run_record_commit "$1" "factory: $TICKET $2 on $HANDLE" "Factory-Outcome: $2" "${@:3}" || { act record-commit-failed; return 1; }
}
push_record() {  # push_record <parent> <outcome> [trailers...]: record commit + push; sets PUSHED_SHA
  local sha
  PUSHED_SHA=""
  sha="$(record_commit "$@")" || return 1
  push_sha "$sha"
}
push_sha() {  # push_sha <sha>: push it to ticket/<id>/<handle>; sets PUSHED_SHA
  local sha="$1"
  PUSHED_SHA=""
  if run_push "$sha"; then
    PUSHED_SHA="$sha"; act "push ticket/$TICKET/$HANDLE"
    rec --arg b "ticket/$TICKET/$HANDLE" --arg s "$sha" '.pushed = {branch: $b, sha: $s}'
  else
    act push-failed; warn "push of ticket/$TICKET/$HANDLE failed (see $LOGBASE.git.err)"; return 1
  fi
}
worker_tip() {  # fleet's worker branch for the ticket, else the run's base
  git -C "$CLONE" rev-parse -q --verify "refs/heads/fleet/$(tr '[:upper:]' '[:lower:]' <<<"$TICKET")^{commit}" || printf '%s\n' "$BASE"
}

# ------------------------------------------------------------------ worktree
wt_remove() {
  local p ib
  [ -n "$WT" ] || return 0
  # fleet cuts its own worktrees beneath the loop's (ADR-0005); drop those first.
  while IFS= read -r p; do
    case "$p" in "$WT"/*) git -C "$CLONE" worktree remove --force "$p" >/dev/null 2>&1 || true ;; esac
  done < <(git -C "$CLONE" worktree list --porcelain | sed -n 's/^worktree //p')
  if [ -e "$WT" ]; then git -C "$CLONE" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"; fi
  git -C "$CLONE" worktree prune
  git -C "$CLONE" branch -D "fleet/$(tr '[:upper:]' '[:lower:]' <<<"$TICKET")" >/dev/null 2>&1 || true
  ib="$(jq -r '.integrationBranch // empty' <<<"${DOC:-null}" 2>/dev/null || true)"
  if [[ "$ib" =~ ^fleet/run-[A-Za-z0-9._-]+$ ]]; then git -C "$CLONE" branch -D "$ib" >/dev/null 2>&1 || true; fi
  [ -z "$RUN_ID" ] || rm -rf "$(mirror_path)"
  act worktree-remove
}
mirror_path() { printf '%s/mirrors/%s.git\n' "$RUN_DIR" "$RUN_ID"; }
mirror_make() {  # fleet's model-plane git mirror: bare, no template (no hooks), one branch at the base, no remote
  local m; m="$(mirror_path)"
  [ ! -d "$m" ] || return 0
  mkdir -p "$(dirname "$m")"
  if git init -q --bare --template= "$m" 2>>"$LOGBASE.err" &&
     git -C "$m" fetch -q --no-tags "$CLONE" "$BASE:refs/heads/base" 2>>"$LOGBASE.err"; then
    act mirror; return 0
  fi
  rm -rf "$m"; return 1
}
wt_make() {
  local exclude
  WT="$CLONE/.worktrees/$TICKET"
  LAPSED="$(git -C "$CLONE" for-each-ref --sort=-committerdate --count=1 --format='%(refname)' "refs/remotes/origin/ticket/$TICKET/")"
  if [ -n "$LAPSED" ]; then BASE_KIND=lapsed; BASE="$(git -C "$CLONE" rev-parse "$LAPSED^{commit}")"
  else BASE_KIND=origin-main; BASE="$(git -C "$CLONE" rev-parse "refs/remotes/origin/main^{commit}")"; fi
  rec --arg b "$BASE" --arg k "$BASE_KIND" --arg l "${LAPSED#refs/remotes/origin/}" \
    '.base = {kind: $k, sha: $b} + (if $l == "" then {} else {lapsed: $l} end)'
  if [ -e "$WT" ]; then wt_remove; fi
  mkdir -p "$CLONE/.worktrees"
  git -C "$CLONE" worktree add -q --detach "$WT" "$BASE" 2>>"$LOGBASE.err" || return 1
  exclude="$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$(dirname "$exclude")" "$WT/.factory-run"
  grep -qxF /.factory-run/ "$exclude" 2>/dev/null || printf '/.factory-run/\n' >>"$exclude"
  act "worktree $BASE_KIND"
  if [ -n "$LAPSED" ]; then run_dead_end "$LAPSED" "$WT/.factory-run/dead-end.md"; act dead-end-material; fi
}

# ------------------------------------------------------------------ budget
ticket_budget() {  # sets MAX_STRIKES, WALL_MIN (the weight's, budget.json) and BUDGET_SOURCE
  local shown b k v
  MAX_STRIKES="$(budget ".weights.\"$WEIGHT\".maxStrikes")"
  WALL_MIN="$(budget ".weights.\"$WEIGHT\".wallClockMinutes")"
  BUDGET_SOURCE=weights
  # The ticket's own budget, read from the store the claim builds on (the worktree's).
  if ! shown="$(cd "$WT" && "${ADLC[@]}" ticket show "$TICKET" --json 2>>"$LOGBASE.err")" ||
     ! b="$(jq -ce --arg t "$TICKET" 'select(.ticket.id == $t) | [.ticket.budget // null]' <<<"$shown" 2>/dev/null)"; then
    BUDGET_SOURCE=weights-store-unreadable; return 0
  fi
  b="$(jq -c '.[0]' <<<"$b")"
  [ "$(jq -r 'type' <<<"$b")" = object ] || return 0       # none, or adlc's token ceiling (a number)
  for k in maxStrikes wallClockMinutes; do
    v="$(jq -r --arg k "$k" 'if has($k) then .[$k] | if type == "number" then tostring else "invalid" end else "" end' <<<"$b")"
    [ -n "$v" ] || continue
    if ! [[ "$v" =~ ^[1-9][0-9]{0,3}$ ]]; then BUDGET_SOURCE=weights-ticket-budget-invalid; break; fi
    case "$k" in maxStrikes) MAX_STRIKES="$v" ;; wallClockMinutes) WALL_MIN="$v" ;; esac
    BUDGET_SOURCE=ticket
  done
  if [ "$BUDGET_SOURCE" = weights-ticket-budget-invalid ]; then   # all or nothing: never half a bad override
    MAX_STRIKES="$(budget ".weights.\"$WEIGHT\".maxStrikes")"
    WALL_MIN="$(budget ".weights.\"$WEIGHT\".wallClockMinutes")"
  fi
}

# ------------------------------------------------------------------ fleet
fleet_argv() {
  local pse dirs=() d t
  dirs=("$FH/bin")
  for t in bash jq cux git; do d="$(command -v "$t" 2>/dev/null || true)"; [ -z "$d" ] || dirs+=("$(dirname "$d")"); done
  dirs+=(/usr/bin /bin)
  pse="$(printf '%s\n' "${dirs[@]}" | jq -Rsc --arg home "$HOME" --arg m "$M" --arg x "${XDG_DATA_HOME:-}" \
           --arg cux "${FACTORY_CUX:-}" --arg now "${FACTORY_NOW:-}" '
    {PATH: (split("\n") | map(select(. != "")) | reduce .[] as $p ([]; if IN(.[]; $p) then . else . + [$p] end) | join(":")),
     HOME: $home, FACTORY_MANIFEST: $m}
    + (if $x == "" then {} else {XDG_DATA_HOME: $x} end)
    + (if $cux == "" then {} else {FACTORY_CUX: $cux} end)
    + (if $now == "" then {} else {FACTORY_NOW: $now} end)')"
  local -a a=(run --tickets "$TICKET" --concurrency 1 --no-pr --no-complete --base "$BASE" --adapter "$ADAPTER"
              --max-strikes "$MAX_STRIKES" --wall-clock-minutes "$WALL_MIN"
              --pre-strike-argv "$(jq -cn --arg p "$B/quota-gate.sh" '[$p]')" --pre-strike-env "$pse"
              --model-plane-read bounded --model-plane-git mirror --model-plane-git-mirror "$(mirror_path)"
              --model-plane-egress allowlist)
  [ -z "$LAPSED" ] || a+=(--dead-end-file "$WT/.factory-run/dead-end.md")
  a+=(--json)
  printf '%s\0' "${a[@]}" | jq -Rsc 'split("\u0000")[:-1]'
}
run_fleet() {  # sets DOC (fleet's --json document, or empty); 1 = no mirror, fleet not run
  local -a argv=()
  local frc=0
  mirror_make || return 1
  while IFS= read -r -d '' x; do argv+=("$x"); done < <(jq -j '.[] | . + "\u0000"' <<<"$FLEET_ARGV")
  act fleet-run
  rec --argjson s "$([ ${#FLEET_ENV[@]} -gt 0 ] && echo true || echo false)" '.bwrap_shim = $s'
  (cd "$WT" && ralon run -C "$WT" -- ${FLEET_ENV[@]+"${FLEET_ENV[@]}"} "${FLEET[@]}" "${argv[@]}") \
    >"$LOGBASE.fleet.json" 2>>"$LOGBASE.fleet.err" || frc=$?
  DOC="$(jq -c 'select(type == "object" and has("exitCode"))' "$LOGBASE.fleet.json" 2>/dev/null | head -n1 || true)"
  rec --argjson rc "$frc" '.fleet_exit = $rc'
}

# ------------------------------------------------------------------ outcomes
finish_release() {  # finish_release <comment?> <sleep> [stop-rc]
  release_lock
  [ "$1" = 1 ] && comment released
  wt_remove; rm -f "$STATE"
  NEXT_SLEEP="$2"; STOP_RC="${3:-}"
}
on_success() {
  local tip tg_out tg verdict score findings rc a
  tip="$(git -C "$CLONE" rev-parse -q --verify "$(jq -r .integrationBranch <<<"$DOC")^{commit}" || true)"
  [ -n "$tip" ] || { REASON=integration-branch-missing; outcome released; finish_release 1 0 1; return; }
  # The node gates exactly the commit it pushes (I17): GATE_BASE is the merge-base of fleet's tip with
  # origin/main, never a lapsed tip (node:G5), and GATE_HEAD the ONE trailered commit of fleet's final
  # tree on GATE_BASE (T23, node:G2); every gate runs on GATE_BASE...GATE_HEAD, so a lapsed branch's
  # work is gated with the rest. fleet's own commits stay local.
  GATE_BASE="$(git -C "$WT" merge-base refs/remotes/origin/main "$tip")" ||
    { REASON=gate-base-missing; outcome released; finish_release 1 0 1; return; }
  GATE_HEAD="$(run_ticket_commit "$GATE_BASE" "$tip" "factory: $TICKET built on $HANDLE" \
                 "Factory-Outcome: built" "Fleet-Run: $FLEET_RUN" "Fleet-Strikes: $STRIKES")" ||
    { act record-commit-failed; REASON=push-failed; outcome released; finish_release 1 "$UNKNOWN_S"; return; }
  # fleet's own commits stay in the node's log for the transcript record (wt_remove deletes fleet's
  # branches): one local ref per run, refs/factory/fleet/<run id>, never pushed.
  git -C "$CLONE" update-ref "refs/factory/fleet/$RUN_ID" "$tip" 2>>"$LOGBASE.git.err" || act fleet-ref-failed
  rec --arg b "$GATE_BASE" --arg h "$GATE_HEAD" '.gate_base = $b | .gate_head = $h'
  # tamperguard over the whole ticket diff, under vetto and this claim's render of build.toml
  # (ADR-0005 decision 8 as amended by T17; lib/policy-render.sh). A root that cannot be derived
  # fails closed: the step never runs under a policy that lacks it.
  local policy="$RUN_DIR/policy/$RUN_ID.build.toml" roots r
  local -a root=() tg_argv=()
  if roots="$(policy_roots "$WT" "$FH" 2>"$LOGBASE.tamperguard.err")"; then
    while IFS= read -r r; do root+=("$r"); done <<<"$roots"
  fi
  if [ ${#root[@]} = 0 ] || ! mkdir -p "$RUN_DIR/policy" ||
     ! policy_render "$FACTORY_ROOT/factory/policy/build.toml" "$policy" "${root[@]}" 2>>"$LOGBASE.tamperguard.err"; then
    act policy-render-failed
    REASON=tamperguard-error; outcome released; finish_release 1 0 1; return
  fi
  act policy-render
  while IFS= read -r a; do tg_argv+=("$a"); done < <(dg_tamper_argv "$GATE_BASE" "$GATE_HEAD" 2>>"$LOGBASE.diff-gates.err")
  # vetto exits 125 whatever happened, so the result is the rc file the command itself writes.
  policy_tamperguard "$WT" "$policy" "${tg_argv[@]}" >>"$LOGBASE.vetto.log" 2>&1
  act tamperguard
  # the findings quote the diff and the stderr may too: they stay on the node, in the run's log
  # (the worktree goes)
  command cp -f "$WT/.factory-run/tamperguard.json" "$LOGBASE.tamperguard.json" 2>/dev/null || true
  command cp -f "$WT/.factory-run/tamperguard.err" "$LOGBASE.tamperguard.err" 2>/dev/null || : >"$LOGBASE.tamperguard.err"
  tg="$(command cat "$WT/.factory-run/tamperguard.rc" 2>/dev/null || echo none)"
  tg_out="$(jq -c 'select(type == "object")' "$WT/.factory-run/tamperguard.json" 2>/dev/null | head -n1 || true)"
  [ -n "$tg_out" ] || tg_out='{}'
  verdict="$(jq -r '.verdict // empty | strings' <<<"$tg_out")"
  score="$(jq -r 'if (.score | type) == "number" then .score else 0 end' <<<"$tg_out")"
  findings="$(jq -r 'if (.findings | type) == "array" then (.findings | length) else 0 end' <<<"$tg_out")"
  case "$(dg_tamper_judge "$tg" "$tg_out")" in
    0:ok|0:review) ;;
    2:tamper)
      rec --arg s "$score" --arg f "$findings" '.tamperguard = {verdict: "tamper", score: ($s | tonumber), findings: ($f | tonumber)}'
      REASON=tamper; outcome desk; comment desk; label_desk; release_lock; wt_remove; rm -f "$STATE"; return ;;
    *) REASON=tamperguard-error; outcome released; finish_release 1 0 1; return ;;
  esac
  rec --arg v "$verdict" --arg s "$score" --arg f "$findings" '.tamperguard = {verdict: $v, score: ($s | tonumber), findings: ($f | tonumber)}'
  # rails-proof, then scope-check: the scripts CI runs, with the node's flags (exit 2 = the gate fails).
  rc=0
  (cd "$WT" && "$FACTORY_ROOT/factory/bin/rails-proof.sh" --ticket "$TICKET" --base "$GATE_BASE" --head "$GATE_HEAD") >/dev/null 2>"$LOGBASE.rails.err" || rc=$?
  act rails-proof
  case "$rc" in
    0) rec '.rails_proof = "pass"' ;;
    2) rec '.rails_proof = "fail"'
       REASON=rails-fail; outcome desk; comment desk; label_desk; release_lock; wt_remove; rm -f "$STATE"; return ;;
    *) rec '.rails_proof = "error"'
       REASON=rails-proof-error; outcome released; finish_release 1 0 1; return ;;
  esac
  rc=0
  (cd "$WT" && "$FACTORY_ROOT/factory/bin/scope-check.sh" --ticket "$TICKET" --base "$GATE_BASE" --head "$GATE_HEAD") >/dev/null 2>"$LOGBASE.scope.err" || rc=$?
  act scope-check
  case "$rc" in
    0) rec '.scope_check = "pass"' ;;
    2) rec '.scope_check = "fail"'
       REASON=scope-fail; outcome desk; comment desk; label_desk; release_lock; wt_remove; rm -f "$STATE"; return ;;
    *) rec '.scope_check = "error"'
       REASON=scope-check-error; outcome released; finish_release 1 0 1; return ;;
  esac
  local lrc=0
  lock_check || lrc=$?
  case "$lrc" in
    0) ;;
    2) lock_lost; return ;;
    *) REASON=lock-check-failed; outcome released; finish_release 1 "$UNKNOWN_S"; return ;;
  esac
  push_sha "$GATE_HEAD" || { REASON=push-failed; outcome released; finish_release 1 "$UNKNOWN_S"; return; }
  PR_PENDING="$(jq -cn --arg sha "$PUSHED_SHA" --arg tip "$tip" --arg v "$verdict" --argjson s "$score" --argjson f "$findings" \
    --arg run "$FLEET_RUN" --argjson st "$STRIKES" \
    '{sha: $sha, tip: $tip, tamperguard: {verdict: $v, score: $s, findings: $f}, fleet_run: $run, strikes: $st, tries: 0}')"
  wt_remove   # the pushed sha is all the PR needs; fleet's tip stays under refs/factory/fleet/<run id>
  pr_open
}
# pr_open: open (or find) the PR for the pushed sha in PR_PENDING, then hand the claim to it. A PR
# that cannot be opened keeps the lock and saves PR_PENDING in the slot state for one retry on the
# next iteration; a second failure goes to the desk (pr-open-failed).
pr_open() {
  local found prn="" url facts_pr tries
  PUSHED_SHA="$(jq -r .sha <<<"$PR_PENDING")"
  tries="$(jq -r '.tries + 1' <<<"$PR_PENDING")"
  found="$(gh pr list --repo "$REPO" --head "ticket/$TICKET/$HANDLE" --state open --json number 2>>"$LOGBASE.err" | jq -r '.[0].number // empty')" || found=""
  if [ -n "$found" ]; then prn="$found"; act pr-exists
  else
    facts_pr="$(facts "ticket/$TICKET/$HANDLE" "$PUSHED_SHA" | jq -c --argjson p "$PR_PENDING" \
      --argjson g "$(run_gate_hashes "$(jq -r .tip <<<"$PR_PENDING")")" '. + {tamperguard: $p.tamperguard, gates: $g}')"
    if url="$(run_pr_body "$facts_pr" | gh pr create --repo "$REPO" --base main --head "ticket/$TICKET/$HANDLE" \
                 --title "$TICKET: built by $HANDLE (issue #$ISSUE)" --body-file - 2>>"$LOGBASE.err")"; then
      prn="$(sed -nE 's#.*/pull/([0-9]+)$#\1#p' <<<"$url" | tail -n1)"; act pr-open
    else act pr-open-failed; fi
  fi
  if [ -n "$prn" ]; then
    rec --argjson p "$prn" '.pr = $p'
    comment built "ticket/$TICKET/$HANDLE" "$PUSHED_SHA" "$prn"
    handoff
    outcome built; PR_PENDING=null; rm -f "$STATE"
  elif [ "$tries" -lt 2 ]; then
    PR_PENDING="$(jq -c --argjson t "$tries" '.tries = $t' <<<"$PR_PENDING")"
    heartbeat_lock || act heartbeat-lock-lost   # the retry's lock check acts on a lost lock
    state_save "$(now_epoch)"
    act keep-lock
    outcome pr-pending; NEXT_SLEEP="$UNKNOWN_S"
  else
    REASON=pr-open-failed; outcome desk
    comment desk "ticket/$TICKET/$HANDLE" "$PUSHED_SHA"; label_desk; release_lock
    PR_PENDING=null; rm -f "$STATE"
  fi
}
pr_retry() {  # the slot state holds a pushed sha whose PR could not be opened: try once more
  act pr-retry
  STRIKES="$(jq -r '.strikes // 0' <<<"$PR_PENDING")"; FLEET_RUN="$(run_id_safe "$(jq -r '.fleet_run // empty' <<<"$PR_PENDING")")"
  rec --arg s "$(jq -r .sha <<<"$PR_PENDING")" '.pr_retry = {sha: $s}'
  local lrc=0
  lock_check || lrc=$?
  case "$lrc" in
    0) pr_open ;;
    2) lock_lost ;;
    *) outcome pr-pending; NEXT_SLEEP="$UNKNOWN_S" ;;      # cannot tell: keep the state, ask again
  esac
}
on_desk() {  # strikes-exhausted | flail (and a pause past the resume cap)
  local lrc=0
  lock_check || lrc=$?
  if [ "$lrc" = 2 ]; then lock_lost; return; fi
  push_record "$(worker_tip)" "$REASON" "Fleet-Reason: $REASON" "Fleet-Strikes: $STRIKES" || true
  comment desk "${PUSHED_SHA:+ticket/$TICKET/$HANDLE}" "$PUSHED_SHA"
  label_desk
  release_lock; wt_remove; rm -f "$STATE"
  outcome desk
}
on_pause() {
  if [ "$RESUMES" -ge "$MAX_RESUMES" ]; then
    rec --argjson m "$MAX_RESUMES" '.note = "resume cap \($m) reached"'
    on_desk; return
  fi
  local lrc=0
  lock_check || lrc=$?
  if [ "$lrc" = 2 ]; then lock_lost; return; fi
  push_record "$(worker_tip)" "$REASON" "Fleet-Reason: $REASON" "Fleet-Strikes: $STRIKES" || true
  if ! heartbeat_lock; then
    REASON=lock-lost; outcome lock-lost; wt_remove; rm -f "$STATE"; return
  fi
  RESUMES=$((RESUMES + 1))
  state_save "$(now_epoch)"
  act keep-lock; act keep-worktree
  outcome paused
  if [ "$REASON" = quota-paused ]; then NEXT_SLEEP="$UNKNOWN_S"; else NEXT_SLEEP=0; fi
}
dispatch() {
  local ec reason
  if [ -z "$DOC" ]; then
    REASON=fleet-output-unreadable; rec '.fleet = null'; outcome released; finish_release 1 0 1; return
  fi
  ec="$(jq -r '.exitCode' <<<"$DOC")"
  reason="$(jq -r '.reason // empty' <<<"$DOC")"
  FLEET_RUN="$(run_id_safe "$(jq -r '.fleetRunId // empty' <<<"$DOC")")"
  STRIKES="$(jq -r --arg t "$TICKET" '(.tickets[$t].strikes // .strikesConsumed // 0) | if type == "number" then floor else 0 end' <<<"$DOC")"
  [ -z "$reason" ] || reason="$(run_code "$reason")"
  rec --argjson d "$DOC" --arg r "$reason" --arg run "$FLEET_RUN" --argjson s "$STRIKES" --arg t "$TICKET" '
    .fleet = {run: $run, exit_code: ($d.exitCode | numbers? // null), reason: (if $r == "" then null else $r end),
              merged: ($d.merged | numbers? // 0), strikes: $s,
              ticket_state: (($d.tickets[$t].state // null) | if type == "string" and test("^[a-z-]{1,24}$") then . else null end)}'
  if [ "$ec" = 0 ] && [ -z "$reason" ]; then
    if jq -e '(.integrationBranch // "" | test("^fleet/run-[A-Za-z0-9._-]+$")) and ((.merged // 0) >= 1)' <<<"$DOC" >/dev/null; then
      REASON=""; on_success
    else
      REASON=no-merge; outcome released; finish_release 1 0 1
    fi
    return
  fi
  REASON="${reason:-dispatch-refused}"
  case "$REASON" in
    quota-paused|wall-clock) on_pause ;;
    strikes-exhausted|flail) on_desk ;;
    review-unavailable) outcome released; finish_release 0 "$REVIEW_S" ;;
    lock-held|ticket-blocked|mirror-fetch-failed) outcome released; finish_release 1 "$NOTHING_S" ;;
    *) outcome released; finish_release 1 0 1 ;;
  esac
}

# ------------------------------------------------------------------ one iteration
iteration() {
  local g grc=0 action greason gsleep c crc=0 now issues issue
  now="$(now_epoch)"
  if [ -f "$STATE" ]; then
    state_load
    rec --argjson n "$ISSUE" --arg t "$TICKET" '.issue = $n | .ticket = $t | .resumed = true'
    if [ $((now - LOCK_BEAT_AT)) -ge "$LOCKBEAT_S" ]; then
      if ! heartbeat_lock; then
        REASON=lock-lost; outcome lock-lost; wt_remove; rm -f "$STATE"; return
      fi
      jq -c --argjson b "$now" '.lock_beat_at = $b' "$STATE" >"$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
    fi
  fi

  g="$(cd "$CLONE" && serial "$B/governor.sh" --json --apply --manifest "$M" 2>>"$RUN_DIR/governor.err")" || grc=$?
  [ -n "$g" ] || g='{}'
  read -r action greason gsleep < <(jq -r '"\(.action) \(.reason) \(.sleep_seconds)"' <<<"$g" 2>/dev/null || echo "- - -")
  rec --arg a "$action" --arg r "$greason" --arg s "$gsleep" '.governor = {action: $a, reason: $r, sleep_seconds: ($s | tonumber? // null)}'
  case "$grc:$action" in
    2:refuse) outcome refused; STOP_RC=2; return ;;
    0:sleep) outcome sleep; NEXT_SLEEP="$gsleep"; return ;;
    0:claim) ;;
    *) outcome governor-error; STOP_RC=1; return ;;
  esac

  if [ -f "$STATE" ] && [ "$PR_PENDING" != null ]; then  # the built ticket's PR, once more
    LOGBASE="$RUN_DIR/logs/$RUN_ID"
    pr_retry; return
  fi
  if [ -f "$STATE" ]; then  # resume the paused claim: the identical argv, in the same worktree
    act resume
    if [ ! -d "$WT" ]; then REASON=worktree-missing; outcome released; finish_release 1 0 1; return; fi
    LOGBASE="$RUN_DIR/logs/$RUN_ID"
    if ! run_fleet; then REASON=mirror-failed; outcome released; finish_release 1 0 1; return; fi
    dispatch; return
  fi

  RUN_ID="$HANDLE-s$slot-$now-$$"
  LOGBASE="$RUN_DIR/logs/$RUN_ID"
  c="$("$B/claim.sh" --apply --json --capacity "$CAPACITY" --run-id "$RUN_ID" --slots "$SLOTS" "${COMMON[@]}" 2>>"$LOGBASE.err")" || crc=$?
  if [ "$crc" != 0 ]; then outcome claim-error; NEXT_SLEEP="$UNKNOWN_S"; return; fi
  ISSUE="$(jq -r '.claimed // empty' <<<"$c")"
  if [ -z "$ISSUE" ]; then outcome nothing-claimable; NEXT_SLEEP="$NOTHING_S"; return; fi
  WEIGHT="$(jq -r --argjson n "$ISSUE" '.candidates[] | select(.number == $n) | .weight' <<<"$c")"
  rec --argjson n "$ISSUE" --arg r "$RUN_ID" --arg w "$WEIGHT" '.issue = $n | .run_id = $r | .weight = $w'
  act claim
  issues="$(gh issue list --repo "$REPO" --state open --limit 1000 --json number,body 2>>"$LOGBASE.err")" || issues='[]'
  issue="$(jq -c --argjson n "$ISSUE" '[.[] | select(.number == $n)][0] // {}' <<<"$issues")"
  TICKET="$(run_ticket_of_issue "$issue")"
  TICKET_HASH="$(run_ticket_hash_of_issue "$issue")"
  if ! valid_ticket_id "$TICKET" || ! git check-ref-format "refs/heads/ticket/$TICKET/$HANDLE"; then
    TICKET=unresolved REASON=ticket-unresolved; outcome released; finish_release 1 0 1; return
  fi
  rec --arg t "$TICKET" '.ticket = $t'

  if ! serial git -C "$CLONE" fetch -q --prune origin "+refs/heads/main:refs/remotes/origin/main" \
         "+refs/heads/ticket/$TICKET/*:refs/remotes/origin/ticket/$TICKET/*" 2>>"$LOGBASE.err"; then
    REASON=fetch-failed; outcome released; finish_release 1 "$UNKNOWN_S"; return
  fi
  act fetch
  if ! wt_make; then REASON=worktree-failed; outcome released; finish_release 1 0 1; return; fi
  local lrc=0
  "$B/lib/ralon-lock.sh" "$TICKET" --worktree "$WT" --apply 2>>"$LOGBASE.err" || lrc=$?
  if [ "$lrc" != 0 ]; then
    REASON="$([ "$lrc" = 2 ] && echo rails-refused || echo rails-lock-failed)"; outcome released; finish_release 1 0 1; return
  fi
  act ralon-lock
  ticket_budget
  FLEET_ARGV="$(fleet_argv)"
  rec --argjson ms "$MAX_STRIKES" --argjson wm "$WALL_MIN" --arg src "$BUDGET_SOURCE" \
    '.budget = {max_strikes: $ms, wall_clock_minutes: $wm, source: $src}'
  if ! run_fleet; then REASON=mirror-failed; outcome released; finish_release 1 0 1; return; fi
  dispatch
}

ITER=0
while :; do
  ITER=$((ITER + 1))
  reset_iteration
  iteration
  [ -z "$REASON" ] || rec --arg r "$REASON" '.reason = $r'
  rec --argjson s "$NEXT_SLEEP" '.sleep_seconds = $s'
  printf '%s\n' "$REC" >>"$LEDGER"
  if [ "$json" = 1 ]; then printf '%s\n' "$REC"; else
    jq -r '"slot \(.slot) #\(.iteration): \(.outcome // "?")\(if .ticket then " \(.ticket)" else "" end)\(if .reason then " (\(.reason))" else "" end); actions: \(.actions | join(", ")); sleep \(.sleep_seconds)s"' <<<"$REC"
  fi
  [ -z "$STOP_RC" ] || exit "$STOP_RC"
  [ "$once" = 0 ] || exit 0
  [ "$max" = 0 ] || [ "$ITER" -lt "$max" ] || exit 0
  if [ "$NEXT_SLEEP" -gt 0 ]; then
    "${SLEEP[@]}" "$(( NEXT_SLEEP < PIECE_S ? NEXT_SLEEP : PIECE_S ))"
  fi
done
