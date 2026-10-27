# shellcheck shell=bash
# Helpers for factory/bin/run.sh (ticket T9). Sourced after common.sh, never executed.
#
# I8 lives here: every string the loop sends off the node (a PR body, an Issue comment, a pushed
# commit message, a ledger line) is built by run_comment / run_pr_body / run_record_commit from
# reason codes, counts, ids, adapter names and shas only. Free text from fleet (tickets[].reason,
# warnings, results), tamperguard (findings[].detail) or the ticket (title, body) never reaches them.

# run_code <string>: the string when it reads as a reason code, else `unrecognized`. fleet's reason
# set is closed, but a value the loop forwards is checked here anyway, so a fleet that one day put
# text in `reason` could not carry it into a comment.
run_code() { if [[ "${1:-}" =~ ^[a-z][a-z0-9-]{0,47}$ ]]; then printf '%s\n' "$1"; else echo unrecognized; fi; }

# run_id_safe <string>: an id (fleet run id, ticket id) the loop may print, else `unknown`.
run_id_safe() { if [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$ ]]; then printf '%s\n' "$1"; else echo unknown; fi; }

# run_mutex_take <dir> [wait-seconds]: a mkdir mutex (no flock on macOS). A holder whose pid is gone
# is broken. Returns 1 when still held after the wait.
run_mutex_take() {
  local d="$1" wait="${2:-0}" i=0 pid
  while ! mkdir "$d" 2>/dev/null; do
    pid="$(command cat "$d/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$d"; continue; fi
    [ "$i" -lt "$wait" ] || return 1
    i=$((i + 1)); sleep 1
  done
  echo "$$" >"$d/pid"
}
run_mutex_drop() { rm -rf "$1"; }

# run_sha256 <file>: hex digest (GNU sha256sum, else macOS shasum).
run_sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# run_ticket_of_issue <issue-json>: the first `Ticket: <id>` line of a mirror Issue body (mirror.sh
# writes it), or nothing.
run_ticket_of_issue() {
  jq -r '[.body // "" | split("\n")[] | capture("^Ticket: (?<id>[^[:space:]]+)[[:space:]]*$")] | .[0].id // empty' <<<"$1"
}

# run_ticket_hash_of_issue <issue-json>: the first `Ticket-Hash: <hash>` line of a mirror Issue body
# (the store state the node claims; it goes into the needs-desk marker), or nothing.
run_ticket_hash_of_issue() {
  jq -r '[.body // "" | split("\n")[] | capture("^Ticket-Hash: (?<h>[A-Za-z0-9._-]{1,128})[[:space:]]*$")] | .[0].h // empty' <<<"$1"
}

# run_signoff: "Name <email>" of whoever commits on this node (git's own resolution: env, then config).
run_signoff() { git -C "$CLONE" var GIT_COMMITTER_IDENT | sed -E 's/ [0-9]+ [-+][0-9]{4}$//'; }

# run_commit_tree <tree-ish> <parent-sha> <subject> <Key: value>...: a commit of <tree-ish>'s tree
# on <parent> whose message is the subject and ONE trailer paragraph (I6): the given trailers,
# Assisted-by, Ticket, Node, Signed-off-by (the node owner's DCO, as `git commit -s` writes it).
# Prints its sha.
run_commit_tree() {
  local tree="$1" parent="$2" subject="$3" msg t
  shift 3
  msg="$subject"$'\n\n'
  for t in "$@"; do msg+="$t"$'\n'; done
  msg+="Assisted-by: $ADAPTER@$ADAPTER_VERSION"$'\n'"Ticket: $TICKET"$'\n'"Node: $HANDLE"$'\n'
  msg+="Signed-off-by: $(run_signoff)"
  printf '%s\n' "$msg" | git -C "$CLONE" commit-tree "$tree^{tree}" -p "$parent"
}

