#!/usr/bin/env bash
# T8: the budget governor (factory/bin/governor.sh, factory/bin/lib/governor.sh) and fleet's
# pre-strike gate (factory/bin/quota-gate.sh). Offline: a fixture origin from
# tests/fixtures/make-repo.sh, the node's clone of it, the fake cux (tests/fakes/cux), a fake
# `claude` for version-check, and a closed PATH. The clock is FACTORY_NOW.
# Acceptance 1 (one case per reason), 2 midnight-wrap, 3 dst, 4 cux-malformed, 5 heartbeat-hourly,
# 6 fake-cux, 7 quota-gate; plus the order of the checks and I8 (no cux account key in any output).
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
GOV="$BIN/governor.sh"
GATE="$BIN/quota-gate.sh"
iso() { jq -nr --argjson e "$1" '$e | todate'; }
epoch() { jq -nr --arg d "$1" '$d | fromdateiso8601'; }
T0="$(epoch 2026-10-25T12:00:00Z)"   # the default clock: a Sunday noon UTC, no DST change near

# gov_setup [make-repo spec lines...]: a fixture origin with adapters.json on main and nodes/dev-box
# on nodes, the node's clone, a manifest, one account under the cap, the closed PATH.
gov_setup() {
  [ -z "${WORLD:-}" ] || rm -rf "$WORLD"   # a case that sets up twice
  WORLD="$(mktemp -d "${TMPDIR:-/tmp}/gov.XXXXXX")"
  # shellcheck disable=SC2064  # expand now: WORLD is per case
  trap "rm -rf '$WORLD'" EXIT
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=node GIT_AUTHOR_EMAIL=node@fake GIT_COMMITTER_NAME=node GIT_COMMITTER_EMAIL=node@fake
  export FACTORY_NOW="$T0" FACTORY_MANIFEST="$WORLD/manifest.json" FAKE_CUX_USAGE="$WORLD/usage.json"
  export FAKE_CUX_LOG="$WORLD/cux.log" GOV_GIT_STATE="$WORLD/git-state" TZ=UTC
  unset FACTORY_CUX FAKE_CUX_REFRESH_EXIT FAKE_CUX_REFRESHED GOV_GIT_MODE FACTORY_HANDLE
  { printf '%s\n' 'main-file factory/policy/adapters.json {"claude-code": "2.1.280", "codex": null}' \
      "node dev-box $((T0 - 7200)) joining 2 dev-box" "$@"; } | tests/fixtures/make-repo.sh "$WORLD/origin.git"
  git clone -q "$WORLD/origin.git" "$WORLD/clone"
  : >"$FAKE_CUX_LOG"
  mkdir -p "$WORLD/bin" "$WORLD/sys"
  ln -s "$REPO_ROOT/tests/fakes/cux" "$WORLD/bin/cux"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo "${FAKE_CLAUDE_VERSION:-2.1.280} (Claude Code)"\n' >"$WORLD/bin/claude"
  # git through a wrapper that can break one fetch or race one push (GOV_GIT_MODE), else the real one.
  REAL_GIT="$(command -v git)"
  command cat >"$WORLD/bin/git" <<EOF
#!/usr/bin/env bash
case "\${GOV_GIT_MODE:-}:\$*" in
  fail-second-main-fetch:*fetch*refs/heads/main*)
    n=\$(( \$(command cat "\$GOV_GIT_STATE" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"\$GOV_GIT_STATE"
    [ "\$n" -lt 2 ] || { echo "fatal: unable to access the remote" >&2; exit 128; } ;;
  race-nodes-*:*push*refs/heads/nodes*)
    n=\$(( \$(command cat "\$GOV_GIT_STATE" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"\$GOV_GIT_STATE"
    if [ "\$n" -le "\${GOV_GIT_MODE#race-nodes-}" ]; then
      o="$WORLD/origin.git"; tip=\$("$REAL_GIT" -C "\$o" rev-parse nodes)
      c=\$(printf 'nodes: someone else %s\n' "\$n" | "$REAL_GIT" -C "\$o" commit-tree "\$tip^{tree}" -p "\$tip")
      "$REAL_GIT" -C "\$o" update-ref refs/heads/nodes "\$c" "\$tip"
    fi ;;
esac
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$WORLD/bin/claude" "$WORLD/bin/git"
  local t
  for t in bash env jq sed grep head tr cat dirname date mktemp rm mv cp awk; do ln -s "$(command -v "$t")" "$WORLD/sys/$t"; done
  GPATH="$WORLD/bin:$WORLD/sys"
  manifest '.'
  usage '{"a@example.invalid": {"polled_at": "'"$(iso $((T0 - 300)))"'",
          "five_hour": {"utilization": 10, "resets_at": "'"$(iso $((T0 + 3600)))"'"},
          "seven_day": {"utilization": 20, "resets_at": "'"$(iso $((T0 + 86400)))"'"}}}'
}
manifest() {  # manifest <jq update>: the node's manifest, last_seen 10 min ago, no quiet hours
  jq -n --arg seen "$(iso $((T0 - 600)))" '
    {handle: "dev-box", owner: "dev-box", os: "linux", cpu: 8, ram_gb: 16, slots: 2, heavy_gates: false,
     adapters: {"claude-code": "2.1.280"}, quota_tier: "pro", quota_cap: 0.4,
     quiet_hours: {tz: "UTC", start: "00:00", end: "00:00"}, accounts: 2, factory_version: "0.1.0",
     last_seen: $seen, status: "joining"}' | jq "$1" >"$FACTORY_MANIFEST"
}
usage() { printf '%s\n' "$1" >"$FAKE_CUX_USAGE"; }
# win <util> <resets-in-seconds|null>: one cux window object
nowe() { if [[ "$FACTORY_NOW" =~ ^[0-9]+$ ]]; then echo "$FACTORY_NOW"; else epoch "$FACTORY_NOW"; fi; }
win() { if [ "$2" = null ]; then printf '{"utilization": %s}' "$1"; else printf '{"utilization": %s, "resets_at": "%s"}' "$1" "$(iso $(($(nowe) + $2)))"; fi; }
polled() { iso $(($(nowe) - ${1:-60})); }  # polled [seconds-ago]: a polled_at that long before the clock
gov() {  # gov <args>: governor in the clone on the closed PATH; sets RC, OUT, ERR
  RC=0
  OUT="$(cd "$WORLD/clone" && PATH="$GPATH" "$GOV" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
gate() {  # gate <args>: quota-gate on the closed PATH; sets RC, OUT, ERR
  RC=0
  OUT="$(PATH="$GPATH" "$GATE" "$@" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
}
is() { eq "$OUT" "{\"action\":\"$1\",\"reason\":\"$2\",\"sleep_seconds\":$3}"; }
quiet() { "$@" >/dev/null 2>&1; }
noleak() { ! grep -q 'example\.invalid' <<<"$OUT$ERR"; }
nodes_tip() { git -C "$WORLD/origin.git" rev-parse nodes; }
nodes_file() { git -C "$WORLD/origin.git" cat-file blob "nodes:nodes/dev-box.json"; }

# ---------------------------------------------------------------------------------- acceptance 1
case_claim() {
  gov_setup
  gov --json --apply
  check "one account under the cap: claim ok, exit 0" is claim ok 0
  check "  exit 0" eq "$RC" 0
  check "  exactly one line on stdout" eq "$(wc -l <<<"$OUT" | tr -d ' ')" 1
  check "  the reading was refreshed, then shown" eq "$(jq -sc 'map(join(" "))' "$FAKE_CUX_LOG")" '["usage refresh","usage show"]'
  check "  no account key on stdout or stderr (I8)" noleak
  gov
  check "without --json: '<action> <reason> <sleep_seconds>'" eq "$OUT" "claim ok 0"
  FACTORY_NOW="$(iso "$T0")"; gov --json
  check "FACTORY_NOW as ISO-8601 gives the same verdict" is claim ok 0
  FACTORY_NOW=2026-10-25T08:00:00-04:00; gov --json
  check "  and with an offset" is claim ok 0
  FACTORY_NOW=yesterday; gov --json
  check "a clock that is neither epoch nor ISO-8601: exit 1" eq "$RC" 1
}

case_version_behind() {
  gov_setup
  echo 0.0.9 >"$WORLD/clone/factory/VERSION"
  gov --json --apply
  check "local factory/VERSION behind origin/main: refuse version_behind" is refuse version_behind 0
  check "  exit 2" eq "$RC" 2
  check "  cux was never asked" eq "$(wc -l <"$FAKE_CUX_LOG" | tr -d ' ')" 0
  echo 0.1.0 >"$WORLD/clone/factory/VERSION"
  FAKE_CLAUDE_VERSION=2.1.279 gov --json --apply
  check "installed claude drifted from its pin: refuse adapter_pins, exit 2" is refuse adapter_pins 0
  check "  exit 2" eq "$RC" 2
  manifest '.adapters = {"codex": "1.0.0"}'
  gov --json
  check "an adapter null in adapters.json: refuse adapter_pins" is refuse adapter_pins 0
}

case_version_unknown() {
  gov_setup
  gov --json --remote nowhere
  check "the fetch fails: sleep version_unknown (unknownStateSleepMinutes)" is sleep version_unknown 600
  check "  exit 0" eq "$RC" 0
}

case_halted() {
  gov_setup 'main-file factory/HALT stop'
  gov --json --apply
  check "factory/HALT on origin/main: sleep halted haltSleepMinutes" \
    is sleep halted "$(( $(jq .governor.haltSleepMinutes "$REPO_ROOT/factory/policy/budget.json") * 60 ))"
  check "  exit 0" eq "$RC" 0
}

case_halt_unknown() {
  gov_setup
  GOV_GIT_MODE=fail-second-main-fetch gov --json
  check "version-check fetched, halt-check's fetch fails: sleep halt_unknown" is sleep halt_unknown 600
}

case_quiet_hours() {
  gov_setup
  manifest '.quiet_hours = {tz: "UTC", start: "09:00", end: "17:00"}'
  gov --json
  check "noon inside 09:00-17:00 UTC: sleep quiet_hours until 17:00" is sleep quiet_hours 18000
  manifest '.quiet_hours = {tz: "Asia/Kolkata", start: "17:00", end: "18:00"}'
  gov --json
  check "noon UTC is 17:30 in Asia/Kolkata (+05:30): sleep 30 min" is sleep quiet_hours 1800
  manifest '.quiet_hours = {tz: "Mars/Olympus", start: "09:00", end: "17:00"}'
  gov --json
  check "an unknown tz is an operational error (jq would read it as UTC): exit 1" eq "$RC" 1
}

case_quota_exhausted() {
  gov_setup
  # a frees in 2 h (its only capped window); b has two capped windows, so it frees when the later
  # one (5 h) resets; a window at 45 % is at the cap 0.4. The earliest account to free: 2 h.
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 50 7200), \"seven_day\": $(win 10 400000)},
          \"b@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 80 3600), \"seven_day\": $(win 45 18000)}}"
  gov --json --apply
  check "every account at the cap: sleep quota_exhausted until the earliest frees (2 h)" is sleep quota_exhausted 7200
  check "  exit 0" eq "$RC" 0
  check "  stderr gives counts only" grep -q '2 account(s): 0 under, 2 at cap, 0 unknown' <<<"$ERR"
  check "  no account key on stdout or stderr (I8)" noleak
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 40 7200)}}"
  gov --json
  check "exactly at the cap (40 at 0.4) is at the cap" is sleep quota_exhausted 7200
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 39.99 7200)}}"
  gov --json
  check "39.99 at 0.4 is under: claim" is claim ok 0
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 95 -60), \"seven_day\": $(win 5 9000)}}"
  gov --json
  check "a window whose resets_at has passed counts as reset: claim" is claim ok 0
  manifest '.quota_cap = 0.9'
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 50 7200)}}"
  gov --json
  check "the manifest's quota_cap is the cap (50 under 0.9): claim" is claim ok 0
  manifest '.'
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"token_expired\": true},
          \"b@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 90 7200)}}"
  gov --json
  check "an expired token is at the cap with no known reset: it counts as unknownState from now" is sleep quota_exhausted 600
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 90 null)}}"
  gov --json
  check "a capped window with no resets_at: sleep unknownState, not forever" is sleep quota_exhausted 600
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 90 7200)},
          \"b@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 1 7200)}}"
  gov --json
  check "one account of two under the cap: claim" is claim ok 0
}

