#!/usr/bin/env bash
# make-repo — build a fixture origin for the janitor tests (ticket T3): a local bare repo with the
# branches and refs a real factory repo carries, every commit dated on purpose.
#
#   make-repo.sh <bare-dir>  < spec
#
# <bare-dir> must not exist. The spec is read from stdin, one item per line (# comments allowed):
#
#   main-dir <dir>                           copy every file under <dir> onto main (for example a
#                                            `git archive` of the factory itself); lines after it
#                                            overlay it, lines before it are overwritten by it
#   version <x.y.z>                          factory/VERSION on main (default 0.1.0)
#   main-file <path> <content...>            any other file on main (one line of content)
#   node <handle> <last_seen-epoch> [status] [slots] [owner]
#                                            nodes/<handle>.json on the nodes branch, a full manifest
#                                            (factory/nodes/manifest.schema.json); status default
#                                            active, slots default 2, owner default the handle
#   preview <name> <expires-epoch> [pr] [branch]
#                                            previews/<name>.json deploy record on the nodes branch
#   state <json>                             janitor/state.json on the nodes branch
#   lock <n> <handle> <commit-epoch> [slots] [run_id]
#                                            refs/locks/issue-<n>, the commit shape factory/bin/lib/
#                                            lock.sh writes (parent = nodes tip), committed at epoch
#   branch <name> <commit-epoch>             refs/heads/<name>, one commit on top of main
#
# main, nodes and flaky-history are always created. Root commits are dated 1761300000
# (2025-10-24T10:00:00Z). Prints nothing; exit 1 on a bad spec line.
set -euo pipefail

die() { printf 'make-repo: %s\n' "$*" >&2; exit 1; }
[ $# = 1 ] || die "usage: make-repo.sh <bare-dir> < spec"
DIR="$1"
[ ! -e "$DIR" ] || die "$DIR already exists"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT_AT=1761300000
git init -q --bare -b main "$DIR"
g() { git -C "$DIR" "$@"; }

commit() {  # commit <tree> <epoch> <message> [parent]: prints the sha
  local -a p=()
  [ -z "${4:-}" ] || p=(-p "$4")
  printf '%s' "$3" | GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@fake GIT_COMMITTER_NAME=fixture \
    GIT_COMMITTER_EMAIL=fixture@fake GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" \
    g commit-tree "$1" "${p[@]}"
}

# tree_of <dir>: write a work dir into the bare repo's object store; prints the tree sha.
tree_of() {
  local idx; idx="$(mktemp)"; rm -f "$idx"
  GIT_INDEX_FILE="$idx" GIT_WORK_TREE="$1" g add -A
  GIT_INDEX_FILE="$idx" g write-tree
  rm -f "$idx"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/main/factory" "$WORK/nodes/nodes" "$WORK/flaky"
echo 0.1.0 >"$WORK/main/factory/VERSION"
echo "fixture main" >"$WORK/main/README.md"
echo "nodes registry" >"$WORK/nodes/README.md"
printf '{"test":"tests/test_example.sh","runs":3,"fails":0}\n' >"$WORK/flaky/history.jsonl"
locks=() branches=()

while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  read -r -a f <<<"$line"
  [ "${#f[@]}" -gt 0 ] || continue
  case "${f[0]}" in
    main-dir)
      [ "${#f[@]}" = 2 ] && [ -d "${f[1]}" ] || die "main-dir needs one existing directory"
      [ ! -e "${f[1]}/.git" ] || die "main-dir ${f[1]} holds a .git: pass an exported tree"
      cp -a "${f[1]}/." "$WORK/main/" ;;
    version) echo "${f[1]:?version needs x.y.z}" >"$WORK/main/factory/VERSION" ;;
    main-file)
      [ "${#f[@]}" -ge 3 ] || die "main-file needs <path> <content>"
      mkdir -p "$(dirname "$WORK/main/${f[1]}")"
      printf '%s\n' "${f[*]:2}" >"$WORK/main/${f[1]}" ;;
    node)
      [ "${#f[@]}" -ge 3 ] || die "node needs <handle> <last_seen-epoch>"
      jq -n --arg h "${f[1]}" --argjson seen "${f[2]}" --arg st "${f[3]:-active}" \
            --argjson slots "${f[4]:-2}" --arg owner "${f[5]:-${f[1]}}" \
        '{handle: $h, owner: $owner, os: "linux", cpu: 8, ram_gb: 16, slots: $slots, heavy_gates: false,
          adapters: {"claude-code": "2.1.280"}, quota_tier: "pro", quota_cap: 0.4,
          quiet_hours: {tz: "UTC", start: "09:00", end: "17:00"}, accounts: 1,
          factory_version: "0.1.0", last_seen: ($seen | todate), status: $st}' \
        >"$WORK/nodes/nodes/${f[1]}.json" ;;
    preview)
      [ "${#f[@]}" -ge 3 ] || die "preview needs <name> <expires-epoch>"
      mkdir -p "$WORK/nodes/previews"
      jq -n --arg n "${f[1]}" --argjson exp "${f[2]}" --arg pr "${f[3]:-}" --arg b "${f[4]:-integration/${f[1]}}" \
        '{branch: $b, pr: (if $pr == "" then null else ($pr | tonumber) end), node: "heavy-node",
          address: "https://\($n).preview.test", deployed_at: (($exp - 86400) | todate),
          expires_at: ($exp | todate)}' >"$WORK/nodes/previews/${f[1]}.json" ;;
    state)
      mkdir -p "$WORK/nodes/janitor"
      jq . <<<"${f[*]:1}" >"$WORK/nodes/janitor/state.json" || die "state needs JSON" ;;
    lock) [ "${#f[@]}" -ge 4 ] || die "lock needs <n> <handle> <epoch>"; locks+=("${f[*]:1}") ;;
    branch) [ "${#f[@]}" -ge 3 ] || die "branch needs <name> <epoch>"; branches+=("${f[*]:1}") ;;
    *) die "unknown spec line: $line" ;;
  esac
done

main="$(commit "$(tree_of "$WORK/main")" "$ROOT_AT" 'main: root')"
g update-ref refs/heads/main "$main"
nodes="$(commit "$(tree_of "$WORK/nodes")" "$ROOT_AT" 'nodes: registry')"
g update-ref refs/heads/nodes "$nodes"
g update-ref refs/heads/flaky-history "$(commit "$(tree_of "$WORK/flaky")" "$ROOT_AT" 'flaky-history: root')"

ntree="$(g rev-parse "$nodes^{tree}")"
for l in "${locks[@]}"; do
  read -r n h at slots run <<<"$l"
  payload="$(jq -cn --arg h "$h" --arg r "${run:-$h-run}" --argjson s "${slots:-2}" --argjson at "$at" \
    '{handle: $h, run_id: $r, slots: $s, claimed_at: ($at | todate)}')"
  g update-ref "refs/locks/issue-$n" \
    "$(commit "$ntree" "$at" "$(printf 'lock issue-%s: %s\n\n%s' "$n" "$h" "$payload")" "$nodes")" ""
done

for b in "${branches[@]}"; do
  read -r name at <<<"$b"
  blob="$(printf 'work on %s\n' "$name" | g hash-object -w --stdin)"
  tree="$( (g ls-tree "$main"; printf '100644 blob %s\tWORK.md\n' "$blob") | g mktree)"
  g update-ref "refs/heads/$name" "$(commit "$tree" "$at" "work: $name" "$main")" ""
done
