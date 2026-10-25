# shellcheck shell=bash
# The per-claim build policy for the run loop's tamperguard step (ticket T17; ADR-0005, amendment
# "decision 8 under the rendered policy"). Sourced, never executed; needs bash 4+, git, jq, awk.
#
# factory/policy/build.toml is the template and is never edited (I15: it is every ticket's rail).
# vetto 0.6.5 strict reads only its own roots, so tamperguard there cannot exec its uv tool or
# interpreter (rc 126) nor read a linked worktree's git dir ("empty diff, nothing to scan"). Each
# claim therefore gets a copy that adds absolute read roots, and nothing else (I14):
#
#   policy_roots <worktree> <factory-home> [tool]
#                       the roots the step needs, one per line: the worktree's common git dir
#                       (resolved), <factory-home>/bin and /uv when they exist, the install root of
#                       the tool [tamperguard] as PATH resolves it (readlink -f), and the install root
#                       of the interpreter its `#!` line names (readlink -f). A root inside another
#                       is dropped. Returns 1 with a reason on stderr when a required one is missing.
#   policy_render <template> <out> <root>...
#                       writes <template> with its one-line [filesystem] allow_read extended by the
#                       roots (each absolute, an existing directory, never $HOME or above it).
#                       Every other line is copied as is. Returns 1, writing nothing, otherwise.
#   policy_tamperguard <worktree> <policy> <range>
#                       the step itself: vetto strict under <policy>, from the worktree root, writes
#                       .factory-run/tamperguard.{json,err,rc}. vetto exits 125 whatever happened
#                       (ADR-0005 amendment T6 item 1), so the caller reads the rc file, never vetto.
#                       vetto's own output goes to stdout/stderr.
#
# Measured on vetto 0.6.5 (specs/factory-run-calls-v1/records/TB1.md): the narrow set is enough. The
# interpreter's install root alone covers a uv python reached through a symlinked version dir
# (cpython-3.14 -> cpython-3.14.3): Landlock checks the file opened, not the links walked.

# _policy_install_root <file>: the resolved file's install root: <root> for <root>/bin/<exe>, else
# the directory holding it.
_policy_install_root() {
  local f d
  f="$(readlink -f "$1" 2>/dev/null)" && [ -f "$f" ] && [ -x "$f" ] || return 1
  d="$(dirname "$f")"
  if [ "$(basename "$d")" = bin ]; then dirname "$d"; else printf '%s\n' "$d"; fi
}

# _policy_interpreter <script>: the interpreter its first line names (`#!/abs/python`, or
# `#!/usr/bin/env <name>` through PATH). Any other form gives a root that does not cover the real
# interpreter, so the step fails closed (rc 126) rather than running outside the policy.
_policy_interpreter() {
  local line w
  line="$(head -n1 "$1" 2>/dev/null)" || return 1
  [[ "$line" =~ ^\#\![[:space:]]*([^[:space:]]+)[[:space:]]*([^[:space:]]*) ]] || return 1
  w="${BASH_REMATCH[1]}"
  if [ "$(basename "$w")" = env ] && [ -n "${BASH_REMATCH[2]}" ]; then
    command -v "${BASH_REMATCH[2]}" 2>/dev/null || return 1
  else
    printf '%s\n' "$w"
  fi
}

policy_roots() {
  local wt="$1" fh="$2" tool="${3:-tamperguard}" git_dir path interp r
  local -a found=() kept=()
  git_dir="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
    git_dir="$(cd "$git_dir" 2>/dev/null && pwd -P)" ||
    { echo "policy-render: no git dir for $wt" >&2; return 1; }
  found+=("$git_dir")
  for r in "$fh/bin" "$fh/uv"; do [ ! -d "$r" ] || found+=("$(cd "$r" && pwd -P)"); done
  path="$(command -v "$tool" 2>/dev/null)" || { echo "policy-render: $tool is not on PATH" >&2; return 1; }
  r="$(_policy_install_root "$path")" || { echo "policy-render: $tool ($path) does not resolve to an executable" >&2; return 1; }
  found+=("$r")
  interp="$(_policy_interpreter "$(readlink -f "$path")")" ||
    { echo "policy-render: $tool names no interpreter on its first line" >&2; return 1; }
  r="$(_policy_install_root "$interp")" || { echo "policy-render: interpreter $interp does not resolve to an executable" >&2; return 1; }
  found+=("$r")
  # keep the first of equal roots and drop one inside another (a joined node's $FH/uv holds both
  # the tool and its python)
  for path in "${found[@]}"; do
    for r in "${found[@]}"; do
      [ "$r" = "$path" ] || [[ "$path" != "$r"/* ]] || continue 2
    done
    for r in ${kept[@]+"${kept[@]}"}; do [ "$r" != "$path" ] || continue 2; done
    kept+=("$path")
  done
  printf '%s\n' "${kept[@]}"
}

policy_render() {
  local tpl="$1" out="$2" home cur new r rr
  shift 2
  home="$(cd "$HOME" 2>/dev/null && pwd -P)" || home="$HOME"
  for r in "$@"; do
    [[ "$r" == /* ]] && [ -d "$r" ] && rr="$(cd "$r" && pwd -P)" ||
      { echo "policy-render: root '$r' is not an absolute existing directory" >&2; return 1; }
    case "$home/" in "${rr%/}/"*) echo "policy-render: root '$r' is \$HOME or above it" >&2; return 1 ;; esac
  done
  # the template's own value: exactly one single-line allow_read inside [filesystem], a string array
  cur="$(awk '/^[[:space:]]*\[/ { t = $0; sub(/[[:space:]]*(#.*)?$/, "", t) }
              t == "[filesystem]" && /^[[:space:]]*allow_read[[:space:]]*=/ { n++; v = $0 }
              END { if (n != 1) exit 1; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*$/, "", v); print v }' "$tpl")" &&
    new="$(jq -ce --args 'if type == "array" and all(.[]; type == "string") then reduce $ARGS.positional[] as $p (.; if IN(.[]; $p) then . else . + [$p] end) else error end' \
             "$@" <<<"$cur" 2>/dev/null)" ||
    { echo "policy-render: $tpl has no single-line string-array allow_read in [filesystem]" >&2; return 1; }
  # a JSON array of strings is a TOML array of basic strings (same escapes)
  NEW="$new" awk '/^[[:space:]]*\[/ { t = $0; sub(/[[:space:]]*(#.*)?$/, "", t) }
                  t == "[filesystem]" && /^[[:space:]]*allow_read[[:space:]]*=/ { print "allow_read = " ENVIRON["NEW"]; next }
                  { print }' "$tpl" >"$out.tmp" && mv -f "$out.tmp" "$out"
}

policy_tamperguard() {
  local wt="$1" policy="$2" range="$3"
  rm -f "$wt/.factory-run/tamperguard.json" "$wt/.factory-run/tamperguard.err" "$wt/.factory-run/tamperguard.rc"
  (cd "$wt" && vetto --profile strict --policy "$policy" --tui none -- \
     bash -c 'tamperguard --range "$1" --json >"$2" 2>"$3"; echo "$?" >"$4"' tamperguard "$range" \
     .factory-run/tamperguard.json .factory-run/tamperguard.err .factory-run/tamperguard.rc) || true
}
