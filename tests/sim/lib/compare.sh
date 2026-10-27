#!/usr/bin/env bash
# compare — the stage results of `make sim` against tests/sim/EXPECTED.md, in both directions.
#
#   compare.sh <EXPECTED.md> <results.tsv>
#
# EXPECTED.md rows are `| <stage> | pass |` or `| <stage> | red: <gap id> … |`; a red row must cite
# a gap id of records/sim (`ci:G6`, `merge:G8a`, `intake:I1`, `node:G2`) or a `kit:` line. Results
# are `<stage>\t<pass|red>\t<detail>` lines (tests/sim/sim.sh). Prints one line per difference:
#   green early      the stage passed but EXPECTED.md says red (flip the line in the row that fixed it)
#   regressed        the stage is red but EXPECTED.md says pass
#   missing in EXPECTED / missing in results / duplicate
# Exit 0 equal, 2 any difference or a malformed EXPECTED.md line, 1 usage.
set -euo pipefail
[ $# = 2 ] && [ -f "$1" ] && [ -f "$2" ] || { echo "usage: compare.sh <EXPECTED.md> <results.tsv>" >&2; exit 1; }
awk -F'\t' -v ef="$1" '
  BEGIN {
    bad = 0
    while ((getline line < ef) > 0) {
      if (line !~ /^\|/ || line ~ /^\| *(stage|-+) *\|/) continue
      n = split(line, c, "|"); st = c[2]; v = c[3]
      gsub(/^ +| +$/, "", st); gsub(/^ +| +$/, "", v)
      if (st == "") continue
      if (v == "pass") want = "pass"
      else if (v ~ /^red: / && v ~ /((ci|merge|intake|node):[GI][0-9]+[a-z]?|kit:)/) want = "red"
      else { printf "malformed EXPECTED line (red needs a gap id or kit:): %s\n", line; bad = 1; continue }
      if (st in W) { printf "duplicate in EXPECTED: %s\n", st; bad = 1 }
      W[st] = want; WHY[st] = v; order[++no] = st
    }
  }
  {
    if ($1 in G) { printf "duplicate in results: %s\n", $1; bad = 1 }
    G[$1] = $2; D[$1] = $3
    if (!($1 in W)) { printf "missing in EXPECTED: %s (%s: %s)\n", $1, $2, $3; bad = 1; next }
    if (W[$1] == "pass" && $2 != "pass") { printf "regressed: %s is red (%s); EXPECTED says pass\n", $1, $3; bad = 1 }
    if (W[$1] == "red" && $2 == "pass") { printf "green early: %s passed (%s); EXPECTED says %s\n", $1, $3, WHY[$1]; bad = 1 }
  }
  END {
    for (i = 1; i <= no; i++) if (!(order[i] in G)) { printf "missing in results: %s\n", order[i]; bad = 1 }
    exit bad ? 2 : 0
  }' "$2"
