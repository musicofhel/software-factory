#!/usr/bin/env bash
# desk-gates — the desk's records and the desk PR's gate (specs/factory-step3-v1 TB7, ticket T26).
#
#   desk-gates.sh [--dry-run | --write] [--ticket <id>]... [--coldstart offline|live] [--json]
#   desk-gates.sh --check [--base <sha>] [--head <sha>] [--json]
#
# The records. mirror.sh labels an open ticket `ready` only with a verified spec-lint record and a
# gap-free coldstart record taken on the ticket's current ticketHash. This writes them, with adlc
# 1.12.0's own record commands (measured in specs/factory-step3-v1/records/TB7.md §1), for every open
# ticket (or each --ticket) whose record is missing or stale:
#   spec-lint   `adlc spec-lint <id>.md --json --record --ticket <id> --dir <repo>/.adlc`
#               (@adlc/spec-lint bin/spec-lint.mjs:118-127, lib/record.mjs:28-36): deterministic, and
#               it records only a pass, with files = {"<id>.md": sha256}. <id>.md is the ticket body,
#               one change made: a line `Acceptance criteria:` (the desk's ticket form, ADR-0002) is
#               written `## Acceptance criteria`, the heading spec-lint parses (lib/parse.mjs:10,113-116);
#               without it spec-lint finds no criteria in any ticket. Stale = no verified record whose
#               files hold the sha256 of that rendering.
#   coldstart   offline (the default): `adlc coldstart <id> --offline --json`, the deterministic
#               contract check (lib/gate.mjs:213-280), and its result recorded through
#               `adlc coldstart <id> --prompt-only --record-verdict -` (bin/coldstart.mjs:94-113,
#               lib/verdict.mjs:58-68) as the verdict {pass, gaps, ticketHash, method: "offline"}.
#               --coldstart live runs `adlc coldstart <id> --tier cheap --json`, the LLM audit, which
#               records its own cache entry {ticketHash, model, gaps} (lib/cache.mjs:85-95); it needs
#               the desk's provider key. Stale = the latest record's ticketHash is not the ticket's.
#               A record with gaps is written too (the mirror shows them); it stays current, and
#               failing, until the desk edits the ticket.
# merge-forecast has no record command in 1.12.0 (`adlc merge-forecast --help` lists none); the
# mirror certifies wave 1 from the live forecast instead (mirror.sh).
#
# --dry-run (the default) writes nothing: a missing or stale record is `planned`, and the result is
# what the deterministic checks say now. --write records.
# Run it at the desk, in the desk PR's checkout, after every ticket write: the records ride in the
# same PR (factory/RULES.md, the desk runbook).
#
# --check is the `desk` job of .github/workflows/gates.yml (CI runs the BASE's copy, I16), on
# pull_request and merge_group. BASE and HEAD come from lib/gate-context.sh (a refused PR exits 2).
# When BASE...HEAD touches no `.adlc/` path it passes at once. Otherwise every check runs on the head's
# store and any failure fails the job:
#   manifest-extends  the head's .adlc/manifest.jsonl (and each manifest.d/ segment of the base) starts
#                     with the base's bytes: a desk PR only appends, from the current main
#   manifest-verify   `adlc gate-manifest verify --json`: seq and prev hash chain intact (two desk PRs,
#                     or a desk PR and a post-merge commit, cut from one main and joined break it)
#   manifest-skipped  `adlc gate-manifest show --json` has 0 skipped entries
#   doctor            `adlc ticket doctor --json` is ok
#   ticket-check      this directory's ticket-check.sh (`make tickets`) passes
#   spec-lint, coldstart  every open ticket the PR adds or changes (its file under .adlc/tickets/ is
#                     added or modified in BASE...HEAD; adding an edge changes the parent) has current,
#                     passing records, and CI's own re-run of the deterministic checks (spec-lint,
#                     coldstart --offline) agrees. Other open tickets are not the PR's: one the desk
#                     keeps unclaimable (no records) stays so
#
# Prints one JSON line per check: {"check", "ticket" (or null), "state": current|missing|stale|null,
# "action": none|planned|recorded|failed, "result": pass|fail, "reasons"}.
# Exit 0 every check passes (or, with --write, ends passing); 1 an operational error; 2 a check fails.
#
# Environment: FACTORY_ADLC (default `npx -y @adlc/cli@1.12.0`); GITHUB_EVENT_NAME, GITHUB_EVENT_PATH
# and GH_TOKEN for --check in CI (lib/gate-context.sh).
set -euo pipefail
PROG="desk-gates"
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/gate-context.sh
. "$(dirname "$0")/lib/gate-context.sh"

