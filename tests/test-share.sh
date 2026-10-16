#!/usr/bin/env bash
# Shared folder checks, warning and guest mount (lib/share.sh).

test_share_resolves_relative_and_symlinked_paths() {
  load_libs
  mkdir -p "$TMP/real/proj"
  ln -s "$TMP/real" "$TMP/link"
  SHARE_DIR=link/proj; share_resolve
  assert_eq "$SHARE_DIR" "$(cd "$TMP/real/proj" && pwd -P)"
  SHARE_DIR="$TMP/real/proj/"; share_resolve
  assert_eq "$SHARE_DIR" "$(cd "$TMP/real/proj" && pwd -P)"
}

test_share_refuses_dangerous_folders() {
  load_libs
  mkdir -p "$HOME/.ssh" "$HOME/.aws/sub"
  touch "$TMP/file"
  SHARE_DIR=/; assert_fails "Refusing to share /" share_resolve
  SHARE_DIR=$HOME; assert_fails "your home folder or contains it" share_resolve
  SHARE_DIR=$TMP; assert_fails "your home folder or contains it" share_resolve
  SHARE_DIR=$HOME/.ssh; assert_fails "holds credentials" share_resolve
  SHARE_DIR=$HOME/.aws/sub; assert_fails "holds credentials" share_resolve
  SHARE_DIR=$TMP/file; assert_fails "is not a folder" share_resolve
  SHARE_DIR=$TMP/a/../b; assert_fails "without . or .." share_resolve
}

test_share_checks_missing_folders_without_creating_them() {
  load_libs
  SHARE_DIR=$HOME/.ssh/new; assert_fails "holds credentials" share_resolve
  [ ! -e "$HOME/.ssh" ] || fail "created part of a refused path"
  SHARE_DIR=$TMP/new/proj; share_resolve
  [ ! -e "$TMP/new" ] || fail "share_resolve created the folder"
  assert_eq "$SHARE_DIR" "$(cd "$TMP" && pwd -P)/new/proj"
}

test_share_create_makes_the_folder() {
  load_libs
  ASSUME_YES=1
  SHARE_DIR=$TMP/new/proj; share_resolve; share_create
  [ -d "$TMP/new/proj" ] || fail "folder not created"
}

test_share_confirm() {
  load_libs libvirt
  SHARE_DIR=$TMP
  assert_fails "needs confirmation" share_confirm
  ASSUME_YES=1
  OUT=$(share_confirm 2>&1)
  assert_out "Shared folder: $TMP"
  assert_out "setuid programs"
  GUEST_DOAS=0
  OUT=$(share_confirm 2>&1)
  assert_not_out "setuid programs"
}

test_share_confirm_qemu_has_no_root_warning() {
  load_libs qemu
  SHARE_DIR=$TMP ASSUME_YES=1
  OUT=$(share_confirm 2>&1)
  assert_not_out "setuid programs"
}

test_share_guest_mount_lines() {
  load_libs libvirt
  OUT=$(share_guest_runcmd roy)
  assert_out "mkdir -p /home/roy/shared"
  assert_out "agentcage /home/roy/shared virtiofs nofail 0 0"
  load_libs qemu
  OUT=$(share_guest_runcmd roy)
  assert_out "agentcage /home/roy/shared 9p trans=virtio,version=9p2000.L"
  assert_out "for m in 9pnet_virtio 9p;"
}