case_order() {
  gov_setup 'main-file factory/HALT stop'
  manifest '.quiet_hours = {tz: "UTC", start: "09:00", end: "17:00"}'
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 99 7200)}}"
  echo 0.0.9 >"$WORLD/clone/factory/VERSION"
  gov --json
  check "behind + HALT + quiet + quota: version_check first (refuse)" is refuse version_behind 0
  echo 0.1.0 >"$WORLD/clone/factory/VERSION"
  gov --json
  check "HALT + quiet + quota: kill switch before quiet hours" is sleep halted 1800
  gov_setup
  manifest '.quiet_hours = {tz: "UTC", start: "09:00", end: "17:00"}'
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 99 7200)}}"
  gov --json
  check "quiet + quota: quiet hours before quota" is sleep quiet_hours 18000
  check "  cux is not asked inside quiet hours" eq "$(wc -l <"$FAKE_CUX_LOG" | tr -d ' ')" 0
}

# ---------------------------------------------------------------------------------- acceptance 2
case_midnight_wrap() {
  gov_setup
  manifest '.quiet_hours = {tz: "UTC", start: "22:00", end: "07:00"}'
  local at want
  for at in 2026-10-25T23:30:00Z:27000 2026-10-26T03:00:00Z:14400 2026-10-25T22:00:00Z:32400 \
            2026-10-26T06:59:59Z:1 2026-10-26T00:00:00Z:25200; do
    FACTORY_NOW="${at%Z:*}Z" want="${at##*:}"
    usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 1 3600)}}"
    gov --json
    check "22:00-07:00 at ${FACTORY_NOW:11:8}: sleep $want s" is sleep quiet_hours "$want"
  done
  for at in 2026-10-26T07:00:00Z 2026-10-25T21:59:00Z 2026-10-25T12:00:00Z; do
    FACTORY_NOW="$at"
    usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 1 3600)}}"
    gov --json
    check "22:00-07:00 at ${at:11:8}: outside, claim" is claim ok 0
  done
  manifest '.quiet_hours = {tz: "UTC", start: "07:00", end: "07:00"}'
  FACTORY_NOW=2026-10-26T07:00:00Z
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 1 3600)}}"
  gov --json
  check "start == end is no window: claim" is claim ok 0
}

