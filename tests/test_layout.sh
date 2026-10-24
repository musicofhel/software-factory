#!/usr/bin/env bash
# The spec's repository layout exists and the invariants that cost nothing to check hold.
set -euo pipefail
cd "$(dirname "$0")/.."
ok=0
chk() { if eval "$2"; then :; else echo "  layout: $1" >&2; ok=1; fi; }
for f in PROJECT.md AGENTS.md CONTRIBUTING.md CODEOWNERS LICENSE factory/VERSION factory/RULES.md \
         factory/nodes/README.md factory/nodes/manifest.schema.json factory/ledger/findings.jsonl \
         factory/policy/prosecution.json factory/policy/budget.json factory/policy/quarantine.json \
         .adlc/config.json docs/adr/0001-adopt-spec-v0.2.md docs/spec/SPEC-v0.2.txt; do
  chk "missing $f" "[ -f '$f' ]"
done
for d in factory/skills/join factory/skills/run factory/skills/release factory/fixtures .github/workflows docs/adr; do
  chk "missing dir $d" "[ -d '$d' ]"
done
chk "factory/VERSION is semver" "grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' factory/VERSION"
chk "factory/HALT must be ABSENT in the tree (present = halted)" "[ ! -e factory/HALT ]"
for p in 'factory/\*\*' '\.adlc/\*\*' '\.github/\*\*' '\.claude/\*\*'; do
  chk "CODEOWNERS covers $p" "grep -Eq \"^$p\" CODEOWNERS"
done
for j in factory/policy/*.json factory/nodes/manifest.schema.json factory/nodes/example.json .adlc/config.json; do
  chk "$j is valid JSON" "jq -e . '$j' >/dev/null"
done
chk "prosecuteFailOn is medium or stricter" "jq -e '.prosecuteFailOn | IN(\"medium\",\"high\",\"critical\") | not | not' factory/policy/prosecution.json >/dev/null && jq -e '.prosecuteFailOn != \"low\"' factory/policy/prosecution.json >/dev/null"
chk "quota cap default is 0.4" "jq -e '.governor.quotaCapDefault == 0.4' factory/policy/budget.json >/dev/null"
chk "every workflow has a concurrency group" "for w in .github/workflows/*.yml; do grep -q '^concurrency:' \"\$w\" || exit 1; done"
chk "no workflow runs factory-node jobs on pull_request" "( for w in \$(grep -l 'runs-on:.*factory-node' .github/workflows/*.yml 2>/dev/null); do grep -q 'pull_request' \"\$w\" && exit 1; done; exit 0 )"
exit $ok
