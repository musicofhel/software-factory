# shellcheck shell=bash
# Test harness for the fake gh (tests/fakes/gh). Sourced by tests/test_*.sh, never executed.
#
#   fakegh_setup                 fresh temp world: a bare origin with `main` and `nodes`, an empty
#                                issue store, an empty settings store (no protection, no rulesets),
#                                call logs, the fakes (gh, curl, adlc, mirror) first on PATH, the
#                                clock unpinned
#   fakegh_issue <n> <created-epoch> <labels,csv> [title] [body]
#   fakegh_close <n>             close Issue n
#   fakegh_pr <n> <head-branch> [OPEN|CLOSED|MERGED] [created-epoch]
#   fakegh_lock <n> <handle> <commit-epoch> [run_id] [slots]
#                                a lock ref as another node would leave it (same commit shape as
#                                factory/bin/lib/lock.sh writes)
#   fakegh_calls <jq-filter>     how many logged calls match (each call is a JSON argv array)
#   fakegh_ref <ref>             sha the origin holds for a ref, or empty
#   eq <got> <want>              string equality that prints both sides on failure
#   check <name> <cmd...>        run an assertion; print it and count failures in FAILED
#   run_case <name>              run case_<name> (dashes become underscores) in a subshell;
#                                PASS/FAIL line; counts in FAILED

FAKES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$FAKES_DIR/../.." && pwd)"
# shellcheck disable=SC2034  # used by the tests that source this file
BIN="$REPO_ROOT/factory/bin"
FAILED=0

fakegh_setup() {
  WORLD="$(mktemp -d "${TMPDIR:-/tmp}/fakegh.XXXXXX")"
  # shellcheck disable=SC2064  # expand now: WORLD is per case
  trap "rm -rf '$WORLD'" EXIT
  export FAKE_GH_GIT="$WORLD/origin.git" FAKE_GH_ISSUES="$WORLD/issues.json" FAKE_GH_LOG="$WORLD/gh.log"
  export FAKE_GH_SETTINGS="$WORLD/settings.json" FAKE_CURL_LOG="$WORLD/curl.log"
  export FAKE_GH_REPO=test/repo FACTORY_REPO=test/repo FAKE_GH_USER=fake-user
  export PATH="$FAKES_DIR:$PATH"
  unset FAKE_GH_NOW FAKE_GH_FAIL FAKE_GH_RACE_REFS FAKE_CURL_FAIL DISCORD_WEBHOOK SUMMONER_TO GITHUB_EVENT_PATH FACTORY_NOW FACTORY_HANDLE FACTORY_SLOTS \
        FACTORY_RUN_ID FACTORY_MANIFEST FACTORY_CAPACITY FACTORY_ADLC FACTORY_MIRROR RUNNER_ENVIRONMENT \
        FAKE_ADLC_TICKETS FAKE_ADLC_FORECAST FAKE_ADLC_FAIL FAKE_MIRROR_FAIL JANITOR_PREVIEW_HOOK JANITOR_REVOKE_HOOK
  export FAKE_ADLC_LOG="$WORLD/adlc.log" FAKE_MIRROR_LOG="$WORLD/mirror.log"
  git init -q --bare "$FAKE_GH_GIT"
  local blob tree commit
  blob="$(printf 'nodes registry\n' | git -C "$FAKE_GH_GIT" hash-object -w --stdin)"
  tree="$(printf '100644 blob %s\tREADME.md\n' "$blob" | git -C "$FAKE_GH_GIT" mktree)"
  commit="$(_fakegh_commit "$tree" 1761300000 'main: root' )"
  git -C "$FAKE_GH_GIT" update-ref refs/heads/main "$commit"
  commit="$(_fakegh_commit "$tree" 1761300000 'nodes: registry' )"
  git -C "$FAKE_GH_GIT" update-ref refs/heads/nodes "$commit"
  printf '{"labels":["ready","needs-desk","in-progress","w:light","w:heavy","tier:0","tier:1"],"issues":[]}\n' >"$FAKE_GH_ISSUES"
  printf '{"protection":{},"rulesets":[],"next_id":1}\n' >"$FAKE_GH_SETTINGS"
  : >"$FAKE_GH_LOG"
  : >"$FAKE_CURL_LOG"
  : >"$FAKE_ADLC_LOG"
  : >"$FAKE_MIRROR_LOG"
}