# ---------------------------------------------------------------------------------- acceptance 3
case_dst() {
  gov_setup
  local now start end want what
  # America/New_York: fall back 2026-11-01 02:00 EDT → 01:00 EST (06:00Z); spring forward
  # 2027-03-14 02:00 EST → 03:00 EDT (07:00Z).
  while IFS='|' read -r now start end want what; do
    [ -n "$now" ] || continue
    manifest ".quiet_hours = {tz: \"America/New_York\", start: \"$start\", end: \"$end\"}"
    FACTORY_NOW="$now"
    usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 1 3600)}}"
    gov --json
    if [ "$want" = 0 ]; then check "$what: claim" is claim ok 0
    else check "$what: sleep $want s" is sleep quiet_hours "$want"; fi
  done <<'ROWS'
2026-10-25T03:00:00Z|22:00|07:00|28800|an ordinary night, 23:00 EDT to 07:00 EDT = 8 h
2026-11-01T03:00:00Z|22:00|07:00|32400|fall back, 23:00 EDT to 07:00 EST = 9 h
2027-03-14T04:00:00Z|22:00|07:00|25200|spring forward, 23:00 EST to 07:00 EDT = 7 h
2027-03-14T06:30:00Z|01:00|02:30|1800|spring forward, end 02:30 does not exist: until 03:00 EDT
2026-11-01T05:10:00Z|01:00|01:30|1200|fall back, 01:10 EDT: until the first 01:30
2026-11-01T06:10:00Z|01:00|01:30|1200|fall back, 01:10 EST (the hour again): until the second 01:30
2026-11-01T05:45:00Z|01:00|01:30|0|fall back, 01:45 EDT is outside 01:00-01:30
2027-03-14T07:00:00Z|01:00|02:30|0|spring forward, 03:00 EDT is past the end
ROWS
}

