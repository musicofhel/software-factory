#!/usr/bin/env bash
# join — make this box a factory node (SPEC-v0.2 "Join wizard" and "Manifest"; ticket T7).
#
#   join.sh --handle H [--owner O] [--apply] [--json] [--remote NAME] [--repo owner/name]
#           [--quota-tier free|pro|max|team|unknown] [--quota-cap X] [--accounts N]
#           [--tz ZONE] [--quiet-start HH:MM] [--quiet-end HH:MM]
#           [--token-file FILE|-] [--no-suite] [--suite-timeout-seconds N]
#   join.sh --validate <manifest.json>
#
# Run it from the root of your clone. Five steps, each printed before it runs:
#   1. probe     factory/bin/lib/probe.sh, then the refusals: root, unsupported OS, no sandbox
#                backend (bwrap on Linux, sandbox-exec on macOS; the install line is printed),
#                slots < 1, --dangerously-skip-permissions in a shell rc or Claude settings file,
#                no authenticated adapter that factory/policy/adapters.json pins. A timed run of
#                `make test` in the clone (timeout: budget.json weights.light.suiteMinutesMax)
#                sets heavy_gates. Warnings: the bwrap shim (ADR-0006) cannot run (no real bwrap,
#                no /usr), or the host is not merged usr (/bin a real directory: fleet 1.12.0's
#                canary still finds no /bin/sh there).
#   2. install   the pinned toolchain (vetto 0.6.5, ralon 0.1.7, tamperguard 0.2.0, dcg v0.15.3,
#                cux v0.4.1, @adlc/cli 1.12.0, the adapter pins). A tool already on PATH at its pin
#                is skipped; the rest install under $FACTORY_HOME (default ~/.factory): cargo
#                --root, uv tool dirs, release binaries checked against the sha256 pinned here,
#                the npx cache. User space only, never sudo.
#   3. register  prints the fine-grained token and self-hosted runner instructions; it never
#                creates either. --token-file stores a fine-grained token at $FACTORY_HOME/token
#                (0600); a classic token is refused.
#   4. manifest  nodes/<handle>.json, validated against factory/nodes/manifest.schema.json,
#                committed on top of <remote>/nodes and pushed without force (a moved tip is a
#                compare-and-swap loss: re-fetch, rebuild, retry, 3 attempts). The push is the
#                node's first heartbeat. A handle another owner holds is refused.
#   5. print     the run-loop command per slot and factory/RULES.md.
#
# Dry run (the default) writes nothing: no file, no git object, no ref (the nodes tip is read with
# ls-remote). The suite run gets a temporary TMPDIR that is removed after. --apply writes only
# inside the clone (the nodes commit) and $FACTORY_HOME (tools, token, env, manifest.json).
# --validate checks one manifest against the schema: exit 0 valid, 2 invalid.
#
# Exit 0 joined (or would join); 2 refused (every cause is printed); 1 operational error.
set -euo pipefail
PROG="join"
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

SCHEMA="$FACTORY_ROOT/factory/nodes/manifest.schema.json"
PINS_FILE="$FACTORY_ROOT/factory/policy/adapters.json"

