#!/usr/bin/env bash
# probe — what is this box? The join wizard's step 1 (SPEC-v0.2 "Join wizard"), as a reader.
#
#   probe.sh [--json] [--clone DIR]
#
# Reads, never writes. Prints one JSON object (--json) or a short report:
#   os            linux | wsl2 | macos, or null when unsupported (os_note says why: WSL1, other)
#   cpu           nproc (Linux) / sysctl hw.ncpu (macOS)
#   ram_total_kb, ram_free_kb, ram_gb, free_ram_gb
#                 /proc/meminfo MemTotal / MemAvailable; macOS sysctl hw.memsize and vm_stat
#                 (free + inactive + speculative pages). GB here is GiB (1024^3 bytes).
#   disk_free_gb  df -Pk on the clone
#   sandbox       the backend fleet needs (ADR-0003): bwrap on Linux and WSL2, run with a read-only
#                 bind of / (a bare `bwrap --unshare-all true` fails on every box, records/TB0.md
#                 gotcha 8); sandbox-exec on macOS. present, works, and the install line when absent.
#   adapters      claude, codex, agy, opencode: installed, version, authenticated. Only claude-code
#                 has a measured auth check (`claude auth status --json` → .loggedIn); the others
#                 report authenticated=null (not measured) and count as not authenticated.
#   skip_permissions
#                 every readable shell rc and Claude Code settings file that sets
#                 --dangerously-skip-permissions (or the same thing, bypassPermissions)
#   vetto_masks   paths vetto 0.6.5 masks in $HOME (src/sandbox/linux/vfs_overlays.rs) that are
#                 symlinks: vetto then fails closed with exit 125 (measured on ~/.aws, records/TB1.md)
#   uid           the user id the wizard runs as (root is refused by the wizard)
#
# FACTORY_PROBE_ROOT (tests only) is prefixed to every /proc and /etc path read here.
# Exit 0 always when the probe ran; 1 on bad usage.
set -euo pipefail
PROG=probe
# shellcheck source=factory/bin/lib/common.sh
. "$(dirname "$0")/common.sh"

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

json=0 clone=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1 ;;
    --clone) clone="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) warn "unknown argument: $1"; usage ;;
  esac
  shift
done
need jq
R="${FACTORY_PROBE_ROOT:-}"
clone="${clone:-$PWD}"

has() { command -v "$1" >/dev/null 2>&1; }
semver_of() { grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true; }

# ---- OS ----------------------------------------------------------------------------------------
kernel="$(uname -s)" arch="$(uname -m)" os="" os_note="" distro=""
case "$kernel" in
  Linux)
    pv="$(command cat "$R/proc/version" 2>/dev/null || true)"
    if grep -q 'microsoft-standard-WSL2\|WSL2' <<<"$pv"; then os=wsl2
    elif grep -qi microsoft <<<"$pv"; then os_note="WSL1: no namespaces, so no sandbox; convert the distro with 'wsl --set-version <distro> 2'"
    else os=linux; fi
    # ID and ID_LIKE, read as data (os-release is not sourced).
    distro="$(sed -nE 's/^(ID|ID_LIKE)=["'"'"']?([^"'"'"']*)["'"'"']?$/\2/p' "$R/etc/os-release" 2>/dev/null | tr '\n' ' ' || true)" ;;
  Darwin) os=macos ;;
  *) os_note="unsupported OS '$kernel' (linux, wsl2 and macos are)" ;;
esac

# ---- CPU, RAM, disk ----------------------------------------------------------------------------
cpu=0 total_kb=0 free_kb=0
if [ "$kernel" = Darwin ]; then
  cpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 0)"
  total_kb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))
  free_kb="$(vm_stat 2>/dev/null | awk '
    /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) ps = $i }
    /^Pages (free|inactive|speculative):/ { gsub(/\./, "", $NF); n += $NF }
    END { printf "%d\n", (n * ps) / 1024 }')" || free_kb=0