# ---------------------------------------------------------------------------------- acceptance 4
case_cux_malformed() {
  gov_setup
  local p what
  while IFS='|' read -r what p; do
    [ -n "$what" ] || continue
    p="${p//@POLLED@/$(polled)}"; p="${p//@OLD@/$(polled 7200)}"
    printf '%s' "$p" >"$FAKE_CUX_USAGE"
    gov --json --apply
    check "$what: sleep quota_unknown, never claim" is sleep quota_unknown 600
    check "  no account key on stdout or stderr (I8)" noleak
  done <<'ROWS'
not JSON (cux show exits 1)|garbage
a JSON array|[]
a JSON string|"x"
no account (`{}`)|{}
an account that is not an object|{"a@example.invalid": 7}
no polled_at|{"a@example.invalid": {"five_hour": {"utilization": 1}}}
a stale reading (2 h old)|{"a@example.invalid": {"polled_at": "@OLD@", "five_hour": {"utilization": 1}}}
five_hour without a number|{"a@example.invalid": {"polled_at": "@POLLED@", "five_hour": {"utilization": "1"}}}
seven_day not an object|{"a@example.invalid": {"polled_at": "@POLLED@", "five_hour": {"utilization": 1}, "seven_day": 3}}
a resets_at that is not a time|{"a@example.invalid": {"polled_at": "@POLLED@", "five_hour": {"utilization": 1, "resets_at": "soon"}}}
no window at all|{"a@example.invalid": {"polled_at": "@POLLED@"}}
ROWS
  : >"$FAKE_CUX_USAGE"
  gov --json
  check "an empty cache file is \`{}\`: sleep quota_unknown" is sleep quota_unknown 600
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 1 3600)}}"
  FACTORY_CUX="$WORLD/no-such-cux" gov --json
  check "cux not installed: sleep quota_unknown" is sleep quota_unknown 600
  FAKE_CUX_REFRESH_EXIT=1 gov --json
  check "a failed refresh with a fresh cached reading still judges the reading: claim" is claim ok 0
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 1 3600)}, \"b@example.invalid\": 7}"
  gov --json
  check "one good account under the cap beside a malformed one: claim" is claim ok 0
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 1 3600), \"extra_usage\": {\"is_enabled\": false}}}"
  gov --json
  check "an unknown non-window key is ignored, as cux does: claim" is claim ok 0
}

