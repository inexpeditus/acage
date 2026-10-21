#!/usr/bin/env bash
# Shared helpers. Sourced by agentcage; do not run directly.

# All messages go to stderr, so functions whose stdout is captured stay clean.
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

dry() { [ "$DRY_RUN" = 1 ]; }
interactive() { [ -t 0 ]; }

# In dry-run mode state-changing commands are printed, not executed. With
# --verbose (VERBOSE=1) they are printed and then executed, so you can see
# exactly what acage does while installing or creating a VM.
run() {
  if dry; then
    printf '\033[1;33m[dry-run]\033[0m %s\n' "$*" >&2
  else
    [ "${VERBOSE:-0}" = 1 ] && printf '\033[1;36m[run]\033[0m %s\n' "$*" >&2
    "$@"
  fi
}

# Like run, but through sudo when the pool is root-owned (libvirt backend).
prun() {
  if [ "$POOL_ROOT" = 1 ]; then run sudo "$@"; else run "$@"; fi
}

need() { command -v "$1" >/dev/null || die "$1 is required${2:+ ($2)}"; }

# Host tool checks are collected so every missing one is reported at once, with
# an install hint, instead of failing a command at a time. want() records a
# missing tool (deduplicated); report_missing() prints them all and exits.
MISSING_DEPS=()
want() {
  command -v "$1" >/dev/null 2>&1 && return 0
  case " ${MISSING_DEPS[*]} " in *" $1 "*) ;; *) MISSING_DEPS+=("$1") ;; esac
}

# Package that provides CMD on package manager MGR (apt or pacman); CMD itself
# when the names match or the manager is unknown.
dep_pkg() {
  case "$1" in
    qemu-img)       [ "$2" = apt ] && echo qemu-utils || echo qemu-img ;;
    qemu-system-*)  [ "$2" = apt ] && echo qemu-system-x86 || echo qemu-base ;;
    xorriso)        [ "$2" = apt ] && echo xorriso || echo libisoburn ;;
    virsh)          [ "$2" = apt ] && echo libvirt-daemon-system || echo libvirt ;;
    gpg)            echo gnupg ;;
    ssh|ssh-keygen) [ "$2" = apt ] && echo openssh-client || echo openssh ;;
    *)              echo "$1" ;;
  esac
}

# If want() found anything missing, list it all with one install command.
report_missing() {
  [ ${#MISSING_DEPS[@]} -eq 0 ] && return 0
  local mgr="" cmd pkgs="" seen=" " p
  command -v apt-get >/dev/null 2>&1 && mgr=apt || { command -v pacman >/dev/null 2>&1 && mgr=pacman; } || true
  for cmd in "${MISSING_DEPS[@]}"; do
    p=$(dep_pkg "$cmd" "$mgr")
    case "$seen" in *" $p "*) ;; *) pkgs+="$p "; seen+="$p " ;; esac
  done
  warn "missing host tools: ${MISSING_DEPS[*]}"
  case "$mgr" in
    apt)    die "install them with: sudo apt install ${pkgs% }" ;;
    pacman) die "install them with: sudo pacman -S ${pkgs% }" ;;
    *)      die "install the packages that provide them, then run acage again" ;;
  esac
}

is_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_yes() { case "$1" in [yY]*) return 0 ;; *) return 1 ;; esac; }

sha512_of() { sha512sum "$1" | awk '{print $1}'; }

# ask VAR "Prompt" default -> prints the prompt with [default], empty input keeps it
ask() {
  local __var=$1 prompt=$2 def=${3:-} reply=""
  read -rp "$prompt${def:+ [$def]}: " reply || true
  printf -v "$__var" '%s' "${reply:-$def}"
}

# yesno "Prompt" default(y|n)  -> returns 0 for yes; no input means the default
yesno() {
  local prompt=$1 def=${2:-y} reply="" hint="[Y/n]"
  [ "$def" = n ] && hint="[y/N]"
  read -rp "$prompt $hint " reply || true
  is_yes "${reply:-$def}"
}

# ask_password VAR "Prompt" -> asks twice (hidden) and stores a SHA-512 crypt
# hash in VAR; the plain password never leaves this function.
ask_password() {
  local __var=$1 prompt=$2 pw pw2
  need openssl "to hash the password"
  while :; do
    read -rsp "$prompt: " pw; echo >&2
    read -rsp "Again: " pw2; echo >&2
    [ "$pw" = "$pw2" ] || { echo "Passwords differ; try again." >&2; continue; }
    [ -n "$pw" ] || { echo "Empty password; try again." >&2; continue; }
    break
  done
  printf -v "$__var" '%s' "$(printf '%s' "$pw" | openssl passwd -6 -stdin)"
  pw=""; pw2=""
}
