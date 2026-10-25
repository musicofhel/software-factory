SHELL := /usr/bin/env bash
.PHONY: test lint live tickets doctor

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

# shellcheck is required: a lint that skips itself is a false green. actionlint is best-effort
# (system binary, else uvx actionlint-py) because hosted runners do not ship it.
lint:
	@set -e; if command -v shellcheck >/dev/null; then SC=shellcheck; \
	elif command -v uvx >/dev/null; then SC="$$(uvx --from shellcheck-py python -c 'import os,sys;print(os.path.join(os.path.dirname(sys.executable),"shellcheck"))')"; \
	else echo "lint: shellcheck not found (install it, or uv for uvx)" >&2; exit 1; fi; \
	"$$SC" -S warning $(SH_FILES); \
	if command -v actionlint >/dev/null; then actionlint -shellcheck "$$SC"; \
	elif command -v uvx >/dev/null; then uvx --from actionlint-py actionlint -shellcheck "$$SC"; \
	else echo "actionlint not installed; workflows not linted"; fi

# The store, then the desk's check on it (factory/bin/ticket-check.sh: exit 2 on an open ticket
# without rails).
tickets:
	@npx -y @adlc/cli@1.12.0 ticket list
	@./factory/bin/ticket-check.sh

doctor:
	@npx -y @adlc/cli@1.12.0 ticket doctor