# run_record_commit <parent-sha> <subject> <Key: value>...: an empty commit on top of <parent>
# carrying the trailer paragraph. Every partial branch the loop pushes ends in one, so the pushed tip
# names the reason, the strikes and the node without any transcript.
run_record_commit() { run_commit_tree "$1" "$@"; }

# run_ticket_commit <merge-base> <tip> <subject> <Key: value>...: the ONE commit a built ticket pushes
# (ticket T23, node:G2): <tip>'s tree, fleet's final tree, with the merge-base with origin/main as its
# only parent and the trailer paragraph. fleet's own commits (its worker commit and its --no-ff
# merge, no trailers) stay in the local log for the transcript record and are never pushed; a lapsed
# branch's commits are dropped the same way (node:G5), its work kept in the tree.
run_ticket_commit() { run_commit_tree "$2" "$1" "${@:3}"; }

# run_push <sha>: push <sha> to ticket/<id>/<handle> on origin with a lease on what the last fetch
# saw (the branch is this node's own name; a lapsed branch of another node is never overwritten).
run_push() {
  local ref="refs/heads/ticket/$TICKET/$HANDLE" seen
  seen="$(git -C "$CLONE" rev-parse -q --verify "refs/remotes/origin/ticket/$TICKET/$HANDLE" || true)"
  git -C "$CLONE" push -q origin "--force-with-lease=$ref:$seen" "$1:$ref" 2>>"$LOGBASE.git.err"
}

# run_push_attested <sha> <note-file> <scratch-ref>: push <sha> to ticket/<id>/<handle> together with
# the attest note on it (lib/attest.sh; ticket T30), in ONE atomic push: the branch with run_push's
# lease, and refs/notes/factory-attest grown by one note from origin's tip (leased on that tip, so a
# note another node pushed in between is never lost). <scratch-ref> is this slot's own notes ref
# (refs/notes/factory-run/slot-<n>): slots never share a notes ref, and the node's tracking refs and
# FETCH_HEAD are not touched. A lost race on the notes ref is retried from a fresh fetch, 3 tries; a
# branch that moved under its lease is not retried. The scratch ref is deleted on every return.
run_push_attested() {
  local sha="$1" note="$2" nref="$3" ref="refs/heads/ticket/$TICKET/$HANDLE" seen ntip try rc
  seen="$(git -C "$CLONE" rev-parse -q --verify "refs/remotes/origin/ticket/$TICKET/$HANDLE" || true)"
  for try in 1 2 3; do
    git -C "$CLONE" update-ref -d "$nref" 2>/dev/null || true
    rc=0; git -C "$CLONE" ls-remote --exit-code origin "$ATTEST_REF" >/dev/null 2>>"$LOGBASE.git.err" || rc=$?
    case "$rc" in
      0) git -C "$CLONE" fetch -q --no-write-fetch-head origin "+$ATTEST_REF:$nref" 2>>"$LOGBASE.git.err" || break
         ntip="$(git -C "$CLONE" rev-parse "$nref")" ;;
      2) ntip="" ;;                                   # the first note ever
      *) break ;;
    esac
    git -C "$CLONE" notes --ref="$nref" add -f -F "$note" "$sha" 2>>"$LOGBASE.git.err" || break
    if git -C "$CLONE" push -q --atomic origin "--force-with-lease=$ref:$seen" "--force-with-lease=$ATTEST_REF:$ntip" \
         "$sha:$ref" "$nref:$ATTEST_REF" 2>>"$LOGBASE.git.err"; then
      git -C "$CLONE" update-ref -d "$nref" 2>/dev/null || true
      return 0
    fi
    printf 'run_push_attested: try %s of 3 refused\n' "$try" >>"$LOGBASE.git.err"
    # Only a moved notes ref is worth a retry: a branch that moved under the lease stays moved.
    [ "$(git -C "$CLONE" ls-remote origin "$ref" 2>/dev/null | cut -f1)" = "$seen" ] || break
  done
  git -C "$CLONE" update-ref -d "$nref" 2>/dev/null || true
  return 1
}

