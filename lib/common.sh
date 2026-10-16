#!/usr/bin/env bash
# Shared helpers. Sourced by agentcage; do not run directly.

# All messages go to stderr, so functions whose stdout is captured stay clean.
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

dry() { [ "$DRY_RUN" = 1 ]; }
interactive() { [ -t 0 ]; }

# In dry-run mode state-changing commands are printed, not executed.
run() {
  if dry; then
    printf '\033[1;33m[dry-run]\033[0m %s\n' "$*" >&2
  else
    "$@"
  fi
}

# Like run, but through sudo when the pool is root-owned (libvirt backend).
prun() {
  if [ "$POOL_ROOT" = 1 ]; then run sudo "$@"; else run "$@"; fi
}

need() { command -v "$1" >/dev/null || die "$1 is required${2:+ ($2)}"; }
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