# validate <manifest-file>: one error per line on stdout, nothing when valid. The schema's keywords
# are interpreted here; a keyword this validator does not implement is itself an error (fail closed).
validate() {
  jq -r --slurpfile s "$SCHEMA" '
    def known: ["$schema", "$id", "title", "description", "default", "type", "enum", "required",
                "properties", "additionalProperties", "pattern", "minimum", "maximum",
                "exclusiveMinimum", "minProperties", "propertyNames", "format"];
    def jtype: if type == "number" and . == floor then ["integer", "number"] else [type] end;
    def v($s; $p):
      . as $x
      | [$s | keys[] | select(. as $k | known | index($k) | not)] as $u
      | if ($u | length) > 0 then ["\($p): schema keyword not supported by the validator: \($u | join(", "))"]
        elif $s.type != null and ($x | jtype | index($s.type)) == null then ["\($p): expected \($s.type), got \($x | type)"]
        else
          (if $s.enum != null and (any($s.enum[]; . == $x) | not)
             then ["\($p): \($x | tojson) is not one of \($s.enum | map(tojson) | join(", "))"] else [] end)
          + (if ($x | type) == "string" then
               (if $s.pattern != null and ($x | test($s.pattern) | not) then ["\($p): \($x | tojson) does not match \($s.pattern)"] else [] end)
               + (if $s.format == "date-time" and ($x | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$") | not)
                    then ["\($p): \($x | tojson) is not a date-time"] else [] end)
             else [] end)
          + (if ($x | type) == "number" then
               (if $s.minimum != null and $x < $s.minimum then ["\($p): \($x) < minimum \($s.minimum)"] else [] end)
               + (if $s.maximum != null and $x > $s.maximum then ["\($p): \($x) > maximum \($s.maximum)"] else [] end)
               + (if $s.exclusiveMinimum != null and $x <= $s.exclusiveMinimum then ["\($p): \($x) <= exclusiveMinimum \($s.exclusiveMinimum)"] else [] end)
             else [] end)
          + (if ($x | type) == "object" then
               [($s.required // [])[] | select(. as $k | $x | has($k) | not) | "\($p): missing \(.)"]
               + (if $s.minProperties != null and ($x | length) < $s.minProperties then ["\($p): fewer than \($s.minProperties) properties"] else [] end)
               + [$x | to_entries[] | .key as $k | .value as $val
                  | if ($s.properties // {}) | has($k) then ($val | v($s.properties[$k]; "\($p).\($k)"))[]
                    elif $s.additionalProperties == false then "\($p): unexpected property \($k)"
                    elif ($s.additionalProperties | type) == "object" then ($val | v($s.additionalProperties; "\($p).\($k)"))[]
                    else empty end]
               + (if $s.propertyNames != null then [$x | keys[] | . as $k | ($k | v($s.propertyNames; "\($p) key \($k | tojson)"))[]] else [] end)
             else [] end)
        end;
    v($s[0]; "manifest")[]' "$1"
}

if [ "${1:-}" = --validate ]; then
  [ $# = 2 ] || usage
  need jq
  [ -f "$2" ] || die "no such file: $2"
  jq -e . "$2" >/dev/null 2>&1 || refuse "not JSON: $2"
  errs="$(validate "$2")" || die "the validator failed on $2"
  [ -z "$errs" ] || { printf '%s\n' "$errs" >&2; refuse "$2 fails $SCHEMA"; }
  echo "$2: valid"
  exit 0
fi

apply=0 json=0 remote=origin repo="" handle="${FACTORY_HANDLE:-}" owner="" tier=unknown cap="" accounts=1
tz="" qstart=09:00 qend=17:00 token_file="" suite=1 suite_timeout=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --dry-run) apply=0 ;;
    --json) json=1 ;;
    --remote) remote="${2:-}"; shift ;;
    --repo) repo="${2:-}"; shift ;;
    --handle) handle="${2:-}"; shift ;;
    --owner) owner="${2:-}"; shift ;;
    --quota-tier) tier="${2:-}"; shift ;;
    --quota-cap) cap="${2:-}"; shift ;;
    --accounts) accounts="${2:-}"; shift ;;
    --tz) tz="${2:-}"; shift ;;
    --quiet-start) qstart="${2:-}"; shift ;;
    --quiet-end) qend="${2:-}"; shift ;;
    --token-file) token_file="${2:-}"; shift ;;
    --no-suite) suite=0 ;;
    --suite-timeout-seconds) suite_timeout="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need git jq
[ -n "$handle" ] || { warn "need --handle (your GitHub login, used in branch and lock names)"; usage; }
valid_handle "$handle" || die "bad handle '$handle'"
owner="${owner:-$handle}"
valid_handle "$owner" || die "bad owner '$owner'"
[[ "$accounts" =~ ^[1-9][0-9]*$ ]] || die "--accounts must be a positive integer, got '$accounts'"
cap="${cap:-$(budget .governor.quotaCapDefault)}"
[[ "$cap" =~ ^(0?\.[0-9]+|1(\.0+)?)$ ]] || die "--quota-cap must be in (0, 1], got '$cap'"
[ -z "$suite_timeout" ] || [[ "$suite_timeout" =~ ^[1-9][0-9]*$ ]] || die "--suite-timeout-seconds must be a positive integer"
[ -n "$remote" ] || die "--remote needs a value"
CLONE="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run join.sh from inside your clone of the factory repo"
FH="${FACTORY_HOME:-$HOME/.factory}"
REPO="$(resolve_repo "$repo")"
NOW="$(now_epoch)"

