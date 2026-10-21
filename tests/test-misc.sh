#!/usr/bin/env bash
# Domain XML rendering, image selection, API key storage and the SSH config
# block.

test_domain_xml_without_share() {
  load_libs libvirt
  RAM_MB=3000 VCPUS=3
  OUT=$(lv_render_xml box /pool/box.qcow2)
  assert_out "<name>box</name>"
  assert_out '<memory unit="KiB">3072000</memory>'
  assert_out '<vcpu placement="static">3</vcpu>'
  assert_out '<source file="/pool/box.qcow2"/>'
  assert_not_out "<filesystem"
  assert_not_out "<memoryBacking>"
  assert_not_out "@DISK_PATH@"
  assert_out "agentcage fills in the name"   # header comment untouched
  if have xmllint; then printf '%s' "$OUT" | xmllint --noout - || fail "invalid XML"; fi
}

test_domain_xml_with_share_escapes_the_path() {
  load_libs libvirt
  SHARE_DIR='/srv/a & <b> "c"'
  OUT=$(lv_render_xml box /pool/box.qcow2)
  assert_out '<source dir="/srv/a &amp; &lt;b&gt; &quot;c&quot;"/>'
  assert_out '<target dir="agentcage"/>'
  assert_out "<memoryBacking>"
  if have xmllint; then printf '%s' "$OUT" | xmllint --noout - || fail "invalid XML"; fi
}

test_want_collects_missing_tools_once() {
  load_libs
  MISSING_DEPS=()
  want sh                       # present: not recorded
  want acage-no-such-tool-1     # missing
  want acage-no-such-tool-1     # duplicate: ignored
  want acage-no-such-tool-2
  assert_eq "${MISSING_DEPS[*]}" "acage-no-such-tool-1 acage-no-such-tool-2"
}

test_dep_pkg_maps_packages_per_distro() {
  load_libs
  assert_eq "$(dep_pkg qemu-img apt)" qemu-utils
  assert_eq "$(dep_pkg qemu-img pacman)" qemu-img
  assert_eq "$(dep_pkg xorriso apt)" xorriso
  assert_eq "$(dep_pkg xorriso pacman)" libisoburn
  assert_eq "$(dep_pkg virsh apt)" libvirt-daemon-system
  assert_eq "$(dep_pkg gpg apt)" gnupg
  assert_eq "$(dep_pkg ssh-keygen pacman)" openssh
  assert_eq "$(dep_pkg curl apt)" curl
}

test_report_missing_lists_everything_at_once() {
  load_libs
  MISSING_DEPS=()
  report_missing   # nothing missing: must not exit
  MISSING_DEPS=(xorriso virsh)
  OUT=$( (report_missing) 2>&1 ) || true
  OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')
  assert_out "missing host tools: xorriso virsh"
  assert_out "install"
}

test_verbose_echoes_commands_before_running_them() {
  load_libs
  DRY_RUN=0 VERBOSE=1
  OUT=$( (run echo hi) 2>&1 )
  OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')
  assert_out "[run] echo hi"   # printed
  assert_out "hi"              # and executed
  DRY_RUN=0 VERBOSE=0
  OUT=$( (run echo hi) 2>&1 )
  assert_not_out "[run]"       # quiet without --verbose
}

test_newest_alpine_image_is_picked() {
  load_libs
  local list="generic_alpine-3.9.2-x86_64-uefi-cloudinit-r0.qcow2
generic_alpine-3.24.9-x86_64-uefi-cloudinit-r0.qcow2
generic_alpine-3.24.10-x86_64-uefi-cloudinit-r0.qcow2
generic_alpine-3.24.10-x86_64-uefi-cloudinit-r1.qcow2
generic_alpine-3.24.10-aarch64-uefi-cloudinit-r2.qcow2
generic_alpine-3.25.0-x86_64-uefi-tiny-r0.qcow2"
  assert_eq "$(alpine_latest_image_name x86_64 <<<"$list")" generic_alpine-3.24.10-x86_64-uefi-cloudinit-r1.qcow2
  assert_eq "$(alpine_latest_image_name aarch64 <<<"$list")" generic_alpine-3.24.10-aarch64-uefi-cloudinit-r2.qcow2
}

test_pi_key_file_is_private_json() {
  load_libs
  printf 'sk-ant-test_123\n' | sh -c "$(harness_store_key_script pi)"
  local f=$HOME/.pi/agent/auth.json
  assert_eq "$(stat -c %a "$f")" 600
  if command -v python3 >/dev/null; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["anthropic"]["key"]=="sk-ant-test_123"' "$f" \
      || fail "bad JSON: $(cat "$f")"
  fi
}

test_claude_key_is_replaced_not_appended() {
  load_libs
  printf 'first\n' | sh -c "$(harness_store_key_script claude-code)"
  printf 'second\n' | sh -c "$(harness_store_key_script claude-code)"
  local f=$HOME/.config/agentcage/env
  assert_eq "$(cat "$f")" "export ANTHROPIC_API_KEY=second"
  assert_eq "$(stat -c %a "$f")" 600
}

test_ssh_config_block_round_trip() {
  load_libs
  SSH_PUBKEY=$TMP/key.pub; touch "$SSH_PUBKEY"
  SSH_HOST=10.0.0.5 SSH_PORT=22
  mkdir -p "$HOME/.ssh"
  printf 'Host a\n  User x\n\n\nHost b\n  User y\n' >"$HOME/.ssh/config"
  cp "$HOME/.ssh/config" "$TMP/orig"

  write_ssh_config_entry vm1 2>/dev/null
  write_ssh_config_entry vm2 2>/dev/null
  SSH_HOST=10.0.0.6 write_ssh_config_entry vm1 2>/dev/null
  grep -q '^    User agent$' "$HOME/.ssh/config" || fail "plain 'ssh vm1' should log in as agent"
  assert_eq "$(grep -c '^# agentcage:begin' "$HOME/.ssh/config")" 2
  grep -q 'HostName 10.0.0.6' "$HOME/.ssh/config" || fail "vm1 not updated"
  assert_eq "$(stat -c %a "$HOME/.ssh/config")" 600
  # Something the user added after our blocks, ending in a blank line.
  printf 'Host c\n  User z\n\n' | tee -a "$HOME/.ssh/config" >>"$TMP/orig"

  remove_ssh_config_entry vm1
  remove_ssh_config_entry vm2
  cmp -s "$HOME/.ssh/config" "$TMP/orig" || fail "not restored: $(cat -A "$HOME/.ssh/config")"
}

test_ssh_config_leaves_foreign_entries_alone() {
  load_libs
  SSH_PUBKEY=$TMP/key.pub; touch "$SSH_PUBKEY"
  SSH_HOST=10.0.0.5 SSH_PORT=22
  mkdir -p "$HOME/.ssh"
  printf 'Host box\n  User mine\n' >"$HOME/.ssh/config"
  OUT=$(write_ssh_config_entry box 2>&1)
  assert_out "already has its own 'Host box' entry"
  assert_eq "$(cat "$HOME/.ssh/config")" "$(printf 'Host box\n  User mine')"
}
