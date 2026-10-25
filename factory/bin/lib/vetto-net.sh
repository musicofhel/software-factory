#!/usr/bin/env bash
# vetto-net — the `--net` value a vetto policy file's [network] table means (ticket T6; ADR-0005
# decision 2).
#
#   vetto-net.sh <policy.toml> [--json]
#
# vetto 0.6.5 enforces a policy file's [network] table only when nothing else sets the network:
# `--agent claude` replaces it with vetto's built-in agent allowlist (github.com, registry.npmjs.org,
# pypi.org, crates.io, ... measured reachable under factory/policy/agent.toml), and an explicit
# `--net` replaces both. A model turn needs `--agent claude` (else the strict profile masks
# ~/.claude), so the caller passes `--net "$(vetto-net.sh factory/policy/agent.toml)"` and the file
# stays the one place the egress list is written:
#
#   vetto --profile strict --agent claude --policy factory/policy/agent.toml \
#         --net "$(factory/bin/lib/vetto-net.sh factory/policy/agent.toml)" --tui none -- <cmd>
#
# Prints `off`, `allowlist:<host,...>` or `strict:<host:port,...>` (vetto --help's spellings); with
# --json, {policy, mode, allow, net}. Reads single-line `mode = "..."` and `allow = [...]` values in
# [network] only. Fails closed: vetto 0.6.5 accepts an unknown mode silently, so this refuses it.
#
# Exit 0 printed; 1 operational error (no such file, bad usage); 2 refused (no [network] mode, an
# unknown mode, allowlist/strict with an empty or malformed allow list, allow entries under off).
set -euo pipefail
PROG=vetto-net
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/common.sh"

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

file="" json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1 ;;
    -h|--help) usage ;;
    -*) warn "unknown argument: $1"; usage ;;
    *) [ -z "$file" ] || { warn "one policy file only"; usage; }; file="$1" ;;
  esac
  shift
done
need jq awk
[ -n "$file" ] || usage
[ -f "$file" ] || die "policy file not found: $file"

# get <key>: the raw single-line value of <key> in [network], or nothing.
get() {
  awk -v k="$1" '
    /^[[:space:]]*\[/ { t = $0; sub(/^[[:space:]]*\[/, "", t); sub(/\].*$/, "", t); cur = t; next }
    cur == "network" && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$file"
}

mode="$(get mode)"
[ -n "$mode" ] || refuse "$file has no [network] mode"
mode="$(jq -er 'if type == "string" then . else error("not a string") end' <<<"$mode" 2>/dev/null)" ||
  refuse "$file: [network] mode is not a single-line string"
raw="$(get allow)"
allow="$(jq -ce 'if type == "array" and all(.[]; type == "string") then . else error("bad") end' <<<"${raw:-[]}" 2>/dev/null)" ||
  refuse "$file: [network] allow is not a single-line array of strings"

case "$mode" in
  off)
    [ "$allow" = '[]' ] || refuse "$file: mode off with allow entries: say which one is meant"
    net=off ;;
  allowlist|strict)
    [ "$allow" != '[]' ] || refuse "$file: mode $mode with an empty allow list"
    re='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?' what=host
    if [ "$mode" = strict ]; then re+=':[0-9]{1,5}' what=host:port; fi
    jq -e --arg re "$re\$" 'all(.[]; test($re))' <<<"$allow" >/dev/null ||
      refuse "$file: under mode $mode every allow entry is a $what: $allow"
    net="$mode:$(jq -r 'join(",")' <<<"$allow")" ;;
  *) refuse "$file: unknown [network] mode '$mode' (vetto 0.6.5 would accept it silently)" ;;
esac

if [ "$json" = 1 ]; then
  jq -nc --arg p "$file" --arg m "$mode" --argjson a "$allow" --arg n "$net" '{policy: $p, mode: $m, allow: $a, net: $n}'
else
  printf '%s\n' "$net"
fi
