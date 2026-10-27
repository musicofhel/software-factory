#!/usr/bin/env bash
# skills-scan — NOT BUILT (build order step 4; merge:G18). Exits 2 so a stub never reads as a passing
# gate. skills-janitor.yml runs it on pull requests touching factory/skills/** or .claude/**, and it is
# deliberately NOT a required check (specs/factory-step3-v1 TB11, ticket T30): its body is the
# skills-janitor /janitor-security review, an agent's verdict, which needs a model and a transcript
# on the runner (transcripts never leave the node, I8) and is no deterministic gate a hosted runner
# can recompute. It is required only once it has a real body and runs on the queue path too
# (merge_group and the first-party queue, I18); until then two code owners review every such PR
# (owners-check.sh: factory/** and .claude/**).
set -euo pipefail
echo "skills-scan: not built (step 4): not a required check; two owners review skills changes (owners)" >&2
exit 2