# ---- output ------------------------------------------------------------------------------------
# Text mode prints to stdout; --json keeps stdout for the one JSON document and narrates on stderr.
say() { if [ "$json" = 1 ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }
step() { say ""; say "== $* =="; }
REFUSALS='[]' WARNINGS='[]'
refusal() { REFUSALS="$(jq -c --arg r "$*" '. + [$r]' <<<"$REFUSALS")"; }
warning() { WARNINGS="$(jq -c --arg r "$*" '. + [$r]' <<<"$WARNINGS")"; }
PLAN='[]' REGISTER='{}' MANIFEST=null MANIFEST_ERRORS='[]' NODES=null SUITE=null SLOTS=null HEAVY=null PROBE=null
finish() {  # finish <exit>: the report, then exit
  if [ "$json" = 1 ]; then
    jq -cn --arg mode "$([ "$apply" = 1 ] && echo apply || echo dry-run)" --argjson probe "$PROBE" \
      --argjson slots "$SLOTS" --argjson heavy "$HEAVY" --argjson suite "$SUITE" --argjson plan "$PLAN" \
      --argjson register "$REGISTER" --argjson manifest "$MANIFEST" --argjson merr "$MANIFEST_ERRORS" \
      --argjson nodes "$NODES" --argjson refusals "$REFUSALS" --argjson warnings "$WARNINGS" \
      --arg fh "$FH" --arg exit "$1" \
      '{mode: $mode, exit: ($exit | tonumber), factory_home: $fh, probe: $probe, slots: $slots,
        heavy_gates: $heavy, suite: $suite, plan: $plan, register: $register, manifest: $manifest,
        manifest_errors: $merr, nodes: $nodes, refusals: $refusals, warnings: $warnings}'
  fi
  if [ "$1" = 2 ]; then
    jq -r '.[]' <<<"$REFUSALS" | while IFS= read -r r; do warn "refused: $r"; done
  fi
  exit "$1"
}
run_cmd() {  # run_cmd <shell-command>: print it, then run it (--apply only)
  say "  \$ $1"
  if [ "$json" = 1 ]; then bash -euo pipefail -c "$1" >&2; else bash -euo pipefail -c "$1"; fi
}
q() { printf '%q' "$1"; }
has() { command -v "$1" >/dev/null 2>&1; }
semver_of() { grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true; }

# ================================================================================================
step "1/5 probe"
PROBE="$("$(dirname "$0")/lib/probe.sh" --json --clone "$CLONE")" || die "the probe failed"
if [ "$json" = 0 ]; then "$(dirname "$0")/lib/probe.sh" --clone "$CLONE" | sed 's/^/  /'; fi
os="$(jq -r '.os // empty' <<<"$PROBE")"

[ "$(jq -r .uid <<<"$PROBE")" != 0 ] || refusal "running as root: run the wizard as your own user (user-space installs only, never sudo)"
[ -n "$os" ] || refusal "$(jq -r .os_note <<<"$PROBE")"
sb_refusal="$(jq -r 'if .os == null then empty else .sandbox | if .present and .works then empty
         elif .present then "sandbox backend \(.backend) is installed but cannot start a sandbox here (unprivileged user namespaces off?); fleet needs it (ADR-0003)"
         else "no sandbox backend: fleet needs \(.backend) (ADR-0003). Install: \(.install_line)" end end' <<<"$PROBE")"