usage() { sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

mode=dry-run coldstart=offline only=() ctx=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) mode="dry-run" ;;
    --write) mode="write" ;;
    --check) mode="check" ;;
    --ticket) [ -n "${2:-}" ] || die "--ticket needs an id"; valid_ticket_id "$2" || die "bad ticket id '$2'"; only+=("$2"); shift ;;
    --coldstart) case "${2:-}" in offline|live) coldstart="$2" ;; *) die "--coldstart is offline or live" ;; esac; shift ;;
    --base|--head) [ -n "${2:-}" ] || die "$1 needs a sha"; ctx+=("$1" "$2"); shift ;;
    --json) ;;                      # the output is always JSON lines
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need jq git
[ "$mode" = check ] || [ "${#ctx[@]}" = 0 ] || die "--base and --head go with --check"
[ "$mode" = check ] && [ "${#only[@]}" -gt 0 ] && die "--check checks every open ticket; drop --ticket"
[ "$mode" = write ] || [ "$coldstart" = offline ] || die "--coldstart live calls the LLM and records; it goes with --write"
read -r -a ADLC <<<"${FACTORY_ADLC:-npx -y @adlc/cli@1.12.0}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git checkout"
cd "$ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/desk-gates.XXXXXX")"
# shellcheck disable=SC2317  # invoked by the trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK/spec"
OUT="$WORK/out.jsonl"; : >"$OUT"

line() {  # line <check> <ticket|''> <state|''> <action> <pass|fail> [reason...]
  local c="$1" t="$2" s="$3" a="$4" r="$5"; shift 5
  jq -cn --arg c "$c" --arg t "$t" --arg s "$s" --arg a "$a" --arg r "$r" '
    (reduce $ARGS.positional[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)) as $why
    | {check: $c, ticket: (if $t == "" then null else $t end), state: (if $s == "" then null else $s end),
       action: $a, result: $r, reasons: $why}' --args "$@" | tee -a "$OUT"
}

