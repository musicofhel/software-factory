# shellcheck shell=bash
# Budget-governor helpers (SPEC-v0.2 "Budget governor"; ticket T8). Sourced by governor.sh and
# quota-gate.sh after lib/common.sh, never executed.
#
#   gov_now                        the clock in epoch seconds: FACTORY_NOW as epoch seconds or as an
#                                  ISO-8601 date-time with Z or an offset (tests pin it), else date
#   gov_iso_epoch <iso>            one ISO-8601 date-time (fraction and offset allowed) → epoch
#   gov_tz_ok <zone>               the zone names a tz database file (jq falls back to UTC silently
#                                  on an unknown TZ, so it is checked first)
#   gov_quiet <now> <tz> <HH:MM> <HH:MM>
#                                  seconds until the quiet window ends, 0 when outside it. The
#                                  window is wall-clock time in <tz>; start > end wraps midnight;
#                                  start == end is no window. Across a DST change the end is the
#                                  next instant whose wall clock reads end (the first one when the
#                                  hour repeats; when end falls in the skipped hour, the instant
#                                  the clock jumps past it).
#   gov_cux_payload <refresh 0|1>  `cux usage refresh` (best effort, output dropped: it lists the
#                                  account e-mails) then `cux usage show` on stdout. FACTORY_CUX names
#                                  the binary (default `cux` on PATH). Exit non-zero when show fails.
#   gov_quota <payload> <now> <quota_cap> <stale_s> <unknown_s>
#                                  one JSON line {state: under|exhausted|unknown, why, accounts,
#                                  under, at_cap, unknown, sleep_seconds}: counts only, never an
#                                  account key (the keys are e-mails; I8).
#   gov_heartbeat <remote> <handle> <owner> <now> <manifest>
#                                  nodes/<handle>.json on <remote>/nodes with last_seen = now,
#                                  committed on the fetched tip and pushed without force (3 tries).
#                                  stdout: pushed <sha> <attempts> | unregistered | retired |
#                                  held-by-other | failed. Exit 0 pushed, 2 refused, 1 failed.
#
# Which cux windows count (records/TB3.md of specs/factory-step2-v1): every window of an account,
# five_hour, seven_day and each model window (seven_day_<family>), because cux v0.4.1 itself ranks
# seats on all of them (usage.go, #52: a seat capped on a model window is refused on the next call).
# A window whose resets_at has passed counts as reset (cux's Settled). An account is
#   under    a reading younger than stale_s, no token_expired, at least one window, and every window
#            that has not reset below quota_cap (utilization is 0–100, quota_cap a fraction);
#   at_cap   token_expired, or some window at or above the cap; it frees when the last of those
#            windows resets (null when one of them has no resets_at, or the token expired);
#   unknown  anything else: no polled_at, a stale reading, a malformed five_hour/seven_day or
#            resets_at, no window at all.
# The node may claim when one account is under. Else, with an account at the cap, it sleeps until
# the earliest account frees (accounts with no known time count as unknown_s from now); else the
# reading is unknown and it sleeps unknown_s. A payload that is not a JSON object, or `{}` (cux
# manages no account), is unknown: fail closed, never claim.

gov_iso_epoch() {
  jq -nr --arg d "$1" '
    [$d | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})[Tt ](?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>[Zz]|[+-][0-9]{2}:?[0-9]{2})$")]
    | if length == 0 then error("not an ISO-8601 date-time: \($d)") else .[0] end
    | (.z | ascii_downcase | gsub(":"; "")) as $z
    | ("\(.d)T\(.t)Z" | fromdateiso8601)
      - (if $z == "z" then 0 else ($z[0:1] | if . == "-" then -1 else 1 end) * (($z[1:3] | tonumber) * 3600 + ($z[3:5] | tonumber) * 60) end)' 2>/dev/null
}

gov_now() {
  local n="${FACTORY_NOW:-}" e
  if [ -z "$n" ]; then date -u +%s; return; fi
  if [[ "$n" =~ ^[0-9]+$ ]]; then printf '%s\n' "$n"; return; fi
  e="$(gov_iso_epoch "$n")" || die "FACTORY_NOW must be epoch seconds or ISO-8601 (2026-10-25T03:10:00Z), got '$n'"
  printf '%s\n' "$e"
}