[ -z "$sb_refusal" ] || refusal "$sb_refusal"
if [ -z "$sb_refusal" ]; then
  while IFS= read -r w; do [ -z "$w" ] || warning "$w"; done < <(jq -r '.sandbox.shim // empty |
    if .ready | not then "the bwrap shim (ADR-0006) cannot run here (\(if .bwrap == null then "no real bwrap on PATH" else "no /usr to bind" end)): fleet 1.12.0 stops every run at its preflight canary (voodootikigod/adlc#1266)"
    elif .merged_usr | not then "/bin is a directory here, not a link to usr/bin: the bwrap shim (ADR-0006) binds only fleet'"'"'s system roots, so fleet 1.12.0'"'"'s preflight canary still finds no /bin/sh and stops every run (voodootikigod/adlc#1266)"
    else empty end' <<<"$PROBE")
fi

# slots = min(8, floor(free_ram_gb / 2) - 1), GB = GiB, computed on whole kB so the boundaries are exact.
free_kb="$(jq -r .ram_free_kb <<<"$PROBE")"
SLOTS=$(( free_kb / 2097152 - 1 ))
[ "$SLOTS" -le 8 ] || SLOTS=8
[ "$SLOTS" -ge 1 ] || refusal "slots = floor($(jq -r .free_ram_gb <<<"$PROBE") GB free / 2) - 1 = $SLOTS < 1: free RAM must be at least 4 GB"

while IFS= read -r f; do
  [ -n "$f" ] && refusal "--dangerously-skip-permissions is set in $f: remove it (the sandbox profiles exist so no node needs it; never vibe mode)"
done < <(jq -r '.skip_permissions[] | "\(.file) (\(.kind), matched \(.match))"' <<<"$PROBE")

jq -e 'type == "object"' "$PINS_FILE" >/dev/null 2>&1 || die "cannot read $PINS_FILE"
ADAPTERS="$(jq -c --slurpfile pins "$PINS_FILE" '
  [.adapters[] | . + {pin: ($pins[0][.name] // null)}
   | . + {usable: (.installed and .authenticated == true and (.pin | type) == "string")}]' <<<"$PROBE")"
if ! jq -e 'any(.[]; .usable)' <<<"$ADAPTERS" >/dev/null; then
  refusal "no authenticated adapter with a pin: $(jq -r 'map("\(.name) \(if .installed | not then "absent"
      elif .authenticated == null then "auth not measured"
      elif .authenticated == false then "not logged in" elif .pin == null then "not pinned in factory/policy/adapters.json"
      else "?" end)") | join(", ")' <<<"$ADAPTERS")"
fi
while IFS= read -r m; do
  [ -n "$m" ] && warning "vetto 0.6.5 masks $m and fails closed (exit 125) when it is a symlink, so the run loop's vetto steps will refuse on this HOME until it is a real directory or file"
done < <(jq -r '.vetto_masks[] | "\(.path) (a symlink to a \(.target_kind))"' <<<"$PROBE")

if [ "$suite" = 0 ]; then
  HEAVY=false SUITE='{"ran": false, "reason": "--no-suite"}'
elif [ "$(jq length <<<"$REFUSALS")" -gt 0 ]; then
  HEAVY=null SUITE='{"ran": false, "reason": "refused before the suite"}'
else
  t_max="${suite_timeout:-$(( $(budget .weights.light.suiteMinutesMax) * 60 ))}"
  say "  timed suite: make test in $CLONE, timeout ${t_max}s (budget.json weights.light.suiteMinutesMax)"
  stmp="$(mktemp -d)"
  t0="$(date +%s)" rc=0 killed=0
  set -m   # the suite gets its own process group, so a timeout stops make and every test under it
  ( cd "$CLONE" && TMPDIR="$stmp" exec make test ) >"$stmp/.suite.log" 2>&1 &
  spid=$!
  set +m
  ( for ((i = 0; i < t_max; i++)); do sleep 1; kill -0 "$spid" 2>/dev/null || exit 0; done
    touch "$stmp/.killed"; kill -TERM -- "-$spid" 2>/dev/null ) >/dev/null 2>&1 &
  wpid=$!
  wait "$spid" 2>/dev/null || rc=$?
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  [ ! -e "$stmp/.killed" ] || killed=1
  secs=$(( $(date +%s) - t0 ))
  rm -rf "$stmp"
  if [ "$killed" = 1 ]; then HEAVY=false; warning "make test did not finish inside ${t_max}s: heavy_gates false"
  elif [ "$rc" != 0 ]; then HEAVY=false; warning "make test exited $rc on this clone: heavy_gates false until it passes"
  else HEAVY=true; fi
  SUITE="$(jq -cn --argjson s "$secs" --argjson rc "$rc" --argjson k "$killed" --argjson t "$t_max" \
    '{ran: true, seconds: $s, exit: $rc, timed_out: ($k == 1), timeout_seconds: $t}')"
  say "  suite: exit $rc in ${secs}s$([ "$killed" = 1 ] && echo ", timed out"); heavy_gates $HEAVY"
fi
say "  slots $SLOTS (min(8, floor(free GB / 2) - 1)), heavy_gates $HEAVY"

# ================================================================================================
step "2/5 install plan (pinned; user space under $FH unless already on PATH at the pin)"
arch="$(jq -r .arch <<<"$PROBE")"
case "$os:$arch" in
  linux:x86_64|wsl2:x86_64) dcg_asset=x86_64-unknown-linux-musl cux_asset=linux-amd64 ;;
  linux:aarch64|wsl2:aarch64) dcg_asset=aarch64-unknown-linux-gnu cux_asset=linux-arm64 ;;
  macos:x86_64) dcg_asset=x86_64-apple-darwin cux_asset=darwin-amd64 ;;
  macos:arm64|macos:aarch64) dcg_asset=aarch64-apple-darwin cux_asset=darwin-arm64 ;;
  *) dcg_asset="" cux_asset="" ;;
esac
# sha256 of each release asset, read from the release's own .sha256 files on 2026-10-25 (records/TB2.md).
declare -A SHA=(
  [dcg-x86_64-unknown-linux-musl.tar.xz]=dc7dcec9679f74ac3e6990959771ca0c84168eba658eff64fe9e63f917a84cc4
  [dcg-aarch64-unknown-linux-gnu.tar.xz]=361765877ef5fc2aa89e3d07b189a4abba4368441125fb5f67b5728d26e5b271
  [dcg-x86_64-apple-darwin.tar.xz]=ec548b61a14c29dd2fc9ae54b1512d99cd3a370911e82639ed1fac71eec91585
  [dcg-aarch64-apple-darwin.tar.xz]=50a1a50762299c7e4b5ebaf3f932f45066c8e7c86a1d5d419b01babd1e2698d7
  [cux-linux-amd64]=d336d1f8a6175265977f5a08ce53c20403e13752b90826df1128c29d89401df6
  [cux-linux-arm64]=a864d0d84301019635343f5b30f32ab7262d5fe8ad9670bf1053106cc6fa7a72
  [cux-darwin-amd64]=879da79489d64e16d871440f7ac5d175ddcd70589d92b4054a3cb38455702561
  [cux-darwin-arm64]=13073a52499af33ca754773e0c61e79ab062f6a340bad475274b0388b02e56dc
)
if [ "$os" = macos ]; then sumcheck="shasum -a 256 -c -"; else sumcheck="sha256sum -c -"; fi
qfh="$(q "$FH")"