else
  cpu="$(nproc 2>/dev/null || echo 0)"
  total_kb="$(awk '/^MemTotal:/ { print $2 }' "$R/proc/meminfo" 2>/dev/null || true)"
  free_kb="$(awk '/^MemAvailable:/ { print $2 }' "$R/proc/meminfo" 2>/dev/null || true)"
fi
[[ "$cpu" =~ ^[0-9]+$ ]] || cpu=0
[[ "$total_kb" =~ ^[0-9]+$ ]] || total_kb=0
[[ "$free_kb" =~ ^[0-9]+$ ]] || free_kb=0
disk_kb="$(df -Pk "$clone" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
[[ "$disk_kb" =~ ^[0-9]+$ ]] || disk_kb=0

# ---- Sandbox backend ---------------------------------------------------------------------------
sb_name="" sb_present=false sb_works=false sb_version="" sb_install=""
case "$os" in
  linux|wsl2)
    sb_name=bwrap
    case " $distro " in
      *" debian "*|*" ubuntu "*) sb_install="sudo apt-get install bubblewrap" ;;
      *" fedora "*|*" rhel "*|*" centos "*) sb_install="sudo dnf install bubblewrap" ;;
      *" arch "*) sb_install="sudo pacman -S bubblewrap" ;;
      *" suse "*|*" opensuse "*) sb_install="sudo zypper install bubblewrap" ;;
      *" alpine "*) sb_install="sudo apk add bubblewrap" ;;
      *) sb_install="install bubblewrap (bwrap) from your distribution's packages" ;;
    esac
    if has bwrap; then
      sb_present=true
      sb_version="$(bwrap --version 2>/dev/null | semver_of)"
      if bwrap --unshare-all --ro-bind / / --dev /dev --proc /proc true >/dev/null 2>&1; then sb_works=true; fi
    fi ;;
  macos)
    sb_name=sandbox-exec
    sb_install="sandbox-exec ships with macOS at /usr/bin/sandbox-exec; restore it (it cannot be installed separately)"
    if has sandbox-exec; then
      sb_present=true
      if sandbox-exec -p '(version 1)(allow default)' /usr/bin/true >/dev/null 2>&1; then sb_works=true; fi
    fi ;;
esac

# ---- Adapters ----------------------------------------------------------------------------------
adapters='[]'
for pair in claude-code:claude codex:codex agy:agy opencode:opencode; do
  name="${pair%%:*}" cli="${pair#*:}" installed=false version="" auth=null check=null
  if has "$cli"; then
    installed=true
    version="$("$cli" --version 2>/dev/null | semver_of)"
    if [ "$name" = claude-code ]; then
      check='"claude auth status --json"'
      auth="$(claude auth status --json 2>/dev/null | jq -c 'if .loggedIn == true then true else false end' 2>/dev/null)" || auth=false
      [ -n "$auth" ] || auth=false
    fi
  fi
  adapters="$(jq -c --arg n "$name" --arg c "$cli" --argjson i "$installed" --arg v "$version" \
                    --argjson a "$auth" --argjson chk "$check" \
    '. + [{name: $n, cli: $c, installed: $i, version: (if $v == "" then null else $v end),
           authenticated: $a, auth_check: $chk}]' <<<"$adapters")"
done

# ---- --dangerously-skip-permissions in shell rc and Claude settings ----------------------------
skips='[]'
add_skip() { skips="$(jq -c --arg f "$1" --arg k "$2" --arg m "$3" '. + [{file: $f, kind: $k, match: $m}]' <<<"$skips")"; }
RC_PAT='dangerously-skip-permissions|permission-mode[ =]+["'"'"']?bypassPermissions'
rc_files=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.bash_aliases" "$HOME/.profile"
          "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.zlogin" "$HOME/.zsh_aliases" "$HOME/.aliases"
          "$HOME/.config/fish/config.fish" "$R/etc/bash.bashrc" "$R/etc/bashrc" "$R/etc/profile"
          "$R/etc/zsh/zshrc" "$R/etc/zshrc" "$R/etc/zsh/zshenv")