gov_tz_ok() {
  [ "$1" = UTC ] && return 0
  [[ "$1" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  [ -f "${TZDIR:-/usr/share/zoneinfo}/$1" ]
}

gov_quiet() {
  local now="$1" tz="$2" start="$3" end="$4"
  [[ "$start" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && "$end" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] ||
    die "quiet_hours start/end must be HH:MM, got '$start'-'$end'"
  gov_tz_ok "$tz" || die "quiet_hours tz '$tz' is not in the tz database (${TZDIR:-/usr/share/zoneinfo})"
  TZ="$tz" jq -n --argjson t "$now" --arg s "$start" --arg e "$end" '
    def mins: split(":") | (.[0] | tonumber) * 60 + (.[1] | tonumber);
    def off: . as $x | ($x | localtime | mktime) - $x;        # the zone offset at instant $x
    def wall: . + (. | off);                                   # the wall clock as a UTC-style epoch
    ($t | floor) as $t | ($s | mins) as $s | ($e | mins) as $e
    | ((($t | wall) % 86400) / 60 | floor) as $m
    | (if $s == $e then false elif $s < $e then $m >= $s and $m < $e else $m >= $s or $m < $e end) as $in
    | if ($in | not) then 0 else
        ($t | wall) as $L
        | ($L - ($L % 86400) + $e * 60) as $Lt0 | (if $Lt0 <= $L then $Lt0 + 86400 else $Lt0 end) as $Lt
        | ($Lt - ($t | off)) as $T0 | ($Lt - ($T0 | off)) as $T1
        | [$T0, $T1 | select(. > $t and wall == $Lt)] as $ok
        | if ($ok | length) > 0 then ($ok | min) - $t
          else [([$T0, $T1] | min), ([$T0, $T1] | max)]
               | until(.[1] - .[0] <= 1; (((.[0] + .[1]) / 2) | floor) as $mid
                       | if ($mid | wall) >= $Lt then [.[0], $mid] else [$mid, .[1]] end)
               | .[1] - $t
          end
      end'
}

gov_cux_payload() {
  local cux="${FACTORY_CUX:-cux}"
  command -v "$cux" >/dev/null 2>&1 || { warn "cux not found ($cux): quota unknown"; return 1; }
  if [ "$1" = 1 ]; then
    "$cux" usage refresh >/dev/null 2>&1 || warn "cux usage refresh failed: using the cached reading"
  fi
  "$cux" usage show 2>/dev/null
}

gov_quota() {
  jq -cn --arg p "$1" --argjson now "$2" --argjson cap "$3" --argjson stale "$4" --argjson unk "$5" '
    def iso2epoch:   # a fraction of a second rounds up: never wake before a reset
      [capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})[Tt](?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>\\.[0-9]+)?(?<z>[Zz]|[+-][0-9]{2}:[0-9]{2})$")]
      | if length == 0 then error("bad time") else .[0] end
      | (.z | ascii_downcase | gsub(":"; "")) as $z
      | ("\(.d)T\(.t)Z" | fromdateiso8601) + (if (.f // "" | test("[1-9]")) then 1 else 0 end)
        - (if $z == "z" then 0 else ($z[0:1] | if . == "-" then -1 else 1 end) * (($z[1:3] | tonumber) * 3600 + ($z[3:5] | tonumber) * 60) end);
    def reserved: ["polled_at", "token_expired", "retry_after", "failures", "limits"];
    def window: type == "object" and (.utilization | type) == "number";
    ($cap * 100 * 1000000 | round / 1000000) as $pct
    | def classify:
        if type != "object" then {state: "unknown"}
        elif .token_expired == true then {state: "at_cap", free_at: null}
        else
          (try (.polled_at | iso2epoch) catch null) as $polled
          | [to_entries[] | select(.key as $k | reserved | index($k) | not)] as $rest
          | if $polled == null or ($now - $polled) > $stale then {state: "unknown"}
            elif any($rest[]; (.key == "five_hour" or .key == "seven_day") and (.value | window | not)) then {state: "unknown"}
            else
              [$rest[] | .value | select(window)
               | {u: .utilization, r: (if .resets_at == null then null else (try (.resets_at | iso2epoch) catch "bad") end)}] as $w
              | if ($w | length) == 0 or any($w[]; .r == "bad") then {state: "unknown"}
                else [$w[] | select(.r == null or .r > $now) | select(.u >= $pct)] as $capped
                  | if ($capped | length) == 0 then {state: "under"}
                    elif any($capped[]; .r == null) then {state: "at_cap", free_at: null}
                    else {state: "at_cap", free_at: ([$capped[].r] | max)} end
                end
            end
        end;
    (try ($p | fromjson) catch null) as $d
    | if ($d | type) != "object" then {state: "unknown", why: "malformed", accounts: 0, under: 0, at_cap: 0, unknown: 0, sleep_seconds: $unk}
      elif ($d | length) == 0 then {state: "unknown", why: "no-accounts", accounts: 0, under: 0, at_cap: 0, unknown: 0, sleep_seconds: $unk}
      else [$d[] | classify] as $c
        | {accounts: ($c | length), under: ([$c[] | select(.state == "under")] | length),
           at_cap: ([$c[] | select(.state == "at_cap")] | length), unknown: ([$c[] | select(.state == "unknown")] | length)} as $n
        | if $n.under > 0 then {state: "under", why: "headroom"} + $n + {sleep_seconds: 0}
          elif $n.at_cap > 0 then {state: "exhausted", why: "all-at-cap"} + $n
            + {sleep_seconds: ([$c[] | if .state == "at_cap" and .free_at != null then .free_at - $now else $unk end] | min | ceil)}
          else {state: "unknown", why: "no-reading"} + $n + {sleep_seconds: $unk} end
      end'
}

gov_heartbeat() {
  local remote="$1" handle="$2" owner="$3" now="$4" manifest="$5"
  local gitdir idx tip blob held status tree commit attempts=0 now_tip tmp out iso
  local tracking="refs/remotes/$remote/nodes" path="nodes/$handle.json"
  gitdir="$(git rev-parse --absolute-git-dir)" || { echo failed; return 1; }
  idx="$gitdir/factory-heartbeat.$$.index"
  iso="$(jq -nr --argjson n "$now" '$n | todate')"
  tmp="$(mktemp)"
  while [ "$attempts" -lt 3 ]; do
    attempts=$((attempts + 1))
    if ! git fetch --quiet --no-tags --no-write-fetch-head "$remote" "+refs/heads/nodes:$tracking" 2>/dev/null; then
      warn "heartbeat: cannot fetch $remote nodes"; rm -f "$tmp"; echo failed; return 1
    fi
    tip="$(git rev-parse --verify --quiet "$tracking^{commit}")" || { rm -f "$tmp"; echo failed; return 1; }
    if ! git cat-file blob "$tip:$path" >"$tmp" 2>/dev/null; then rm -f "$tmp"; echo unregistered; return 2; fi
    held="$(jq -r '.owner // empty' "$tmp" 2>/dev/null)" || { warn "heartbeat: $path on $remote/nodes is not JSON"; rm -f "$tmp"; echo failed; return 1; }
    [ "$held" = "$owner" ] || { rm -f "$tmp"; echo held-by-other; return 2; }
    status="$(jq -r '.status // empty' "$tmp")"
    [ "$status" != retired ] || { rm -f "$tmp"; echo retired; return 2; }
    out="$(jq --arg at "$iso" '.last_seen = $at | .status = (if .status == "joining" or .status == "stale" then "active" else .status end)' "$tmp")"
    printf '%s\n' "$out" >"$tmp"
    if ! "$FACTORY_ROOT/factory/bin/join.sh" --validate "$tmp" >/dev/null 2>&1; then
      warn "heartbeat: $path would fail factory/nodes/manifest.schema.json; not pushed"; rm -f "$tmp"; echo failed; return 1
    fi
    blob="$(git hash-object -w "$tmp")"
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git read-tree "$tip"
    GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$blob,$path"
    tree="$(GIT_INDEX_FILE="$idx" git write-tree)"
    rm -f "$idx"
    commit="$(printf 'nodes: heartbeat %s\n\nNode: %s\n' "$handle" "$handle" | git commit-tree "$tree" -p "$tip")"
    if git push --quiet "$remote" "$commit:refs/heads/nodes" 2>/dev/null; then
      if [ -n "$manifest" ] && [ -w "$manifest" ]; then
        jq --arg at "$iso" --arg st "$(jq -r .status <<<"$out")" '.last_seen = $at | .status = $st' "$manifest" >"$manifest.tmp.$$" &&
          mv -f "$manifest.tmp.$$" "$manifest" || warn "heartbeat: pushed, but cannot update $manifest"
      fi
      rm -f "$tmp"; echo "pushed $commit $attempts"; return 0
    fi
    now_tip="$(git ls-remote --heads "$remote" nodes 2>/dev/null | awk '$2 == "refs/heads/nodes" { print $1 }')"
    if [ "$now_tip" = "$tip" ]; then warn "heartbeat: push to $remote nodes refused and the tip did not move"; break; fi
    warn "heartbeat: attempt $attempts lost the compare-and-swap on $remote/nodes; retrying"
  done
  rm -f "$tmp"; echo failed; return 1
}
