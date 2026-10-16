#!/usr/bin/env bash
# The acage command line: help, argument checks, dry runs, delete and list.

test_help_and_version() {
  acage_run --help; assert_rc 0; assert_out "Usage: acage <command>"
  acage_run --version; assert_rc 0; assert_out "acage 0."
}

test_no_command_prints_usage() {
  acage_run; assert_rc 1; assert_out "Usage: acage"
}

test_unknown_command_and_option() {
  acage_run frob; assert_rc 1; assert_out "Unknown command: frob"
  acage_run list --frob; assert_rc 1; assert_out "Unknown option: --frob"
  acage_run list --backend vbox; assert_rc 1; assert_out "Unknown backend 'vbox'"
}

test_option_without_value() {
  acage_run create --name; assert_rc 1; assert_out "--name needs a value"
}

test_refuses_non_linux_hosts() {
  stub uname 'echo Darwin'
  acage_run list; assert_rc 1; assert_out "needs a Linux host"
}

test_rejects_bad_numbers() {
  local a
  for a in "--ram abc" "--ram 100" "--ram a[\$(id)]" "--vcpus 0" "--vcpus 65" "--disk 10G" "--disk 0"; do
    # shellcheck disable=SC2086
    acage_run create box --user roy --pool-dir "$POOL" -n $a
    assert_rc 1
    assert_out "must be a whole number"
  done
}

test_rejects_bad_vm_names() {
  local n
  for n in 123 Box box- a_b "$(printf 'a%.0s' {1..64})"; do
    acage_run create --name "$n" --user roy --pool-dir "$POOL" -n
    assert_rc 1
    assert_out "Invalid VM name"
  done
}

test_rejects_bad_guest_users() {
  acage_run create box --user root --pool-dir "$POOL" -n; assert_rc 1; assert_out "not root"
  acage_run create box --user Roy --pool-dir "$POOL" -n; assert_rc 1; assert_out "Invalid guest user"
}

test_rejects_unknown_harness() {
  acage_run create box --user roy --harness pi,cursor --pool-dir "$POOL" -n
  assert_rc 1; assert_out "Unknown harness 'cursor'"
}

test_commands_that_need_a_name() {
  local c
  for c in ssh start stop console delete; do
    acage_run "$c"; assert_rc 1; assert_out "Which VM? acage $c NAME"
  done
}

test_dry_run_libvirt_changes_nothing() {
  acage_run create box --user roy --pool-dir "$POOL" --disk 1 -n
  assert_rc 0
  assert_out "[dry-run] sudo virsh -c qemu:///system define"
  assert_out "#cloud-config"
  [ ! -e "$POOL" ] || fail "dry run created $POOL"
  [ ! -e "$HOME/.ssh" ] || fail "dry run created ~/.ssh"
  [ ! -e "$XDG_CONFIG_HOME/agentcage" ] || fail "dry run saved settings"
}

test_dry_run_qemu_command_line() {
  acage_run create box --user roy --backend qemu --pool-dir "$POOL" --disk 1 -n
  assert_rc 0
  assert_out "[dry-run] qemu-system-"
  assert_out "-accel kvm"
  assert_out "hostfwd=tcp:127.0.0.1:2222-:22"
  assert_out "-nodefaults"
  assert_not_out "-virtfs"
}

test_dry_run_qemu_with_share_uses_9p() {
  mkdir "$TMP/proj"
  acage_run create box --user roy --backend qemu --pool-dir "$POOL" --disk 1 --share "$TMP/proj" -n -y
  assert_rc 0
  assert_out "-virtfs local,path=$TMP/proj,mount_tag=agentcage,security_model=none"
  assert_out "!! Shared folder: $TMP/proj"
}

test_share_needs_confirmation_without_a_terminal() {
  mkdir "$TMP/proj"
  acage_run create box --user roy --pool-dir "$POOL" --disk 1 --share "$TMP/proj" -n
  assert_rc 1; assert_out "Sharing a folder needs confirmation"
}

test_not_enough_space_stops_early() {
  acage_run create box --user roy --pool-dir "$POOL" --disk 4096 -n
  assert_rc 1; assert_out "Not enough disk space for a 4096 GB VM disk"
}

# A fake stopped VM for the qemu backend.
fake_qemu_vm() {
  mkdir -p "$POOL/vms/$1"
  printf 'C_RAM_MB=2048\nC_VCPUS=2\nC_SSH_PORT=2222\nC_SHARE_DIR=\n' >"$POOL/vms/$1/config"
}

test_list_shows_qemu_vms() {
  fake_qemu_vm box
  acage_run list --backend qemu --pool-dir "$POOL"
  assert_rc 0; assert_out "box"; assert_out "stopped"; assert_out "127.0.0.1:2222"
}

test_delete_needs_confirmation_then_cleans_up() {
  fake_qemu_vm box
  mkdir -p "$HOME/.ssh"
  printf 'Host other\n    User x\n' >"$HOME/.ssh/config"
  cp "$HOME/.ssh/config" "$TMP/config.orig"
  printf '\n# agentcage:begin box\nHost box\n    Port 2222\n# agentcage:end box\n' >>"$HOME/.ssh/config"

  acage_run delete box --backend qemu --pool-dir "$POOL"
  assert_rc 1; assert_out "Deleting needs confirmation"
  [ -d "$POOL/vms/box" ] || fail "VM was deleted without confirmation"

  acage_run delete box --backend qemu --pool-dir "$POOL" -y
  assert_rc 0; assert_out "Deleted box"
  [ ! -e "$POOL/vms/box" ] || fail "VM folder still there"
  cmp -s "$HOME/.ssh/config" "$TMP/config.orig" || fail "SSH config not restored: $(cat "$HOME/.ssh/config")"
}

test_start_unknown_vm() {
  acage_run start nope --backend qemu --pool-dir "$POOL"
  assert_rc 1; assert_out "No VM named 'nope'"
}