plan_add() {  # plan_add <tool> <pin> <state> <found> <blocked> <cmd...>
  local tool="$1" pin="$2" state="$3" found="$4" blocked="$5"; shift 5
  PLAN="$(jq -c --arg t "$tool" --arg p "$pin" --arg s "$state" --arg f "$found" --arg b "$blocked" \
           --argjson cmds "$(printf '%s\0' "$@" | jq -Rsc 'split("\u0000")[:-1] | map(select(. != ""))')" \
    '. + [{tool: $t, pin: $p, state: $s, found: (if $f == "" then null else $f end),
           blocked: (if $b == "" then null else $b end), commands: $cmds}]' <<<"$PLAN")"
}
state_of() {  # state_of <found> <pin>
  if [ -z "$1" ]; then echo missing; elif [ "$1" = "$2" ]; then echo installed; else echo drift; fi
}
version_of() { if has "$1"; then "$1" --version 2>/dev/null | semver_of; fi; }  # version_of <cli>: '' when absent

# @adlc/cli: every factory script runs it through npx; installing = priming the npx cache under $FH.
adlc_found=""
for p in "$FH"/npm/_npx/*/node_modules/@adlc/cli/package.json; do
  [ -f "$p" ] || continue
  [ "$(jq -r .version "$p" 2>/dev/null)" != 1.12.0 ] || adlc_found=1.12.0
done
plan_add @adlc/cli 1.12.0 "$(state_of "$adlc_found" 1.12.0)" "$adlc_found" \
  "$(has npx || echo "npx not found: install Node 18+ (AGENTS.md)")" \
  "npm_config_cache=$qfh/npm npx -y @adlc/cli@1.12.0 --version"
if [ -d "$CLONE/.adlc" ]; then plan_add "adlc init" 1.12.0 installed present ""
else plan_add "adlc init" 1.12.0 missing "" "$(has npx || echo "npx not found")" \
  "npm_config_cache=$qfh/npm npx -y @adlc/cli@1.12.0 init --root $(q "$CLONE") --harness claude-code"; fi
for crate in vetto:0.6.5 ralon:0.1.7; do
  name="${crate%%:*}" pin="${crate#*:}" found="$(version_of "${crate%%:*}")"
  plan_add "$name" "$pin" "$(state_of "$found" "$pin")" "$found" \
    "$(has cargo || echo "cargo not found: install Rust with rustup (https://rustup.rs), then re-run")" \
    "CARGO_HOME=$qfh/cargo cargo install --locked --root $qfh $name@$pin"
done
tg_found=""
if has uv; then
  if uv tool list 2>/dev/null | grep -qx 'tamperguard v0.2.0' ||
     { [ -d "$FH/uv/tools" ] && UV_TOOL_DIR="$FH/uv/tools" uv tool list 2>/dev/null | grep -qx 'tamperguard v0.2.0'; }; then
    tg_found=0.2.0
  fi
fi
plan_add tamperguard 0.2.0 "$(state_of "$tg_found" 0.2.0)" "$tg_found" \
  "$(has uv || echo "uv not found: install uv (https://docs.astral.sh/uv/), then re-run")" \
  "UV_TOOL_DIR=$qfh/uv/tools UV_TOOL_BIN_DIR=$qfh/bin UV_CACHE_DIR=$qfh/uv/cache UV_PYTHON_INSTALL_DIR=$qfh/uv/python UV_PYTHON_BIN_DIR=$qfh/uv/python-bin uv tool install tamperguard==0.2.0"
release_cmd() {  # release_cmd <tool> <asset-file> <url> <member|''>
  local a="$2" sha="${SHA[$2]}" get
  get="d=\$(mktemp -d $qfh/tmp/$1.XXXXXX) && curl -fsSL -o \"\$d/$a\" $(q "$3") && printf '%s  %s\\n' $sha \"\$d/$a\" | $sumcheck"
  if [ -n "$4" ]; then
    printf '%s && tar -xJf "$d/%s" -C "$d" %s && install -m 0755 "$d/%s" %s/bin/%s && rm -rf "$d"' "$get" "$a" "$4" "$4" "$qfh" "$1"
  else
    printf '%s && install -m 0755 "$d/%s" %s/bin/%s && rm -rf "$d"' "$get" "$a" "$qfh" "$1"
  fi
}
release_blocked() {  # release_blocked <asset|''> <needs...>
  local t
  [ -n "$1" ] || { echo "no measured release asset for $os $arch: install it by hand"; return; }
  shift
  for t in "$@"; do has "$t" || { echo "$t not found (needed to fetch and verify the release)"; return; }; done
}
found="$(version_of dcg)"
plan_add dcg 0.15.3 "$(state_of "$found" 0.15.3)" "$found" \
  "$(release_blocked "$dcg_asset" curl tar xz "${sumcheck%% *}")" \
  "$([ -z "$dcg_asset" ] || release_cmd dcg "dcg-$dcg_asset.tar.xz" \
     "https://github.com/Dicklesworthstone/destructive_command_guard/releases/download/v0.15.3/dcg-$dcg_asset.tar.xz" dcg)"
found="$(version_of cux)"
plan_add cux 0.4.1 "$(state_of "$found" 0.4.1)" "$found" \
  "$(release_blocked "$cux_asset" curl "${sumcheck%% *}")" \
  "$([ -z "$cux_asset" ] || release_cmd cux "cux-$cux_asset" "https://github.com/inulute/cux/releases/download/v0.4.1/cux-$cux_asset" "")"
# Adapters: each usable one at its adapters.json pin. Only claude-code has a known package.
while IFS=$'\t' read -r name cli pin found; do
  [ -n "$name" ] || continue
  [ "$found" != null ] || found=""
  if [ "$name" = claude-code ]; then
    plan_add "$name" "$pin" "$(state_of "$found" "$pin")" "$found" "$(has npm || echo "npm not found")" \
      "npm install -g --prefix $qfh --cache $qfh/npm @anthropic-ai/claude-code@$pin"
  elif [ "$found" != "$pin" ]; then
    plan_add "$name" "$pin" "$(state_of "$found" "$pin")" "$found" "no install recipe for $name: install $cli $pin by hand"
  else plan_add "$name" "$pin" installed "$found" ""; fi
done < <(jq -r '.[] | select(.usable) | [.name, .cli, .pin, (.version // "null")] | @tsv' <<<"$ADAPTERS")

# A blocked step refuses only when the tool is not already at its pin.
while IFS= read -r r; do [ -n "$r" ] && refusal "$r"; done < <(jq -r '.[] | select(.state != "installed" and .blocked != null) | "install \(.tool) \(.pin): \(.blocked)"' <<<"$PLAN")
if [ "$json" = 0 ]; then
  jq -r '.[] | "  \(.tool) \(.pin): \(.state)\(if .found and .state != "installed" then " (found \(.found))" else "" end)\(if .blocked and .state != "installed" then " BLOCKED: \(.blocked)" else "" end)",
               (select(.state != "installed") | .commands[] | "    $ \(.)")' <<<"$PLAN"
fi

# ================================================================================================
step "3/5 register (by hand; the wizard never creates a token or a runner)"
token=""
if [ -n "$token_file" ]; then
  if [ "$token_file" = - ]; then IFS= read -r token || true
  else [ -r "$token_file" ] || die "cannot read --token-file $token_file"; IFS= read -r token <"$token_file" || true; fi
  token="${token//[[:space:]]/}"
  if [[ "$token" =~ ^(ghp|gho|ghu|ghs|ghr)_ ]]; then
    refusal "--token-file holds a classic or app token ($(cut -c1-4 <<<"$token")…): the factory needs a fine-grained token scoped to $REPO"
  elif ! [[ "$token" =~ ^github_pat_[A-Za-z0-9_]{20,}$ ]]; then
    refusal "--token-file does not hold a fine-grained GitHub token (github_pat_…)"
  fi
fi
REGISTER="$(jq -cn --arg repo "$REPO" --arg h "$handle" --arg fh "$FH" --argjson given "$([ -n "$token" ] && echo true || echo false)" '
  {token: {url: "https://github.com/settings/personal-access-tokens/new", repository: $repo,
           permissions: {contents: "read and write", metadata: "read"}, expiry_days: 90,
           ref_patterns: ["ticket/**", "nodes/**", "refs/locks/**"], store: "\($fh)/token", given: $given},
   runner: {url: "https://github.com/\($repo)/settings/actions/runners/new", labels: ["factory-node"],
            command: "./config.sh --url https://github.com/\($repo) --token <registration token from that page> --labels factory-node --name \($h)"}}')"
if [ "$json" = 0 ]; then
  jq -r '"  a. Fine-grained personal access token: \(.token.url)",
         "     Repository access: only \(.token.repository). Repository permissions: Contents read and write (Metadata read is added).",
         "     Expiration: \(.token.expiry_days) days. It may write only \(.token.ref_patterns | join(", ")): the token form has no ref field,",
         "     so the repo rules hold that line (whether GitHub scopes it is measured at first join).",
         "     Store it: re-run with --apply --token-file <file> (kept at \(.token.store), mode 0600).",
         "  b. Self-hosted runner, label factory-node: \(.runner.url)",
         "     \(.runner.command)",
         "     (in a runner group scoped to this repo when the repo belongs to an organization; --ephemeral if the box can afford it)"' <<<"$REGISTER"
fi

# ================================================================================================
step "4/5 manifest nodes/$handle.json"
tz="${tz:-${TZ:-}}"
if [ -z "$tz" ]; then
  lt="$(readlink "${FACTORY_PROBE_ROOT:-}/etc/localtime" 2>/dev/null || true)"
  if [[ "$lt" == */zoneinfo/* ]]; then tz="${lt##*/zoneinfo/}"
  elif [ -r "${FACTORY_PROBE_ROOT:-}/etc/timezone" ]; then tz="$(tr -d '[:space:]' <"${FACTORY_PROBE_ROOT:-}/etc/timezone")"; fi
