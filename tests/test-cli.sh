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

test_refuses_running_as_root() {
  stub id 'case "$1" in -u) echo 0 ;; *) echo root ;; esac'
  acage_run list; assert_rc 1; assert_out "as root"
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
  # SSH forwarded from a free port on 127.0.0.1 only (2222 or the next free one).
  [[ "$OUT" =~ hostfwd=tcp:127\.0\.0\.1:2[23][0-9][0-9]-:22 ]] || fail "no localhost-only SSH forward in: $OUT"
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

test_delete_asks_and_can_be_declined() {
  have script || return 0
  fake_qemu_vm box
  acage_tty 'n\n' delete box --backend qemu --pool-dir "$POOL"
  assert_rc 1; assert_out "Are you sure?"; assert_out "Nothing was deleted"
  [ -d "$POOL/vms/box" ] || fail "deleted after answering no"
}

test_delete_offers_the_shared_folder_only_if_acage_made_it() {
  have script || return 0
  mkdir -p "$XDG_CONFIG_HOME/agentcage" "$TMP/made" "$TMP/mine"
  touch "$TMP/made/a" "$TMP/mine/b"
  fake_qemu_vm box; fake_qemu_vm box2
  printf 'share_box=%s\nshare_created_box=1\nshare_box2=%s\n' "$TMP/made" "$TMP/mine" >"$XDG_CONFIG_HOME/agentcage/config"
  acage_tty 'y\ny\n' delete box --backend qemu --pool-dir "$POOL"
  assert_rc 0; assert_out "Also delete the shared folder $TMP/made"; assert_out "Deleted the shared folder"
  [ ! -e "$TMP/made" ] || fail "shared folder not deleted after yes"
  # A folder that existed before the VM is never offered.
  acage_tty 'y\ny\n' delete box2 --backend qemu --pool-dir "$POOL"
  assert_rc 0; assert_not_out "Also delete the shared folder"; assert_out "Kept the shared folder $TMP/mine"
  [ -f "$TMP/mine/b" ] || fail "deleted a folder acage didn't make"
}

test_delete_cleans_leftovers_of_a_failed_create() {
  mkdir -p "$HOME/.ssh" "$XDG_CONFIG_HOME/agentcage"
  printf '# agentcage:begin ghost\nHost ghost\n# agentcage:end ghost\n' >"$HOME/.ssh/config"
  printf 'user_ghost=roy\n' >"$XDG_CONFIG_HOME/agentcage/config"
  acage_run delete ghost --backend qemu --pool-dir "$POOL" -y
  assert_rc 0; assert_out "left over"; assert_out "Deleted ghost"
  [ ! -s "$HOME/.ssh/config" ] || fail "leftover SSH entry kept: $(cat "$HOME/.ssh/config")"
  [ ! -s "$XDG_CONFIG_HOME/agentcage/config" ] || fail "leftover settings kept"
  acage_run delete ghost --backend qemu --pool-dir "$POOL" -y
  assert_rc 1; assert_out "No VM named 'ghost'"
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

  mkdir -p "$XDG_CONFIG_HOME/agentcage"
  printf 'user_box=roy\nshare_box=%s\nshare_created_box=1\nuser_other=x\n' "$TMP/share" >"$XDG_CONFIG_HOME/agentcage/config"
  mkdir "$TMP/share"; touch "$TMP/share/work.txt"
  printf 'box ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIbox\nother ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIoth\n' >"$HOME/.ssh/known_hosts"
  acage_run delete box --backend qemu --pool-dir "$POOL" -y
  assert_rc 0
  assert_out "This deletes 'box'"
  assert_out "Deleted box"
  assert_eq "$(cat "$XDG_CONFIG_HOME/agentcage/config")" "user_other=x"
  grep -q '^box ' "$HOME/.ssh/known_hosts" && fail "host key of box still in known_hosts"
  grep -q '^other ' "$HOME/.ssh/known_hosts" || fail "removed another host's key"
  # --yes never deletes the shared folder.
  assert_out "Kept the shared folder $TMP/share (1 files and folders)"
  [ -f "$TMP/share/work.txt" ] || fail "shared folder deleted with --yes"
  [ ! -e "$POOL/vms/box" ] || fail "VM folder still there"
  cmp -s "$HOME/.ssh/config" "$TMP/config.orig" || fail "SSH config not restored: $(cat "$HOME/.ssh/config")"
}

test_uninstall_needs_confirmation() {
  acage_run uninstall --backend qemu --pool-dir "$POOL"
  assert_rc 1; assert_out "Uninstalling needs confirmation"
}

test_uninstall_dry_run_changes_nothing() {
  fake_qemu_vm box
  mkdir -p "$XDG_CONFIG_HOME/agentcage"
  printf 'user_box=roy\n' >"$XDG_CONFIG_HOME/agentcage/config"
  cp "$XDG_CONFIG_HOME/agentcage/config" "$TMP/orig"
  stub pacman 'exit 1'
  acage_run uninstall --backend qemu --pool-dir "$POOL" -n -y
  assert_rc 0; assert_out "removes everything acage set up"
  [ -d "$POOL/vms/box" ] || fail "dry run removed the VM"
  cmp -s "$XDG_CONFIG_HOME/agentcage/config" "$TMP/orig" || fail "dry run changed the config"
}

test_uninstall_removes_all_data_and_prints_package_hint() {
  fake_qemu_vm box
  fake_qemu_vm dev
  mkdir -p "$XDG_CONFIG_HOME/agentcage" "$HOME/.ssh" "$XDG_CACHE_HOME/agentcage/images"
  printf 'pool_dir_qemu=%s\nuser_box=roy\nuser_dev=roy\n' "$POOL" >"$XDG_CONFIG_HOME/agentcage/config"
  printf 'Host other\n    User x\n\n# agentcage:begin box\nHost box\n# agentcage:end box\n' >"$HOME/.ssh/config"
  printf 'box ssh-ed25519 AAAAbox\nother ssh-ed25519 AAAAoth\n' >"$HOME/.ssh/known_hosts"
  : >"$HOME/.ssh/id_agentcage"; : >"$HOME/.ssh/id_agentcage.pub"
  : >"$XDG_CACHE_HOME/agentcage/images/img.qcow2"
  # pacman present, reporting acage + qemu-base installed and qemu-base unneeded.
  stub pacman 'case "$1 $2" in
  "-Qq acage") exit 0 ;;
  "-Qq qemu-base") exit 0 ;;
  "-Qq"*) exit 1 ;;
  "-Qi qemu-base") echo "Required By     : None" ;;
  *) exit 1 ;;
