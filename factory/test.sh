#!/usr/bin/env bash
# Runs every tests/*.sh offline. Exit 0 only if all pass. No network, no keys.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0; n=0
for t in tests/*.sh; do
  n=$((n+1))
  if bash "$t"; then printf 'PASS %s\n' "$t"; else printf 'FAIL %s\n' "$t"; fail=1; fi
done
[ "$n" -gt 0 ] || { echo "no tests found" >&2; exit 1; }
exit "$fail"
