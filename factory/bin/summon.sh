#!/usr/bin/env bash
# summon — pull one named human in with one Discord message (SPEC-v0.2 "Summoner").
#
#   summon.sh --kind halt|needs-approval|needs-acceptance [--apply] [--json]
#             [--to HANDLE] [--ticket ID] [--link URL] [--reason TEXT] [--event FILE]
#
# Exactly two kinds of immediate message exist: a gate ask (needs-approval = spec approval, P1;
# needs-acceptance = acceptance, P6) and a halt notice (halt). Any other kind is refused with
# exit 2 and nothing is sent. One run sends at most one message, to one human, naming the ticket
# id, the decision needed and a link. Dry run by default (prints the payload); --apply POSTs it to
# $DISCORD_WEBHOOK (the repo secret SUMMONER_WEBHOOK). The webhook URL is never printed.
#
# Each field comes from its flag, else from the GitHub event ($GITHUB_EVENT_PATH or --event):
#   to      --to > $SUMMONER_TO > the first owner on the CODEOWNERS line for factory/HALT (halt)
#           or factory/** (gate asks)
#   ticket  --ticket > a `Ticket: <id>` line in the Issue/PR body (the mirror writes it) > #<n>;
#           on a push, the head commit's `Ticket:` trailer > the short sha
#   link    --link > the Issue/PR html_url > the head commit url > the compare url
#   reason  (halt) --reason > the first line of factory/HALT at the pushed commit > the label event
# A push whose commit has no factory/HALT (the halt was lifted) is not a halt: exit 0, no message.
#
# Exit 0: sent (or planned, or nothing to send). 1: a field is missing, the webhook is unset or
# the POST failed. 2: not one of the three kinds.
set -euo pipefail
PROG=summon
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

apply=0 json=0 kind="" kind_set=0 to="" ticket="" link="" reason="" event="${GITHUB_EVENT_PATH:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) kind="${2:-}"; kind_set=1; shift ;;
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --json) json=1 ;;
    --to) to="${2:-}"; shift ;;
    --ticket) ticket="${2:-}"; shift ;;
    --link) link="${2:-}"; shift ;;
    --reason) reason="${2:-}"; shift ;;
    --event) event="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
[ "$kind_set" = 1 ] || { warn "--kind is required"; usage; }
case "$kind" in
  halt) title="Halt notice"; decision="the factory is halted: decide when to lift it (a PR deleting factory/HALT)" ;;
  needs-approval) title="Gate ask: spec approval (P1)"; decision="approve or reject this spec" ;;
  needs-acceptance) title="Gate ask: acceptance (P6)"; decision="accept or reject this change" ;;
  *) refuse "kind '$kind' is not a summons; the summoner sends halt, needs-approval or needs-acceptance only (everything else goes to the digest)" ;;
esac
need jq

ev='{}'
if [ -n "$event" ]; then
  [ -f "$event" ] || die "event file not found: $event"
  ev="$(jq -c . "$event")" || die "event file is not JSON: $event"
fi
item="$(jq -c '.issue // .pull_request // {}' <<<"$ev")"
after="$(jq -r 'if (.ref // "") != "" and (.after // "") != "" then .after else "" end' <<<"$ev")"
clip() { local s="$1" n="$2"; if [ "${#s}" -gt "$n" ]; then printf '%s…' "${s:0:$n}"; else printf '%s' "$s"; fi; }

# A push that touches factory/HALT is a halt only if the pushed commit has it.
halt_text=""
if [ "$kind" = halt ] && [ -n "$after" ]; then
  need git
  git cat-file -e "$after^{commit}" 2>/dev/null || die "pushed commit $after is not in this checkout"
  if [ -z "$(git ls-tree "$after" factory/HALT)" ]; then
    msg="factory/HALT is absent at ${after:0:12}: the halt was lifted, not set; no summons (the digest reports it)"
    if [ "$json" = 1 ]; then jq -cn --arg k "$kind" --arg s "$after" --arg m "$msg" \
      '{mode: "skip", kind: $k, sha: $s, posted: false, reason: $m}'; else printf '%s\n' "$msg"; fi
    exit 0
  fi
  halt_text="$(git show "$after:factory/HALT" 2>/dev/null | sed -n '/[^[:space:]]/{p;q;}' || true)"
fi