# ------------------------------------------------------------------------------- the desk PR's diff
if [ "$mode" = check ]; then
  if [ -n "${GITHUB_EVENT_NAME:-}" ] && [ "${#ctx[@]}" = 0 ]; then
    gate_begin                      # CI: the event's base and head; a refused PR exits 2
  else                              # the desk's own run before it opens the PR
    b="" h=HEAD; set -- "${ctx[@]}"
    while [ $# -gt 0 ]; do case "$1" in --base) b="$2" ;; --head) h="$2" ;; esac; shift 2; done
    GC_HEAD="$(git rev-parse --verify -q "$h^{commit}")" || die "head $h is not a commit here"
    if [ -n "$b" ]; then GC_BASE="$(git rev-parse --verify -q "$b^{commit}")" || die "base $b is not a commit here"
    else GC_BASE="$(git merge-base refs/remotes/origin/main "$GC_HEAD")" || die "no merge-base of origin/main and $GC_HEAD (pass --base)"; fi
  fi
  # adlc and ticket-check read the checkout's store, so the head is the checkout, as committed.
  [ "$(git rev-parse HEAD)" = "$GC_HEAD" ] || die "the checkout is not the head $GC_HEAD: check it out first (adlc reads the checkout's store)"
  git diff --quiet HEAD -- .adlc || die "uncommitted changes under .adlc/: commit them first (the check is on the head commit)"
  adlc_paths="$(git diff --name-only --no-renames "$GC_BASE...$GC_HEAD" -- .adlc)" ||
    die "git diff $GC_BASE...$GC_HEAD failed (is the base fetched?)"
  if [ -z "$adlc_paths" ]; then
    echo "desk-gates: no .adlc/ path in $GC_BASE...$GC_HEAD; nothing for the desk gate" >&2
    exit 0
  fi
  echo "desk-gates: $(wc -l <<<"$adlc_paths" | tr -d ' ') .adlc/ path(s) changed; the desk gate runs on the head's store" >&2

  # The manifest only grows, from the current main: the base's bytes are the head's first bytes.
  bad=()
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    git cat-file -e "$GC_BASE:$m" 2>/dev/null || continue
    bsize="$(git cat-file -s "$GC_BASE:$m")"
    if ! git cat-file -e "$GC_HEAD:$m" 2>/dev/null; then bad+=("$m: deleted"); continue; fi
    if ! cmp -s <(git cat-file -p "$GC_BASE:$m") <(git cat-file -p "$GC_HEAD:$m" | head -c "$bsize"); then
      bad+=("$m: the head does not extend the base's $bsize bytes (rebase the desk PR onto main, then re-run desk-gates.sh --write; never join two manifests by hand)")
    fi
  done < <(git ls-tree -r --name-only "$GC_BASE" -- .adlc/manifest.jsonl .adlc/manifest.d)
  if [ "${#bad[@]}" = 0 ]; then line manifest-extends "" "" none pass
  else line manifest-extends "" "" none fail "${bad[@]}"; fi

  rc=0; v="$("${ADLC[@]}" gate-manifest verify --json 2>"$WORK/err")" || rc=$?
  if [ "$rc" = 0 ] && jq -e '.valid == true' <<<"$v" >/dev/null 2>&1; then line manifest-verify "" "" none pass
  elif jq -e '.valid == false' <<<"$v" >/dev/null 2>&1; then line manifest-verify "" "" none fail "$(jq -r .message <<<"$v")"
  else die "adlc gate-manifest verify failed (exit $rc): $(tail -n1 "$WORK/err")"; fi

  "${ADLC[@]}" gate-manifest show --json >"$WORK/gm.json" || die "adlc gate-manifest show failed"
  n="$(jq -e '.skipped // [] | length' "$WORK/gm.json")" || die "adlc gate-manifest show: not its JSON"
  if [ "$n" = 0 ]; then line manifest-skipped "" "" none pass
  else line manifest-skipped "" "" none fail "$n unreadable manifest entries"; fi

  rc=0; d="$("${ADLC[@]}" ticket doctor --json 2>"$WORK/err")" || rc=$?
  if jq -e '.ok == true' <<<"$d" >/dev/null 2>&1; then line doctor "" "" none pass
  elif jq -e '.ok == false' <<<"$d" >/dev/null 2>&1; then
    mapfile -t why < <(jq -r '.checks[] | select(.ok | not) | "\(.name): \(.detail // "failed")"' <<<"$d")
    line doctor "" "" none fail "${why[@]}"
  else die "adlc ticket doctor failed (exit $rc): $(tail -n1 "$WORK/err")"; fi

  rc=0; "$(dirname "$0")/ticket-check.sh" >"$WORK/tc.jsonl" 2>"$WORK/err" || rc=$?
  case "$rc" in
    0) line ticket-check "" "" none pass ;;
    2) mapfile -t why < <(jq -r 'select(.result == "refused") | "\(.ticket): \(.reasons | join("; "))"' "$WORK/tc.jsonl")
       line ticket-check "" "" none fail "${why[@]}" ;;
    *) die "ticket-check.sh failed (exit $rc): $(tail -n1 "$WORK/err")" ;;
  esac

  # The tickets this PR adds or changes: the ids in the ticket files it adds or modifies.
  touched=""
  while IFS= read -r f; do
    case "$f" in .adlc/tickets/*.json) ;; *) continue ;; esac
    [ "${f##*/}" != .store.json ] || continue
    t="$(git cat-file -p "$GC_HEAD:$f" | jq -r '.id // empty' 2>/dev/null)" || die "$f: not a ticket file"
    valid_ticket_id "$t" || die "$f: no valid ticket id in it"
    touched+="$t"$'\n'
  done < <(git diff --name-only --no-renames --diff-filter=AM "$GC_BASE...$GC_HEAD" -- .adlc/tickets)
  [ -n "$touched" ] || echo "desk-gates: the PR adds or changes no ticket; no records to check" >&2
fi
if [ "$mode" != check ] || [ -n "$touched" ]; then
  "${ADLC[@]}" gate-manifest show --json >"$WORK/gm.json" || die "adlc gate-manifest show failed"
  jq -e '(.entries | type) == "array"' "$WORK/gm.json" >/dev/null 2>&1 || die "adlc gate-manifest show: no entries list"
fi

# ------------------------------------------------------------------------------- the records
list="$("${ADLC[@]}" ticket list --json)" || die "adlc ticket list failed"
ids="$(jq -r 'if type == "array" then .[].id else error("not a list") end' <<<"$list" 2>/dev/null)" ||
  die "adlc ticket list is not a JSON list of tickets"