# run_dead_end <lapsed-ref> <file>: the material a lapsed ticket branch carries, for fleet's
# --dead-end-file (strike 1 of the resumed run reads it, fenced). Local only: commit subjects,
# the record trailers and a diffstat of the lapsed work against origin/main.
run_dead_end() {
  local ref="$1" file="$2" tip
  tip="$(git -C "$CLONE" rev-parse "$ref")"
  {
    printf 'A previous claim on ticket %s lapsed. Its branch %s (%s) is the base of this run.\n\n' \
      "$TICKET" "${ref#refs/remotes/origin/}" "${tip:0:12}"
    printf 'Outcome recorded on the branch tip:\n'
    git -C "$CLONE" log -1 --format='%(trailers:key=Factory-Outcome,key=Fleet-Reason,key=Fleet-Strikes,key=Node)' "$tip"
    printf '\nCommits beyond origin/main (newest first):\n'
    git -C "$CLONE" log --max-count=50 --format='  %h %s' "refs/remotes/origin/main..$tip"
    printf '\nFiles changed against origin/main:\n'
    git -C "$CLONE" diff --stat=120 "refs/remotes/origin/main...$tip" | tail -n 60
  } >"$file"
}

# run_comment <kind> <json>: the Issue comment for an outcome. Ids, codes and counts only.
run_comment() {
  jq -r --arg kind "$1" '
    "Node `\(.handle)` " + (
      if $kind == "built" then
        "built `\(.ticket)` (fleet run `\(.fleet_run)`): strikes \(.strikes) of \(.max_strikes), adapter \(.adapter), tokens \(.tokens // "not reported"). Pushed `\(.branch)` at `\(.head[0:12])`" + (if .pr then "; PR #\(.pr)." else "." end)
      elif $kind == "desk" then
        "stopped `\(.ticket)`: reason `\(.reason)`, strikes \(.strikes) of \(.max_strikes), adapter \(.adapter)."
        + (if .branch then " Branch `\(.branch)` at `\(.head[0:12])`." else " Nothing pushed." end)
        + " Labeled needs-desk; lock released."
      else
        "released `\(.ticket)`: reason `\(.reason)`, strikes \(.strikes) of \(.max_strikes), adapter \(.adapter). Lock released."
      end)' <<<"$2"
}

# run_pr_body <json>: the PR body. Ids, codes, counts and hashes only.
run_pr_body() {
  jq -r '
    "Ticket: \(.ticket)\nIssue: #\(.issue)\nNode: \(.handle)\n\n"
    + "| | |\n|---|---|\n"
    + "| fleet run | `\(.fleet_run)` |\n"
    + (if .rebased then "| outcome | rebased: the ejected `\(.rebased.from[0:12])` (PR #\(.rebased.pr), rebase strike \(.rebased.strike)) cherry-picked onto main; no fleet run |\n"
       else "| outcome | built (fleet exit 0, reason none) |\n" end)
    + "| strikes | \(.strikes) of \(.max_strikes) |\n| adapter | \(.adapter) |\n"
    + "| tokens | \(.tokens // "not reported by fleet 1.12.0") |\n"
    + "| base | `\(.base[0:12])` (\(.base_kind)) |\n| head | `\(.head[0:12])` |\n"
    + "| tamperguard | \(.tamperguard.verdict) (score \(.tamperguard.score), \(.tamperguard.findings) finding(s)) |\n"
    + "| scope-check | pass |\n"
    + "| rails-proof | pass |\n\n"
    + (if .attest then "Gate manifest: the attest note (`refs/notes/factory-attest`, format `\(.attest.format)`, unsigned) on `\(.head[0:12])`, sha256 `\(.attest.sha256)`; attest-verify recomputes it in CI.\n"
       else "Gate manifest: not recorded.\n" end)
    + "\nTranscripts never leave the node: this body carries ids, reason codes, counts and hashes only."' <<<"$1"
}
