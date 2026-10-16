#!/usr/bin/env bash
# Shared setup and assertions for tests/run. Sourced, not run.

# Python modules installed in the real home (pip --user) stay visible after
# HOME is pointed at a temporary folder.
export PYTHONUSERBASE=${PYTHONUSERBASE:-$HOME/.local}

setup() {
  TMP=$(mktemp -d)
  export HOME=$TMP/home XDG_CONFIG_HOME=$TMP/home/.config XDG_CACHE_HOME=$TMP/home/.cache XDG_DATA_HOME=$TMP/home/.local/share
  mkdir -p "$HOME"
  POOL=$TMP/pool
  STUBS=$TMP/bin
  mkdir -p "$STUBS"
  # Stand-ins: no VM ever "exists", sudo is never used for real, and the
  # QEMU tools succeed without doing anything.
  stub virsh 'exit 1'
  stub sudo 'exit 1'
  stub qemu-img 'exit 0'
  stub qemu-system-x86_64 'exit 0'
  stub qemu-system-aarch64 'exit 0'
  stub virtiofsd 'exit 0'
  export PATH="$STUBS:$PATH"
  cd "$TMP" || exit 1
}

teardown() {
  cd "$ROOT" || exit 1
  rm -rf "$TMP"
}

# stub NAME SCRIPT -> an executable NAME in front of PATH running SCRIPT
stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# acage_run ARGS... -> runs acage without a terminal; sets OUT (colours
# stripped) and RC.
acage_run() {
  RC=0
  OUT=$("$ROOT/acage" "$@" </dev/null 2>&1) || RC=$?
  OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')
}

# acage_tty INPUT ARGS... -> like acage_run, but in a pseudo-terminal fed with
# INPUT (one answer per line), so the interactive questions are asked.
acage_tty() {
  local input=$1 cmd q; shift
  cmd=$(printf '%q ' "$ROOT/acage" "$@")
  RC=0
  OUT=$(printf '%b' "$input" | script -qec "$cmd" /dev/null 2>&1) || RC=$?
  OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
}

assert_rc() { [ "$RC" = "$1" ] || fail "exit status $RC, expected $1. Output:
$OUT"; }
assert_out() { [[ "$OUT" == *"$1"* ]] || fail "expected '$1' in output:
$OUT"; }
assert_not_out() { [[ "$OUT" != *"$1"* ]] || fail "did not expect '$1' in output:
$OUT"; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }

# assert_fails TEXT CMD... -> CMD must fail and mention TEXT
assert_fails() {
  local want=$1 out; shift
  if out=$( ("$@") 2>&1 ); then fail "expected '$*' to fail"; fi
  [[ "$out" == *"$want"* ]] || fail "expected '$want' in: $out"
}

# load_libs [BACKEND] -> sources lib/ with the defaults acage would set.
load_libs() {
  VM=box GUEST_USER=roy GUEST_DOAS=1 GUEST_PW_HASH="" HARNESS=pi SHARE_DIR="" SHARE_CREATED=0 ALLOW_LAN=0 WHO=""
  RAM_MB=2048 VCPUS=2 DISK_GB=10 SSH_PUBKEY="" DRY_RUN=0 ASSUME_YES=0
  BACKEND=${1:-libvirt} DATA_DIR=$ROOT/share POOL_DIR=$POOL
  local f
  for f in common pool alpine harness share cloudinit image provision push "backend-$BACKEND"; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$f.sh"
  done
  backend_init
}

# have CMD -> true if CMD exists on the real system (outside the stubs)
have() { PATH=${PATH#"$STUBS:"} command -v "$1" >/dev/null 2>&1; }

have_pyyaml() { python3 -c 'import yaml' 2>/dev/null; }
