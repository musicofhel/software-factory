# shellcheck shell=bash
# diff-gates — the three diff gates' one implementation, sourced (after lib/common.sh) by run.sh and by
# rails-proof.sh, scope-check.sh and tamper-check.sh, so the node and CI call the same matcher with the
# same argv, the same tool pin and the same range rule (specs/factory-step3-v1 TB3, ticket T22, I17).
#
# The range is always three-dot from the merge-base: `BASE...HEAD`, read in the current directory. The
# ticket (its scope and rails) is read from the BASE commit's store, never from the head: a branch
# cannot widen its own scope or drop its own rails.
#
#   dg_ticket <id> <base>         the ticket JSON from <base>:.adlc/tickets/<slug>--<sha256 id>.json
#                                 (adlc tickets/lib/filename.mjs); absent or completed → exit 2
#   dg_changed <base> <head>      every path BASE...HEAD touches, NUL-separated (--no-renames: a rename
#                                 out of a rail shows both paths, never only the new one)
#   dg_rails <id> <base> <head>   return 2 and print the paths that touch a rail; no rails → refuse
#   dg_scope <id> <base> <head>   return 2 and print the paths outside the ticket's scope, and every
#                                 `.adlc/**` path (a ticket never writes the store, even when a scope
#                                 glob covers it)
#   dg_tamper_argv <base> <head>  tamperguard's argv, one per line: --range BASE...HEAD --json
#   dg_tamper_judge <rc> <json>   0:ok 0:review 2:tamper; anything else is tamper-error
#
# Globs. scope uses fleet's own matcher, ported exactly: @adlc/cli 1.12.0 fleet lib/gates.mjs:54-60
# scopeViolations → @adlc/core lib/tickets.mjs:136-138 inScope → lib/glob.mjs:37-81 globMatch. Its
# tokens are `**/` (nothing, or a run ending at `/`), `**` (any run, `/` included), `*` (a run inside
# one segment); everything else is literal, `?` and `[` included. Git's `:(glob)` differs in 3 of 442
# measured cases (records/TB3.md): `src/**.js` matches `src/a/b.js` for fleet and not for git (git reads
# a `**` that is not slash-bounded as `*`), while `a?c` and `[ab]x` are wildcards for git only. So a rail
# freezes the UNION of what `git diff -- ':(glob)<rail>'` reports and what the fleet port matches:
# whichever reading reaches a path, the path is frozen.
#
# Every dg_* call prints one trace line on stderr, `diff-gates: <fn> <argv>` (and tamperguard's argv);
# tests compare the node's lines with CI's (I17).

# shellcheck disable=SC2034  # read by tests/test_diff_gates.sh against gates.yml
DG_TAMPERGUARD_PIN=0.2.0
# The node's uv resolves tamperguard 0.2.0 on CPython 3.14 (`uv tool list --show-python`); CI pins the
# same minor (node:G16).
# shellcheck disable=SC2034  # as above
DG_TAMPERGUARD_PYTHON=3.14

dg_trace() { printf 'diff-gates: %s\n' "$*" >&2; }

# The fleet matcher as a jq function: `<path> | dg_glob(<pattern>)`. reach[i] = the pattern so far
# can end at offset i (code points), as in glob.mjs.
DG_GLOB_JQ='
def dg_glob($p):
  (explode) as $c | ($c | length) as $end | ([range(0; $end + 1) | false]) as $none |
  reduce ($p | [scan("\\*\\*/|\\*\\*|\\*|[^*]+")] | .[]) as $t ([range(0; $end + 1) | . == 0];
    . as $r |
    if $t == "**" then
      reduce range(0; $end + 1) as $i ({o: false, n: []}; .o = (.o or $r[$i]) | .n += [.o]) | .n
    elif $t == "**/" then
      reduce range(0; $end + 1) as $i ({o: false, n: $none};
        (if $r[$i] then .n[$i] = true | .o = true else . end)
        | if .o and $i < $end and $c[$i] == 47 then .n[$i + 1] = true else . end) | .n
    elif $t == "*" then
      reduce range(0; $end + 1) as $i ({o: false, n: []};
        .o = (.o or $r[$i]) | .n += [.o] | if $i < $end and $c[$i] == 47 then .o = false else . end) | .n
    else
      ($t | explode) as $tc | ($tc | length) as $l |
      reduce range(0; $end + 1) as $i ($none;
        if $r[$i] and $i + $l <= $end and $c[$i:$i + $l] == $tc then .[$i + $l] = true else . end)
    end) | .[$end];
