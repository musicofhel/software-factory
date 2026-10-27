# shellcheck shell=bash
# The scratch world of `make sim` (tests/sim/sim.sh sources this; never executed).
#
#   world_build        $SIM/origin.git seeded from the working tree (tests/fixtures/make-repo.sh
#                      `main-dir`, with nodes dev-box and node-b on the nodes branch), the ticket
#                      store emptied to its two .store.json files and an empty manifest, a desk commit
#                      setting factory/ledger/post-merge.json's marker to the seed; the desk clone
#                      $SIM/desk; the fake gh state; the runner shims ($SIM/runner-bin); the adlc
#                      the scripts call (real 1.12.0 offline from the npx cache, or the fake in
#                      git-store mode)
#   node_env <handle>  exports, in the caller's subshell, what a node's run loop sees (the harness
#                      of tests/test_run.sh): FACTORY_HOME, the manifest, the fakes, the clock
#   clone_of <dir>     a clone whose origin reads https://github.com/$REPO (as on GitHub), rewritten
#                      to the bare origin by a local insteadOf
#
# Every git remote is https://github.com/$REPO rewritten to the bare repo, so resolve_repo
# (lib/common.sh) parses the repo as on a real runner or node.

SIM_FAKES="$SIM_ROOT/tests/fakes"
T0="$(jq -nr '"2026-10-26T20:00:00Z" | fromdateiso8601')"   # outside make-repo's 09-17 quiet hours

clone_of() {
  git clone -q "$ORIGIN" "$1"
  git -C "$1" config url."$ORIGIN".insteadOf "https://github.com/$REPO"
  git -C "$1" remote set-url origin "https://github.com/$REPO"
}