for d in "$HOME/.config/fish/conf.d" "$HOME/.bashrc.d" "$HOME/.zshrc.d" "$HOME/.oh-my-zsh/custom" "$R/etc/profile.d"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do [ -f "$f" ] && rc_files+=("$f"); done
done
for f in "${rc_files[@]}"; do
  [ -r "$f" ] && [ -f "$f" ] || continue
  # Comment lines do not count; a live alias, function or export does.
  if grep -vE '^[[:space:]]*#' "$f" | grep -qE "$RC_PAT"; then add_skip "$f" shell-rc "$RC_PAT"; fi
done
settings=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.local.json"
          "$clone/.claude/settings.json" "$clone/.claude/settings.local.json"
          "$R/etc/claude-code/managed-settings.json" "$R/Library/Application Support/ClaudeCode/managed-settings.json")
for f in "${settings[@]}"; do
  [ -r "$f" ] && [ -f "$f" ] || continue
  if grep -q 'dangerously-skip-permissions' "$f"; then add_skip "$f" claude-settings dangerously-skip-permissions
  elif jq -e '.permissions.defaultMode == "bypassPermissions"' "$f" >/dev/null 2>&1; then
    add_skip "$f" claude-settings 'permissions.defaultMode = bypassPermissions'
  fi
done

# ---- Paths vetto masks that are symlinks -------------------------------------------------------
masks='[]'
for p in .ssh .aws .gnupg .env .npmrc .docker/config.json .config/gh/hosts.yml; do
  [ -L "$HOME/$p" ] || continue
  kind="file"; [ -d "$HOME/$p" ] && kind="directory"
  masks="$(jq -c --arg p "$HOME/$p" --arg k "$kind" '. + [{path: $p, target_kind: $k}]' <<<"$masks")"
done

out="$(jq -cn --arg os "$os" --arg note "$os_note" --arg kernel "$kernel" --arg arch "$arch" --arg distro "$distro" \
  --argjson cpu "$cpu" --argjson tk "$total_kb" --argjson fk "$free_kb" --argjson dk "$disk_kb" \
  --arg sbn "$sb_name" --argjson sbp "$sb_present" --argjson sbw "$sb_works" --arg sbv "$sb_version" \
  --arg sbi "$sb_install" --argjson adapters "$adapters" --argjson skips "$skips" --argjson masks "$masks" \
  --argjson uid "$(id -u)" --arg clone "$clone" '
  def gb: . / 1048576 * 100 | round / 100;
  {os: (if $os == "" then null else $os end), os_note: (if $note == "" then null else $note end),
   kernel: $kernel, arch: $arch, distro: ($distro | ltrimstr(" ") | rtrimstr(" ")),
   cpu: $cpu, ram_total_kb: $tk, ram_free_kb: $fk, ram_gb: ($tk | gb), free_ram_gb: ($fk | gb),
   clone: $clone, disk_free_gb: ($dk | gb),
   sandbox: {backend: (if $sbn == "" then null else $sbn end), present: $sbp, works: $sbw,
             version: (if $sbv == "" then null else $sbv end), install_line: (if $sbi == "" then null else $sbi end)},
   adapters: $adapters, skip_permissions: $skips, vetto_masks: $masks, uid: $uid}')"

if [ "$json" = 1 ]; then printf '%s\n' "$out"; else
  jq -r '"os \(.os // "unsupported")\(if .os_note then " (\(.os_note))" else "" end), \(.kernel) \(.arch)",
         "cpu \(.cpu), RAM \(.ram_gb) GB total, \(.free_ram_gb) GB free, disk \(.disk_free_gb) GB free",
         "sandbox \(.sandbox.backend // "none"): present \(.sandbox.present), works \(.sandbox.works)",
         (.adapters[] | "adapter \(.name): \(if .installed then "\(.version // "?") authenticated \(.authenticated // "not measured")" else "absent" end)"),
         (.skip_permissions[] | "skip-permissions in \(.file) (\(.kind))"),
         (.vetto_masks[] | "vetto masks \(.path), a symlink to a \(.target_kind)")' <<<"$out"
fi
