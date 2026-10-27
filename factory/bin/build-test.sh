#!/usr/bin/env bash
# build-test — run exactly the gate commands of the base's `.adlc/config.json` `fleet.gate`, as fleet
# runs them on the node (specs/factory-step3-v1 TB5, ticket T24; I16, I17).
#
#   build-test.sh [--config FILE] [--list]
#
# The commands come from the config of the checkout this script lives in: CI runs the BASE's copy
# from ./.base (gates.yml `build-test`), so a PR that edits `.adlc/config.json` or this script is
# still gated by the base's (I16); --config names another file (tests). They run in the current
# directory, the PR head's checkout. fleet 1.12.0 runs the same two keys the same way: `build`, then
# `test`, each skipped when empty, each as `/bin/sh -c <command>`, stopping at the first failure
# (@adlc/fleet lib/gates.mjs:20-21 runGateCommand, :34-47 runGates). On the node fleet reads the
# config of the base it builds on, origin/main, so node and CI run one list (I17). fleet runs them in
# its repo-command sandbox with a scrubbed env (lib/env-scrub.mjs repoCommandEnv); CI keeps the
# runner's env, which is where the pinned tools are (gates.yml).
#
# --list prints the command list as one JSON array of {key, command, argv} and runs nothing.
# Exit 0 every gate passed (or --list), 2 a gate command failed, 1 the config is unusable: missing,
# not JSON, a gate value that is not a string, or no build and no test command (fleet's preflight
# refuses that config too, lib/preflight.mjs:63-64, so CI never passes a gate fleet would not run).
set -euo pipefail
PROG=build-test
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

cfg="$FACTORY_ROOT/.adlc/config.json" list=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config) [ -n "${2:-}" ] || usage; cfg="$2"; shift ;;
    --list) list=1 ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need jq

[ -f "$cfg" ] || die "no config at $cfg"
jq -e 'type == "object"' "$cfg" >/dev/null 2>&1 || die "$cfg is not a JSON object"
bad="$(jq -r '(.fleet.gate // {}) as $g | if ($g | type) != "object" then "fleet.gate is not an object"
  else [("build", "test") as $k | select($g | has($k) and ($g[$k] | type) != "string" and $g[$k] != null)
        | "fleet.gate.\($k) is not a string"] | join("; ") end' "$cfg")"
[ -z "$bad" ] || die "$cfg: $bad"
LIST="$(jq -c '[("build", "test") as $k | (.fleet.gate // {})[$k] // "" | select(. != "")
               | {key: $k, command: ., argv: ["/bin/sh", "-c", .]}]' "$cfg")"
[ "$(jq length <<<"$LIST")" -gt 0 ] ||
  die "$cfg has no fleet.gate.build or fleet.gate.test: fleet refuses an ungated run (preflight.mjs:63-64), and so does CI"

if [ "$list" = 1 ]; then printf '%s\n' "$LIST"; exit 0; fi

# By index, never through a `while read` pipe: a gate command must not inherit the list as stdin,
# and a command is passed byte for byte (no @tsv escaping).
for ((i = 0; i < $(jq length <<<"$LIST"); i++)); do
  key="$(jq -r --argjson i "$i" '.[$i].key' <<<"$LIST")"
  cmd="$(jq -r --argjson i "$i" '.[$i].command' <<<"$LIST")"
  echo "build-test: $key: /bin/sh -c $cmd" >&2
  rc=0; /bin/sh -c "$cmd" || rc=$?
  if [ "$rc" != 0 ]; then echo "build-test: FAIL: $key (\`$cmd\`) exited $rc" >&2; exit 2; fi
  echo "build-test: $key passed" >&2
done
echo "build-test: pass: every fleet.gate command of $cfg" >&2