# to: exactly one human
if [ -z "$to" ]; then to="${SUMMONER_TO:-}"; fi
if [ -z "$to" ] && [ -f "$FACTORY_ROOT/CODEOWNERS" ]; then
  pattern='factory/**'; [ "$kind" = halt ] && pattern='factory/HALT'
  to="$(awk -v p="$pattern" '$1 == p && NF > 1 { print $2; exit }' "$FACTORY_ROOT/CODEOWNERS")"
fi
to="${to#@}"
[ -n "$to" ] || die "no human to summon: pass --to, set SUMMONER_TO, or name an owner in CODEOWNERS"
[[ "$to" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}(/[A-Za-z0-9._-]+)?$ ]] ||
  die "--to must be exactly one GitHub handle (or org/team), got '$to'"

# ticket: `Ticket: <id>` lines of a JSON string (the body's first, the commit's last trailer)
TICKET_LINES='[splits("\r?\n") | capture("^ticket:[ \t]*(?<id>[A-Za-z0-9._-]+)[ \t]*$"; "i") | .id]'
if [ -z "$ticket" ]; then
  ticket="$(jq -r "$TICKET_LINES | first // empty" <<<"$(jq -c '.body // ""' <<<"$item")")"
fi
if [ -z "$ticket" ]; then ticket="$(jq -r 'if .number then "#\(.number)" else empty end' <<<"$item")"; fi
if [ -z "$ticket" ] && [ -n "$after" ]; then
  ticket="$(jq -r "$TICKET_LINES | last // empty" <<<"$(jq -c '.head_commit.message // ""' <<<"$ev")")"
  [ -n "$ticket" ] || ticket="commit ${after:0:12}"
fi
[ -n "$ticket" ] || die "no ticket id: pass --ticket, or run from an Issue, PR or push event"

# link
if [ -z "$link" ]; then
  link="$(jq -r --argjson i "$item" '$i.html_url // .head_commit.url // .compare // empty' <<<"$ev")"
fi
[ -n "$link" ] || die "no link: pass --link, or run from an Issue, PR or push event"
[[ "$link" =~ ^https?://[^[:space:]]+$ ]] || die "the link must be one http(s) URL, got '$link'"

# reason (halt only): why the factory stopped
if [ "$kind" = halt ] && [ -z "$reason" ]; then
  if [ -n "$after" ]; then
    reason="factory/HALT landed on main at ${after:0:12}"
    [ -z "$halt_text" ] || reason="$reason: $(clip "$halt_text" 300)"
  elif [ "$item" != '{}' ]; then
    reason="$(jq -r '"factory:halt set on #\(.number): \(.title // "")"' <<<"$item")"
  else
    die "a halt notice needs --reason (or a push or label event)"
  fi
fi
subject="$(jq -r '.title // empty' <<<"$item")"

content="**$title** for @$to"$'\n'"Ticket: $ticket"$'\n'"Decision needed: $decision"
[ -z "$reason" ] || content="$content"$'\n'"Why: $(clip "$reason" 400)"
[ -z "$subject" ] || [ "$kind" = halt ] || content="$content"$'\n'"Subject: $(clip "$subject" 200)"
content="$content"$'\n'"$link"
# allowed_mentions.parse = []: text from Issues (titles, HALT reasons) can never ping @everyone.
payload="$(jq -cn --arg c "$(clip "$content" 1900)" \
  '{username: "factory summoner", content: $c, allowed_mentions: {parse: []}}')"

posted=false
if [ "$apply" = 1 ]; then
  need curl
  [ -n "${DISCORD_WEBHOOK:-}" ] || die "DISCORD_WEBHOOK is not set (the repo secret SUMMONER_WEBHOOK); nothing sent"
  if ! err="$(curl -fsS --max-time 20 -X POST -H 'Content-Type: application/json' \
                --data-binary @- "$DISCORD_WEBHOOK" <<<"$payload" 2>&1 >/dev/null)"; then
    die "webhook POST failed: $(tail -n1 <<<"${err//"$DISCORD_WEBHOOK"/<webhook>}")"
  fi
  posted=true
fi

if [ "$json" = 1 ]; then
  jq -cn --arg mode "$([ "$apply" = 1 ] && echo apply || echo dry-run)" --arg k "$kind" --arg to "$to" \
    --arg t "$ticket" --arg d "$decision" --arg l "$link" --argjson posted "$posted" --argjson p "$payload" \
    '{mode: $mode, kind: $k, to: $to, ticket: $t, decision: $d, link: $l, posted: $posted, payload: $p}'
else
  printf '%s\n' "$content"
  if [ "$posted" = true ]; then echo "-- posted to the webhook"; else echo "-- dry run: not sent (--apply to post)"; fi
fi