# ---------------------------------------------------------------------------------- acceptance 5
case_heartbeat_hourly() {
  gov_setup
  local tip0 tip1 seen0
  tip0="$(nodes_tip)"
  manifest ".last_seen = \"$(iso $((T0 - 59 * 60)))\""
  seen0="$(jq -r .last_seen "$FACTORY_MANIFEST")"
  gov --json --apply
  check "last_seen 59 min old: claim" is claim ok 0
  check "  nodes not touched" eq "$(nodes_tip)" "$tip0"
  check "  manifest last_seen unchanged" eq "$(jq -r .last_seen "$FACTORY_MANIFEST")" "$seen0"
  check "  stderr says skipped" grep -q 'heartbeat: skipped' <<<"$ERR"
  manifest ".last_seen = \"$(iso $((T0 - 61 * 60)))\""
  gov --json
  check "61 min old without --apply: claim, nothing written" is claim ok 0
  check "  nodes not touched" eq "$(nodes_tip)" "$tip0"
  check "  stderr says it would" grep -q 'would push nodes/dev-box.json' <<<"$ERR"
  gov --json --apply
  tip1="$(nodes_tip)"
  check "61 min old with --apply: claim" is claim ok 0
  check "  nodes moved one commit, a fast-forward of the old tip" eq "$(git -C "$WORLD/origin.git" rev-parse "$tip1^")" "$tip0"
  check "  nodes/dev-box.json last_seen = now" eq "$(nodes_file | jq -r .last_seen)" "$(iso "$T0")"
  check "  joining → active" eq "$(nodes_file | jq -r .status)" active
  check "  every other field kept" eq "$(nodes_file | jq -c 'del(.last_seen, .status)')" \
    "$(git -C "$WORLD/origin.git" cat-file blob "$tip0:nodes/dev-box.json" | jq -c 'del(.last_seen, .status)')"
  check "  the commit carries the Node trailer" eq "$(git -C "$WORLD/origin.git" log -1 --format='%(trailers:key=Node,valueonly)' nodes)" dev-box
  check "  the manifest's last_seen follows" eq "$(jq -r .last_seen "$FACTORY_MANIFEST")" "$(iso "$T0")"
  FACTORY_NOW=$((T0 + 30 * 60)); gov --json --apply
  check "30 min later: skipped, nodes not touched" eq "$(nodes_tip)" "$tip1"
  FACTORY_NOW=$((T0 + 60 * 60)); gov --json --apply
  check "60 min later: due again, pushed" eq "$(nodes_file | jq -r .last_seen)" "$(iso $((T0 + 3600)))"
}

