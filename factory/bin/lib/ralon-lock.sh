#!/usr/bin/env bash
# ralon-lock — render the rails lock a ticket's build runs under (ticket T6; ADR-0005 decision 1).
#
#   ralon-lock.sh <ticket-id> [--worktree DIR] [--apply] [--json]
#
# Reads the ticket's `rails` globs (`adlc ticket show <id> --json`, run in DIR so it reads DIR's
# store) and renders the policy file ralon 0.1.7 reads from `ralon run -C DIR`: `agent.lock`, YAML
# `version: 1` + `protect:`, every pattern relative to the lock's own directory. So the lock sits
# at the root of the worktree it protects; it cannot live under .ralon/ because ralon refuses `..`.
#
#   - `factory/policy/**` is always protected, so a ticket with no rails still renders a lock
#     (ralon refuses an empty agent.lock by design).
#   - Each glob is rendered twice: as itself and under `.worktrees/*/`, because fleet cuts its
#     worker worktrees beneath its own working directory. ralon binds those paths when it starts,
#     so the second form covers worktrees that exist then (a resumed run), not ones fleet cuts
#     later (records/TB1.md of specs/factory-step2-v1 measures this).
#   - A glob ralon would refuse or reinterpret is refused here with exit 2: empty, `!` negation,
#     `~`, absolute (`/x`; ralon would silently strip the slash), `:` (ralon reads it as a drive),
#     `\`, a `..` segment, a control character, or one that names nothing (`.`, `./`).
#
# Default is a dry run: print the lock (or, with --json, {ticket, worktree, lock, patterns,
# applied: false}) and change nothing. --apply writes DIR/agent.lock (atomically) and adds
# `/agent.lock` to the repository's info/exclude, so fleet's dirty-tree check never sees it. DIR
# (default: the current directory) must be the top of a git work tree. A tracked agent.lock there
# is the project's own policy and is never overwritten (exit 2).
#
# Exit 0 rendered (and written with --apply); 1 operational error (adlc failed, unknown ticket,
# not a work tree); 2 refused (a glob ralon would refuse, a tracked agent.lock).
# Environment: FACTORY_ADLC (default `npx -y @adlc/cli@1.12.0`).
set -euo pipefail
PROG=ralon-lock
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/common.sh"

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

ticket="" wt=. apply=0 json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) wt="${2:-}"; shift ;;
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --json) json=1 ;;
    -h|--help) usage ;;
    -*) warn "unknown argument: $1"; usage ;;
    *) [ -z "$ticket" ] || { warn "one ticket id only"; usage; }; ticket="$1" ;;
  esac
  shift
done
need git jq
[ -n "$ticket" ] || usage
valid_ticket_id "$ticket" || die "bad ticket id '$ticket'"
[ -d "$wt" ] || die "--worktree is not a directory: $wt"
wt="$(cd "$wt" && pwd -P)"
top="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)" || die "$wt is not inside a git work tree"
[ "$(cd "$top" && pwd -P)" = "$wt" ] || die "$wt is not the top of its work tree ($top): ralon patterns are relative to the lock"

read -r -a ADLC <<<"${FACTORY_ADLC:-npx -y @adlc/cli@1.12.0}"
shown="$(cd "$wt" && "${ADLC[@]}" ticket show "$ticket" --json 2>/dev/null)" || die "adlc ticket show $ticket failed in $wt"
# adlc may print a second JSON document after the first; read the first only.
rails="$(jq -cs '.[0].ticket.rails // [] | if type == "array" then . else error("rails is not an array") end' <<<"$shown")" ||
  die "adlc ticket show $ticket: no ticket object, or rails is not an array"

# norm <glob>: print the pattern ralon would store; or print why ralon would refuse it, return 2.
norm() {
  local g="$1" p
  g="${g#"${g%%[![:space:]]*}"}"; g="${g%"${g##*[![:space:]]}"}"
  [ -n "$g" ] || { printf 'is empty'; return 2; }
  case "$g" in
    '!'*) printf 'is a negation (ralon 0.1.7 has none)'; return 2 ;;
    '~'*) printf 'starts with ~ (ralon does not expand it)'; return 2 ;;
    /*) printf 'is absolute (patterns are relative to agent.lock)'; return 2 ;;
    *:*) printf 'contains : (ralon reads it as an absolute path)'; return 2 ;;
    *\\*) printf 'contains a backslash'; return 2 ;;
  esac
  p="${g#./}"
  while [[ "$p" == */ ]]; do p="${p%/}"; done
  [ -n "$p" ] && [ "$p" != . ] || { printf 'names nothing inside the project'; return 2; }
  case "/$p/" in */../*) printf 'has a .. segment'; return 2 ;; esac
  printf '%s' "$p"
}

jq -e 'all(.[]; type == "string")' <<<"$rails" >/dev/null || die "ticket $ticket has a rail that is not a string: $rails"
if jq -e 'any(.[]; test("[\u0000-\u001f\u007f]"))' <<<"$rails" >/dev/null; then
  refuse "ticket $ticket has a rail with a control character: $rails"
fi

patterns=() bad=0
add() { local x; for x in "${patterns[@]}"; do [ "$x" = "$1" ] && return 0; done; patterns+=("$1"); }
while IFS= read -r -d '' g; do
  if p="$(norm "$g")"; then
    add "$p"; add ".worktrees/*/$p"
  else
    warn "rail $(jq -cn --arg g "$g" '$g') $p: ralon would refuse it"; bad=1
  fi
done < <(jq -j '("factory/policy/**"), .[] | . + "\u0000"' <<<"$rails")
[ "$bad" = 0 ] || refuse "ticket $ticket: refusing to render a lock with a rail ralon would refuse"

lock="# agent.lock for ticket $ticket, rendered by factory/bin/lib/ralon-lock.sh from the ticket's rails.
# ralon 0.1.7 policy file: patterns are relative to this file. Regenerate it; never edit it.
version: 1
protect:"
for p in "${patterns[@]}"; do lock+=$'\n'"  - $(jq -cn --arg p "$p" '$p')"; done
lock+=$'\n'

applied=false
if [ "$apply" = 1 ]; then
  if git -C "$wt" ls-files --error-unmatch agent.lock >/dev/null 2>&1; then
    refuse "$wt/agent.lock is tracked: it is the project's own ralon policy, not the factory's to overwrite"
  fi
  tmp="$(mktemp "$wt/.agent.lock.XXXXXX")"
  printf '%s' "$lock" >"$tmp"
  mv -f "$tmp" "$wt/agent.lock"
  exclude="$(git -C "$wt" rev-parse --path-format=absolute --git-path info/exclude)" || die "cannot resolve info/exclude for $wt"
  mkdir -p "$(dirname "$exclude")"
  grep -qxF /agent.lock "$exclude" 2>/dev/null || printf '/agent.lock\n' >>"$exclude"
  applied=true
fi

if [ "$json" = 1 ]; then
  printf '%s\n' "${patterns[@]}" | jq -Rnc --arg t "$ticket" --arg wt "$wt" --argjson a "$applied" \
    '{ticket: $t, worktree: $wt, lock: "\($wt)/agent.lock", patterns: [inputs], applied: $a}'
elif [ "$apply" = 0 ]; then
  printf '%s' "$lock"
else
  printf 'ralon-lock: wrote %s/agent.lock (%s patterns) for %s\n' "$wt" "${#patterns[@]}" "$ticket" >&2
fi
