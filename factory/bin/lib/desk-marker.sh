# shellcheck shell=bash
# The needs-desk marker (ticket T14, step-2 ruling Q3). Sourced, never executed. This file is the one
# place its format is defined: run.sh writes it (desk_marker) as the last line of the result comment
# whenever it labels an Issue needs-desk, and mirror.sh reads it (DESK_JQ with DESK_MARKER_RE and
# DESK_CLAIM_RE) to keep that label until the ticket's store state changes.
#
#   <!-- factory-needs-desk v1 ticket=<id> hash=<ticketHash|unknown> reason=<code> node=<handle> -->
#
# ticket and hash name the store state the node worked on: the Issue's `Ticket:` and `Ticket-Hash:`
# lines as mirror.sh wrote them when the node claimed it (`unknown` when the Issue had no hash line,
# which no store hash equals, so such a label is recomputed). reason is the loop's reason code and
# node its handle. Every field is an id, a code or a hash (I8).
#
# The mirror keeps a node's needs-desk while all of these hold (factory/RULES.md, the claim-protocol
# exception): the Issue is open and labeled needs-desk; it has fewer than DESK_COMMENT_CAP comments
# (gh lists at most 100 per Issue, so a longer thread may hide the newest); and of its comments by
# DESK_TRUSTED authors (repo owner, org members, collaborators: a stranger's comment counts for
# nothing either way) that are a marker or a claim, the newest is a marker for this ticket at the
# store's current ticketHash. A desk edit changes the hash; a new claim cycle is a claim comment
# (claim.sh: "Claimed by node `<handle>`: fleet run `<id>`, ...") after the marker. Either drops
# the hold and the label is recomputed from the store as for any other Issue.
DESK_MARKER_RE='^<!-- factory-needs-desk v1 ticket=(?<ticket>[A-Za-z0-9][A-Za-z0-9._:/#-]{0,127}) hash=(?<hash>[A-Za-z0-9._-]{1,128}) reason=(?<reason>[a-z][a-z0-9-]{0,47}) node=(?<node>[A-Za-z0-9][A-Za-z0-9-]{0,38}) -->$'
DESK_CLAIM_RE='^Claimed by node `[A-Za-z0-9][A-Za-z0-9-]{0,38}`: fleet run `'
DESK_TRUSTED='["OWNER","MEMBER","COLLABORATOR"]'
# shellcheck disable=SC2034  # read by mirror.sh
DESK_COMMENT_CAP=100

# jq: `desk_marker` = the last marker line of a comment body as {ticket, hash, reason, node}, else
# null; `desk_event` = {kind: "desk", ...marker} or {kind: "claim"} for a comment object, else
# empty. Callers pass --arg desk_re "$DESK_MARKER_RE" --arg claim_re "$DESK_CLAIM_RE"
# --argjson desk_trusted "$DESK_TRUSTED".
# shellcheck disable=SC2016  # jq source, not shell
DESK_JQ='
def desk_marker: [gsub("\r"; "") | split("\n")[] | capture($desk_re)?] | last;
def desk_event:
  select((.authorAssociation // "") | IN($desk_trusted[]))
  | (.body // "") as $b | ($b | desk_marker) as $m
  | if $m != null then {kind: "desk"} + $m
    elif ($b | gsub("\r"; "") | split("\n")[0] | test($claim_re)) then {kind: "claim"}
    else empty end;
'

# desk_marker <ticket> <ticketHash> <reason> <handle>: the marker line. A hash that is not one is
# written as `unknown`; a ticket, reason or handle that is not an id/code fails (exit 1, nothing
# printed), and the caller sends its comment without a marker, so the label is recomputed.
desk_marker() {
  local hash="$2" line
  [[ "$hash" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || hash=unknown
  line="<!-- factory-needs-desk v1 ticket=$1 hash=$hash reason=$3 node=$4 -->"
  jq -en --arg l "$line" --arg desk_re "$DESK_MARKER_RE" '$l | test($desk_re)' >/dev/null || return 1
  printf '%s\n' "$line"
}

# desk_marker_read <body>: the body's last marker as JSON, or nothing.
desk_marker_read() {
  jq -cn --arg b "$1" --arg desk_re "$DESK_MARKER_RE" --arg claim_re "$DESK_CLAIM_RE" \
    --argjson desk_trusted "$DESK_TRUSTED" "$DESK_JQ"'$b | desk_marker // empty'
}
