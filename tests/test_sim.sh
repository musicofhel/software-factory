#!/usr/bin/env bash
# T20 (specs/factory-step3-v1 TB1): `make sim`, the offline end-to-end pipeline simulation.
#   - the sim in fake-adlc mode reaches tests/sim/EXPECTED.md exactly;
#   - compare.sh fails in both directions (a red stage going green early, a pass stage regressing),
#     on a stage missing on either side, and on a red line without a gap id;
#   - every `gh` form the repo's scripts call is one the fake gh models, and an unknown form is
#     refused and logged;
#   - the driver's jobs come from the YAML: its job ids equal an independent parse of every
#     workflow's `jobs:` keys, and a job added to gates.yml is run without editing the driver.
# Offline; the sim world is a temp dir.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
SIMDIR="$REPO_ROOT/tests/sim"
W="$(mktemp -d "${TMPDIR:-/tmp}/test-sim.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# One sim run, kept for the cases below.
echo "  sim (fake adlc)"
SIM_RC=0
bash "$SIMDIR/sim.sh" --adlc fake --keep "$W/world" --results "$W/results.tsv" >"$W/sim.out" 2>&1 || SIM_RC=$?
[ "$SIM_RC" = 0 ] || sed 's/^/      /' "$W/sim.out"

case_sim_equals_expected() {
  check "sim exits 0 against EXPECTED.md (rc $SIM_RC)" eq "$SIM_RC" 0
  check "every stage of the results is in EXPECTED.md" eq "$(cut -f1 "$W/results.tsv" | sort)" \
    "$(sed -n 's/^| \([^ |]*\) | \(pass\|red: \).*/\1/p' "$SIMDIR/EXPECTED.md" | sort)"
  check "the T-sim walk reaches both completions" \
    eq "$(awk -F'\t' '$1 == "P.complete" || $1 == "C.complete" {print $2}' "$W/results.tsv" | tr '\n' ' ')" "pass pass "
}

flip() {  # flip <stage> <new expected cell> < EXPECTED: one line rewritten
  awk -v s="$1" -v v="$2" -F'|' 'BEGIN{OFS="|"} { st=$2; gsub(/^ +| +$/, "", st); if (st == s) { $3 = " " v " " } print }'
}
case_compare_both_directions() {
  local out rc=0
  # One stage each way: world.seed passes but EXPECTED says red; janitor.no-nodes is expected to pass,
  # and the results say red (built on the results side, so it holds whichever gaps are still open).
  flip world.seed 'red: ci:G1 flipped' <"$SIMDIR/EXPECTED.md" >"$W/exp-flip.md"
  sed -E 's/^(janitor\.no-nodes)\tpass\t/\1\tred\t/' "$W/results.tsv" >"$W/res-flip.tsv"
  out="$("$SIMDIR/lib/compare.sh" "$W/exp-flip.md" "$W/res-flip.tsv")" || rc=$?
  check "a flipped EXPECTED.md fails with exit 2" eq "$rc" 2
  check "a pass stage marked red reads as green early" grep -q '^green early: world.seed passed' <<<"$out"
  check "a stage expected to pass that ran red reads as regressed" grep -q '^regressed: janitor.no-nodes is red' <<<"$out"
  check "nothing else differs" eq "$(wc -l <<<"$out" | tr -d ' ')" 2
}
case_compare_missing_and_malformed() {
  local out rc=0
  /usr/bin/grep -v '^| P.merge |' "$SIMDIR/EXPECTED.md" >"$W/exp-miss.md"
  out="$("$SIMDIR/lib/compare.sh" "$W/exp-miss.md" "$W/results.tsv")" || rc=$?
  check "a stage EXPECTED.md lacks fails" eq "$rc:$(grep -c '^missing in EXPECTED: P.merge ' <<<"$out")" 2:1
  rc=0; /usr/bin/grep -v '^S.halt-add	' "$W/results.tsv" >"$W/res-miss.tsv"
  out="$("$SIMDIR/lib/compare.sh" "$SIMDIR/EXPECTED.md" "$W/res-miss.tsv")" || rc=$?
  check "a stage the sim did not run fails" eq "$rc:$out" "2:missing in results: S.halt-add"
  rc=0; flip P.merge 'red: no queue' <"$SIMDIR/EXPECTED.md" >"$W/exp-bad.md"
  out="$("$SIMDIR/lib/compare.sh" "$W/exp-bad.md" "$W/results.tsv")" || rc=$?
  check "a red line without a gap id is malformed" eq "$rc:$(grep -c '^malformed EXPECTED line' <<<"$out")" 2:1
  rc=0; "$SIMDIR/lib/compare.sh" "$W/exp-bad.md" >/dev/null 2>&1 || rc=$?
  check "compare without a results file is a usage error" eq "$rc" 1
}