case_heartbeat_cas() {
  gov_setup
  manifest ".last_seen = \"$(iso $((T0 - 7200)))\""
  GOV_GIT_MODE=race-nodes-1 gov --json --apply
  check "nodes moved under the first push: claim" is claim ok 0
  check "  retried on the new tip and won on attempt 2" grep -q 'pushed .* in 2 attempt(s)' <<<"$ERR"
  check "  the other writer's commit is kept (no force)" grep -q 'someone else 1' <(git -C "$WORLD/origin.git" log --format=%s nodes)
  check "  last_seen = now" eq "$(nodes_file | jq -r .last_seen)" "$(iso "$T0")"
  gov_setup
  manifest ".last_seen = \"$(iso $((T0 - 7200)))\""
  GOV_GIT_MODE=race-nodes-3 gov --json --apply
  check "lost the race 3 times: a warning, still claim (the next run retries)" is claim ok 0
  check "  nothing forced: last_seen on nodes is the old one" eq "$(nodes_file | jq -r .last_seen)" "$(iso $((T0 - 7200)))"
  check "  the manifest's last_seen is not moved, so the next run is due" eq "$(jq -r .last_seen "$FACTORY_MANIFEST")" "$(iso $((T0 - 7200)))"
  check "  stderr names the failure" grep -q 'heartbeat: failed' <<<"$ERR"
}

case_heartbeat_refusals() {
  gov_setup 'node other 1761300000 active 2 someone'
  manifest ".last_seen = \"$(iso $((T0 - 7200)))\" | .handle = \"ghost\" | .owner = \"ghost\""
  gov --json --apply
  check "handle not on nodes: refuse node_unregistered" is refuse node_unregistered 0
  manifest ".last_seen = \"$(iso $((T0 - 7200)))\" | .handle = \"other\""
  gov --json --apply
  check "handle held by another owner: refuse handle_taken" is refuse handle_taken 0
  gov_setup "node gone $((T0 - 86400 * 9)) retired 2 gone"
  manifest ".last_seen = \"$(iso $((T0 - 7200)))\" | .handle = \"gone\" | .owner = \"gone\""
  gov --json --apply
  check "retired on nodes: refuse node_retired" is refuse node_retired 0
  check "  exit 2" eq "$RC" 2
}

