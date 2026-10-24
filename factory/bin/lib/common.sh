# shellcheck shell=bash
# Shared helpers for factory/bin/*.sh. Sourced, never executed. Callers set PROG first.
#
# Conventions every script follows (AGENTS.md): exit 0 pass, 1 operational error (bad usage, a
# failed call), 2 gate fail (the thing asked for is refused). Writers are dry-run unless given
# --apply. Readers take --json.
#
# Environment:
#   FACTORY_REPO   owner/name of the factory repo (else parsed from `git remote get-url origin`)
#   FACTORY_NOW    the clock, in epoch seconds (tests pin it; unset = the real clock)

FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FACTORY_BUDGET="$FACTORY_ROOT/factory/policy/budget.json"

die()  { printf '%s: %s\n' "${PROG:-factory}" "$*" >&2; exit 1; }
refuse() { printf '%s: %s\n' "${PROG:-factory}" "$*" >&2; exit 2; }
warn() { printf '%s: %s\n' "${PROG:-factory}" "$*" >&2; }

need() { local c; for c in "$@"; do command -v "$c" >/dev/null || die "$c not found on PATH"; done; }

now_epoch() {
  if [ -n "${FACTORY_NOW:-}" ]; then
    [[ "$FACTORY_NOW" =~ ^[0-9]+$ ]] || die "FACTORY_NOW must be epoch seconds, got '$FACTORY_NOW'"
    printf '%s\n' "$FACTORY_NOW"
  else
    date -u +%s
  fi
}

# jq does the date math so BSD (macOS nodes) and GNU date behave the same.
epoch_to_iso() { jq -nr --argjson e "$1" '$e | todate'; }
iso_to_epoch() { jq -nr --arg d "$1" '$d | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601'; }

# budget <jq path>: one value from factory/policy/budget.json; a missing key is an error.
budget() { jq -er "$1" "$FACTORY_BUDGET" || die "budget.json has no $1"; }

# resolve_repo [explicit]: owner/name from the flag, FACTORY_REPO, or the origin remote.
resolve_repo() {
  local r="${1:-${FACTORY_REPO:-}}" url
  if [ -z "$r" ]; then
    url="$(git -C "$FACTORY_ROOT" remote get-url origin 2>/dev/null)" || die "no --repo, no FACTORY_REPO, no origin remote"
    r="${url%.git}"; r="${r#https://github.com/}"; r="${r#git@github.com:}"; r="${r#ssh://git@github.com/}"
  fi
  [[ "$r" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "not an owner/name repo: '$r'"
  printf '%s\n' "$r"
}

valid_handle() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]; }
valid_issue()  { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# load_node <manifest|''> <handle|''> <slots|''>: sets NODE_HANDLE and NODE_SLOTS. Flags win over
# the manifest (nodes/<handle>.json shape, factory/nodes/manifest.schema.json), which wins over
# FACTORY_HANDLE / FACTORY_SLOTS. Empty results are left empty; callers decide what is required.
load_node() {
  local manifest="${1:-${FACTORY_MANIFEST:-}}" h="$2" s="$3" mh="" ms=""
  if [ -n "$manifest" ]; then
    [ -f "$manifest" ] || die "manifest not found: $manifest"
    mh="$(jq -r '.handle // empty' "$manifest")" || die "manifest is not JSON: $manifest"
    ms="$(jq -r '.slots // empty' "$manifest")"
  fi
  NODE_HANDLE="${h:-${mh:-${FACTORY_HANDLE:-}}}"
  NODE_SLOTS="${s:-${ms:-${FACTORY_SLOTS:-}}}"
  if [ -n "$NODE_HANDLE" ]; then valid_handle "$NODE_HANDLE" || die "bad handle '$NODE_HANDLE'"; fi
  if [ -n "$NODE_SLOTS" ]; then
    [[ "$NODE_SLOTS" =~ ^[1-8]$ ]] || die "slots must be 1..8 (manifest schema), got '$NODE_SLOTS'"
  fi
}
