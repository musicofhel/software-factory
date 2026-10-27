#!/usr/bin/env bash
# attest-verify — NOT BUILT YET (specs/factory-step3-v1 TB11). Exits 2 so a stub never reads as a passing gate.
# It already resolves the gate context (lib/gate-context.sh): CI runs the BASE's copy of this script
# from ./.base against the PR head's checkout (I16), and a ticket PR whose body or trailers name
# another ticket is refused before the gate body.
set -euo pipefail
PROG=attest-verify
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=factory/bin/lib/gate-context.sh
. "$(dirname "$0")/lib/gate-context.sh"
gate_begin "$@"
echo "attest-verify: not built" >&2
exit 2
