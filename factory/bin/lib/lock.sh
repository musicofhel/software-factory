# shellcheck shell=bash
# Claim locks (SPEC-v0.2 "Claim protocol"). Sourced after common.sh; callers set REPO.
#
# A lock is the ref refs/locks/issue-<n>. It points at a commit whose parent is the tip of the
# `nodes` branch and whose message is one subject line, a blank line, and the JSON payload
#   {"handle": ..., "run_id": ..., "slots": ..., "claimed_at": ...}
# so the payload reads the same through the API (`.message`) and through git
# (`git log -1 --format=%B`), which is how the janitor sees it. The lock's age is its commit's
# committer date. Creating the ref (POST git/refs, 422 if it exists) is the only compare-and-swap.

lock_ref() { printf 'refs/locks/issue-%s\n' "$1"; }

# lock_index: JSON array [{"issue": n, "sha": ...}] of every lock ref. One API call.
lock_index() {
  gh api "repos/$REPO/git/matching-refs/locks/" |
    jq -c '[.[] | select(.ref | test("^refs/locks/issue-[1-9][0-9]*$"))
              | {issue: (.ref | ltrimstr("refs/locks/issue-") | tonumber), sha: .object.sha}]'
}

# lock_sha <n>: the lock's commit sha, or empty when there is no lock. matching-refs answers []
# for a missing ref, so absence is never inferred from an error.
lock_sha() {
  local ref; ref="$(lock_ref "$1")"
  gh api "repos/$REPO/git/matching-refs/${ref#refs/}" |
    jq -r --arg ref "$ref" '[.[] | select(.ref == $ref)][0].object.sha // empty'
}

# lock_read <sha>: {"sha", "committed_at", "payload"}; payload is null if the message carries none.
lock_read() {
  gh api "repos/$REPO/git/commits/$1" |
    jq -c '{sha, committed_at: .committer.date,
            payload: ((.message | split("\n\n") | .[1:] | join("\n\n")) as $b
                      | try ($b | fromjson) catch null)}'
}

lock_payload() {
  jq -cn --arg h "$1" --arg r "$2" --argjson s "$3" --arg at "$4" \
    '{handle: $h, run_id: $r, slots: $s, claimed_at: $at}'
}

# lock_commit <n> <payload-json>: creates the lock commit on top of the nodes tip; prints its sha.
lock_commit() {
  local tip tree msg
  tip="$(gh api "repos/$REPO/git/ref/heads/nodes" --jq .object.sha)" || die "cannot read the nodes branch"
  tree="$(gh api "repos/$REPO/git/commits/$tip" --jq .tree.sha)" || die "cannot read nodes tip $tip"
  msg="$(printf 'lock issue-%s: %s\n\n%s' "$1" "$(jq -r .handle <<<"$2")" "$2")"
  gh api -X POST "repos/$REPO/git/commits" -f message="$msg" -f tree="$tree" -f "parents[]=$tip" --jq .sha
}

# lock_state <n> <now-epoch>: one JSON object describing the lock on issue n.
lock_state() {
  local n="$1" now="$2" sha info at stale_h
  stale_h="$(budget .claim.staleAfterHours)"
  sha="$(lock_sha "$n")" || die "cannot list lock refs"
  if [ -z "$sha" ]; then
    jq -cn --argjson n "$n" --arg ref "$(lock_ref "$n")" --argjson h "$stale_h" \
      '{issue: $n, ref: $ref, state: "absent", stale_after_hours: $h}'
    return
  fi
  info="$(lock_read "$sha")" || die "cannot read lock commit $sha"
  at="$(iso_to_epoch "$(jq -r .committed_at <<<"$info")")"
  jq -c --argjson n "$n" --arg ref "$(lock_ref "$n")" --argjson h "$stale_h" \
        --argjson now "$now" --argjson at "$at" \
    '{issue: $n, ref: $ref, sha, committed_at, age_seconds: ($now - $at),
      state: (if ($now - $at) > ($h * 3600) then "stale" else "fresh" end),
      stale_after_hours: $h,
      handle: .payload.handle, run_id: .payload.run_id, slots: .payload.slots,
      claimed_at: .payload.claimed_at}' <<<"$info"
}

# lock_owned <n>: sets LOCK_SHA and LOCK_INFO for issue n's lock and refuses (exit 2) unless this
# node (NODE_HANDLE) holds it. A missing lock is refused too, unless LOCK_ABSENT_OK=1, in which
# case LOCK_SHA is left empty.
lock_owned() {
  local holder
  LOCK_SHA="$(lock_sha "$1")" || die "cannot list lock refs"
  LOCK_INFO=""
  if [ -z "$LOCK_SHA" ]; then
    [ "${LOCK_ABSENT_OK:-0}" = 1 ] || refuse "no lock on issue #$1 ($(lock_ref "$1")): the claim was lost"
    return 0
  fi
  LOCK_INFO="$(lock_read "$LOCK_SHA")" || die "cannot read lock commit $LOCK_SHA"
  holder="$(jq -r '.payload.handle // empty' <<<"$LOCK_INFO")"
  [ "$holder" = "$NODE_HANDLE" ] ||
    refuse "$(lock_ref "$1") is held by '${holder:-unknown}', not '$NODE_HANDLE'; refusing"
}
