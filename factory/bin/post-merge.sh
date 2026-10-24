#!/usr/bin/env bash
# post-merge — NOT BUILT YET (build order step 3/4). Exits 2 so a stub never reads as a passing gate.
set -euo pipefail
echo "post-merge: not built" >&2
exit 2
