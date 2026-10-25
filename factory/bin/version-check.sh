#!/usr/bin/env bash
# version-check — may this node claim, or is its factory behind? (SPEC-v0.2 "Run loop" version_check;
# "Factory version skew": factory/VERSION and adapter pins, behind means no claims.)
#
#   version-check.sh [--json] [--remote NAME] [--branch NAME] [--manifest nodes/<handle>.json]
#
# Fetches <remote>/<branch> (default origin/main) as halt-check does, then compares:
#   version    the checkout's factory/VERSION with factory/VERSION on <remote>/<branch>
#   pins       each adapter pin in the node's manifest (--manifest, else $FACTORY_MANIFEST) with
#              factory/policy/adapters.json on <remote>/<branch> ({"<adapter>": "<x.y.z>"}) when that
#              file exists there (it does not yet: pins_source is null and only drift is checked)
#   installed  each manifest pin with the installed CLI's `--version` (claude-code is `claude`;
#              codex, agy, opencode are themselves). Drift, or a pinned CLI that is not installed,
#              refuses claims until the owner re-pins.
# Versions compare as numbers, x.y.z; anything after the third number is ignored.
#
# Exit 0: current, or ahead. Exit 2: behind or drifted: do not claim (pull, re-pin, restart).
# Exit 1: the fetch failed, or a VERSION, pin file or manifest is unreadable: the state is unknown,
#         so a caller must treat any exit other than 0 as "do not claim".
set -euo pipefail
PROG=version-check
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/lib/common.sh"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

json=0 remote=origin branch=main manifest="${FACTORY_MANIFEST:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1 ;;
    --remote) remote="${2:-}"; shift ;;
    --branch) branch="${2:-}"; shift ;;
    --manifest) manifest="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need git jq
[ -n "$remote" ] && [ -n "$branch" ] || die "--remote and --branch need a value"

tracking="refs/remotes/$remote/$branch"
git fetch --quiet --no-tags "$remote" "+refs/heads/$branch:$tracking" ||
  die "cannot fetch $remote $branch; version state unknown, do not claim"
sha="$(git rev-parse --verify --quiet "$tracking^{commit}")" || die "$tracking is not a commit after the fetch"
top="$(git rev-parse --show-toplevel)"

semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; }
local_v="$(tr -d '[:space:]' <"$top/factory/VERSION" 2>/dev/null)" || die "cannot read factory/VERSION in $top"
remote_v="$(git cat-file blob "$sha:factory/VERSION" 2>/dev/null | tr -d '[:space:]')" || die "no factory/VERSION on $remote/$branch ($sha)"
semver "$local_v" || die "factory/VERSION in $top is not x.y.z: '$local_v'"
semver "$remote_v" || die "factory/VERSION on $remote/$branch is not x.y.z: '$remote_v'"

PINS_FILE=factory/policy/adapters.json
pins=null pins_source=null
if git cat-file -e "$sha:$PINS_FILE" 2>/dev/null; then
  pins="$(git cat-file blob "$sha:$PINS_FILE" | jq -ce 'select(type == "object")')" ||
    die "$PINS_FILE on $remote/$branch is not a JSON object"
  pins_source="\"$PINS_FILE\""
fi

adapters='[]'
if [ -n "$manifest" ]; then
  [ -f "$manifest" ] || die "manifest not found: $manifest"
  mine="$(jq -ce '.adapters | select(type == "object")' "$manifest")" || die "manifest has no adapters object: $manifest"
  while IFS=$'\t' read -r name pin; do
    [ -n "$name" ] || continue
    semver "$pin" || die "manifest pin for $name is not x.y.z: '$pin' ($manifest)"
    case "$name" in claude-code) cli=claude ;; *) cli="$name" ;; esac
    installed=""
    if command -v "$cli" >/dev/null 2>&1; then
      installed="$("$cli" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    fi
    adapters="$(jq -c --arg n "$name" --arg p "$pin" --arg cli "$cli" --arg i "$installed" \
      '. + [{name: $n, cli: $cli, pin: $p, installed: (if $i == "" then null else $i end)}]' <<<"$adapters")"
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$mine")
fi

report="$(jq -cn --arg ref "$remote/$branch" --arg sha "$sha" --arg lv "$local_v" --arg rv "$remote_v" \
  --argjson pins "$pins" --argjson src "$pins_source" --argjson ads "$adapters" --arg manifest "$manifest" '
  def v: capture("^(?<a>[0-9]+)\\.(?<b>[0-9]+)\\.(?<c>[0-9]+)") | [.a, .b, .c] | map(tonumber);
  def cmp($x; $y): if ($x | v) < ($y | v) then "behind" elif ($x | v) > ($y | v) then "ahead" else "current" end;
  {ref: $ref, sha: $sha,
   version: {local: $lv, remote: $rv, state: cmp($lv; $rv)},
   manifest: (if $manifest == "" then null else $manifest end), pins_source: $src,
   adapters: [ $ads[] | . + {main_pin: ($pins[.name] // null)}
               | . + {state: (if .main_pin != null and ((.main_pin | tostring | test("^[0-9]+\\.[0-9]+\\.[0-9]+")) | not) then "bad-pin"
                              elif .main_pin != null and cmp(.pin; .main_pin) == "behind" then "behind"
                              elif .installed == null then "not-installed"
                              elif cmp(.installed; .pin) != "current" then "drift"
                              else "current" end)} ]}
  | .refusals = ([ if .version.state == "behind" then "factory/VERSION \(.version.local) is behind \($ref) (\(.version.remote)): pull and restart" else empty end ]
                 + [ .adapters[] | select(.state != "current")
                     | if .state == "behind" then "\(.name) pin \(.pin) is behind \($ref) (\(.main_pin)): re-pin and upgrade"
                       elif .state == "bad-pin" then "\(.name) pin on \($ref) is not x.y.z: \(.main_pin)"
                       elif .state == "not-installed" then "\(.name) is pinned at \(.pin) but `\(.cli)` is not installed"
                       else "\(.name) installed \(.installed) drifted from its pin \(.pin): re-pin" end ])
  | .ok = (.refusals | length == 0)')"

if [ "$json" = 1 ]; then printf '%s\n' "$report"; else
  jq -r '"factory/VERSION \(.version.local): \(.version.state) with \(.ref) (\(.version.remote))",
         (.adapters[] | "adapter \(.name): pin \(.pin), main \(.main_pin // "unpinned"), installed \(.installed // "none"): \(.state)")' <<<"$report"
fi
if jq -e '.ok' <<<"$report" >/dev/null; then exit 0; fi
jq -r '.refusals[]' <<<"$report" | while IFS= read -r r; do warn "$r"; done
warn "behind or drifted: refusing to claim"
exit 2
