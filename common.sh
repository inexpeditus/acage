#!/usr/bin/env bash
# Shared helpers for this standalone folder. Private copy of the relevant bits of
# ../lib/common.sh, trimmed down. Sourced by create.sh; do not run directly.

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# In dry-run mode state-changing commands are printed, not executed.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '\033[1;33m[dry-run]\033[0m %s\n' "$*"
  else
    "$@"
  fi
}

dry() { [ "$DRY_RUN" = 1 ]; }

# Create POOL_DIR if needed, owned so only root (i.e. only via sudo/libvirt) can
# write into it, matching the main repo's storage-pool setup.
ensure_pool_dir() {
  run sudo mkdir -p "$POOL_DIR"
  run sudo chown root:root "$POOL_DIR"
  run sudo chmod 711 "$POOL_DIR"
}

# ask VAR "Prompt" default -> prints the prompt with [default], empty input keeps it
ask() {
  local __var=$1 prompt=$2 def=${3:-} reply
  read -rp "$prompt${def:+ [$def]}: " reply
  printf -v "$__var" '%s' "${reply:-$def}"
}

# yesno "Prompt" default(y|n)  -> returns 0 for yes
yesno() {
  local prompt=$1 def=${2:-y} reply hint="[Y/n]"
  [ "$def" = n ] && hint="[y/N]"
  read -rp "$prompt $hint " reply
  reply=${reply:-$def}
  [[ "${reply,,}" == y* ]]
}

# ask_password VAR "Prompt" -> asks twice (hidden) and stores a SHA-512 crypt
# hash in VAR; the plain password never leaves this function.
ask_password() {
  local __var=$1 prompt=$2 pw pw2
  command -v openssl >/dev/null || die "openssl is needed to hash the password"
  while :; do
    read -rsp "$prompt: " pw; echo
    read -rsp "Again: " pw2; echo
    [ "$pw" = "$pw2" ] || { echo "Passwords differ; try again." >&2; continue; }
    [ -n "$pw" ] || { echo "Empty password; try again." >&2; continue; }
    break
  done
  printf -v "$__var" '%s' "$(printf '%s' "$pw" | openssl passwd -6 -stdin)"
  pw=""; pw2=""
}

virsh_() {
  case "$1" in
    dominfo|domstate|domblklist|domifaddr|dumpxml|pool-info|pool-list)
      if dry; then
        command -v virsh >/dev/null && virsh -c "$URI" "$@" 2>/dev/null
      else
        sudo virsh -c "$URI" "$@"
      fi ;;
    *) run sudo virsh -c "$URI" "$@" ;;
  esac
}