_fakegh_commit() {  # _fakegh_commit <tree> <epoch> <message> [parent]
  local -a p=()
  [ -z "${4:-}" ] || p=(-p "$4")
  printf '%s' "$3" | GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@fake GIT_COMMITTER_NAME=fixture \
    GIT_COMMITTER_EMAIL=fixture@fake GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" \
    git -C "$FAKE_GH_GIT" commit-tree "$1" "${p[@]}"
}

fakegh_issue() {
  local tmp; tmp="$(mktemp)"
  jq --argjson n "$1" --argjson at "$2" --arg l "$3" --arg t "${4:-issue $1}" --arg b "${5:-}" \
    '.issues += [{number: $n, title: $t, body: $b, state: "open", createdAt: ($at | todate),
                  labels: ($l | split(",") | map(select(. != "")) | map({name: .})),
                  assignees: [], comments: []}]' "$FAKE_GH_ISSUES" >"$tmp"
  mv "$tmp" "$FAKE_GH_ISSUES"
}

fakegh_close() {
  local tmp; tmp="$(mktemp)"
  jq --argjson n "$1" '(.issues[] | select(.number == $n)).state = "closed"' "$FAKE_GH_ISSUES" >"$tmp"
  mv "$tmp" "$FAKE_GH_ISSUES"
}

fakegh_pr() {
  local tmp; tmp="$(mktemp)"
  jq --argjson n "$1" --arg h "$2" --arg s "${3:-OPEN}" --argjson at "${4:-1761300000}" \
    '.pulls += [{number: $n, headRefName: $h, state: $s, createdAt: ($at | todate)}]' "$FAKE_GH_ISSUES" >"$tmp"
  mv "$tmp" "$FAKE_GH_ISSUES"
}

fakegh_lock() {
  local n="$1" h="$2" at="$3" tip payload sha
  tip="$(git -C "$FAKE_GH_GIT" rev-parse refs/heads/nodes)"
  payload="$(jq -cn --arg h "$h" --arg r "${4:-$h-run}" --argjson s "${5:-2}" --argjson at "$at" \
    '{handle: $h, run_id: $r, slots: $s, claimed_at: ($at | todate)}')"
  sha="$(_fakegh_commit "$(git -C "$FAKE_GH_GIT" rev-parse "$tip^{tree}")" "$at" \
          "$(printf 'lock issue-%s: %s\n\n%s' "$n" "$h" "$payload")" "$tip")"
  git -C "$FAKE_GH_GIT" update-ref "refs/locks/issue-$n" "$sha" ""
}

fakegh_calls() { jq -c "select($1)" "$FAKE_GH_LOG" | wc -l | tr -d ' '; }
fakegh_ref() { git -C "$FAKE_GH_GIT" show-ref --verify -s "$1" 2>/dev/null || true; }

eq() { [ "$1" = "$2" ] || { printf '      expected [%s] got [%s]\n' "$2" "$1"; return 1; }; }

check() {
  local name="$1"; shift
  if "$@"; then printf '    ok   %s\n' "$name"; else printf '    FAIL %s\n' "$name"; FAILED=$((FAILED + 1)); fi
}

# The subshell runs outside any `if` so `set -e` holds inside it: an unexpected failure in a case
# fails the case instead of being swallowed.
run_case() {
  local rc
  printf '  case %s\n' "$1"
  set +e
  ( set -e; FAILED=0; "case_${1//-/_}"; exit "$FAILED" )
  rc=$?
  set -e
  if [ "$rc" = 0 ]; then printf '  PASS %s\n' "$1"; else printf '  FAIL %s (rc %s)\n' "$1" "$rc"; FAILED=$((FAILED + 1)); fi
}
