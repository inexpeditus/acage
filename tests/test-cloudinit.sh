#!/usr/bin/env bash
# The first-boot config (lib/cloudinit.sh).

KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test"

# yaml_check -> parses OUT as YAML when PyYAML is available and runs the
# Python expression given as $1 against it (as 'd').
yaml_check() {
  have_pyyaml || return 0
  printf '%s' "$OUT" | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
assert eval(sys.argv[1]), sys.argv[1]
' "$1" || fail "YAML check failed: $1"
}

test_userdata_defaults() {
  load_libs
  OUT=$(cloudinit_userdata "$KEY")
  assert_out "#cloud-config"
  assert_out "hostname: box"
  assert_out "  - name: roy"
  assert_out "groups: [wheel]"
  assert_out 'passwd: "*"'
  assert_out "permit nopass roy"
  assert_out "deluser --remove-home alpine"
  assert_out "ssh_pwauth: false"
  assert_out '[npm, install, -g, --ignore-scripts, "@earendil-works/pi-coding-agent"]'
  yaml_check 'd["users"][0]["name"] == "roy" and d["users"][0]["ssh_authorized_keys"] == ["'"$KEY"'"]'
  yaml_check '{"git","openssh","nodejs","npm","vim","doas"} <= set(d["packages"])'
  yaml_check 'd["disable_root"] is True'
}

test_userdata_uid_follows_the_host() {
  load_libs
  OUT=$(cloudinit_userdata "$KEY")
  if [ "$(id -u)" -ge 500 ]; then
    assert_out "uid: $(id -u)"
  else
    assert_not_out "uid:"
  fi
}

test_userdata_with_password() {
  load_libs
  GUEST_PW_HASH='$6$salt$hash'
  OUT=$(cloudinit_userdata "$KEY")
  assert_out 'passwd: "$6$salt$hash"'
  assert_out "permit persist roy"
  assert_not_out "nopass"
}

test_userdata_without_doas() {
  load_libs
  GUEST_DOAS=0
  OUT=$(cloudinit_userdata "$KEY")
  assert_not_out "doas"
  yaml_check '"doas" not in d["packages"]'
}

test_userdata_harnesses() {
  load_libs
  HARNESS=claude-code,codex
  OUT=$(cloudinit_userdata "$KEY")
  assert_out '[npm, install, -g, "@anthropic-ai/claude-code"]'
  assert_out '[npm, install, -g, --ignore-scripts, "@openai/codex"]'
  assert_out "export USE_BUILTIN_RIPGREP=0"
  assert_not_out "pi-coding-agent"
  [ "$(printf '%s\n' "$OUT" | grep -c '^  - ripgrep$')" = 1 ] || fail "ripgrep listed more than once"
  yaml_check '{"libgcc","libstdc++","ripgrep"} <= set(d["packages"])'
  HARNESS=none
  OUT=$(cloudinit_userdata "$KEY")
  assert_not_out "npm, install"
}

test_userdata_with_share() {
  load_libs
  SHARE_DIR=$TMP
  OUT=$(cloudinit_userdata "$KEY")
  assert_out "mount /home/roy/shared"
  yaml_check 'any("mount /home/roy/shared" == c for c in d["runcmd"])'
}

test_cloudinit_validate() {
  load_libs
  GUEST_USER=""; assert_fails "--user is required" cloudinit_validate
  GUEST_USER=root; assert_fails "not root" cloudinit_validate
  GUEST_USER="a b"; assert_fails "Invalid guest user" cloudinit_validate
  GUEST_USER=roy; cloudinit_validate
}