if [ "${#only[@]}" -gt 0 ]; then
  for id in "${only[@]}"; do grep -qxF -- "$id" <<<"$ids" || die "no ticket $id in the store"; done
  ids="$(printf '%s\n' "${only[@]}" | awk '!seen[$0]++')"
elif [ "$mode" = check ]; then
  rc=0; ids="$(grep -xF -f <(printf '%s' "$touched") <<<"$ids")" || rc=$?
  [ "$rc" -le 1 ] || die "could not match the PR's tickets against the store"
fi

# The latest record of a gate for a ticket, as mirror.sh reads it (entries in manifest order).
latest() { jq -c --arg g "$1" --arg t "$2" '[.entries[] | select((.gate // .type) == $g and .ticket == $t)] | last' "$WORK/gm.json"; }
# coldstart's two record shapes (mirror.sh coldstart_shape): {gaps, hash} or null.
COLD_SHAPE='if . == null then null
  elif (.data.cache | type) == "object" then {gaps: .data.cache.gaps, hash: .data.cache.ticketHash}
  elif (.data.verdict | type) == "string" then
    (.data.verdict | try fromjson catch null) as $v
    | if ($v | type) == "object" then {gaps: $v.gaps, hash: $v.ticketHash} else null end
  else null end'

spec_lint_run() {  # spec_lint_run <id> [--record]: rc of adlc spec-lint on the rendering; SL_WHY on a fail
  local rc=0 out recargs=()
  [ -z "${2:-}" ] || recargs=(--record --ticket "$1" --dir "$ROOT/.adlc")
  out="$(cd "$WORK/spec" && "${ADLC[@]}" spec-lint "$1.md" --json "${recargs[@]}" 2>"$WORK/err")" || rc=$?
  SL_WHY=""
  case "$rc" in
    0) ;;
    2) if [ "$(jq -r '.total // 0' <<<"$out" 2>/dev/null)" = 0 ]; then SL_WHY="spec-lint: no acceptance criteria found"
       else SL_WHY="spec-lint: $(jq -r '.wishes' <<<"$out" 2>/dev/null) criterion/criteria without a verification method"; fi ;;
    *) die "adlc spec-lint $1 failed (exit $rc): $(tail -n1 "$WORK/err")" ;;
  esac
  return "$rc"
}
cold_offline() {  # cold_offline <id>: prints the offline gap list (JSON); rc 0 pass, 2 gaps
  local rc=0 out
  out="$("${ADLC[@]}" coldstart "$1" --offline --json 2>"$WORK/err")" || rc=$?
  { [ "$rc" = 0 ] || [ "$rc" = 2 ]; } && jq -ce --arg id "$1" '[.results[] | select(.id == $id) | .gaps] | if length == 1 then .[0] else error("no result") end' <<<"$out" 2>/dev/null ||
    die "adlc coldstart $1 --offline failed (exit $rc): $(tail -n1 "$WORK/err")"
}
gap_text() { jq -r '.[] | "coldstart: \(.what // .)\(if .why_blocking then " (\(.why_blocking))" else "" end)"'; }

