#!/usr/bin/env bash
# T22 (specs/factory-step3-v1 TB3): factory/bin/lib/diff-gates.sh and the three diff gates it backs,
# rails-proof.sh, scope-check.sh and tamper-check.sh.
#   - the fleet glob port, against the per-pattern table measured with fleet's own globMatch (real node,
#     @adlc/core lib/glob.mjs, records/TB3.md), and the three cases where git's `:(glob)` differs;
#   - each gate passes, fails and errors on fixture repos; the ticket is read from the BASE's store;
#     a rail glob that would cross `/` without `:(glob)`, the union with the fleet port, a rename out of
#     a rail, `.adlc/**` in a ticket diff, an empty scope, an absent or completed ticket, no rails;
#   - tamper: ok, review, tamper, a tamperguard error, argparse's rc 2 with no JSON;
#   - CI mode and node mode make the same diff-gates calls (the trace lines and tamperguard's argv, I17);
#   - run.sh's static call sites, and gates.yml's tamper job against the helper's pins.
# Offline; every repo is a temp dir, gh and tamperguard are the fakes.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
EV="$REPO_ROOT/tests/fixtures/events"
FREPO=Codertocat/Hello-World   # the repository of GitHub's example payloads

# gate <script> [flags]: one gate script in R; OUT, ERR, RC.
gate() {
  local s="$1"; shift
  RC=0
  OUT="$(cd "$R" && "$BIN/$s.sh" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
# put_ticket <id> <scope-json> <rails-json> [completed]: the store file adlc would write (slug--sha256 id).
put_ticket() {
  local slug; slug="$(tr '[:upper:]' '[:lower:]' <<<"$1" | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//')"
  jq -n --arg id "$1" --argjson s "$2" --argjson r "$3" --argjson c "${4:-false}" \
    '{id: $id, title: "t", body: "", category: "feature", duration: 1, scope: $s, rails: $r, edges: []}
     + (if $c then {completed: true} else {} end)' >"$R/.adlc/tickets/$slug--$(sha "$1").json"
}

# R: main holds the store (T-dg, T-un, T-nr, T-empty, T-done) and a few files the cases change.
setup() {
  fakegh_setup
  export FAKE_GH_REPO="$FREPO" GITHUB_REPOSITORY="$FREPO" FAKE_TAMPERGUARD_LOG="$WORLD/tamperguard.log"
  printf '{"labels":[],"issues":[],"pulls":[],"collaborators":["dev-box-owner"]}\n' >"$FAKE_GH_ISSUES"
  : >"$FAKE_TAMPERGUARD_LOG"
  R="$WORLD/r"
  git init -q -b main "$R"
  git -C "$R" config user.name t; git -C "$R" config user.email t@t.invalid
  mkdir -p "$R/.adlc/tickets" "$R/factory/policy" "$R/sim/dg"
  : >"$R/.adlc/tickets/.store.json"; echo base >"$R/README.md"; echo '{}' >"$R/factory/policy/old.json"
  echo keep >"$R/sim/dg/keep"
  put_ticket T-dg '["sim/dg/**","docs/*.md"]' '["factory/policy/**","factory/*.sh"]'
  put_ticket T-un '["**"]' '["lib/**.js","a?c"]'
  put_ticket T-nr '["**"]' '[]'
  put_ticket T-empty '[]' '["factory/policy/**"]'
  put_ticket T-done '["**"]' '["factory/policy/**"]' true
  git -C "$R" add -A; git -C "$R" commit -qm base
  BASE="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" update-ref refs/remotes/origin/main "$BASE"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH GH_TOKEN FAKE_TAMPERGUARD_VERDICT
}
# change <branch> <op:path>...: a commit on a new branch from BASE; + add/modify, - delete, >a=b rename.
change() {
  local b="$1" a; shift
  git -C "$R" checkout -q -B "$b" "$BASE"
  for a in "$@"; do
    case "$a" in
      +*) mkdir -p "$R/$(dirname "${a#+}")"; echo "$b" >>"$R/${a#+}"; git -C "$R" add -- "${a#+}" ;;
      -*) git -C "$R" rm -q -- "${a#-}" ;;
      \>*) a="${a#>}"; mkdir -p "$R/$(dirname "${a#*=}")"; git -C "$R" mv -- "${a%%=*}" "${a#*=}" ;;
    esac
  done
  git -C "$R" commit -qm "work"
  git -C "$R" rev-parse HEAD
}
pr_event() {  # pr_event <head-sha> <head-ref> <body> [assoc]
  jq --arg b "$BASE" --arg h "$1" --arg r "$2" --arg body "$3" --arg a "${4:-OWNER}" --arg hr "$FREPO" \
    '.pull_request.base.sha = $b | .pull_request.head.sha = $h | .pull_request.head.ref = $r | .pull_request.body = $body
     | .pull_request.author_association = $a | .pull_request.head.repo.full_name = $hr' "$EV/pull_request-opened.json" >"$WORLD/event.json"
  export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$WORLD/event.json"
}