def dg_any($globs): . as $s | any($globs[]; . as $g | $s | dg_glob($g));
'

dg_sha256() {
  if command -v sha256sum >/dev/null; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; fi
}

dg_ticket() {
  local id="$1" base="$2" h f t
  dg_trace "dg_ticket $id $base"
  valid_ticket_id "$id" || refuse "bad ticket id '$id'"
  h="$(dg_sha256 "$id")"
  f="$(git ls-tree -z --name-only "$base" -- .adlc/tickets/ | tr '\0' '\n' | grep -E -- "^\.adlc/tickets/[a-z0-9-]+--$h\.json\$" | head -n1 || true)"
  [ -n "$f" ] || refuse "ticket $id is not in the store at base ${base:0:12} (.adlc/tickets/*--$h.json)"
  t="$(git show "$base:$f" | jq -c .)" || die "cannot read $f at ${base:0:12}"
  [ "$(jq -r '.id // empty' <<<"$t")" = "$id" ] || refuse "$f at ${base:0:12} is not ticket $id"
  [ "$(jq -r '.completed // false' <<<"$t")" != true ] || refuse "ticket $id is completed at base ${base:0:12}"
  printf '%s\n' "$t"
}

# dg_paths <base> <head> [pathspec...]: the paths BASE...HEAD touches as one JSON array (no trace).
# A failed diff is an error, never an empty diff.
dg_paths() {
  local base="$1" head="$2" tmp rc=0; shift 2
  tmp="$(mktemp)" || die "mktemp failed"
  git diff --no-renames --name-only -z "$base...$head" -- "$@" >"$tmp" || rc=$?
  [ "$rc" = 0 ] && jq -Rsc 'split("\u0000") | map(select(. != ""))' <"$tmp" || rc=1
  rm -f "$tmp"
  [ "$rc" = 0 ] || die "git diff $base...$head failed"
}

dg_changed() {
  dg_trace "dg_changed $1 $2"
  dg_paths "$1" "$2" | jq -j '.[] | ., "\u0000"'
}

dg_rails() {
  local id="$1" base="$2" head="$3" t globs spec=() r all viagit hits
  dg_trace "dg_rails $id $base $head"
  t="$(dg_ticket "$id" "$base")" || return
  globs="$(jq -c '.rails // [] | map(select(type == "string" and . != ""))' <<<"$t")"
  [ "$(jq 'length' <<<"$globs")" -gt 0 ] || refuse "rails: none declared for $id (a ticket without rails is not gated, it is refused)"
  while IFS= read -r r; do spec+=(":(glob)$r"); done < <(jq -r '.[]' <<<"$globs")
  all="$(dg_paths "$base" "$head")" || return 1
  viagit="$(dg_paths "$base" "$head" "${spec[@]}")" || return 1
  hits="$(jq -nr --argjson all "$all" --argjson git "$viagit" --argjson g "$globs" "$DG_GLOB_JQ"'
    ($git + [$all[] | select(dg_any($g))]) | unique[]')" || die "the rails matcher failed"
  [ -z "$hits" ] || { printf '%s\n' "$hits"; return 2; }
}

dg_scope() {
  local id="$1" base="$2" head="$3" t globs all out
  dg_trace "dg_scope $id $base $head"
  t="$(dg_ticket "$id" "$base")" || return
  globs="$(jq -c '.scope // [] | map(select(type == "string"))' <<<"$t")"
  all="$(dg_paths "$base" "$head")" || return 1
  # An empty or missing scope puts every path out of scope (fleet gates.mjs:55-58).
  out="$(jq -nr --argjson all "$all" --argjson g "$globs" "$DG_GLOB_JQ"'
    $all[] | select(startswith(".adlc/") or (dg_any($g) | not))')" || die "the scope matcher failed"
  [ -z "$out" ] || { printf '%s\n' "$out"; return 2; }
}

dg_tamper_argv() { dg_trace "tamperguard --range $1...$2 --json"; printf '%s\n' --range "$1...$2" --json; }

dg_tamper_judge() {
  local rc="$1" v
  v="$(jq -r 'select(type == "object") | .verdict // empty' <<<"$2" 2>/dev/null | head -n1 || true)"
  case "$rc:$v" in
    0:ok|0:review|2:tamper) printf '%s\n' "$rc:$v" ;;
    *) printf 'tamper-error\n' ;;
  esac
}
