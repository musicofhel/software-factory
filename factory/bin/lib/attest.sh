# shellcheck shell=bash
# attest — the gate manifest as a git note: the node writes it, attest-verify.sh checks it
# (specs/factory-step3-v1 TB11, ticket T30; ci:G6, ci:G16, node:G6; the format is ADR-0007 decision 9).
# Sourced after lib/common.sh and lib/diff-gates.sh, never executed.
#
# The note is one JSON object (format factory-attest/1) on the ONE ticket commit the node pushes
# (GATE_HEAD), under refs/notes/factory-attest, pushed atomically with the branch
# (lib/run.sh run_push_attested). It is unsigned: the store's securityMode is `unsigned-fallback`
# (ruling Q1 of factory-run-calls-v1), and a key can replace that later. CorvidLabs/attest 1.0.0
# (records/TB0.md (c)) also keeps its records in git notes, but under refs/notes/attest, as
# {reviewer, confidence, verdict, tests-passed, human-approved} gated by a confidence policy: it has
# no field for a recomputable gate verdict, so the factory's own format sits beside it (ADR-0007 decision 9).
#
#   {format, signing, ticket, node, adapter, outcome: built | rebased, base, head, tree,
#    fleet: {run, strikes, doc_sha256}, gate_commands, tests_run,
#    verdicts: {tamperguard: {verdict, score, findings}, rails-proof, scope},
#    hashes: {tamperguard_json}}
#
# Ids, shas, codes, counts, the base's gate commands and hashes only (I8): never a finding's text.
#
#   attest_gate_list <commit>      build-test.sh --list of <commit>:.adlc/config.json (fleet.gate as
#                                  fleet runs it); exit 1 when that config is unusable
#   attest_signing <commit>        the securityMode of <commit>:.adlc/config.json, or `none`
#   attest_manifest <facts-json>   the note, from the node's facts {ticket, node, adapter, outcome,
#                                  base, head, fleet, verdicts, hashes} plus what git knows: tree,
#                                  gate_commands (at base), tests_run (gate_commands when fleet ran,
#                                  [] on a rebase strike), signing; exit 1 when the base's store is
#                                  not securityMode unsigned-fallback (the note cannot be signed)
#   attest_read <commit>           the note on <commit> as compact JSON; 2 when there is none or it is
#                                  not one JSON object
#   attest_fetch                   origin's refs/notes/factory-attest into the same local ref; 2 when
#                                  origin has none, 1 on any other failure
#   attest_target                  the commit the note is on: GC_HEAD, or on merge_group and the
#                                  first-party queue the queue commit's second parent (its parents
#                                  are [base, PR head], records/TB4.md), which must be PR GC_PR's
#                                  head (gh api pulls/N); 2 for any other shape, 1 when gh fails
#   attest_check <note> <ticket> <handle> <base> <target>
#                                  recompute what CI can and compare: prints one `mismatch:` line per
#                                  difference (2; a note lacking a key, or a ticket not open at the
#                                  merge-base, is one), 1 on an operational error, 0 when all agree
# Every git call reads the repository in the current directory.

ATTEST_REF=refs/notes/factory-attest
ATTEST_FORMAT=factory-attest/1
ATTEST_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

attest_gate_list() {
  local tmp rc=0 out
  tmp="$(mktemp)" || return 1
  if git show "$1:.adlc/config.json" >"$tmp" 2>/dev/null; then
    out="$("$ATTEST_BIN/build-test.sh" --list --config "$tmp" 2>/dev/null)" || rc=1
  else rc=1; fi
  rm -f "$tmp"
  [ "$rc" = 0 ] || return 1
  jq -c . <<<"$out"
}

attest_signing() {
  local sm
  sm="$(git show "$1:.adlc/config.json" 2>/dev/null | jq -r '.securityMode // "none" | tostring' 2>/dev/null)" || sm=""
  printf '%s\n' "${sm:-none}"
}

