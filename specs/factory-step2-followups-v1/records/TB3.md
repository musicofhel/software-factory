# TB3 — needs-desk survives the mirror (ticket T14; ruling Q3)

Session 6, 2026-10-25. No prep existed for this row (`specs/factory-step2-followups-v1/prep/` is
absent). Nothing was pushed and nothing was written to GitHub (I1). The only `gh` calls against a
real repo were two read-only queries on the public `cli/cli` repo (§3). Every file touched is inside
T14's scope globs, so no desk update was needed.

Commit: the `Ticket: T14` commit that carries this file.

## 1. What was built

Step-2 ruling Q3: "the node sets needs-desk; mirror.sh preserves a node-added needs-desk"
(`specs/factory-step2-v1/RULINGS.md`).

- **`factory/bin/lib/desk-marker.sh` (new)**: the one place the marker format is defined.
  - The marker is one line, the last line of run.sh's desk comment:
    `<!-- factory-needs-desk v1 ticket=<id> hash=<ticketHash|unknown> reason=<code> node=<handle> -->`.
    Each field is an id, a code or a hash (I8). `desk_marker` writes it and refuses (exit 1, prints
    nothing) a field that would not parse back. `desk_marker_read` parses a body. `DESK_JQ` defines
    the jq functions `desk_marker` and `desk_event`, which mirror.sh runs inside its plan.
  - `DESK_MARKER_RE`, `DESK_CLAIM_RE` (claim.sh's claim comment, "Claimed by node `<h>`: fleet run `…`"),
    `DESK_TRUSTED` (`OWNER`, `MEMBER`, `COLLABORATOR`) and `DESK_COMMENT_CAP` (100) are defined here.
    The file's header also states the hold rule.
- **`factory/bin/mirror.sh`**
  - The Issue body gains `Ticket-Hash: <ticketHash>` after the `Depends-on:` lines. This is the store
    state a node claims. Every existing Issue gets one body update on the first run after this lands.
  - A new read, done before any write like the others: `gh issue list --state open --label needs-desk
    --json number,comments` (exit 1 on failure, or if the list is at its limit, i.e. possibly truncated).
  - The hold: an Issue keeps `needs-desk` and gets no `ready` only when all of these are true:
    - it is open and labeled `needs-desk`;
    - it has fewer than 100 comments;
    - looking only at comments from trusted authors that are markers or claim comments, the newest one
      is a marker for this ticket at the store's current ticketHash.
    The plan line carries `desk_hold: {node, reason}`, and the reasons gain
    `node: \`<h>\` stopped it (<reason>); needs-desk holds until the ticket changes or a new claim`.
    Anything else recomputes the label exactly as before: no marker, an older hash (a desk edit), a
    newer claim comment (a new claim cycle), a marker for another ticket, an untrusted author, or the
    label already removed. A completed ticket still closes.
- **`factory/bin/run.sh`, `factory/bin/lib/run.sh`**
  - `run_ticket_hash_of_issue` reads the Issue's `Ticket-Hash:` at claim time into `TICKET_HASH`. It
    is kept in the slot state (`ticket_hash`) so that a paused-then-resumed claim still has it. State
    files from before this change read as `""`, which becomes `unknown` in the marker.
  - `comment desk` appends `desk_marker …` (or records `desk-marker-failed` and sends the comment
    without the marker).
  - On all four needs-desk paths (strikes-exhausted/flail incl. the resume cap, tamper, real scope
    failure), the order is now comment, then label. `label_desk` is one `gh issue edit --add-label
    needs-desk --remove-label ready`.
- **`factory/RULES.md`**: a new section, "A node's needs-desk (the claim-protocol exception)".

## 2. Decisions (and why)

1. **The store state is the ticketHash, carried by the Issue.** "A desk edit" means a new
   ticketHash. The node can only know the hash it worked on if something hands it over. The mirror
   already writes the Issue the node reads at claim time, so the mirror writes `Ticket-Hash:` there.
   run.sh does not call adlc for it. A desk edit made after the claim but before the stop therefore
   ends the hold, which is correct: the node failed on the old ticket.
2. **A new claim cycle is a trusted claim comment newer than the marker.** claim.sh writes exactly
   one claim comment per claim, and T14's scope does not include claim.sh. So the shape of that
   comment is matched in desk-marker.sh (`DESK_CLAIM_RE`), and test_run's `desk-marker` case checks
   that the real claim.sh's comment matches it. Lock refs were the alternative, but a released claim
   leaves no ref, and they would add a second API surface to the mirror.
3. **Trust comes from `authorAssociation`.** Anyone can comment on a public repo's Issue, so an
   untrusted marker could park any ticket in needs-desk. Markers and claims count only from
   OWNER/MEMBER/COLLABORATOR (node owners are collaborators). An untrusted comment can neither hold
   a label nor end a hold.
4. **run.sh removes `ready` in the same edit that adds `needs-desk`.** claim.sh claims any open
   Issue labeled `ready` and does not look at `needs-desk`. Until the next mirror run, a desk-labeled
   Issue would otherwise stay claimable by another node, and that claim would then end the hold.
   RULES.md states this as part of the exception. This does not change which fleet reasons lead to
   needs-desk, which is T14's out-of-scope item.
5. **Comment before label.** If the label went on first and a mirror run fell between the two calls,
   the mirror would see the label without a marker and strip it. Done the other way round, the worst
   case is a marker on an Issue without the label, which never adds one.
6. **The comment cap.** `gh issue list --json comments` returns only the oldest 100 comments (§3).
   On a longer thread the newest marker or claim may be hidden, so such an Issue is recomputed and
   never held.

## 3. Evidence

- gh's comments shape, read-only on a public repo (gh 2.45.0):
  `gh issue list --repo cli/cli --state all --limit 1 --search "comments:>120" --json number,comments`
  returns #14090 with 100 comments, keys `author, authorAssociation, body, createdAt, id,
  includesCreatedEdit, isMinimized, minimizedReason, reactionGroups, url, viewerDidAuthor`, first
  2026-08-06T14:04:57Z, last 2026-10-14T15:30:27Z. `gh issue view 14090 --repo cli/cli --json comments`
  returns 141, last 2026-10-24T18:28:42Z. So list returns the *oldest* 100, which is why the cap exists.
- `tests/test_mirror.sh` case `node-needs-desk` (T14 AC1–3):
  - Run 1: T1 (node marker) is held, its line reads `["needs-desk",{"node":"dev-box","reason":"strikes-exhausted"},[],[]]`.
    T2 (needs-desk, no marker), T3 (marker by `NONE`), T4 (old hash), T5 (newest marker names T9,
    same hash), T6 (label removed), T7 (100 comments) are all recomputed to `ready`.
  - Runs 2 and 3: T1 is still needs-desk, there are zero writes, and all 7 lines are `unchanged`.
  - A store edit (new ticketHash + fresh coldstart) gives `["ready",null,["ready"],["needs-desk"]]`.
    A second stop at the new hash is held again. A claim comment after it gives `ready`.
  - A store edit that leaves coldstart stale gives needs-desk for the store's reason only, with no
    hold. A held ticket that is completed closes. The new read happens once per run, and its failure
    exits 1 with nothing written.
  - Case `creates` checks the `Ticket-Hash:` line.
- `tests/test_run.sh` (T14 AC4):
  - `desk_case` (strikes-exhausted, flail), `tamper` and `resume-cap` each assert the marker
    `{ticket: T-run, hash: hash-T-run, reason: <r>, node: dev-box}` and the labels
    `in-progress,needs-desk,w:light`. `resume-cap` proves the hash survives three resumes via the slot state.
  - The new case `desk-marker` checks:
    - real scope failure → desk `scope-fail` with the marker as the comment's last line;
    - in the fake gh log, the marker comment comes before the label edit;
    - the edit argv is `--add-label needs-desk --remove-label ready`;
    - claim.sh's real claim comment reads as `{"kind":"claim"}`;
    - an Issue without `Ticket-Hash:` gives `hash=unknown`;
    - scope-check-not-built and a run-level `preflight` failure carry no marker and no label.
- Mutation checks (each mutation was applied, the suite run, and the file restored byte-identical):
  | mutation | failing checks |
  |---|---|
  | mirror ignores the hash | 6 |
  | claim comments ignored | 2 |
  | trust filter removed | 3 |
  | comment cap removed | 3 |
  | hold never computed | 9 |
  | ticket-id check removed | 2 |
  | run.sh labels before commenting | 1 |
  | label edit keeps `ready` | 2 |
  | slot state drops `ticket_hash` | 1 |

  Removing the "Issue has the needs-desk label" test is equivalent (0 failures), because the new read
  already lists only needs-desk Issues. The check stays as defence in depth.
- AC5: `grep -n needs-desk factory/RULES.md` → lines 20, 22, 24, 25, 26, 28.
- Gates at the T14 commit: `make test` 15 files PASS, `make lint` 0 (shellcheck -S warning +
  actionlint). No live file touches this.

## 4. Left as is (outside T14's scope)

- `docs/adr/0005-run-loop-cli-reality.md` open question 1 (SPEC-v0.2's needs-desk contradiction) is
  now answered by ruling Q3 and this row, but the ADR text was not edited.
  `factory/skills/run/SKILL.md`'s outcome table still says "label needs-desk, comment". Both are a
  later doc pass's job (TB5's close-out can mention them).
- claim.sh still claims an Issue labeled both `ready` and `needs-desk`. run.sh's single edit closes
  that window for node-set labels. A human who hand-adds `ready` to a held Issue starts a claim cycle,
  and that ends the hold, as intended.