esac'

  acage_run uninstall --backend qemu --pool-dir "$POOL" -y
  assert_rc 0
  assert_out "removes everything acage set up"
  assert_out "box"; assert_out "dev"
  assert_out "sudo pacman -Rns acage qemu-base"
  assert_out "Review the command"
  [ ! -e "$POOL/vms/box" ] || fail "VM box not removed"
  [ ! -e "$POOL/vms/dev" ] || fail "VM dev not removed"
  [ ! -e "$XDG_CONFIG_HOME/agentcage" ] || fail "settings not removed"
  [ ! -e "$XDG_CACHE_HOME/agentcage" ] || fail "image cache not removed"
  [ ! -e "$HOME/.ssh/id_agentcage" ] || fail "SSH key not removed"
  [ ! -e "$HOME/.ssh/id_agentcage.pub" ] || fail "SSH public key not removed"
  grep -q '^box ' "$HOME/.ssh/known_hosts" && fail "box host key kept"
  grep -q '^other ' "$HOME/.ssh/known_hosts" || fail "another host's key wrongly removed"
  grep -q 'agentcage:begin' "$HOME/.ssh/config" && fail "agentcage SSH block kept"
  grep -q 'Host other' "$HOME/.ssh/config" || fail "foreign SSH entry removed"
  return 0
}

test_attach_and_ssh_flags() {
  fake_qemu_vm box
  # attach now starts a stopped VM (so no "not running" error); it still
  # refuses one that does not exist. The auto-start path needs a real VM and
  # is covered by tests/e2e.
  acage_run attach nope --user --backend qemu --pool-dir "$POOL"
  assert_rc 1; assert_out "No VM named 'nope'"
  acage_run ssh box --agent --backend qemu --pool-dir "$POOL" -- true
  assert_rc 1; assert_out "'box' is not running"
  # For create, --user still takes a name.
  acage_run create box --user agent --pool-dir "$POOL" -n
  assert_rc 1; assert_out "is the agent's account"
}

test_firewall_is_on_unless_allow_lan() {
  acage_run create box --user roy --pool-dir "$POOL" --disk 1 -n
  assert_rc 0; assert_out "path: /etc/nftables.nft"
  acage_run create box --user roy --pool-dir "$POOL" --disk 1 --allow-lan -n
  assert_rc 0; assert_not_out "nftables"
}

test_start_unknown_vm() {
  acage_run start nope --backend qemu --pool-dir "$POOL"
  assert_rc 1; assert_out "No VM named 'nope'"
}