attest_manifest() {
  local facts="$1" base head tree gates
  base="$(jq -r .base <<<"$facts")"; head="$(jq -r .head <<<"$facts")"
  tree="$(git rev-parse --verify -q "$head^{tree}")" || return 1
  gates="$(attest_gate_list "$base")" || return 1
  # The note is unsigned: a base store that wants more than unsigned-fallback gets no note at all.
  [ "$(attest_signing "$base")" = unsigned-fallback ] || return 1
  jq -c --arg f "$ATTEST_FORMAT" --arg tree "$tree" --argjson g "$gates" '
    {format: $f, signing: "unsigned-fallback", ticket, node, adapter, outcome, base, head, tree: $tree,
     fleet, gate_commands: $g, tests_run: (if .outcome == "built" then $g else [] end), verdicts, hashes}' <<<"$facts"
}

attest_read() {
  local raw
  raw="$(git notes --ref="$ATTEST_REF" show "$1" 2>/dev/null)" || return 2
  jq -sce 'if length == 1 and (.[0] | type) == "object" then .[0] else error("not one object") end' <<<"$raw" 2>/dev/null || return 2
}

attest_fetch() {
  local rc=0
  git ls-remote --exit-code origin "$ATTEST_REF" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) git fetch -q --no-write-fetch-head origin "+$ATTEST_REF:$ATTEST_REF" ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
}

attest_target() {
  local -a p
  local prh
  case "$GC_EVENT" in
    merge_group|queue)
      read -r -a p <<<"$(git rev-list --parents -n 1 "$GC_HEAD" 2>/dev/null)"
      [ "${#p[@]}" = 3 ] && [ "${p[1]}" = "$GC_BASE" ] || return 2
      # The second parent must be PR N's head (gate-context checks this on `queue` only).
      prh="$(gh api "repos/$GC_REPO/pulls/$GC_PR" --jq '.head.sha // empty' 2>/dev/null)" || return 1
      [ "$prh" = "${p[2]}" ] || return 2
      printf '%s\n' "${p[2]}" ;;
    *) printf '%s\n' "$GC_HEAD" ;;
  esac
}

# attest_recompute_verdict <fn> <ticket> <base> <head>: pass (0) | fail (2) of dg_rails / dg_scope;
# anything else is an error.
attest_recompute_verdict() {
  local rc=0
  ( "$1" "$2" "$3" "$4" ) >/dev/null || rc=$?   # its own subshell: a refusal inside exits only it
  case "$rc" in 0) echo pass ;; 2) echo fail ;; *) return 1 ;; esac
}

