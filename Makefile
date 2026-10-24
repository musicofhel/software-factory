SHELL := /usr/bin/env bash
.PHONY: test lint tickets doctor

# Every shell file the factory ships or tests with, including helpers and fakes that later rows add.
SH_FILES = $(shell find factory tests -type f \( -name '*.sh' -o -path 'tests/fakes/*' \) | sort)

test:
	@./factory/test.sh

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

tickets:
	@npx -y @adlc/cli@1.12.0 ticket list

doctor:
	@npx -y @adlc/cli@1.12.0 ticket doctor