world_build() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TZ=UTC
  export FACTORY_REPO="$REPO" FAKE_GH_REPO="$REPO" FAKE_GH_GIT="$ORIGIN" FAKE_GH_ISSUES="$SIM/gh.json"
  export FAKE_GH_SETTINGS="$SIM/settings.json" FAKE_GH_LOG="$SIM/gh.log" FAKE_GH_UNKNOWN="$SIM/gh-unknown.log"
  export FAKE_CURL_LOG="$SIM/curl.log" FAKE_TAMPERGUARD_LOG="$SIM/tg-ci.log" FAKE_TAMPERGUARD_VERDICT=diff
  export FACTORY_NOW="$T0" FAKE_GH_NOW="$T0" npm_config_offline=true
  : "${npm_config_cache:=$HOME/.npm}"; export npm_config_cache
  : >"$FAKE_GH_LOG"; : >"$FAKE_GH_UNKNOWN"; : >"$FAKE_CURL_LOG"; : >"$FAKE_TAMPERGUARD_LOG"; : >"$SIM/jobs.jsonl"
  # The repo's collaborators besides its owner (sim-owner): the node owners and the desk. A PR's
  # author_association (fake gh GET pulls/<n>) reads them; anyone else is NONE.
  printf '{"labels":[],"issues":[],"pulls":[],"checks":[],"queue":[],"merged":[],"collaborators":["dev-box-owner","node-b-owner","desk"]}\n' >"$FAKE_GH_ISSUES"
  printf '{"protection":{},"rulesets":[],"next_id":1}\n' >"$FAKE_GH_SETTINGS"

  # The seed: every tracked and untracked-not-ignored file of the working tree, the store emptied.
  local seed="$SIM/seed" f
  mkdir -p "$seed"
  (cd "$SIM_ROOT" && git ls-files -co --exclude-standard -z) | while IFS= read -r -d '' f; do
    [ -f "$SIM_ROOT/$f" ] || continue
    case "$f" in .adlc/tickets/*|.adlc/ticket-archive/*|.adlc/ticket-transactions/*|.adlc/manifest.jsonl) continue ;; esac
    mkdir -p "$seed/$(dirname "$f")" && command cp -p "$SIM_ROOT/$f" "$seed/$f"
  done
  mkdir -p "$seed/.adlc/tickets" "$seed/.adlc/ticket-archive"
  printf '{"format":"adlc-ticket-directory","version":1}\n' | tee "$seed/.adlc/tickets/.store.json" >"$seed/.adlc/ticket-archive/.store.json"
  : >"$seed/.adlc/manifest.jsonl"
  printf '%s\n' "main-dir $seed" "node dev-box $((T0 - 600)) active 1 dev-box-owner" \
    "node node-b $((T0 - 600)) active 1 node-b-owner" | "$SIM_ROOT/tests/fixtures/make-repo.sh" "$ORIGIN"
  git -C "$ORIGIN" config uploadpack.allowAnySHA1InWant true

  # The runner's shims: gh is the fake; tamperguard through pipx; make test/lint stubbed (the suite
  # runs this sim, so a job running it would recurse; build-test's real command list is TB5's).
  mkdir -p "$SIM/runner-bin" "$SIM/runner-home" "$SIM/bin"
  ln -sf "$SIM_FAKES/gh" "$SIM/runner-bin/gh"
  ln -sf "$SIM_FAKES/curl" "$SIM/runner-bin/curl"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = run ] && [ "${2:-}" = tamperguard==0.2.0 ]; then shift 2; exec "'"$SIM_FAKES"'/tamperguard" "$@"; fi' \
    'echo "sim pipx: only \`pipx run tamperguard==0.2.0\` is simulated: $*" >&2; exit 127' >"$SIM/runner-bin/pipx"
  printf '%s\n' '#!/usr/bin/env bash' \
    'case "$*" in test|lint) echo "sim make: \`make $*\` stubbed (the suite runs the sim itself)"; exit 0 ;; esac' \
    'exec /usr/bin/make "$@"' >"$SIM/runner-bin/make"
  # The adlc every script reaches: real 1.12.0 through npx (offline), or the fake's git-store mode,
  # the runner's npx mapped onto it.
  if [ "$ADLC_MODE" = fake ]; then
    printf '%s\n' '#!/usr/bin/env bash' "export FAKE_ADLC_GITSTORE=1 FAKE_ADLC_LOG=\"\${FAKE_ADLC_LOG:-$SIM/adlc.log}\"" \
      "exec \"$SIM_FAKES/adlc\" \"\$@\"" >"$SIM/bin/adlc"
    printf '%s\n' '#!/usr/bin/env bash' \
      'if [ "${1:-}" = -y ] && [ "${2:-}" = @adlc/cli@1.12.0 ]; then shift 2; exec "'"$SIM"'/bin/adlc" "$@"; fi' \
      'echo "sim npx: only @adlc/cli@1.12.0 is simulated: $*" >&2; exit 127' >"$SIM/runner-bin/npx"
    ADLC="$SIM/bin/adlc"
  else
    ADLC="npx -y @adlc/cli@1.12.0"
  fi
  chmod +x "$SIM"/runner-bin/*
  [ "$ADLC_MODE" != fake ] || chmod +x "$SIM/bin/adlc"
  RUNNER_PATH="$SIM/runner-bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v git)"):/usr/local/bin:/usr/bin:/bin"
  [ "$ADLC_MODE" = fake ] || RUNNER_PATH="$RUNNER_PATH:$(dirname "$(command -v npx)")"
  export RUNNER_PATH

  clone_of "$SIM/desk"
  git -C "$SIM/desk" config user.name desk; git -C "$SIM/desk" config user.email desk@sim.invalid
  SEED_SHA="$(git -C "$ORIGIN" rev-parse refs/heads/main)"
  jq -n --arg s "$SEED_SHA" '{through: $s}' >"$SIM/desk/factory/ledger/post-merge.json"
  git -C "$SIM/desk" commit -qam "desk: post-merge marker at the seed"
  git -C "$SIM/desk" push -q origin HEAD:main
}

# A node home (the harness of tests/test_run.sh run_setup, minus its cases), built once per handle.
node_build() {
  local h="$1" d="$SIM/nodes/$1" u
  mkdir -p "$d/bin" "$d/fh"
  clone_of "$d/clone"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo "2.1.280 (Claude Code)"\n' >"$d/bin/claude"
  printf '#!/usr/bin/env bash\necho "$1" >>"%s/naps"\n' "$d" >"$d/bin/nap"
  # tamperguard as uv installs it (test_run.sh fake_uv): its own dir, python through a version link.
  u="$d/uv"
  mkdir -p "$u/python/cpython-9.9.9-fake/bin" "$u/tools/tamperguard/bin"
  command cp "$(readlink -f "$(command -v bash)")" "$u/python/cpython-9.9.9-fake/bin/python9.9"
  ln -sfn cpython-9.9.9-fake "$u/python/cpython-9.9-fake"
  ln -sf "$u/python/cpython-9.9-fake/bin/python9.9" "$u/tools/tamperguard/bin/python"
  printf '#!%s\nexec "%s/tamperguard" "$@"\n' "$u/tools/tamperguard/bin/python" "$SIM_FAKES" >"$u/tools/tamperguard/bin/tamperguard"
  chmod +x "$d/bin/claude" "$d/bin/nap" "$u/tools/tamperguard/bin/tamperguard"
  ln -sf "$u/tools/tamperguard/bin/tamperguard" "$d/bin/tamperguard"
  jq -n --arg h "$h" --arg seen "$(jq -nr --argjson e $((T0 - 600)) '$e | todate')" '
    {handle: $h, owner: "\($h)-owner", os: "linux", cpu: 8, ram_gb: 16, slots: 1, heavy_gates: false,
     adapters: {"claude-code": "2.1.280"}, quota_tier: "pro", quota_cap: 0.4,
     quiet_hours: {tz: "UTC", start: "00:00", end: "00:00"}, accounts: 1, factory_version: "0.1.0",
     last_seen: $seen, status: "active"}' >"$d/manifest.json"
  printf '{"a@example.invalid": {"polled_at": "%s", "five_hour": {"utilization": 10, "resets_at": "%s"}, "seven_day": {"utilization": 20, "resets_at": "%s"}}}\n' \
    "$(jq -nr --argjson e $((T0 - 60)) '$e | todate')" "$(jq -nr --argjson e $((T0 + 3600)) '$e | todate')" \
    "$(jq -nr --argjson e $((T0 + 86400)) '$e | todate')" >"$d/usage.json"
  : >"$d/fleet.log"; : >"$d/cux.log"; : >"$d/ralon.log"; : >"$d/vetto.log"; : >"$d/tg.log"
}

node_env() {  # call inside a subshell
  local h="$1" d="$SIM/nodes/$1"
  export FACTORY_HOME="$d/fh" FACTORY_MANIFEST="$d/manifest.json" FAKE_CUX_USAGE="$d/usage.json" FAKE_CUX_LOG="$d/cux.log"
  export FAKE_FLEET_LOG="$d/fleet.log" FAKE_RALON_LOG="$d/ralon.log" FAKE_VETTO_LOG="$d/vetto.log" FAKE_TAMPERGUARD_LOG="$d/tg.log"
  export FACTORY_ADLC="$ADLC" FACTORY_FLEET="$SIM_FAKES/fleet" FACTORY_SLEEP="$d/bin/nap" FACTORY_FLEET_PIN=1.12.0
  export FAKE_ADLC_LOG="$d/adlc.log" FAKE_GH_USER="$h-owner" FAKE_GH_BOT=0
  export GIT_AUTHOR_NAME="$h-owner" GIT_AUTHOR_EMAIL="$h-owner@sim.invalid" GIT_COMMITTER_NAME="$h-owner" GIT_COMMITTER_EMAIL="$h-owner@sim.invalid"
  export PATH="$d/bin:$SIM/bin:$SIM_FAKES:$PATH"
  unset FAKE_FLEET_REASON FAKE_FLEET_REASONS FAKE_FLEET_STRIKES FACTORY_SCOPE_CHECK FACTORY_HANDLE
  cd "$d/clone" || return 1
}
