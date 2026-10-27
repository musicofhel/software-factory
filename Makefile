SHELL := /usr/bin/env bash
.PHONY: test lint live sim tickets doctor

# Every shell file the factory ships or tests with, including helpers and fakes that later rows add,
# and the extension-less bwrap shim (ADR-0006).
SH_FILES = $(shell find factory tests -type f \( -name '*.sh' -o -path 'tests/fakes/*' -o -path factory/bin/lib/bwrap-shim \) | sort)

test:
	@./factory/test.sh

# The real pinned tools (vetto, ralon, dcg, fleet). Never part of `make test`: each tests/live/*.sh
# prints `SKIP <reason>` and exits 0 only when a tool it needs is absent.
live:
	@fail=0; for t in tests/live/*.sh; do \
	  if bash "$$t"; then echo "PASS $$t"; else echo "FAIL $$t"; fail=1; fi; \
	done; exit $$fail

# The offline end-to-end pipeline simulation (tests/sim/sim.sh; specs/factory-step3-v1 TB1): its stage
# results against tests/sim/EXPECTED.md. tests/test_sim.sh also runs it inside `make test`.
sim:
	@bash tests/sim/sim.sh

# `make lint` is fleet.gate.build in .adlc/config.json (specs/factory-step3-v1 TB5, ticket T24), so it
# downloads nothing and needs no /dev/null: fleet 1.12.0 runs it with no network, and its bwrap
# repo-command plane binds only the worktree and the system roots (no /dev, /proc, /tmp or $HOME;
# measured, records/TB5.md). shellcheck is $SHELLCHECK, else the one on PATH, and is required: a lint
# that skips itself is a false green. On a node it must sit under a system root for fleet's sandbox to
# see it (join.sh refuses otherwise); CI installs the pinned shellcheck-py (gates.yml build-test).
# actionlint ($ACTIONLINT, else PATH) is best-effort until CI pins it (TB10).
lint:
	@set -e; SC="$${SHELLCHECK:-$$(command -v shellcheck || true)}"; \
	[ -n "$$SC" ] || { echo "lint: shellcheck not found: install it (join.sh prints how), or set SHELLCHECK" >&2; exit 1; }; \
	echo "lint: shellcheck $$("$$SC" --version | sed -n 's/^version: //p') at $$SC"; \
	"$$SC" -S warning $(SH_FILES); \
	AL="$${ACTIONLINT:-$$(command -v actionlint || true)}"; \
	if [ -n "$$AL" ]; then "$$AL" -shellcheck "$$SC"; else echo "lint: actionlint not installed; workflows not linted"; fi

# The store, then the desk's contract lint on it (factory/bin/ticket-check.sh: exit 2 on an open
# ticket without rails, a bad header, a scope glob that matches nothing tracked or declared new, an
# edge to no ticket, a tier inversion or a forecast warning naming it; ticket T26). The desk's
# records and the desk PR's gate are factory/bin/desk-gates.sh (factory/RULES.md, the desk runbook).
tickets:
	@npx -y @adlc/cli@1.12.0 ticket list
	@./factory/bin/ticket-check.sh

doctor:
	@npx -y @adlc/cli@1.12.0 ticket doctor
