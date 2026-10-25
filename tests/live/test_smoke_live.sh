#!/usr/bin/env bash
# T11 Part A against the REAL box (`make live`, never `make test`): build order step 2 end to end, a
# friend's path with a fixture in place of GitHub (I1: nothing here can reach github.com).
#
#   1. origin  tests/fixtures/make-repo.sh builds a bare origin whose main is this repo's HEAD
#              (`git archive`) plus three overlays: the toy ticket T-smoke, created in the fixture's
#              own store by the real `adlc ticket create --write`; `fleet.gate` in .adlc/config.json
#              (test: `bash tests/test_hello.sh`) with `fleet.allowedCommands` for the toy ticket,
#              whose one rail is factory/policy/** (fleet's rails-guard refuses a ticket with none);
#              budget weights.light.wallClockMinutes = 15. fleet's claude-code worker may run only
#              the gate commands, allowedCommands and read-only git (adapters/claude-code.mjs
#              buildSettings), so without `chmod +x` it answers TICKET-BLOCKED (follow-ups TB5 records).
#   2. HOME    a scratch HOME, because vetto 0.6.5 fails closed on this box's real one (~/.aws is a
#              symlink, records/TB1.md §3.9; ~/.claude as a symlink fails the same way). Its
#              .claude/.credentials.json is a HARD link to the real file: no copy of the secret, a
#              token refreshed in place lands in the real file, and bwrap cannot bind over a
#              symlink. .claude.json carries only the keys fleet's own synthetic home allows.
#   3. GitHub  the API surface (Issues, the ref-lock API) is tests/fakes/gh backed by the fixture
#              origin, so the claim ref lands in the fixture. Issue #1 mirrors T-smoke (ready,
#              w:light). The repo slug is fixture/smoke and the scratch HOME holds no gh login.
#   4. join    `join.sh --handle dev-box --apply --remote origin` from a clone of the fixture
#              (--no-suite; no quiet hours; quota cap 0.95, because this box's one account is also
#              the account of whoever runs the smoke). join installs fleet's trusted prosecutor,
#              adversarial-review 2.11.1, under the scratch FACTORY_HOME, checked against its pinned
#              npm integrity (ruling Q4, T15); the smoke installs no reviewer of its own.
#   5. quota   the `cux add` line join printed in its register step (ruling Q5; join never runs
#              it), run here as the owner would, into the scratch HOME's cux store; then
#              `cux usage refresh`.
#   6. review  fleet resolves the reviewer join installed on the orchestrator PATH ($FACTORY_HOME/bin
#              first, from join's env file).
#   7. run     `run.sh --slot 1 --apply --once --json` with the real vetto (tamperguard under the
#              claim's render of build.toml, T17), ralon, tamperguard, cux
#              and `npx -y @adlc/cli@1.12.0 fleet`, adapter claude-code, at most 2 strikes in 15 min.
#
# It then checks that the loop took the branch ADR-0005 specifies for the reason fleet gave (a
# reason other than success passes when its branch is the specified one), that fleet's sandbox
# was enforced, and that no ticket text left the node (I8). It prints the six recorded items
# (governor line, claim ref, fleet reason, pushed branch, ledger line, token count) and the sandbox
# evidence (fleet's policy echo, vetto audit) for the records: TB6 of specs/factory-step2-v1, TB5 of
# specs/factory-step2-followups-v1.
#
# Prints `SKIP <reason>` and exits 0 when a tool it needs is absent, the network is unreachable,
# claude is not logged in, or the governor will not claim now (quota at the cap): it never waits.
# FACTORY_SMOKE_KEEP=<dir> copies the node-local evidence there (it holds transcripts: keep it local).
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/../fakes/lib.sh"
echo "test_smoke_live"

for t in git jq curl npx npm node claude bwrap vetto ralon tamperguard cux timeout; do
  command -v "$t" >/dev/null || { echo "SKIP $t not installed"; exit 0; }
done
for u in https://registry.npmjs.org/@adlc%2fcli https://api.anthropic.com; do
  curl -sS -o /dev/null --max-time 15 "$u" 2>/dev/null || { echo "SKIP $u unreachable"; exit 0; }
