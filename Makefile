SHELL := /usr/bin/env bash
.PHONY: test lint tickets doctor

test:
	@./factory/test.sh

lint:
	@if command -v shellcheck >/dev/null; then shellcheck -S warning factory/bin/*.sh factory/test.sh tests/*.sh; elif command -v uvx >/dev/null; then uvx --from shellcheck-py shellcheck -S warning factory/bin/*.sh factory/test.sh tests/*.sh; else echo "shellcheck not installed; skipped"; fi
	@command -v actionlint >/dev/null && actionlint || echo "actionlint not installed; skipped"

tickets:
	@npx -y @adlc/cli@1.12.0 ticket list

doctor:
	@npx -y @adlc/cli@1.12.0 ticket doctor
