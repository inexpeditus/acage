#!/usr/bin/env bash
# Pool folder choice, saved settings and free-space checks (lib/pool.sh).

test_config_get_and_set() {
  load_libs
  assert_eq "$(config_get pool_dir_libvirt)" ""
  config_set pool_dir_libvirt /srv/a
  config_set other x
  config_set pool_dir_libvirt /srv/b
  assert_eq "$(config_get pool_dir_libvirt)" /srv/b
  assert_eq "$(config_get other)" x
  assert_eq "$(grep -c '^pool_dir_libvirt=' "$CONFIG_FILE")" 1
}

# fs_info stand-in: /home is a big separate partition, everything else is
# on a small root filesystem.
fake_fs_split() {
  fs_info() { case "$1" in /home|/home/*) echo "89 /home" ;; *) echo "11 /" ;; esac; }
}

test_libvirt_default_moves_to_home_when_root_is_small() {
  load_libs libvirt
  fake_fs_split
  pool_pick_default
  assert_eq "$POOL_DIR" /home/agentcage
}

test_libvirt_default_stays_when_home_is_on_root() {
  load_libs libvirt
  fs_info() { echo "200 /"; }
  pool_pick_default
  assert_eq "$POOL_DIR" /var/lib/libvirt/images/agentcage
}

test_saved_pool_wins() {
  load_libs libvirt
  fake_fs_split
  config_set pool_dir_libvirt /srv/vms
  pool_pick_default
  assert_eq "$POOL_DIR" /srv/vms
}

test_qemu_default_is_in_home() {
  load_libs qemu
  fake_fs_split
  pool_pick_default
  assert_eq "$POOL_DIR" "$XDG_DATA_HOME/agentcage"
}

test_pool_remember_saves_once() {
  load_libs
  POOL_DIR=/srv/vms
  pool_remember 2>/dev/null
  assert_eq "$(config_get pool_dir_libvirt)" /srv/vms
  [ -z "$(pool_remember 2>&1)" ] || fail "saved the same folder twice"
}

test_pool_validate() {
  load_libs libvirt
  POOL_DIR="/srv/vms///"; pool_validate; assert_eq "$POOL_DIR" /srv/vms
  POOL_DIR=relative; assert_fails "must be an absolute path" pool_validate
  POOL_DIR=/; assert_fails "Refusing to use /" pool_validate
  POOL_DIR=$HOME/vms; assert_fails "can't enter your home folder" pool_validate
  POOL_DIR="~/vms"; assert_fails "can't enter your home folder" pool_validate
}

test_qemu_pool_may_be_in_home() {
  load_libs qemu
  POOL_DIR=$HOME/vms
  pool_validate
  assert_eq "$POOL_DIR" "$HOME/vms"
}

test_check_space() {
  load_libs
  fs_info() { echo "12 /home"; }
  check_space 10 "a disk"
  assert_fails "has 12 GB free, and this needs 20 GB" check_space 20 "a disk"
  # On the root filesystem, 5 GB more must stay free.
  fs_info() { echo "12 /"; }
  check_space 7 "a disk"
  assert_fails "plus 5 GB left free for the system" check_space 10 "a disk"
}

test_fs_info_on_missing_folder_uses_parent() {
  load_libs
  set -- $(fs_info "$TMP/does/not/exist")
  [[ "$1" =~ ^[0-9]+$ ]] || fail "free GB is '$1'"
  [ -n "$2" ] || fail "no mount point"
}