# The per-pattern match lists over one universe of paths, measured with fleet's globMatch (real node).
case_glob_table() {
  local universe want p got
  universe='[".adlc/config.json","README.md","[ab]x","a/b","a/x/y/b","a?c","abc","ax","docs/a/b/c.md","docs/a/x.md","docs/x.md","factory","factory/bin/lib/diff-gates.sh","factory/bin/x.sh","factory/policy","factory/policy/a.json","factory/x.sh","foo/bar","foobar","sim/parent","sim/parent/hello.sh","src/a/b.js","src/b.js","tests/fakes/gh","tests/fakesy","x/"]'
  while IFS=$'\t' read -r p want; do
    got="$(jq -r --arg p "$p" --argjson u "$universe" "$(bash -c '. "$1"; printf %s "$DG_GLOB_JQ"' _ "$BIN/lib/diff-gates.sh")"'
      [$u[] | select(dg_glob($p))] | sort | join(" ")' -n)"
    want="$(tr ' ' '\n' <<<"$want" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
    [ "$want" != '(every)' ] || want="$(jq -r 'sort | join(" ")' <<<"$universe")"
    check "fleet glob $p" eq "$got" "$want"
  done <<'EOF'
*	factory README.md abc a?c ax [ab]x foobar
**	(every)
**/	x/
**/*.md	README.md docs/a/b/c.md docs/x.md docs/a/x.md
.adlc/**	.adlc/config.json
[ab]x	[ab]x
a/**/b	a/b a/x/y/b
a?c	a?c
docs/**/x.md	docs/x.md docs/a/x.md
factory/**	factory/x.sh factory/bin/x.sh factory/policy/a.json factory/policy factory/bin/lib/diff-gates.sh
factory/*.sh	factory/x.sh
factory/bin/lib/diff-gates.sh	factory/bin/lib/diff-gates.sh
factory/policy/**	factory/policy/a.json
foo**	foo/bar foobar
sim/parent/**	sim/parent/hello.sh
src/**.js	src/a/b.js src/b.js
tests/fakes/**	tests/fakes/gh
EOF
  # The three measured disagreements with git's :(glob), on real files.
  setup
  local h; h="$(change ub +src/a/b.js +abc +ax)"
  check "git :(glob)src/**.js misses src/a/b.js (fleet matches it)" \
    eq "$(git -C "$R" diff --name-only "$BASE...$h" -- ':(glob)src/**.js')" ""
  check "git :(glob)a?c and [ab]x are wildcards (fleet's are literal)" \
    eq "$(git -C "$R" diff --name-only "$BASE...$h" -- ':(glob)a?c' ':(glob)[ab]x' | tr '\n' ' ')" "abc ax "
}

case_rails() {
  setup
  local h
  h="$(change w1 +sim/dg/a.sh +docs/x.md)"
  gate rails-proof --ticket T-dg --base "$BASE" --head "$h"
  check "pass: no rail touched → exit 0" eq "$RC:$(tail -n1 <<<"$ERR")" "0:rails-proof: pass: $BASE...$h touches no rail of T-dg"
  h="$(change w2 +sim/dg/a.sh +factory/policy/p.json)"
  gate rails-proof --ticket T-dg --base "$BASE" --head "$h"
  check "fail: a rail path → exit 2 naming it" eq "$RC:$(tail -n1 <<<"$ERR")" "2:  factory/policy/p.json"
  # factory/*.sh: a plain pathspec's * crosses '/', :(glob) and fleet's do not.
  h="$(change w3 +factory/bin/x.sh)"
  check "a plain pathspec factory/*.sh would freeze factory/bin/x.sh" \
    eq "$(git -C "$R" diff --name-only "$BASE...$h" -- 'factory/*.sh')" factory/bin/x.sh
  gate rails-proof --ticket T-dg --base "$BASE" --head "$h"
  check "the rail factory/*.sh does not cross '/' (factory/bin/x.sh passes)" eq "$RC" 0
  h="$(change w4 +factory/x.sh)"
  gate rails-proof --ticket T-dg --base "$BASE" --head "$h"
  check "the rail factory/*.sh freezes factory/x.sh" eq "$RC:$(tail -n1 <<<"$ERR")" "2:  factory/x.sh"
  # The union: lib/**.js reaches lib/a/b.js only through fleet; a?c reaches abc only through git.
  h="$(change w5 +lib/a/b.js +abc +ok.txt)"
  gate rails-proof --ticket T-un --base "$BASE" --head "$h"
  check "union: fleet's lib/**.js and git's a?c both freeze" \
    eq "$RC:$(grep '^  ' <<<"$ERR" | tr -d ' ' | tr '\n' ' ')" "2:abc lib/a/b.js "
  # A rename out of a rail shows the old path (--no-renames).
  h="$(change w6 '>factory/policy/old.json=sim/dg/old.json')"
  gate rails-proof --ticket T-dg --base "$BASE" --head "$h"
  check "a rename out of a rail fails naming the old path" eq "$RC:$(tail -n1 <<<"$ERR")" "2:  factory/policy/old.json"
  # The rails are the BASE's: the head dropping its rails from the store changes nothing.
  h="$(change w7 +factory/policy/p.json)"
  put_ticket T-dg '["**"]' '[]'; git -C "$R" add -A; git -C "$R" commit -qm drop; h="$(git -C "$R" rev-parse HEAD)"
  gate rails-proof --ticket T-dg --base "$BASE" --head "$h"
  check "the head's own store edit does not lift the base's rails" eq "$RC:$(grep -c '^  factory/policy/p.json$' <<<"$ERR")" 2:1
  h="$(change w8 +sim/dg/a.sh)"
  gate rails-proof --ticket T-nr --base "$BASE" --head "$h"
  check "no rails declared → refused (exit 2)" eq "$RC:$(grep -c 'rails: none declared for T-nr' <<<"$ERR")" 2:1
  gate rails-proof --ticket T-absent --base "$BASE" --head "$h"
  check "a ticket absent from the base's store → exit 2" eq "$RC:$(grep -c 'ticket T-absent is not in the store' <<<"$ERR")" 2:1
  gate rails-proof --ticket T-dg --base 0000000000000000000000000000000000000000 --head "$h"
  check "a base that is not a commit → exit 1" eq "$RC" 1
}

case_scope() {
  setup
  local h
  h="$(change s1 +sim/dg/a.sh +sim/dg/deep/b.sh +docs/x.md)"
  gate scope-check --ticket T-dg --base "$BASE" --head "$h"
  check "pass: every path in scope → exit 0" eq "$RC:$(tail -n1 <<<"$ERR")" "0:scope-check: pass: every path of $BASE...$h is in the scope of T-dg"
  h="$(change s2 +sim/dg/a.sh +docs/a/x.md +README.md)"
  gate scope-check --ticket T-dg --base "$BASE" --head "$h"
  check "fail: out-of-scope paths → exit 2 naming each (docs/*.md does not cross '/')" \
    eq "$RC:$(grep '^  ' <<<"$ERR" | tr -d ' ' | tr '\n' ' ')" "2:README.md docs/a/x.md "
  h="$(change s3 +.adlc/config.json +sim/dg/a.sh)"
  gate scope-check --ticket T-un --base "$BASE" --head "$h"
  check "a ticket touching .adlc/** fails even when its scope is **" eq "$RC:$(grep '^  ' <<<"$ERR" | tr -d ' ')" "2:.adlc/config.json"
  gate scope-check --ticket T-empty --base "$BASE" --head "$h"
  check "an empty scope puts every path out of scope" eq "$RC:$(grep -c '^  ' <<<"$ERR")" 2:2
  h="$(change s4 +sim/dg/a.sh)"
  gate scope-check --ticket T-done --base "$BASE" --head "$h"
  check "a ticket completed at the base → exit 2" eq "$RC:$(grep -c 'T-done is completed' <<<"$ERR")" 2:1
  gate scope-check --ticket T-absent --base "$BASE" --head "$h"
  check "a ticket absent from the base's store → exit 2" eq "$RC:$(grep -c 'not in the store' <<<"$ERR")" 2:1
  # The scope is the BASE's: the head widening its own scope changes nothing (and touches .adlc).
  h="$(change s5 +outside.sh)"
  put_ticket T-dg '["**"]' '["factory/policy/**"]'; git -C "$R" add -A; git -C "$R" commit -qm widen; h="$(git -C "$R" rev-parse HEAD)"
  gate scope-check --ticket T-dg --base "$BASE" --head "$h"
  check "the head's own scope edit does not widen the base's scope" eq "$RC:$(grep -c '^  outside.sh$' <<<"$ERR")" 2:1
  gate scope-check --ticket T-dg --base "$BASE" --head 0000000000000000000000000000000000000000
  check "a head that is not a commit → exit 1" eq "$RC" 1
}

case_tamper() {
  setup
  local h v
  h="$(change t1 +sim/dg/a.sh)"
  for v in ok review; do
    export FAKE_TAMPERGUARD_VERDICT="$v"
    gate tamper-check --ticket T-dg --base "$BASE" --head "$h"
    check "$v → exit 0, the JSON in the log" eq "$RC:$(jq -r .verdict <<<"$OUT")" "0:$v"
  done
  export FAKE_TAMPERGUARD_VERDICT=tamper
  gate tamper-check --ticket T-dg --base "$BASE" --head "$h"
  check "a parsed tamper verdict (rc 2) → exit 2" eq "$RC:$(jq -r .verdict <<<"$OUT"):$(tail -n1 <<<"$ERR")" "2:tamper:tamper-check: FAIL: tamperguard's verdict is tamper"
  export FAKE_TAMPERGUARD_VERDICT=error
  gate tamper-check --ticket T-dg --base "$BASE" --head "$h"
  check "a tamperguard error (rc 1) → tamper-error, exit 1" eq "$RC:$(grep -c 'tamper-error' <<<"$ERR")" 1:1
  check "the argv is --range BASE...HEAD --json" eq "$(tail -n1 "$FAKE_TAMPERGUARD_LOG")" "[\"--range\",\"$BASE...$h\",\"--json\"]"
  # argparse's rc 2 carries no JSON: never a tamper verdict, never a pass.
  mkdir -p "$WORLD/argparse"
  printf '#!/usr/bin/env bash\necho "tamperguard: error: unrecognized arguments: $1" >&2\nexit 2\n' >"$WORLD/argparse/tamperguard"
  chmod +x "$WORLD/argparse/tamperguard"
  RC=0; (cd "$R" && PATH="$WORLD/argparse:$PATH" "$BIN/tamper-check.sh" --ticket T-dg --base "$BASE" --head "$h") >/dev/null 2>"$WORLD/err" || RC=$?
  check "argparse's rc 2 with no JSON → tamper-error, exit 1" eq "$RC:$(grep -c 'tamper-error' "$WORLD/err")" 1:1
  check "dg_tamper_judge: rc 2 with an ok verdict is tamper-error" eq "$(bash -c '. "$1"; dg_tamper_judge 2 "{\"verdict\":\"ok\"}"' _ "$BIN/lib/diff-gates.sh")" tamper-error
  check "dg_tamper_judge: rc 0 with a tamper verdict is tamper-error" eq "$(bash -c '. "$1"; dg_tamper_judge 0 "{\"verdict\":\"tamper\"}"' _ "$BIN/lib/diff-gates.sh")" tamper-error
  RC=0; (cd "$R" && PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin" "$BIN/tamper-check.sh" --ticket T-dg --base "$BASE" --head "$h") >/dev/null 2>"$WORLD/err" || RC=$?
  check "no tamperguard on PATH → exit 1" eq "$RC:$(grep -c 'tamperguard not found' "$WORLD/err")" 1:1
}

# CI: the event's class decides; a non-ticket PR has no scope or rails (approvals, TB10), tamper runs.
case_classes() {
  setup
  local h s
  h="$(change human +README.md)"
  pr_event "$h" human-change 'a fix'
  for s in rails-proof scope-check; do
    gate "$s"
    check "$s: a human PR → exit 0, no ticket scope/rails" eq "$RC:$(grep -c 'class human: no ticket' <<<"$ERR")" 0:1
  done
  gate tamper-check
  check "tamper-check: a human PR is still checked" eq "$RC:$(jq -r .verdict <<<"$OUT")" 0:ok
  h="$(change ticket/T-dg/dev-box +sim/dg/a.sh)"
  for s in rails-proof scope-check tamper-check; do
    pr_event "$h" ticket/T-dg/dev-box 'Ticket: T-un'
    gate "$s"
    check "$s: a body naming another ticket is refused before the gate body" \
      eq "$RC:$(grep -c "says 'Ticket: T-un'" <<<"$ERR"):$(grep -c '^diff-gates:' <<<"$ERR" || true)" 2:1:0
  done
}

# I17: CI (pull_request and merge_group) and the node make the same helper calls with the same argv.
case_ci_equals_node() {
  setup
  local h s node ci
  h="$(change ticket/T-dg/dev-box +sim/dg/a.sh +factory/policy/p.json +README.md)"
  for s in rails-proof scope-check tamper-check; do
    unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
    : >"$FAKE_TAMPERGUARD_LOG"
    gate "$s" --ticket T-dg --base "$(git -C "$R" merge-base origin/main "$h")" --head "$h"
    node="$RC|$(grep '^diff-gates:' <<<"$ERR")|$(grep -v '^diff-gates:\|gate from ' <<<"$ERR")|$(command cat "$FAKE_TAMPERGUARD_LOG")"
    pr_event "$h" ticket/T-dg/dev-box 'Ticket: T-dg'
    : >"$FAKE_TAMPERGUARD_LOG"
    gate "$s"
    ci="$RC|$(grep '^diff-gates:' <<<"$ERR")|$(grep -v '^diff-gates:\|gate from ' <<<"$ERR")|$(command cat "$FAKE_TAMPERGUARD_LOG")"
    check "$s: the node's calls, verdict and output equal CI's" eq "$node" "$ci"
    check "$s: the calls are the helper's (traced)" eq "$(grep -c "^diff-gates: .*$BASE" <<<"$ERR" | sed 's/^0$/none/')" \
      "$(case "$s" in tamper-check) echo 1 ;; *) echo 2 ;; esac)"
  done
}

# run.sh calls the same scripts and the same helper with the same range (I17).
case_run_call_sites() {
  local run="$BIN/run.sh"
  check "run.sh sources lib/diff-gates.sh" grep -qE '^\. "\$\(dirname "\$0"\)/lib/diff-gates\.sh"' "$run"
  check "run.sh calls rails-proof.sh --ticket --base \$GATE_BASE --head \$GATE_HEAD" \
    grep -qF '"$FACTORY_ROOT/factory/bin/rails-proof.sh" --ticket "$TICKET" --base "$GATE_BASE" --head "$GATE_HEAD"' "$run"
  check "run.sh calls scope-check.sh --ticket --base \$GATE_BASE --head \$GATE_HEAD" \
    grep -qF '"$FACTORY_ROOT/factory/bin/scope-check.sh" --ticket "$TICKET" --base "$GATE_BASE" --head "$GATE_HEAD"' "$run"
  check "run.sh feeds tamperguard dg_tamper_argv's argv and judges with dg_tamper_judge" \
    eq "$(grep -cE 'dg_tamper_argv "\$GATE_BASE" "\$GATE_HEAD"|dg_tamper_judge ' "$run")" 2
  check "the gate base is the merge-base with origin/main (of fleet's tip; GATE_HEAD is built on it, T23)" grep -qF 'GATE_BASE="$(git -C "$WT" merge-base refs/remotes/origin/main "$tip")"' "$run"
  check "run.sh has no scope-check seam and no not-built hold" eq "$(grep -cE 'FACTORY_SCOPE_CHECK|scope-check-not-built' "$run" || true)" 0
  check "run.sh refuses to start without adversarial-review" grep -qE '^need adversarial-review' "$run"
}

# gates.yml's tamper job runs the base's tamper-check.sh with the helper's pins.
case_gates_yml_tamper() {
  local wf="$REPO_ROOT/.github/workflows/gates.yml" pin py
  pin="$(bash -c '. "$1"; echo "$DG_TAMPERGUARD_PIN"' _ "$BIN/lib/diff-gates.sh")"
  py="$(bash -c '. "$1"; echo "$DG_TAMPERGUARD_PYTHON"' _ "$BIN/lib/diff-gates.sh")"
  check "tamper: checkout head (fetch-depth 0), then base into .base" \
    eq "$(yq -o=json -I=0 '.jobs.tamper.steps | map(select((.uses // "") | test("^actions/checkout@")) | .with)' "$wf")" \
       '[{"ref":"${{ env.GATE_HEAD }}","fetch-depth":0},{"ref":"${{ env.GATE_BASE }}","path":".base"}]'
  check "tamper: setup-python is the node's minor ($py)" eq "$(yq -r '.jobs.tamper.steps[] | select((.uses // "") | test("^actions/setup-python@")) | .with."python-version"' "$wf")" "$py"
  check "tamper: pipx installs tamperguard==$pin on python$py" \
    eq "$(yq -r '.jobs.tamper.steps[] | select(has("run")) | .run' "$wf" | grep -c "^pipx install --python python$py tamperguard==$pin\$")" 1
  check "tamper: runs the base's tamper-check.sh" \
    eq "$(yq -r '.jobs.tamper.steps[] | select(has("run")) | .run' "$wf" | grep -c '^\./\.base/factory/bin/tamper-check\.sh$')" 1
  check "tamper: no if: (it reports on pull_request and merge_group)" eq "$(yq -r '.jobs.tamper | has("if")' "$wf")" false
  check "rails-proof and scope run the base's scripts" \
    eq "$(yq -r '.jobs["rails-proof"].steps[-1].run + " " + .jobs.scope.steps[-1].run' "$wf")" \
       "./.base/factory/bin/rails-proof.sh ./.base/factory/bin/scope-check.sh"
}

for c in glob-table rails scope tamper classes ci-equals-node run-call-sites gates-yml-tamper; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
