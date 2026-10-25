#!/usr/bin/env bash
# T12: the bwrap shim (factory/bin/lib/bwrap-shim, ADR-0006). Offline: the four argv shapes
# @adlc/fleet 1.12.0 builds (tests/fixtures/bwrap-shim/*.json, captured from the real modules by
# capture.sh in that directory), three host layouts under FACTORY_SHIM_ROOT (merged usr, a classic
# /bin directory, a box with none of the paths) and a recording stand-in for the real bwrap.
# Acceptance 1 (I12 on every shape and layout), 2 (idempotence), 3 (the version gate); plus the
# exact insertions, the real-bwrap lookup, and the argv the shim leaves alone.
set -euo pipefail
# shellcheck source=tests/fakes/lib.sh
. "$(dirname "$0")/fakes/lib.sh"
SHIM="$BIN/lib/bwrap-shim"
FIX="$REPO_ROOT/tests/fixtures/bwrap-shim"
SHAPES="canary repo-command bounded-model host-read"

# The I12 reading of an argv, independent of the shim's own parser: every bwrap 0.9.0 option with its
# arity (`bwrap --help`), parsed up to `--`; then the write mounts, network flags and namespace flags.
JQ_DEFS='
  def arity: {
    "--unshare-all":0, "--share-net":0, "--unshare-user":0, "--unshare-user-try":0, "--unshare-ipc":0,
    "--unshare-pid":0, "--unshare-net":0, "--unshare-uts":0, "--unshare-cgroup":0, "--unshare-cgroup-try":0,
    "--disable-userns":0, "--assert-userns-disabled":0, "--clearenv":0, "--new-session":0,
    "--die-with-parent":0, "--as-pid-1":0,
    "--argv0":1, "--userns":1, "--userns2":1, "--pidns":1, "--uid":1, "--gid":1, "--hostname":1, "--chdir":1,
    "--unsetenv":1, "--lock-file":1, "--sync-fd":1, "--remount-ro":1, "--exec-label":1, "--file-label":1,
    "--proc":1, "--dev":1, "--tmpfs":1, "--mqueue":1, "--dir":1, "--seccomp":1, "--add-seccomp-fd":1,
    "--block-fd":1, "--userns-block-fd":1, "--info-fd":1, "--json-status-fd":1, "--cap-add":1,
    "--cap-drop":1, "--perms":1, "--size":1,
    "--setenv":2, "--bind":2, "--bind-try":2, "--dev-bind":2, "--dev-bind-try":2, "--ro-bind":2,
    "--ro-bind-try":2, "--bind-fd":2, "--ro-bind-fd":2, "--file":2, "--bind-data":2, "--ro-bind-data":2,
    "--symlink":2, "--chmod":2};
  def ops: . as $a | ($a | index("--") // length) as $end
    | [foreach range(0; $end) as $i ({skip: 0, op: null};
        if .skip > 0 then .skip -= 1 | .op = null
        else (arity[$a[$i]] // error("unknown option \($a[$i])")) as $k | .skip = $k | .op = $a[$i:$i + $k + 1] end;
        .op) | select(. != null)];
  def writes: [ops[] | select(.[0] | IN("--bind", "--bind-try", "--dev-bind", "--dev-bind-try", "--bind-fd",
                 "--bind-data", "--file", "--tmpfs", "--dir", "--dev", "--mqueue", "--proc"))] | sort;
  def net: [ops[] | select(.[0] | IN("--unshare-net", "--share-net", "--unshare-all"))] | sort;
  def ns: [ops[] | select(.[0] | test("^--(unshare-|share-net$|userns|pidns|disable-userns|assert-userns-disabled)"))] | sort;
'

roots() {  # three host layouts under $WORLD/root-*
  local r
  r="$WORLD/root-merged"
  mkdir -p "$r/usr/bin" "$r/usr/sbin" "$r/usr/lib" "$r/usr/lib64" "$r/etc/ssl/certs" "$r/run"
  ln -s usr/bin "$r/bin"; ln -s usr/sbin "$r/sbin"; ln -s usr/lib "$r/lib"; ln -s usr/lib64 "$r/lib64"
  echo 'nameserver 10.0.0.1' >"$r/run/resolv.conf"; ln -s ../run/resolv.conf "$r/etc/resolv.conf"
  echo '127.0.0.1 localhost' >"$r/etc/hosts"
  r="$WORLD/root-classic"
  mkdir -p "$r/usr/bin" "$r/bin" "$r/sbin" "$r/lib" "$r/etc/ssl"
  echo 'nameserver 10.0.0.1' >"$r/etc/resolv.conf"; echo '127.0.0.1 localhost' >"$r/etc/hosts"
  mkdir -p "$WORLD/root-bare"
}
setup() {
  WORLD="$(mktemp -d "${TMPDIR:-/tmp}/bwrap-shim.XXXXXX")"
  # shellcheck disable=SC2064  # expand now: WORLD is per case
  trap "rm -rf '$WORLD'" EXIT
  roots
  # the stand-in for the real bwrap: records its argv, prints what it was asked to run
  mkdir -p "$WORLD/real" "$WORLD/shim"
  printf '#!/usr/bin/env bash\nfor a in "$@"; do jq -n --arg a "$a" '"'"'$a'"'"'; done | jq -sc . >>"%s/real.log"\necho real-bwrap\n' \
    "$WORLD" >"$WORLD/real/bwrap"
  chmod +x "$WORLD/real/bwrap"
  ln -s "$SHIM" "$WORLD/shim/bwrap"
  echo 1.12.0 >"$WORLD/shim/fleet-pin"
  # the tools the shim itself needs, without any bwrap
  mkdir -p "$WORLD/sys"
  local t
  for t in bash env jq readlink dirname basename cat; do ln -s "$(command -v "$t")" "$WORLD/sys/$t"; done
  : >"$WORLD/real.log"
}
args_of() { jq -c '.[1:]' "$FIX/$1.json"; }          # fleet's argv without argv[0]
shim_argv() {  # shim_argv <layout> <pin> <json args>: the shim's output, one JSON array
  local -a a=()
  while IFS= read -r -d '' x; do a+=("$x"); done < <(jq -j '.[] | . + "\u0000"' <<<"$3")
  FACTORY_SHIM_ROOT="$WORLD/root-$1" "$SHIM" argv "$2" ${a[@]+"${a[@]}"}
}
i12() {  # i12 <in> <out>: the I12 verdict, "ok" or the first broken clause
  jq -rn --argjson in "$1" --argjson out "$2" "$JQ_DEFS"'
    (($out | length) - ($in | length)) as $n
    | ($out[0:$n]) as $ins
    | if $n < 0 or $out[$n:] != $in then "fleet argv dropped or moved"
      elif ($n % 3) != 0 or ($ins | ops | map(length) | add // 0) != $n then "insertion is not whole triples"
      elif any($ins | ops[]; .[0] | IN("--ro-bind", "--symlink") | not) then "an insertion other than --ro-bind/--symlink"
      elif any($ins | ops[]; .[0] == "--ro-bind" and .[1] != .[2]) then "a --ro-bind that moves a path"
      elif ($in | writes) != ($out | writes) then "write mounts differ"
      elif ($in | net) != ($out | net) then "network flags differ"
      elif ($in | ns) != ($out | ns) then "namespace flags differ"
      else "ok" end'
}
inserted() { jq -c --argjson in "$1" '.[0:(length - ($in | length))]' <<<"$2"; }

# ---------------------------------------------------------------------------------------------
case_fixtures() {
  setup
  local s
  for s in $SHAPES; do
    check "fixture $s: argv[0] bwrap, parses as bwrap 0.9.0 options up to --" \
      eq "$(jq -r "$JQ_DEFS"'"\(.[0]) \(.[1:] | ops | length > 0) \(index("--") != null)"' "$FIX/$s.json")" "bwrap true true"
  done
  check "the capture command is recorded beside them" grep -q 'node --input-type=module -e' "$FIX/capture.sh"
  check "  canary: the shape bin/fleet.mjs dispatchCanary runs" \
    eq "$(jq -c '.[-3:]' "$FIX/canary.json")" '["/bin/sh","-c","echo __fleet_canary_ok__"]'
  check "  host-read: --ro-bind / /" eq "$(jq -c '.[1:] | [index("--ro-bind"), .[index("--ro-bind") + 1]]' "$FIX/host-read.json")" '[3,"/"]'
  check "  bounded-model: --unshare-net and fleet's SYSTEM_ROOTS bound" \
    eq "$(jq -c '[index("--unshare-net") != null, ([.[] | select(IN("/usr", "/lib", "/lib64", "/etc/ssl", "/etc/resolv.conf", "/etc/hosts"))] | length)]' "$FIX/bounded-model.json")" '[true,12]'
}

case_i12() {
  setup
  local s l in out v
  for l in merged classic bare; do
    for s in $SHAPES; do
      in="$(args_of "$s")"
      out="$(shim_argv "$l" 1.12.0 "$in")"
      v="$(i12 "$in" "$out")"
      check "I12 $s on a $l host: only --ro-bind/--symlink prepended; writes, net, namespaces equal" eq "$v" ok
    done
  done
  # the checker itself catches each broken clause
  in="$(args_of canary)"
  check "  checker: a dropped fleet argument" eq "$(i12 "$in" "$(jq -c 'del(.[0])' <<<"$in")")" "fleet argv dropped or moved"
  check "  checker: a writable bind" eq "$(i12 "$in" "$(jq -c '["--bind", "/usr", "/usr"] + .' <<<"$in")")" "an insertion other than --ro-bind/--symlink"
  check "  checker: a network flag" eq "$(i12 "$in" "$(jq -c '["--share-net"] + .' <<<"$in")")" "insertion is not whole triples"
  check "  checker: --ro-bind that moves a path" eq "$(i12 "$in" "$(jq -c '["--ro-bind", "/", "/usr"] + .' <<<"$in")")" "a --ro-bind that moves a path"
  check "  checker: a reordered fleet argv" eq "$(i12 "$in" "$(jq -c '.[1:2] + .[0:1] + .[2:]' <<<"$in")")" "fleet argv dropped or moved"
}

case_inserts() {
  setup
  check "canary, merged usr: /usr bound, /bin /sbin /lib /lib64 as symlinks, the /etc files bound" \
    eq "$(inserted "$(args_of canary)" "$(shim_argv merged 1.12.0 "$(args_of canary)")")" \
       '["--ro-bind","/usr","/usr","--symlink","usr/bin","/bin","--symlink","usr/sbin","/sbin","--symlink","usr/lib","/lib","--symlink","usr/lib64","/lib64","--ro-bind","/etc/ssl","/etc/ssl","--ro-bind","/etc/resolv.conf","/etc/resolv.conf","--ro-bind","/etc/hosts","/etc/hosts"]'
  check "  the symlinked /etc/resolv.conf is bound through, never re-made as a symlink" \
    eq "$(shim_argv merged 1.12.0 "$(args_of canary)" | jq -c '[index("/etc/resolv.conf"), .[index("/etc/resolv.conf") - 1]]')" '[19,"--ro-bind"]'
  check "repo-command, merged usr: the same nine paths" \
    eq "$(inserted "$(args_of repo-command)" "$(shim_argv merged 1.12.0 "$(args_of repo-command)")" | jq -c '[.[range(2; length; 3)]]')" \
       '["/usr","/bin","/sbin","/lib","/lib64","/etc/ssl","/etc/resolv.conf","/etc/hosts"]'
  check "bounded-model, merged usr: only /bin and /sbin (fleet already binds its SYSTEM_ROOTS)" \
    eq "$(inserted "$(args_of bounded-model)" "$(shim_argv merged 1.12.0 "$(args_of bounded-model)")")" \
       '["--symlink","usr/bin","/bin","--symlink","usr/sbin","/sbin"]'
  check "host-read: nothing (it binds / already)" \
    eq "$(shim_argv merged 1.12.0 "$(args_of host-read)")" "$(args_of host-read)"
  check "canary, classic /bin directory: /usr, /lib and the /etc files bound; /bin /sbin are not system roots" \
    eq "$(inserted "$(args_of canary)" "$(shim_argv classic 1.12.0 "$(args_of canary)")" | jq -c '[.[range(2; length; 3)]]')" \
       '["/usr","/lib","/etc/ssl","/etc/resolv.conf","/etc/hosts"]'
  check "canary, a box with none of the paths: nothing" eq "$(shim_argv bare 1.12.0 "$(args_of canary)")" "$(args_of canary)"
  rm "$WORLD/root-merged/run/resolv.conf"
  check "a dangling /etc/resolv.conf is skipped" \
    eq "$(shim_argv merged 1.12.0 "$(args_of canary)" | jq 'index("/etc/resolv.conf")')" null
  check "a path fleet mounts itself is skipped (trailing slash and doubled slashes are the same path)" \
    eq "$(shim_argv merged 1.12.0 '["--tmpfs", "//etc//ssl/", "--", "true"]' | jq -c '[.[] | select(test("etc"))]')" \
       '["/etc/hosts","/etc/hosts","//etc//ssl/"]'
  check "  so is everything when fleet binds /" eq "$(shim_argv merged 1.12.0 '["--bind", "/", "/", "true"]')" '["--bind","/","/","true"]'
  check "an argv with no -- (the command is the first non-option) still gets the binds" \
    eq "$(shim_argv merged 1.12.0 '["--unshare-net", "/bin/sh", "-c", "--tmpfs /usr"]' | jq -c '.[0:3]')" '["--ro-bind","/usr","/usr"]'
}

case_idempotent() {
  setup
  local s l once twice
  for l in merged classic bare; do
    for s in $SHAPES; do
      once="$(shim_argv "$l" 1.12.0 "$(args_of "$s")")"
      twice="$(shim_argv "$l" 1.12.0 "$once")"
      check "idempotent: $s on a $l host, shim(shim(argv)) = shim(argv)" eq "$twice" "$once"
    done
  done
}

case_version_gate() {
  setup
  local s p
  for p in 1.12.1 1.13.0 1.11.9 2.0.0 1.12.0-rc.1 v1.12.0 "1.12.0 " ""; do
    for s in $SHAPES; do
      check "pin '$p' on $s: argv unchanged" eq "$(shim_argv merged "$p" "$(args_of "$s")")" "$(args_of "$s")"
    done
  done
  check "pin 1.12.0 on canary: changed" test "$(shim_argv merged 1.12.0 "$(args_of canary)")" != "$(args_of canary)"
}

run_as_bwrap() {  # run_as_bwrap <PATH> <fixture>: the shim as fleet calls it; sets RC, OUT, ERR, GOT (the real bwrap's argv)
  local -a a=()
  while IFS= read -r -d '' x; do a+=("$x"); done < <(jq -j '.[1:][] | . + "\u0000"' "$FIX/$2.json")
  : >"$WORLD/real.log"
  RC=0
  OUT="$(PATH="$1" FACTORY_SHIM_ROOT="$WORLD/root-merged" bwrap "${a[@]}" 2>"$WORLD/err")" || RC=$?
  ERR="$(command cat "$WORLD/err")"
  GOT="$(command cat "$WORLD/real.log")"
}

case_exec() {
  setup
  local base="$WORLD/sys" want
  want="$(shim_argv merged 1.12.0 "$(args_of canary)")"
  run_as_bwrap "$WORLD/shim:$WORLD/real:$base" canary
  check "as \`bwrap\` with pin 1.12.0: execs the real bwrap with the shim's argv" eq "$RC $OUT $GOT" "0 real-bwrap $want"
  echo 1.13.0 >"$WORLD/shim/fleet-pin"
  run_as_bwrap "$WORLD/shim:$WORLD/real:$base" canary
  check "  pin 1.13.0 beside it: fleet's argv unchanged" eq "$GOT" "$(args_of canary)"
  rm "$WORLD/shim/fleet-pin"
  run_as_bwrap "$WORLD/shim:$WORLD/real:$base" canary
  check "  no pin file: fleet's argv unchanged" eq "$GOT" "$(args_of canary)"
  echo 1.12.0 >"$WORLD/shim/fleet-pin"
  # shim of shim: a second shim directory and the shim's own directory ahead of the real one
  mkdir -p "$WORLD/shim2"; ln -s "$SHIM" "$WORLD/shim2/bwrap"; echo 1.12.0 >"$WORLD/shim2/fleet-pin"
  run_as_bwrap "$WORLD/shim:$WORLD/shim2:$BIN/lib:relative/dir:$WORLD/real:$base" canary
  check "  another shim, its own directory and a relative entry ahead of the real bwrap: skipped, argv shimmed once" \
    eq "$RC $GOT" "0 $want"
  run_as_bwrap "$WORLD/shim:$WORLD/shim2:$base" canary
  check "  no real bwrap on PATH: exit 127, named" eq "$RC $ERR" "127 bwrap-shim: no real bwrap on PATH"
}

case_left_alone() {
  setup
  local a
  for a in '["--version"]' '["--help"]' '["--args", "3", "--", "true"]' '["--overlay-src", "/x", "--", "true"]' \
           '["--unshare-net", "--bind", "/tmp"]'; do
    check "left alone: $a" eq "$(shim_argv merged 1.12.0 "$a" 2>/dev/null)" "$(jq -c . <<<"$a")"
  done
  check "  an option bwrap 0.9.0 lacks is named on stderr" \
    eq "$(shim_argv merged 1.12.0 '["--overlay-src", "/x", "--", "true"]' 2>&1 >/dev/null)" \
       "bwrap-shim: unknown bwrap option --overlay-src; argv passed through unchanged"
  check "no argument: the binds alone (the real bwrap then prints its usage)" \
    eq "$(shim_argv merged 1.12.0 '[]' | jq length)" 24
}

case_probe() {
  setup
  local p
  p="$(PATH="$WORLD/real:$WORLD/sys" FACTORY_SHIM_ROOT="$WORLD/root-merged" "$SHIM" probe)"
  check "probe, merged usr: the real bwrap, merged_usr, ready" \
    eq "$(jq -c '[.fleet_pin, .bwrap, .merged_usr, .ready]' <<<"$p")" "[\"1.12.0\",\"$WORLD/real/bwrap\",true,true]"
  check "  each path with what the shim inserts" \
    eq "$(jq -c '[.paths[] | "\(.path):\(.host):\(.insert)\(if .target then ":" + .target else "" end)"]' <<<"$p")" \
       '["/usr:directory:ro-bind","/bin:symlink:symlink:usr/bin","/sbin:symlink:symlink:usr/sbin","/lib:symlink:symlink:usr/lib","/lib64:symlink:symlink:usr/lib64","/etc/ssl:directory:ro-bind","/etc/resolv.conf:symlink:ro-bind","/etc/hosts:file:ro-bind"]'
  p="$(PATH="$WORLD/real:$WORLD/sys" FACTORY_SHIM_ROOT="$WORLD/root-classic" "$SHIM" probe)"
  check "probe, classic /bin: not merged usr, still ready; /bin is not a system root" \
    eq "$(jq -c '[.merged_usr, .ready, (.paths[] | select(.path == "/bin") | .why)]' <<<"$p")" '[false,true,"not-a-system-root"]'
  p="$(PATH="$WORLD/shim:$WORLD/sys" FACTORY_SHIM_ROOT="$WORLD/root-bare" "$SHIM" probe)"
  check "probe, no real bwrap and no /usr: not ready" eq "$(jq -c '[.bwrap, .ready, .paths[0].why]' <<<"$p")" '[null,false,"absent"]'
}

cd "$REPO_ROOT"
for c in fixtures i12 inserts idempotent version-gate exec left-alone probe; do
  run_case "$c"
done
[ "$FAILED" = 0 ]