# ---------------------------------------------------------------------------------- acceptance 6
# `cux usage show` of the real cux 0.4.1, captured on this box from a synthetic usage cache
# (records/TB3.md §2): the API's limits[] became seven_day_fable, a zero window with no reset and an
# unknown key were dropped, a null resets_at was omitted, keys sorted, two-space indent.
RECORDED='{
  "a@example.invalid": {
    "five_hour": {
      "utilization": 42,
      "resets_at": "2026-10-25T07:00:00.5Z"
    },
    "polled_at": "2026-10-25T03:50:00.123456789Z",
    "seven_day": {
      "utilization": 12.5,
      "resets_at": "2026-10-30T00:00:00Z"
    },
    "seven_day_fable": {
      "utilization": 55,
      "resets_at": "2026-10-29T00:00:00Z"
    }
  },
  "b@example.invalid": {
    "failures": 2,
    "five_hour": {
      "utilization": 100
    },
    "polled_at": "2026-10-25T03:00:00Z",
    "retry_after": "2026-10-25T04:00:00Z",
    "token_expired": true
  }
}'
case_fake_cux() {
  gov_setup
  local out rc
  printf '%s\n' "$RECORDED" >"$FAKE_CUX_USAGE"
  # The fake re-prints like Go's MarshalIndent: maps sorted, Window fields in struct order.
  check "fed a reordered copy, it prints the recorded bytes" \
    eq "$(jq -c '{"b@example.invalid": ."b@example.invalid", "a@example.invalid": (."a@example.invalid"
                  | {seven_day_fable, polled_at, seven_day, five_hour: {resets_at: .five_hour.resets_at, utilization: 42}})}' \
          <<<"$RECORDED" >"$FAKE_CUX_USAGE"; PATH="$GPATH" cux usage show)" "$RECORDED"
  printf '%s\n' "$RECORDED" >"$FAKE_CUX_USAGE"
  check "fed the recorded payload, \`usage show\` prints it byte for byte" eq "$(PATH="$GPATH" cux usage show)" "$RECORDED"
  check "  exit 0" quiet env PATH="$GPATH" cux usage show
  check "  the shape: an object keyed by account, each with polled_at and windows {utilization 0-100, resets_at?}" \
    quiet jq -e 'type == "object" and all(.[]; (.polled_at | type) == "string"
           and all(to_entries[] | select(.value | type == "object"); (.value.utilization | type) == "number"))' "$FAKE_CUX_USAGE"
  rm -f "$FAKE_CUX_USAGE"
  check "no cache file: \`{}\`, exit 0 (the real cux with no account)" eq "$(PATH="$GPATH" cux usage show)" "{}"
  : >"$FAKE_CUX_USAGE"
  check "an empty cache file: \`{}\` (the real LoadCache)" eq "$(PATH="$GPATH" cux usage show)" "{}"
  echo garbage >"$FAKE_CUX_USAGE"
  rc=0; out="$(PATH="$GPATH" cux usage show 2>&1)" || rc=$?
  check "a cache that is not JSON: exit 1 (as the real one)" eq "$rc" 1
  check "  'cux: usage: parse cache:' on stderr" grep -q '^cux: usage: parse cache:' <<<"$out"
  check "\`cux --version\` is cux 0.4.1" eq "$(PATH="$GPATH" cux --version)" "cux 0.4.1"
  printf '%s\n' "$RECORDED" >"$FAKE_CUX_USAGE"
  check "\`usage refresh\` prints the account e-mails on stdout, as the real one's list does" \
    grep -q 'a@example.invalid' <(PATH="$GPATH" cux usage refresh 2>/dev/null)
  rc=0; FAKE_CUX_REFRESH_EXIT=1 PATH="$GPATH" cux usage refresh >/dev/null 2>&1 || rc=$?
  check "  FAKE_CUX_REFRESH_EXIT=1: exit 1 (the real one when nothing was polled)" eq "$rc" 1
  rc=0; PATH="$GPATH" cux status --json >/dev/null 2>&1 || rc=$?
  check "\`cux status --json\` (does not exist at 0.4.1) is refused: exit 2" eq "$rc" 2
  # The recorded payload through the governor's reader (lib/governor.sh), at 04:00Z.
  q() { (PROG=t; . "$REPO_ROOT/factory/bin/lib/common.sh"; . "$REPO_ROOT/factory/bin/lib/governor.sh"
         gov_quota "$RECORDED" "$(epoch 2026-10-25T04:00:00Z)" "$1" 1800 600); }
  check "recorded, cap 0.6: a is under (42, 12.5, 55): under" eq "$(q 0.6 | jq -r .state)" under
  check "recorded, cap 0.5: a is capped by its model window seven_day_fable (55): exhausted" eq "$(q 0.5 | jq -c '[.state, .at_cap, .under]')" '["exhausted",2,0]'
  check "recorded, cap 0.4: b's expired token is at the cap, a frees on 10-29: sleep 600 (unknownState)" \
    eq "$(q 0.4 | jq -c '[.state, .sleep_seconds]')" '["exhausted",600]'
  check "  the reader's output never holds an account key (I8)" eq "$(q 0.4 | grep -c '@' || true)" 0
}