fi
tz="${tz:-UTC}"
if [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/$tz" ]; then refusal "unknown time zone '$tz' (--tz, e.g. America/New_York)"; fi
pinned="$(jq -c 'map(select(.usable) | {key: .name, value: .pin}) | from_entries' <<<"$ADAPTERS")"
fv="$(tr -d '[:space:]' <"$FACTORY_ROOT/factory/VERSION")"
MANIFEST="$(jq -cn --arg h "$handle" --arg o "$owner" --arg os "$os" --argjson probe "$PROBE" --argjson slots "$SLOTS" \
  --argjson heavy "$HEAVY" --argjson ad "$pinned" --arg tier "$tier" --argjson cap "$cap" --arg tz "$tz" \
  --arg qs "$qstart" --arg qe "$qend" --argjson acc "$accounts" --arg fv "$fv" --argjson now "$NOW" '
  {handle: $h, owner: $o, os: (if $os == "" then null else $os end), cpu: $probe.cpu,
   ram_gb: ($probe.ram_total_kb / 1048576 | round), slots: $slots, heavy_gates: $heavy, adapters: $ad,
   quota_tier: $tier, quota_cap: $cap, quiet_hours: {tz: $tz, start: $qs, end: $qe}, accounts: $acc,
   factory_version: $fv, last_seen: ($now | todate), status: "joining"}')"
mtmp="$(mktemp)"
printf '%s\n' "$MANIFEST" >"$mtmp"
MANIFEST_ERRORS="$(validate "$mtmp" | jq -Rsc 'split("\n") | map(select(. != ""))')" || { rm -f "$mtmp"; die "the validator failed"; }
rm -f "$mtmp"
while IFS= read -r e; do [ -n "$e" ] && refusal "the manifest fails factory/nodes/manifest.schema.json: $e"; done < <(jq -r '.[]' <<<"$MANIFEST_ERRORS")
[ "$json" = 1 ] || jq . <<<"$MANIFEST" | sed 's/^/  /'

if [ "$(jq length <<<"$REFUSALS")" -gt 0 ]; then
  jq -r '.[]' <<<"$WARNINGS" | while IFS= read -r w; do warn "warning: $w"; done
  finish 2
fi

if [ "$apply" = 0 ]; then
  reach=true
  tip="$(git -C "$CLONE" ls-remote --heads "$remote" nodes 2>/dev/null | awk '$2 == "refs/heads/nodes" { print $1 }')" || reach=false
  NODES="$(jq -cn --arg r "$remote" --arg t "$tip" --argjson reach "$reach" \
    '{remote: $r, reachable: $reach, tip: (if $t == "" then null else $t end), pushed: false}')"
  if [ "$reach" = false ]; then warning "cannot reach $remote to read the nodes tip: --apply needs it"
  elif [ -z "$tip" ]; then say "  $remote has no nodes branch: --apply will stop here (the maintainer creates it)"
  else say "  would commit nodes/$handle.json on $remote/nodes (${tip:0:12}) and push it, no force"; fi
fi

# ================================================================================================
if [ "$apply" = 1 ]; then
  step "apply: install"
  mkdir -p "$FH/bin" "$FH/tmp"
  chmod 0700 "$FH"
  while IFS= read -r c; do
    run_cmd "$c" || die "install step failed: $c"
  done < <(jq -r '.[] | select(.state != "installed") | .commands[]' <<<"$PLAN")
  PATH="$FH/bin:$PATH"
  for t in vetto:0.6.5 ralon:0.1.7 dcg:0.15.3 cux:0.4.1; do
    [ "$(version_of "${t%%:*}")" = "${t#*:}" ] || die "${t%%:*} is not at ${t#*:} after the install"
  done
  while IFS=$'\t' read -r cli pin; do
    [ -n "$cli" ] || continue
    [ "$(version_of "$cli")" = "$pin" ] || die "$cli is not at its pin $pin after the install"
  done < <(jq -r '.[] | select(.usable) | [.cli, .pin] | @tsv' <<<"$ADAPTERS")

  step "apply: register"
  if [ -n "$token" ]; then
    ( umask 077; printf '%s\n' "$token" >"$FH/token.tmp" ) && mv -f "$FH/token.tmp" "$FH/token" && chmod 0600 "$FH/token"
    say "  token stored at $FH/token (0600)"
  else
    say "  no --token-file: no token stored (re-run with one before /factory:run)"
  fi
  printf '%s\n' "$MANIFEST" | jq . >"$FH/manifest.json"
  { echo "# Written by factory/bin/join.sh for $handle; sourced by the run loop."
    printf 'export FACTORY_HOME=%s\n' "$qfh"
    printf 'export FACTORY_MANIFEST=%s\n' "$(q "$FH/manifest.json")"
    printf 'export FACTORY_HANDLE=%s\n' "$(q "$handle")"
    printf 'export npm_config_cache=%s\n' "$(q "$FH/npm")"
    printf 'export PATH=%s:"$PATH"\n' "$(q "$FH/bin")"
  } >"$FH/env"

  step "apply: commit nodes/$handle.json to $remote/nodes (compare-and-swap, never force)"
  idx="$(git -C "$CLONE" rev-parse --absolute-git-dir)/factory-join.index"
  attempts=0 pushed=""
  while [ "$attempts" -lt 3 ]; do
    attempts=$((attempts + 1))
    git -C "$CLONE" fetch --quiet --no-tags "$remote" "+refs/heads/nodes:refs/remotes/$remote/nodes" 2>/dev/null ||
      die "cannot fetch $remote nodes: the nodes branch must exist (the maintainer creates it)"
    tip="$(git -C "$CLONE" rev-parse "refs/remotes/$remote/nodes")"
    held="$(git -C "$CLONE" cat-file blob "$tip:nodes/$handle.json" 2>/dev/null | jq -r '.owner // empty' 2>/dev/null || true)"
    [ -z "$held" ] || [ "$held" = "$owner" ] || refuse "handle $handle is held by owner $held on $remote/nodes: pick another --handle"
    blob="$(printf '%s\n' "$MANIFEST" | jq . | git -C "$CLONE" hash-object -w --stdin)"
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git -C "$CLONE" read-tree "$tip"
    GIT_INDEX_FILE="$idx" git -C "$CLONE" update-index --add --cacheinfo "100644,$blob,nodes/$handle.json"
    tree="$(GIT_INDEX_FILE="$idx" git -C "$CLONE" write-tree)"
    rm -f "$idx"
    commit="$(printf 'nodes: join %s\n\nNode: %s\n' "$handle" "$handle" | git -C "$CLONE" commit-tree "$tree" -p "$tip")"
    if git -C "$CLONE" push --quiet "$remote" "$commit:refs/heads/nodes" 2>"$FH/tmp/push.err"; then
      pushed="$commit"; break
    fi
    now_tip="$(git -C "$CLONE" ls-remote --heads "$remote" nodes | awk '$2 == "refs/heads/nodes" { print $1 }')"
    if [ "$now_tip" = "$tip" ]; then
      command cat "$FH/tmp/push.err" >&2; rm -f "$FH/tmp/push.err"
      die "push to $remote nodes failed and the tip did not move (not a race): see git's error above"
    fi
    say "  attempt $attempts lost the compare-and-swap ($remote/nodes moved ${tip:0:12} -> ${now_tip:0:12}); retrying on the new tip"
  done
  rm -f "$FH/tmp/push.err"
  NODES="$(jq -cn --arg r "$remote" --arg c "$pushed" --argjson a "$attempts" \
    '{remote: $r, pushed: ($c != ""), commit: (if $c == "" then null else $c end), attempts: $a}')"
  [ -n "$pushed" ] || die "lost the compare-and-swap on $remote/nodes $attempts times; nothing was forced: re-run join.sh"
  say "  pushed ${pushed:0:12} to $remote nodes in $attempts attempt(s): the first heartbeat"
fi

# ================================================================================================
step "5/5 run"
if [ "$apply" = 1 ]; then say "  . $FH/env"; else say "  . $FH/env   (written by --apply)"; fi
for ((s = 1; s <= SLOTS; s++)); do say "  factory/bin/run.sh --slot $s      # one loop per slot (/factory:run)"; done
say ""
if [ "$json" = 1 ]; then command cat "$FACTORY_ROOT/factory/RULES.md" >&2; else command cat "$FACTORY_ROOT/factory/RULES.md"; fi
jq -r '.[]' <<<"$WARNINGS" | while IFS= read -r w; do warn "warning: $w"; done
finish 0