attest_check() {
  local note="$1" ticket="$2" handle="$3" base="$4" target="$5" mb tree trailers gates rails scope
  local tg_out tg_rc=0 tg judged signing a out
  local -a argv=()
  # The note's shape first: every key of the format, and objects where the format has objects.
  out="$(jq -r --arg f "$ATTEST_FORMAT" '
    (["adapter", "base", "fleet", "format", "gate_commands", "hashes", "head", "node", "outcome", "signing",
      "ticket", "tests_run", "tree", "verdicts"] - keys | if length == 0 then empty
     else "mismatch: keys: the note lacks \(join(", ")) (format \($f))" end),
    (. as $n | ["fleet", "hashes", "verdicts"][] as $k | select($n | has($k)) | $n[$k] | select(type != "object")
     | "mismatch: \($k): the note holds \(tojson), not an object")' <<<"$note")" || return 1
  [ -z "$out" ] || { printf '%s\n' "$out"; return 2; }
  mb="$(git merge-base "$base" "$target")" || return 1
  tree="$(git rev-parse --verify -q "$target^{tree}")" || return 1
  trailers="$(git log -1 --format='%(trailers:key=Assisted-by,key=Ticket,key=Node,unfold)' "$target" |
    jq -Rsc 'split("\n") | map(capture("^(?<k>[A-Za-z-]+): (?<v>.*)$")?) | group_by(.k)
             | map({key: .[0].k, value: [.[].v]}) | from_entries')" || return 1
  gates="$(attest_gate_list "$mb")" || return 1
  signing="$(attest_signing "$base")"
  # A ticket missing from (or completed in) the store at the merge-base is named, not read as a
  # rails/scope fail: a node gates only an open ticket of the store it built on.
  a=0; (dg_ticket "$ticket" "$mb" >/dev/null 2>&1) || a=$?
  case "$a" in
    0) ;;
    2) printf 'mismatch: ticket: %s is not an open ticket in the store at the merge-base %s\n' "$ticket" "${mb:0:12}"; return 2 ;;
    *) return 1 ;;
  esac
  rails="$(attest_recompute_verdict dg_rails "$ticket" "$mb" "$target")" || return 1
  scope="$(attest_recompute_verdict dg_scope "$ticket" "$mb" "$target")" || return 1
  while IFS= read -r a; do argv+=("$a"); done < <(dg_tamper_argv "$mb" "$target")
  tg_out="$(tamperguard "${argv[@]}")" || tg_rc=$?
  judged="$(dg_tamper_judge "$tg_rc" "$tg_out")"
  [ "$judged" != tamper-error ] || return 1
  tg="$(jq -c '{verdict, score: (if (.score | type) == "number" then .score else 0 end),
                findings: (if (.findings | type) == "array" then (.findings | length) else 0 end)}' <<<"$tg_out")" || return 1
  out="$(jq -nr --argjson n "$note" --arg f "$ATTEST_FORMAT" --arg t "$ticket" --arg h "$handle" --arg mb "$mb" \
    --arg target "$target" --arg tree "$tree" --argjson tr "$trailers" --argjson g "$gates" --arg sm "$signing" \
    --arg rails "$rails" --arg scope "$scope" --argjson tg "$tg" '
    def m($k; $note; $want): if $note == $want then empty else "mismatch: \($k): the note says \($note | tojson), CI recomputes \($want | tojson)" end;
    def one($k): ($tr[$k] // []) | if length == 1 then .[0] else . end;
    m("format"; $n.format; $f),
    (if $n.signing == "unsigned-fallback" and $sm == "unsigned-fallback" then empty
     else "mismatch: signing: the note is \($n.signing | tojson), the store at the base is securityMode \($sm | tojson) (only an unsigned note under unsigned-fallback is verifiable)" end),
    m("ticket"; $n.ticket; $t),
    (if $h == "" then empty else m("node"; $n.node; $h) end),
    m("node (its Node trailer)"; $n.node; one("Node")),
    m("ticket (its Ticket trailer)"; $n.ticket; one("Ticket")),
    m("adapter (its Assisted-by trailer)"; $n.adapter; one("Assisted-by")),
    m("head"; $n.head; $target),
    m("base (the merge-base with the base)"; $n.base; $mb),
    m("tree"; $n.tree; $tree),
    m("gate_commands (fleet.gate at the merge-base)"; $n.gate_commands; $g),
    (if $n.outcome == "built" then m("tests_run (fleet ran the gate commands)"; $n.tests_run; $g)
     elif $n.outcome == "rebased" then m("tests_run (a rebase strike runs no fleet)"; $n.tests_run; [])
     else "mismatch: outcome: \($n.outcome | tojson) is neither built nor rebased" end),
    m("verdicts.rails-proof"; $n.verdicts["rails-proof"]; $rails),
    m("verdicts.scope"; $n.verdicts.scope; $scope),
    m("verdicts.tamperguard"; $n.verdicts.tamperguard; $tg),
    (if $rails == "pass" and $scope == "pass" and ($tg.verdict | IN("ok", "review")) then empty
     else "mismatch: the recomputed verdicts do not pass (rails-proof \($rails), scope \($scope), tamperguard \($tg.verdict)): a node pushes only a passing commit" end)
  ')" || return 1
  [ -z "$out" ] || { printf '%s\n' "$out"; return 2; }
}