while IFS= read -r id; do
  [ -n "$id" ] || continue
  valid_ticket_id "$id" || die "refusing ticket id '$id' from the store"
  show="$("${ADLC[@]}" ticket show "$id" --json)" || die "adlc ticket show $id failed"
  jq -e --arg id "$id" '.ticket.id == $id and (.ticketHash | type) == "string"' <<<"$show" >/dev/null 2>&1 ||
    die "adlc ticket show $id: not the ticket asked for"
  if [ "$(jq -r '.ticket.completed == true' <<<"$show")" = true ]; then
    [ "${#only[@]}" = 0 ] || warn "$id is completed; no records are written for it"
    continue
  fi
  hash="$(jq -r .ticketHash <<<"$show")"
  jq -r '.ticket.body // "" | gsub("\r"; "") | split("\n")
         | map(if test("^Acceptance criteria:[ \t]*$") then "## Acceptance criteria" else . end) | join("\n")' \
    <<<"$show" >"$WORK/spec/$id.md"
  bsha="$(sha256sum "$WORK/spec/$id.md" | cut -d' ' -f1)"

  # spec-lint
  rec="$(latest spec-lint "$id")"
  if [ "$rec" = null ]; then state=missing
  elif jq -e --arg s "$bsha" '.data.verified == true and any((.files // {})[]; . == $s)' <<<"$rec" >/dev/null; then state=current
  else state=stale; fi
  if [ "$state" = current ] && [ "$mode" != check ]; then line spec-lint "$id" current none pass
  elif [ "$mode" = write ]; then
    if spec_lint_run "$id" record; then line spec-lint "$id" "$state" recorded pass
    else line spec-lint "$id" "$state" failed fail "$SL_WHY"; fi
  else
    why=() act=none
    [ "$mode" = check ] || act=planned
    [ "$mode" != check ] || [ "$state" = current ] || why+=("spec-lint: $state record (the desk runs factory/bin/desk-gates.sh --write)")
    spec_lint_run "$id" || why+=("$SL_WHY")
    if [ "${#why[@]}" = 0 ]; then line spec-lint "$id" "$state" "$act" pass
    else line spec-lint "$id" "$state" "$act" fail "${why[@]}"; fi
  fi

  # coldstart
  shape="$(latest coldstart "$id" | jq -c "$COLD_SHAPE")"
  if [ "$(latest coldstart "$id")" = null ]; then state=missing
  elif jq -e --arg h "$hash" '. != null and .hash == $h and (.gaps | type) == "array"' <<<"$shape" >/dev/null; then state=current
  else state=stale; fi
  if [ "$state" = current ] && [ "$mode" != check ]; then
    if [ "$(jq '.gaps | length' <<<"$shape")" = 0 ]; then line coldstart "$id" current none pass
    else mapfile -t why < <(jq -c .gaps <<<"$shape" | gap_text); line coldstart "$id" current none fail "${why[@]}"; fi
  elif [ "$mode" = write ] && [ "$coldstart" = live ]; then
    rc=0; "${ADLC[@]}" coldstart "$id" --tier cheap --json >"$WORK/cs.json" 2>"$WORK/err" || rc=$?
    case "$rc" in
      0) line coldstart "$id" "$state" recorded pass ;;
      2) mapfile -t why < <(jq -c --arg id "$id" '[.results[]? | select(.id == $id) | .gaps[]?]' "$WORK/cs.json" | gap_text)
         line coldstart "$id" "$state" recorded fail "${why[@]}" ;;
      *) die "adlc coldstart $id (live) failed (exit $rc): $(tail -n1 "$WORK/err")" ;;
    esac
  elif [ "$mode" = write ]; then
    gaps="$(cold_offline "$id")"
    jq -cn --argjson g "$gaps" --arg h "$hash" '{pass: ($g == []), gaps: $g, ticketHash: $h, method: "offline"}' |
      "${ADLC[@]}" coldstart "$id" --prompt-only --record-verdict - >"$WORK/rec.out" 2>"$WORK/err" ||
      die "adlc coldstart $id --record-verdict failed: $(tail -n1 "$WORK/err")"
    if [ "$gaps" = '[]' ]; then line coldstart "$id" "$state" recorded pass
    else mapfile -t why < <(gap_text <<<"$gaps"); line coldstart "$id" "$state" recorded fail "${why[@]}"; fi
  else
    why=() act=none
    [ "$mode" = check ] || act=planned
    [ "$mode" != check ] || [ "$state" = current ] || why+=("coldstart: $state record (the desk runs factory/bin/desk-gates.sh --write)")
    [ "$state" != current ] || [ "$(jq '.gaps | length' <<<"$shape")" = 0 ] || mapfile -t -O "${#why[@]}" why < <(jq -c .gaps <<<"$shape" | gap_text)
    gaps="$(cold_offline "$id")"
    [ "$gaps" = '[]' ] || mapfile -t -O "${#why[@]}" why < <(gap_text <<<"$gaps")
    if [ "${#why[@]}" = 0 ]; then line coldstart "$id" "$state" "$act" pass
    else line coldstart "$id" "$state" "$act" fail "${why[@]}"; fi
  fi
done <<<"$ids"

if jq -se 'any(.[]; .result == "fail")' "$OUT" >/dev/null; then
  refuse "$(jq -sr '[.[] | select(.result == "fail") | "\(.check)\(if .ticket then " \(.ticket)" else "" end)"] | join(", ")' "$OUT") failed"
fi
exit 0