case_gh_forms_static() {
  # Every `gh <issue|pr|label> <sub>` and every literal `gh api [-X M] "repos/$REPO/<path>"` in the
  # repo's scripts and workflows is a form the fake gh models (gh __forms; `*` matches either way).
  local forms line m p f hit bad=0 n=0
  forms="$(FAKE_GH_ISSUES=/dev/null "$FAKES_DIR/gh" __forms)"
  while IFS= read -r line; do
    n=$((n + 1))
    grep -qxF "$line" <<<"$forms" || { echo "      fake gh lacks: $line"; bad=1; }
  done < <(/usr/bin/grep -rhoE '\bgh (issue|pr|label) [a-z]+' "$REPO_ROOT/factory" "$REPO_ROOT/.github" | sed 's/^gh //' | sort -u)
  while IFS= read -r line; do
    m="$(sed -nE 's/.*gh api -X ([A-Z]+).*/\1/p' <<<"$line")"; m="${m:-GET}"
    p="$(sed -nE 's/.*"repos\/\$REPO\/([^"]*)".*/\1/p' <<<"$line")"
    [ -n "$p" ] || continue
    n=$((n + 1))
    p="${p%%\?*}"; p="$(sed -E 's/\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*/*/g' <<<"$p")"
    hit=0
    while IFS= read -r f; do
      # shellcheck disable=SC2053  # both sides are globs on purpose
      if [[ "$f" == api\ $m\ * ]] && { [[ "${f#api "$m" }" == $p ]] || [[ "$p" == ${f#api "$m" } ]]; }; then hit=1; break; fi
    done <<<"$forms"
    [ "$hit" = 1 ] || { echo "      fake gh lacks: api $m $p"; bad=1; }
  done < <(/usr/bin/grep -rhE '\bgh api\b' "$REPO_ROOT/factory" "$REPO_ROOT/.github" | /usr/bin/grep -vE '^\s*#')
  check "every gh form in factory/ and .github/ is modeled ($n checked)" eq "$bad" 0
  check "the sim's run refused no gh form" test ! -s "$W/world/gh-unknown.log"
}
case_gh_unknown_refused() {
  local rc=0
  : >"$W/unknown.log"
  printf '{"issues":[],"pulls":[]}\n' >"$W/gh-u.json"
  FAKE_GH_UNKNOWN="$W/unknown.log" FAKE_GH_ISSUES="$W/gh-u.json" FAKE_GH_REPO=a/b "$FAKES_DIR/gh" repo view --repo a/b >/dev/null 2>&1 || rc=$?
  check "gh repo view is refused" test "$rc" != 0
  check "and logged to FAKE_GH_UNKNOWN" grep -q 'repo view' "$W/unknown.log"
  rc=0
  git init -q --bare "$W/u.git"
  FAKE_GH_GIT="$W/u.git" FAKE_GH_UNKNOWN="$W/unknown.log" FAKE_GH_ISSUES="$W/gh-u.json" FAKE_GH_REPO=a/b "$FAKES_DIR/gh" api repos/a/b/deployments >/dev/null 2>&1 || rc=$?
  check "an unknown api path is refused" test "$rc" != 0
  check "and logged" eq "$(grep -c 'deployments' "$W/unknown.log")" 1
}

jobs_awk() {  # jobs_awk <workflow.yml>: the `jobs:` keys, parsed without yq
  awk '/^jobs:/ {in_j = 1; next} in_j && /^[^ #]/ {in_j = 0} in_j && /^  [A-Za-z0-9_-]+:/ {sub(/^  /, ""); sub(/:.*/, ""); print}' "$1" | sort
}
case_driver_jobs_from_yaml() {
  local f all bad=0
  all="$(SIM_LIB="$SIMDIR/lib" ORIGIN="$W/world/origin.git" bash -c '. "$SIM_LIB/driver.sh"; wf_all refs/heads/main')"
  for f in "$W"/world/desk/.github/workflows/*.yml; do
    eq "$(jq -r --arg f ".github/workflows/${f##*/}" '.[] | select(.file == $f) | .wf' <<<"$all" |
          SIM_LIB="$SIMDIR/lib" bash -c '. "$SIM_LIB/driver.sh"; jq -r "$JOB_ORDER_JQ"' | sort)" "$(jobs_awk "$f")" || bad=1
  done
  check "the driver's job ids equal an awk parse of every workflow's jobs:" eq "$bad" 0
  check "the gates jobs the walk ran on pull_request are gates.yml's jobs" \
    eq "$(jq -r 'select(.workflow == ".github/workflows/gates.yml" and .event == "pull_request") | .job' "$W/world/jobs.jsonl" | sort -u)" \
       "$(jobs_awk "$REPO_ROOT/.github/workflows/gates.yml")"
}
case_driver_runs_a_new_job() {
  # A later row adds a job to gates.yml: the driver runs it with no edit of its own.
  local c="$W/newjob" head merge base n=900
  git clone -q "$W/world/origin.git" "$c"
  yq -i '.jobs["sim-extra"] = {"runs-on": "ubuntu-latest", "steps": [{"run": "echo sim-extra ran on ${{ github.event_name }}"}]}' "$c/.github/workflows/gates.yml"
  git -C "$c" -c user.name=t -c user.email=t@t.invalid commit -qam "gates: sim-extra"
  git -C "$c" push -q origin HEAD:refs/heads/sim-extra
  head="$(git -C "$c" rev-parse HEAD)"; base="$(git -C "$W/world/origin.git" rev-parse refs/heads/main)"
  (
    export SIM="$W/world" ORIGIN="$W/world/origin.git" REPO=sim-owner/factory SIM_LIB="$SIMDIR/lib"
    RUNNER_PATH="$W/world/runner-bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v git)"):/usr/bin:/bin"
    export RUNNER_PATH
    export SIM_VARS='{}' SIM_SECRETS='{}' FAKE_GH_ISSUES="$W/world/gh.json" FAKE_GH_REPO=sim-owner/factory FAKE_GH_GIT="$W/world/origin.git"
    export FAKE_GH_LOG="$W/world/gh.log" FAKE_GH_UNKNOWN="$W/world/gh-unknown.log" FAKE_TAMPERGUARD_LOG="$W/world/tg-ci.log"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    # shellcheck source=tests/sim/lib/driver.sh
    . "$SIMDIR/lib/driver.sh"
    merge="$(pr_merge_ref "$n" "$base" "$head")"
    jq -n --argjson n "$n" --arg hs "$head" --arg bs "$base" \
      '{action: "opened", number: $n, pull_request: {number: $n, head: {ref: "sim-extra", sha: $hs}, base: {ref: "main", sha: $bs}, labels: []}}' >"$W/ev.json"
    drive pull_request "$W/ev.json" "$merge" .github/workflows/gates.yml
  ) >"$W/newjob.out" 2>&1
  check "the new job ran and succeeded" \
    eq "$(jq -r --arg h "$head" 'select(.head_sha == $h and .job == "sim-extra") | .conclusion' "$W/world/jobs.jsonl")" success
  check "with the event templated into its run:" \
    grep -q 'sim-extra ran on pull_request' "$(jq -r --arg h "$head" 'select(.head_sha == $h and .job == "sim-extra") | .log' "$W/world/jobs.jsonl")"
}

for c in sim-equals-expected compare-both-directions compare-missing-and-malformed gh-forms-static gh-unknown-refused \
         driver-jobs-from-yaml driver-runs-a-new-job; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