# ---------------------------------------------------------------------------------- acceptance 7
case_quota_gate() {
  gov_setup
  gate --json
  check "one account under the cap: exit 0" eq "$RC" 0
  check "  --json counts" eq "$(jq -c '[.state, .accounts, .under]' <<<"$OUT")" '["under",1,1]'
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 40 3600)},
          \"b@example.invalid\": {\"polled_at\": \"$(polled)\", \"seven_day\": $(win 77 3600)}}"
  gate
  check "every account at or above the cap: exit 2" eq "$RC" 2
  check "  no account key on stdout or stderr (I8)" noleak
  gate --cap 0.8
  check "  --cap 0.8 lifts both under it: exit 0" eq "$RC" 0
  manifest '.quota_cap = 0.8'
  gate
  check "  the manifest's quota_cap: exit 0" eq "$RC" 0
  gate --manifest /nonexistent
  check "  a manifest that is not there: exit 1" eq "$RC" 1
  manifest '.'
  echo garbage >"$FAKE_CUX_USAGE"
  gate
  check "malformed payload: non-zero (1)" eq "$RC" 1
  : >"$FAKE_CUX_USAGE"
  gate
  check "empty payload (\`{}\`): non-zero (1)" eq "$RC" 1
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled 7200)\", \"five_hour\": $(win 1 3600)}}"
  gate
  check "stale reading: non-zero (1)" eq "$RC" 1
  # fleet's pre-strike call: absolute argv[0], no shell, exactly --pre-strike-env.
  usage "{\"a@example.invalid\": {\"polled_at\": \"$(polled)\", \"five_hour\": $(win 1 3600)}}"
  RC=0
  OUT="$(env -i PATH="$GPATH" HOME="$WORLD" FACTORY_NOW="$FACTORY_NOW" FAKE_CUX_USAGE="$FAKE_CUX_USAGE" \
         "$GATE" 2>&1)" || RC=$?
  check "under env -i with only PATH and HOME (and the fakes' knobs): exit 0" eq "$RC" 0
  check "  argv[0] is absolute" eq "${GATE:0:1}" /
  check "  refreshed, then shown" eq "$(jq -sc '.[-2:] | map(join(" "))' "$FAKE_CUX_LOG")" '["usage refresh","usage show"]'
  gate --no-refresh
  check "--no-refresh: only \`usage show\`" eq "$(jq -sc '.[-1:] | map(join(" "))' "$FAKE_CUX_LOG")" '["usage show"]'
}

for c in claim version-behind version-unknown halted halt-unknown quiet-hours quota-exhausted order \
         midnight-wrap dst cux-malformed heartbeat-hourly heartbeat-cas heartbeat-refusals fake-cux quota-gate; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
