#!/usr/bin/env bash
# revoke-collaborator — cut a retired node's repo access (step-1 ruling Q4): its owner stops being a
# collaborator, so the node's fine-grained token (the owner's) can no longer reach the repo.
#
#   revoke-collaborator.sh [--dry-run | --apply] [--json] [--repo owner/name] [--codeowners FILE] <handle> <owner>
#
# The janitor calls it as JANITOR_REVOKE_HOOK (`revoke-collaborator.sh --apply <handle> <owner>`)
# for every node it retires. <handle> names the node (for the record only); <owner> is the GitHub
# login from its manifest. --apply runs exactly one call:
#
#   gh api -X DELETE repos/{repo}/collaborators/{owner}
#
# --dry-run (the default) calls nothing and prints that call. Refused (exit 2, nothing called):
# an owner listed in CODEOWNERS (`@owner` on any rule line; the first of .github/CODEOWNERS,
# CODEOWNERS, docs/CODEOWNERS, as GitHub picks it, unless --codeowners names one), the repo's own
# owner, and a handle or owner that is not a GitHub login. No CODEOWNERS file at all is exit 1:
# without the owner list the refusal cannot be checked. Teams (`@org/team`) are not expanded: a
# user-owned repo has none, and expanding one would be a read in a dry run.
#
# Output: the call (plain), or one JSON line {mode, handle, owner, repo, call,
# result: planned|done|failed|refused, detail?} with --json.
# Exit 0 planned or done; 1 usage, no CODEOWNERS, or the DELETE failed; 2 refused.
#
# Environment: FACTORY_REPO; REVOKE_GH_TOKEN (when set, the DELETE runs on it instead of GH_TOKEN:
# removing a collaborator needs the Administration permission, which GITHUB_TOKEN never has).
set -euo pipefail
PROG=revoke-collaborator
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

apply=0 json=0 repo="" codeowners="" args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --json) json=1 ;;
    --repo) repo="${2:-}"; shift ;;
    --codeowners) codeowners="${2:-}"; shift ;;
    -h|--help) usage ;;
    -*) warn "unknown argument: $1"; usage ;;
    *) args+=("$1") ;;
  esac
  shift
done
[ "${#args[@]}" = 2 ] || { warn "need <handle> <owner>"; usage; }
handle="${args[0]}" owner="${args[1]}"
need jq
REPO="$(resolve_repo "$repo")"
MODE="$([ "$apply" = 1 ] && echo apply || echo dry-run)"
CALL=(gh api -X DELETE "repos/$REPO/collaborators/$owner")

report() {  # report <result> [detail]
  if [ "$json" = 1 ]; then
    jq -cn --arg mode "$MODE" --arg h "$handle" --arg o "$owner" --arg repo "$REPO" --arg call "${CALL[*]}" \
      --arg r "$1" --arg d "${2:-}" \
      '{mode: $mode, handle: $h, owner: $o, repo: $repo, call: $call, result: $r} + (if $d == "" then {} else {detail: $d} end)'
  else
    printf '# %s: remove collaborator %s (node %s) from %s%s\n' "$1" "$owner" "$handle" "$REPO" "${2:+ ($2)}"
    [ "$1" = refused ] || printf '%s\n' "${CALL[*]}"
  fi
}
refused() { report refused "$1"; refuse "$1"; }

valid_handle "$handle" || refused "not a node handle: '$handle'"
valid_handle "$owner" || refused "not a GitHub login: '$owner'"

if [ -z "$codeowners" ]; then
  for f in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
    if [ -f "$FACTORY_ROOT/$f" ]; then codeowners="$FACTORY_ROOT/$f"; break; fi
  done
fi
[ -n "$codeowners" ] && [ -f "$codeowners" ] ||
  die "no CODEOWNERS file (looked in .github/, the root and docs/); refusing to revoke without the owner list"

# Every @login on a rule line (comments stripped), matched case-blind: GitHub logins are.
owners="$(sed 's/#.*//' "$codeowners" | awk '{for (i = 2; i <= NF; i++) print $i}' | grep '^@' || true)"
if grep -qixF "@$owner" <<<"$owners"; then
  refused "$owner is a code owner in ${codeowners#"$FACTORY_ROOT/"}; a CODEOWNERS owner is never removed by the janitor"
fi
repo_owner="${REPO%%/*}"
[ "${owner,,}" != "${repo_owner,,}" ] || refused "$owner owns $REPO"

if [ "$apply" = 0 ]; then report planned; exit 0; fi
need gh
err="$(mktemp)"; trap 'rm -f "$err"' EXIT
[ -z "${REVOKE_GH_TOKEN:-}" ] || export GH_TOKEN="$REVOKE_GH_TOKEN"
if "${CALL[@]}" >/dev/null 2>"$err"; then
  report "done"
else
  report failed "$(tail -n1 "$err")"
  exit 1
fi
