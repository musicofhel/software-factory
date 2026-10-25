#!/usr/bin/env bash
# halt-check — is the kill switch set? (SPEC-v0.2 "Kill switch")
#
#   halt-check.sh [--json] [--remote NAME] [--branch NAME]
#
# Fetches <remote>/<branch> (default origin/main), then looks for factory/HALT in that commit's tree
# with `git ls-tree`. The working tree, the index and local branches are never consulted: a HALT
# that is not on the remote main halts nothing, and a HALT that is on it halts everyone.
#
# Exit 0: absent (go on; stdout empty, or the JSON line with --json).
# Exit 3: present (sleep; stdout is the sleep interval in minutes from budget.json
#         .governor.haltSleepMinutes, or the JSON line with --json).
# Exit 1: the fetch failed or the remote branch is unreadable. The halt state is UNKNOWN, so a
#         caller must treat any exit other than 0 as "do not claim".
# Runs in the git repository of the current directory (the node's checkout of the factory repo).
set -euo pipefail
PROG=halt-check
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

json=0 remote=origin branch=main
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1 ;;
    --remote) remote="${2:-}"; shift ;;
    --branch) branch="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need git jq
[ -n "$remote" ] && [ -n "$branch" ] || die "--remote and --branch need a value"
minutes="$(budget .governor.haltSleepMinutes)"
[[ "$minutes" =~ ^[1-9][0-9]*$ ]] || die "budget.json .governor.haltSleepMinutes must be a positive integer, got '$minutes'"

# An explicit refspec, forced: works in single-branch clones and follows a rewritten main.
tracking="refs/remotes/$remote/$branch"
git fetch --quiet --no-tags "$remote" "+refs/heads/$branch:$tracking" ||
  die "cannot fetch $remote $branch; halt state unknown, do not claim"
sha="$(git rev-parse --verify --quiet "$tracking^{commit}")" || die "$tracking is not a commit after the fetch"
entry="$(git ls-tree "$sha" factory/HALT)" || die "cannot read the tree of $remote/$branch ($sha)"

halted=false
[ -z "$entry" ] || halted=true
if [ "$json" = 1 ]; then
  jq -cn --argjson h "$halted" --arg ref "$remote/$branch" --arg sha "$sha" --argjson m "$minutes" \
    '{halted: $h, ref: $ref, sha: $sha, path: "factory/HALT"} + (if $h then {sleep_minutes: $m} else {} end)'
elif [ "$halted" = true ]; then
  printf '%s\n' "$minutes"
fi
if [ "$halted" = true ]; then
  warn "factory/HALT is on $remote/$branch ($sha): halted, sleep $minutes min and check again"
  exit 3
fi
exit 0