done
CRED="$HOME/.claude/.credentials.json"
[ -f "$CRED" ] && [ ! -L "$CRED" ] || { echo "SKIP claude-code has no credential file at $CRED"; exit 0; }
[ "$(claude auth status --json 2>/dev/null | jq -r '.loggedIn // false' 2>/dev/null)" = true ] ||
  { echo "SKIP claude-code is not logged in"; exit 0; }

ADV_VERSION=2.11.1
ADV_INTEGRITY=sha512-LiPc0R5UXJQ/tsUd3yEOVkISYxtbyFlvDlMFPtLW1lcVNhLjOqluDZXaVmYYEb0oONdsSs+xVbAbyWN2e0HCEA==
MARK="exactly the five letters h e l l o"   # in the ticket body only: I8 greps every outbound payload for it

info() { printf '    INFO %s\n' "$*"; }
quiet() { "$@" >/dev/null 2>&1; }
base="${FACTORY_LIVE_TMP:-$HOME/.cache}"   # vetto refuses a cwd under /tmp
mkdir -p "$base"
S="$(mktemp -d "$base/factory-smoke.XXXXXX")"
chmod 700 "$S"
KEEP="${FACTORY_SMOKE_KEEP:-}"
keep() {
  local k="$KEEP"
  [ -n "$k" ] || return 0
  rm -rf "$k"; mkdir -p "$k"
  command cp -a "$S/fh/run" "$k/run" 2>/dev/null || true
  command cp -a "$S"/*.json "$S"/*.log "$S"/*.out "$S"/*.err "$k/" 2>/dev/null || true
  git clone -q --mirror "$S/origin.git" "$k/origin.git" 2>/dev/null || true
}
trap 'keep; chmod -R u+w "$S" 2>/dev/null; rm -rf "$S"' EXIT
O="$S/origin.git" C="$S/clone" FH="$S/fh" NH="$S/home"

# ---- 1. the fixture origin ----------------------------------------------------------------------
echo "  1. fixture origin: this repo's HEAD + T-smoke + fleet.gate + fleet.allowedCommands"
mkdir -p "$S/main"
git -C "$REPO_ROOT" archive HEAD | tar -x -C "$S/main"
# Each entry becomes a `Bash(<entry>)` rule in the worker's .claude/settings.local.json.
ALLOWED='["chmod +x hello.sh", "chmod +x hello.sh tests/test_hello.sh", "./hello.sh", "bash tests/test_hello.sh:*"]'
jq --argjson a "$ALLOWED" '.fleet = {gate: {test: "bash tests/test_hello.sh"}, allowedCommands: $a}' \
  "$S/main/.adlc/config.json" >"$S/cfg.tmp"
mv "$S/cfg.tmp" "$S/main/.adlc/config.json"
jq '.weights.light.wallClockMinutes = 15' "$S/main/factory/policy/budget.json" >"$S/budget.tmp"
mv "$S/budget.tmp" "$S/main/factory/policy/budget.json"
body="$(printf '%s\n' 'weight: light' 'tier: 0' 'charter: C5' '' \
  'Add an executable shell script `hello.sh` at the repository root that prints hello: '"$MARK"', on one line, and exits 0. Add `tests/test_hello.sh`, a bash test that runs ./hello.sh, compares its output with hello, prints PASS or FAIL and exits non-zero on a mismatch. Touch nothing else.' '' \
  'Acceptance criteria:' \
  '1. ./hello.sh prints hello and exits 0. Verify: `test "$(./hello.sh)" = hello`.' \
  '2. tests/test_hello.sh passes against hello.sh and fails when hello.sh prints anything else. Verify: `bash tests/test_hello.sh`.')"
# One rail at least: fleet's gate runs `adlc rails-guard --ticket <id>`, which exits 1 on a ticket
# with no rails ("has no rails declared"), so `rails: []` fails every strike (follow-ups TB5 records).
# factory/policy/** is the rail ralon-lock.sh protects for every ticket anyway.
jq -n --arg b "$body" '{id: "T-smoke", title: "Add hello.sh that prints hello, with a test", category: "feature",
    duration: 1, scope: ["hello.sh", "tests/test_hello.sh"], rails: ["factory/policy/**"], edges: [], body: $b}' >"$S/t-smoke.json"
# HEAD's store already holds railed tickets (T17-T19), so it is a frozen trust root and adlc 1.12.0
# refuses an unkeyed write with MANIFEST_KEY_REQUIRED; the desk writes unsigned (ruling Q1 of
# specs/factory-run-calls-v1, as post-merge.sh does), into the fixture's copy only.
rc=0
(cd "$S/main" && npx -y @adlc/cli@1.12.0 ticket create --input "$S/t-smoke.json" --write --allow-unsigned --json) >"$S/ticket-create.json" 2>"$S/ticket-create.err" || rc=$?
check "adlc ticket create --write T-smoke exits 0" eq "$rc" 0
check "T-smoke is in the fixture's store" quiet ls "$S/main/.adlc/tickets/"t-smoke--*.json
printf 'main-dir %s\nnode alice 1761300000 active 2\n' "$S/main" | bash "$REPO_ROOT/tests/fixtures/make-repo.sh" "$O"
check "the fixture's main carries T-smoke, the gate and the allowed commands" \
  eq "$(git -C "$O" show main:.adlc/config.json | jq -c '[.fleet.gate.test, .fleet.allowedCommands]') $(git -C "$O" ls-tree --name-only main .adlc/tickets/ | grep -c t-smoke)" \
  "$(jq -cn --argjson a "$ALLOWED" '["bash tests/test_hello.sh", $a]') 1"
check "main's factory/bin is this repo's HEAD factory/bin, byte for byte and mode for mode" \
  eq "$(git -C "$O" rev-parse main:factory/bin)" "$(git -C "$REPO_ROOT" rev-parse HEAD:factory/bin)"

# ---- 2. the node's HOME, gh and environment -------------------------------------------------------
echo "  2. node: scratch HOME, fake gh on the fixture, no GitHub reachable"
mkdir -p "$NH/.claude" "$S/bin"
chmod 700 "$NH" "$NH/.claude"
ln "$CRED" "$NH/.claude/.credentials.json" 2>/dev/null || { echo "SKIP $base is not on the filesystem of $CRED (a hard link is needed)"; exit 0; }
jq '{oauthAccount, hasCompletedOnboarding, userID, installMethod, autoUpdates, theme, numStartups, hasSeenTasksHint}
    | with_entries(select(.value != null))' "$HOME/.claude.json" >"$NH/.claude.json"
gname="$(git config user.name || echo dev-box)" gmail="$(git config user.email || echo dev-box@factory.invalid)"
printf '[user]\n\tname = %s\n\temail = %s\n' "$gname" "$gmail" >"$NH/.gitconfig"
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$REPO_ROOT/tests/fakes/gh" >"$S/bin/gh"
chmod +x "$S/bin/gh"
printf '{"labels":["ready","needs-desk","in-progress","w:light","w:heavy"],"issues":[]}\n' >"$S/issues.json"
: >"$S/gh.log"
while IFS= read -r v; do unset "$v"; done < <(compgen -e | grep -E '^(CLAUDECODE|CLAUDE_CODE_|ANTHROPIC_|ADLC_|GH_|GITHUB_|XDG_|GIT_|FACTORY_|FAKE_)' || true)
export HOME="$NH" FACTORY_HOME="$FH" FACTORY_REPO=fixture/smoke PATH="$S/bin:$PATH"
export FAKE_GH_GIT="$O" FAKE_GH_ISSUES="$S/issues.json" FAKE_GH_LOG="$S/gh.log" FAKE_GH_REPO=fixture/smoke FAKE_GH_USER=dev-box
fakegh_issue 1 "$(($(date +%s) - 3600))" ready,w:light "T-smoke: Add hello.sh that prints hello, with a test" \
  "$(printf '<!-- mirrored by factory/bin/mirror.sh -->\nTicket: T-smoke\n\n%s\n' "$body")" musicofhel
check "gh is the fake, on the fixture" eq "$(command -v gh)" "$S/bin/gh"
check "claude is logged in under the scratch HOME" eq "$(claude auth status --json 2>/dev/null | jq -r .loggedIn)" true
git clone -q "$O" "$C"

# ---- 3. join ----------------------------------------------------------------------------------------
echo "  3. join.sh --apply against the fixture"
tip0="$(git -C "$O" rev-parse refs/heads/nodes)"
rc=0
(cd "$C" && factory/bin/join.sh --handle dev-box --apply --remote origin --repo fixture/smoke --no-suite \
   --tz UTC --quiet-start 00:00 --quiet-end 00:00 --quota-cap 0.95 --json) >"$S/join.json" 2>"$S/join.err" || rc=$?
check "join --apply exits 0" eq "$rc" 0
[ "$rc" = 0 ] || sed -n '1,60p' "$S/join.err"
check "no refusal" eq "$(jq -c .refusals "$S/join.json")" "[]"
check "nodes/dev-box.json is on the fixture's nodes tip, a fast-forward" \
  eq "$(git -C "$O" rev-parse refs/heads/nodes^) $(git -C "$O" cat-file blob refs/heads/nodes:nodes/dev-box.json | jq -r .handle)" "$tip0 dev-box"
info "join plan: $(jq -r '[.plan[] | "\(.tool) \(.pin) \(.state)"] | join("; ")' "$S/join.json")"
info "manifest: $(jq -c '{handle, slots, heavy_gates, adapters, quota_cap, quiet_hours}' "$FH/manifest.json")"

# ---- 4. quota and the prosecutor, both from join ------------------------------------------------------
echo "  4. the cux line join printed, and join's adversarial-review $ADV_VERSION"
# shellcheck source=/dev/null  # written by join.sh --apply
. "$FH/env"
qline="$(jq -r '.register.quota.command // empty' "$S/join.json")"
check "join printed the cux line for the owner" eq "$qline" "cux add --no-alias"
read -ra qargv <<<"$qline"
check "the owner runs join's cux line (the logged-in account, into the scratch HOME's store)" quiet "${qargv[@]}"
quiet cux usage refresh || true
info "cux usage: $(cux usage show | jq -c '[.[] | {five_hour: .five_hour.utilization, seven_day: .seven_day.utilization}]')"
check "join installed adversarial-review $ADV_VERSION under FACTORY_HOME with the pinned integrity" \
  eq "$(jq -r .version "$FH/lib/node_modules/adversarial-review/package.json" 2>/dev/null) $(command cat "$FH/receipts/adversarial-review@$ADV_VERSION" 2>/dev/null)" \
  "$ADV_VERSION $ADV_INTEGRITY"
check "fleet will resolve join's reviewer on the orchestrator PATH" eq "$(command -v adversarial-review)" "$FH/bin/adversarial-review"

# ---- 5. the run loop ------------------------------------------------------------------------------------
echo "  5. run.sh --slot 1 --apply --once (real vetto, ralon, fleet; claude-code)"
dry="$(cd "$C" && factory/bin/run.sh --slot 1 --json 2>/dev/null)" || true
info "dry run: $dry"
if [ "$(jq -r '.governor.action // empty' <<<"$dry")" != claim ]; then
  echo "SKIP the governor will not claim now: $(jq -c .governor <<<"$dry")"
  [ "$FAILED" = 0 ] && echo "PASS test_smoke_live (setup only)" || echo "FAIL test_smoke_live ($FAILED)"
  [ "$FAILED" = 0 ]; exit
fi
t0="$(date +%s)" rc=0
(cd "$C" && timeout 1800 factory/bin/run.sh --slot 1 --apply --once --json) >"$S/run.out" 2>"$S/run.err" || rc=$?
elapsed=$(( $(date +%s) - t0 ))
L="$(tail -n1 "$S/run.out")"
f() { jq -r "$@" <<<"$L"; }
check "one ledger line, the same on stdout and in the ledger" \
  eq "$(wc -l <"$S/run.out" | tr -d ' ') $(tail -n1 "$FH/run/ledger.jsonl")" "1 $L"
check "the governor said claim" eq "$(f .governor.action)" claim
check "the loop claimed Issue #1 for T-smoke (weight light)" eq "$(f '"\(.issue) \(.ticket) \(.weight)"')" "1 T-smoke light"
check "the budget is 2 strikes in 15 minutes" eq "$(f '"\(.budget.max_strikes) \(.budget.wall_clock_minutes)"')" "2 15"
lockpost="$(jq -c 'select(.[0] == "api" and index("POST") != null and index("ref=refs/locks/issue-1") != null)' "$S/gh.log" | head -n1)"
lock_sha="$(jq -r '.[] | select(startswith("sha=")) | ltrimstr("sha=")' <<<"$lockpost" 2>/dev/null || true)"
check "the claim POSTed refs/locks/issue-1 on the fixture's ref API" test -n "$lock_sha"
check "the lock commit is in the fixture and names dev-box and this run" \
  eq "$(git -C "$O" cat-file commit "$lock_sha" 2>/dev/null | sed '1,/^$/d' | tail -n1 | jq -r '"\(.handle) \(.run_id)"')" "dev-box $(f .run_id)"
check "ralon rendered the rails lock and fleet ran under it" \
  eq "$(f '[.actions[] | select(. == "ralon-lock" or . == "fleet-run")] | join(" ")')" "ralon-lock fleet-run"
DOC="$FH/run/logs/$(f .run_id).fleet.json"
doc() { jq -c 'select(type == "object" and has("exitCode"))' "$DOC" 2>/dev/null | head -n1 | jq -r "$@"; }
check "fleet printed its --json result document" test -n "$(doc '.exitCode // empty')"
check "strikes <= 2" test "$(f '.fleet.strikes // 0')" -le 2
check "fleet's wall clock held (run.sh took $elapsed s; 15 min + the loop's own steps)" test "$elapsed" -le 1200

# The sandbox: fleet refuses to dispatch without one (preflight). Once it dispatched, its policy echo
# must show the bounded model plane with the git mirror on the egress allowlist. When it stopped
# before any worker (a run-level reason from preflight or the flag checks), the echo is not
# evidence: no worker ran, the loop built the mirror the bounded argv names, and fleet's own stderr
# names the cause (a canary that bwrap refused is an enforced sandbox, never an open one).
if [ "$(doc '.fleetRunId != null')" = true ]; then
  check "fleet's model plane: bounded reads, the git mirror" eq "$(doc '"\(.readPolicy) \(.privateTmp) \(.gitSource)"')" "bounded true mirror"
  check "fleet's model plane ran on the egress allowlist (adapter hosts only)" \
    eq "$(doc '"\(.egress) \(.egressAllowlist | sort | join(","))"')" "allowlist api.anthropic.com:443,console.anthropic.com:443,platform.claude.com:443"
else
  cause="$(grep -hE '^(preflight failed|fleet:)' "$FH/run/logs/"*.fleet.err 2>/dev/null | head -n1 || true)"
  info "fleet stopped before any worker: ${cause:-no cause on its stderr}"
  check "fleet stopped before any worker: no run id, no strike consumed" eq "$(doc '"\(.fleetRunId) \(.strikesConsumed)"')" "null 0"
  check "  the loop built the model-plane mirror its bounded argv names" eq "$(f '.actions | index("mirror") != null')" true
  check "  fleet's stderr names the cause" test -n "$cause"
  if grep -q 'canary' <<<"$cause"; then
    check "  the canary failed INSIDE bwrap (enforced, not open)" grep -q 'bwrap: ' <<<"$cause"
  fi
fi
check "fleet did not refuse its sandbox" eq "$(grep -ciE 'sandbox precondition|no sandbox backend' "$S/run.err" "$FH/run/logs/"*.fleet.err 2>/dev/null | awk -F: '{s += $NF} END {print s + 0}')" 0

# ---- 6. the branch for the reason (ADR-0005 decision 11 and run.sh's header) --------------------------
reason="$(f '.reason // ""')" outcome="$(f .outcome)"
origin_branch="$(git -C "$O" rev-parse -q --verify refs/heads/ticket/T-smoke/dev-box || true)"
local_branch="$(git -C "$C" rev-parse -q --verify refs/heads/ticket/T-smoke/dev-box || true)"
lock_now="$(git -C "$O" rev-parse -q --verify refs/locks/issue-1 || true)"
labels="$(jq -r '.issues[0] | [.labels[].name] | sort | join(",")' "$S/issues.json")"
ncomments="$(jq -r '.issues[0].comments | length' "$S/issues.json")"
echo "  6. fleet reason '$(f '.fleet.reason // "none (success)"')' -> loop reason '${reason:-none}', outcome $outcome, exit $rc"
case "$reason" in
  scope-check-not-built)  # success, then step 3's scope-check stub: held locally, nothing pushed
    check "fleet merged the ticket into its integration branch" eq "$(f '"\(.fleet.exit_code) \(.fleet.merged >= 1)"')" "0 true"
    check "tamperguard ran under vetto and passed" eq "$(f '.tamperguard.verdict | IN("ok", "review")')" true
    check "held: exit 2, local ticket branch, nothing pushed, lock released" \
      eq "$rc $outcome ${local_branch:+local} ${origin_branch:-none} ${lock_now:-released}" "2 held local none released" ;;
  quota-paused|wall-clock)
    check "paused: exit 0, partial branch pushed, lock kept, slot state saved" \
      eq "$rc $outcome ${origin_branch:+pushed} ${lock_now:+held} $([ -f "$FH/run/slot-1.json" ] && echo saved)" "0 paused pushed held saved" ;;
  strikes-exhausted|flail)
    check "desk: exit 0, branch pushed, needs-desk, lock released" \
      eq "$rc $outcome ${origin_branch:+pushed} $(grep -c needs-desk <<<"$labels") ${lock_now:-released}" "0 desk pushed 1 released" ;;
  review-unavailable)
    check "review-unavailable: exit 0, released, no comment beyond the claim, nap 30 min" \
      eq "$rc $outcome ${lock_now:-released} $ncomments $(f .sleep_seconds)" "0 released released 1 1800" ;;
  lock-held|ticket-blocked|mirror-fetch-failed)
    check "$reason: exit 0, released, nap 10 min" eq "$rc $outcome ${lock_now:-released} $(f .sleep_seconds)" "0 released released 600" ;;
  tamper|scope-fail)
    check "$reason: desk, needs-desk, nothing pushed" eq "$outcome $(grep -c needs-desk <<<"$labels") ${origin_branch:-none}" "desk 1 none" ;;
  *)  # run-level fleet reasons and the loop's own failures stop the slot
    check "$reason: exit 1, released, slot stopped" eq "$rc $outcome ${lock_now:-released}" "1 released released" ;;
esac
if [ -n "$origin_branch" ]; then
  check "the pushed tip is a record commit with the I6 trailers" \
    eq "$(git -C "$O" log -1 --format='%(trailers:key=Ticket,valueonly,separator=)|%(trailers:key=Node,valueonly,separator=)' "$origin_branch")" "T-smoke|dev-box"
fi
# Whenever the loop ran its tamperguard step, it ran under vetto + this claim's render of build.toml
# ($FACTORY_HOME/run/policy/<run id>.build.toml, T17): the latest vetto session in the scratch HOME is
# that call (step-2 AC2). vetto exits 125 whatever happened, so this proves where tamperguard ran,
# not what it said; the ledger's reason says that. vetto 0.6.5's session detail redacts a
# high-entropy path segment in .command (`factory-smoke.[REDACTED_HIGH_ENTROPY].build.toml`), so the
# render is matched on its history entry's policy_path, which it keeps whole. The render itself only
# adds read roots (I14).
RENDER="$FH/run/policy/$(f .run_id).build.toml"
if [ "$(f '.actions | index("tamperguard") != null')" = true ]; then
  latest="$(vetto audit --latest --json 2>/dev/null || true)"
  check "tamperguard ran under vetto: the latest session is factory-build, strict, tamperguard over the range" \
    eq "$(jq -r '"\(.profile) \(.command | test("--profile strict --policy [^ ]+\\.build\\.toml ")) \(.command | test("tamperguard --range"))"' <<<"$latest" 2>/dev/null)" \
    "factory-build true true"
  check "  that session ran under this claim's render (vetto's history: its policy_path)" \
    eq "$(vetto audit --query "$RENDER" --json 2>/dev/null | jq -r --arg p "$RENDER" '[.[] | select(.policy_path == $p) | .session_id] | last // "none"')" \
    "$(jq -r '.session_id // "no-session"' <<<"$latest" 2>/dev/null)"
  check "  the render differs from build.toml only on its allow_read line (I14)" \
    eq "$(diff "$C/factory/policy/build.toml" "$RENDER" 2>/dev/null | grep -E '^[<>]' | sed -E 's/^([<>]) *([a-z_]+).*/\1 \2/' | sort | tr '\n' ' ')" "< allow_read > allow_read "
  check "  tamperguard's stderr is kept in the run's logs" test -f "$FH/run/logs/$(f .run_id).tamperguard.err"
fi

# ---- 7. I8: no ticket text in anything that left the node ---------------------------------------------
outbound="$S/outbound.txt"
{
  jq -r 'select(.[0] != "issue" or .[1] != "list") | .[]' "$S/gh.log"
  jq -r '.issues[].comments[]?.body' "$S/issues.json"
  git -C "$O" log --format=%B --all
  command cat "$FH/run/ledger.jsonl" "$S/run.out"
} >"$outbound"
check "no ticket text in a gh call, comment, pushed commit or ledger line (I8)" eq "$(grep -cF "$MARK" "$outbound" || true)" 0

# ---- the recorded items -------------------------------------------------------------------------------
tokens="$({ find "$NH/.claude/projects" -name '*.jsonl' -print0 2>/dev/null || true; } | xargs -0 -r cat |
  jq -sc '[.[] | select(.type == "assistant") | .message.usage // empty]
          | {messages: length, input: (map(.input_tokens // 0) | add // 0), output: (map(.output_tokens // 0) | add // 0),
             cache_read: (map(.cache_read_input_tokens // 0) | add // 0),
             cache_creation: (map(.cache_creation_input_tokens // 0) | add // 0)}' 2>/dev/null || echo null)"
echo "  recorded items"
info "governor line: $(f -c .governor)"
info "claim ref: refs/locks/issue-1 -> $lock_sha in the fixture ($(git -C "$O" cat-file commit "$lock_sha" 2>/dev/null | sed '1,/^$/d' | tail -n1)); now ${lock_now:-released}"
info "fleet: $(f -c .fleet); doc reason $(doc '.reason // "null"'), ticket reasonCode $(doc '.tickets["T-smoke"].reasonCode // "null"'), review $(doc -c '.tickets["T-smoke"].review // .review // null')"
info "pushed: origin ticket/T-smoke/dev-box ${origin_branch:-absent}; local ticket/T-smoke/dev-box ${local_branch:-absent}"
[ -z "$origin_branch" ] || git -C "$O" log -1 --format='%B' "$origin_branch" | sed 's/^/    | /'
info "ledger line: $L"
info "tokens (node-local claude transcripts; fleet 1.12.0's result has no count, so the ledger says null): $tokens"
info "wall clock: run.sh $elapsed s"
info "fleet policy echo: $(doc -c '{readPolicy, privateTmp, gitSource, mirror, egress, egressAllowlist, homeBinds, writableRoots}')"
info "issue #1: labels $labels, $ncomments comment(s)"
jq -r '.issues[0].comments[].body' "$S/issues.json" | sed 's/^/    | comment: /'
info "rendered policy: $(grep -E '^[[:space:]]*allow_read[[:space:]]*=' "$RENDER" 2>/dev/null || echo "none (the step did not run)")"
info "tamperguard: ledger $(f -c .tamperguard), loop reason ${reason:-none}; stderr: $(head -c 300 "$FH/run/logs/$(f .run_id).tamperguard.err" 2>/dev/null | tr '\n' ' ')"
if quiet vetto audit --latest --json; then
  info "vetto audit --latest: $(vetto audit --latest --json 2>/dev/null | jq -c '{session: (.session_id // .id), profile, command, tier, net_mode, violations_total, events_total, filesystem_denials}' 2>/dev/null || echo unparsed)"
  info "vetto history for the render: $(vetto audit --query "$RENDER" --json 2>/dev/null | jq -c '[.[] | {session_id, profile, policy_path, tier, net_mode, blocked_count}]' 2>/dev/null || echo none)"
else
  info "vetto audit: no session (the loop's vetto step, tamperguard, runs only after fleet merges)"
fi

[ "$FAILED" = 0 ] && echo "PASS test_smoke_live" || echo "FAIL test_smoke_live ($FAILED)"
[ "$FAILED" = 0 ]
