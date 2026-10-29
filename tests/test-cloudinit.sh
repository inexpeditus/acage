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
  assert_out "GRUB_TIMEOUT=0"
  assert_out "touch /etc/cloud/cloud-init.disabled"
  yaml_check 'd["users"][1]["name"] == "roy" and d["users"][1]["ssh_authorized_keys"] == ["'"$KEY"'"]'
  yaml_check '{"git","openssh","nodejs","npm","tmux","vim","doas"} <= set(d["packages"])'
  yaml_check 'd["disable_root"] is True'
}

test_userdata_no_packages() {
  load_libs
  # --no-packages: no apk install at all, no harness npm, no firewall load.
  OUT=$( NO_PACKAGES=1 cloudinit_userdata "$KEY" 2>/dev/null )
  assert_not_out "packages:"
  assert_not_out "npm, install"
  assert_not_out "rc-update add nftables"
}

test_userdata_skip_packages() {
  load_libs
  # --skip-packages drops the named packages but keeps the rest.
  OUT=$( SKIP_PACKAGES="vim tmux" cloudinit_userdata "$KEY" 2>/dev/null )
  assert_out "  - git"
  assert_not_out "  - vim"
  assert_not_out "  - tmux"
  yaml_check '"git" in set(d["packages"]) and {"vim","tmux"}.isdisjoint(set(d["packages"]))'
}

test_userdata_skip_nftables_drops_firewall() {
  load_libs
  OUT=$( SKIP_PACKAGES="nftables" cloudinit_userdata "$KEY" 2>/dev/null )
  assert_not_out "  - nftables"
  assert_not_out "rc-update add nftables"
}

test_userdata_skip_npm_drops_harness() {
  load_libs
  OUT=$( SKIP_PACKAGES="npm" cloudinit_userdata "$KEY" 2>/dev/null )
  assert_not_out "npm, install"
}

test_userdata_package_flags_warn() {
  load_libs
  # Dropping nftables/npm warns (on stderr) that the firewall and harness go off.
  OUT=$( NO_PACKAGES=1 ALLOW_LAN=0 cloudinit_userdata "$KEY" 2>&1 >/dev/null )
  assert_out "nftables"
  assert_out "npm"
}

test_userdata_two_accounts() {
  load_libs
  OUT=$(cloudinit_userdata "$KEY")
  assert_out "  - name: agent"
  assert_out "  - name: roy"
  assert_out "chmod 700 /home/roy /home/agent"
  # Only your account is in wheel and gets doas.
  [ "$(printf '%s\n' "$OUT" | grep -c 'groups: \[wheel\]')" = 1 ] || fail "wheel listed more than once"
  assert_not_out "permit nopass agent"
  yaml_check '[u["name"] for u in d["users"]] == ["agent", "roy"]'
  yaml_check 'd["users"][1].get("groups") == ["wheel"] and "groups" not in d["users"][0]'
  yaml_check 'all(u["ssh_authorized_keys"] == ["'"$KEY"'"] for u in d["users"])'
}

test_userdata_agent_gets_the_host_uid() {
  load_libs
  OUT=$(cloudinit_userdata "$KEY")
  if [ "$(id -u)" -ge 500 ]; then
    yaml_check 'd["users"][0]["uid"] == '"$(id -u)"' and "uid" not in d["users"][1]'
    assert_out "uid: $(id -u)"
  else
    assert_not_out "uid:"
  fi
}

test_userdata_firewall() {
  load_libs
  OUT=$(cloudinit_userdata "$KEY")
  assert_out "path: /etc/nftables.nft"
  assert_out "rc-update add nftables default"
  local b64
  b64=$(printf '%s\n' "$OUT" | awk '/path: \/etc\/nftables.nft/ {f=1} f && /content:/ {print $2; exit}')
  printf '%s' "$b64" | base64 -d | cmp -s - "$ROOT/share/firewall.nft" || fail "firewall content differs from share/firewall.nft"
  yaml_check '"nftables" in d["packages"]'
  ALLOW_LAN=1
  OUT=$(cloudinit_userdata "$KEY")
  assert_not_out "nftables"
}

test_userdata_login_messages() {
  load_libs
  OUT=$(cloudinit_userdata "$KEY")
  local f b64
  for f in agent user; do
    b64=$(printf '%s\n' "$OUT" | awk -v p="path: /etc/agentcage/motd.$f" '$0 ~ p {g=1} g && /content:/ {print $2; exit}')
    printf '%s' "$b64" | base64 -d | cmp -s - "$ROOT/share/motd.$f" || fail "motd.$f differs from share/motd.$f"
  done
  assert_out 'if [ "$(id -un)" = agent ]; then cat /etc/agentcage/motd.agent'
  yaml_check 'any(w["path"] == "/etc/motd" and w["content"] == "" for w in d["write_files"])'
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

test_userdata_autostart() {
  load_libs
  # With a harness and autostart on, the agent's interactive login launches it
  # (non-exec, so quitting drops to a shell).
  HARNESS=claude-code AUTOSTART=1
  OUT=$(cloudinit_userdata "$KEY")
  assert_out 'command -v claude >/dev/null 2>&1 && claude'
  # Off (the default) -> no autostart line.
  AUTOSTART=0
  OUT=$(cloudinit_userdata "$KEY")
  assert_not_out "command -v claude"
  # No harness -> nothing to launch, even with autostart on.
  HARNESS=none AUTOSTART=1
  OUT=$(cloudinit_userdata "$KEY")
  assert_not_out "command -v"
}

test_userdata_with_share() {
  load_libs
  SHARE_DIR=$TMP
  OUT=$(cloudinit_userdata "$KEY")
  assert_out "mount /home/agent/shared"
  assert_out "chown agent:agent /home/agent/shared"
  yaml_check 'any("mount /home/agent/shared" == c for c in d["runcmd"])'
}

test_userdata_agent_access() {
  load_libs
  OUT=$(cloudinit_userdata "$KEY")
  # Both homes stay private, and your account gets rw to the agent's files via
  # an ACL (plus a default ACL so new files inherit it). The reverse direction
  # is never granted.
  assert_out "chmod 700 /home/roy /home/agent"
  # r-x on the home itself (keeps sshd StrictModes happy), rwX as a default ACL
  # so new files the agent creates are yours.
  assert_out "setfacl -m u:roy:rx /home/agent"
  assert_out "setfacl -d -m u:roy:rwX /home/agent"
  assert_not_out "u:agent:"
  yaml_check '"acl" in set(d["packages"])'
}

test_userdata_agent_md() {
  load_libs
  printf '# Be careful\n' >"$TMP/ctx.md"
  AGENT_MD="$TMP/ctx.md"
  OUT=$(cloudinit_userdata "$KEY")
  # Installed into the agent's home under both names, owned by the agent.
  assert_out "path: /home/agent/CLAUDE.md"
  assert_out "path: /home/agent/AGENTS.md"
  assert_out "owner: agent:agent"
  yaml_check 'sum(1 for f in d["write_files"] if f["path"] in ("/home/agent/CLAUDE.md","/home/agent/AGENTS.md")) == 2'
  # Off by default: no such files without the flag.
  AGENT_MD=""
  OUT=$(cloudinit_userdata "$KEY")
  assert_not_out "/home/agent/CLAUDE.md"
}

test_bake_userdata() {
  load_libs
  HARNESS=claude-code
  OUT=$(cloudinit_bake_userdata)
  assert_out "#cloud-config"
  # Packages are baked in; the harness is installed under 'set -e' so a failed
  # install never yields a silent golden, and output goes to the serial console.
  assert_out "set -e"
  assert_out 'npm install -g "@anthropic-ai/claude-code" >/dev/ttyS0'
  # Per-instance identity and cloud-init state are stripped, then it powers off.
  assert_out "rm -f /etc/ssh/ssh_host_*"
  assert_out ": > /etc/machine-id"
  assert_out "poweroff"
  # No accounts, keys or firewall: those are added per cage in golden mode.
  assert_not_out "name: roy"
  assert_not_out "ssh_authorized_keys"
  assert_not_out "nftables.nft"
  yaml_check '{"nodejs","npm"} <= set(d["packages"])'
  yaml_check '"users" not in d'
  # No harness -> nothing to npm-install, but it still strips and powers off.
  HARNESS=none
  OUT=$(cloudinit_bake_userdata)
  assert_not_out "npm install"
  assert_out "poweroff"
}

test_cloudinit_validate() {
  load_libs
  GUEST_USER=""; assert_fails "--user is required" cloudinit_validate
  GUEST_USER=root; assert_fails "not root" cloudinit_validate
  GUEST_USER="a b"; assert_fails "Invalid guest user" cloudinit_validate
  GUEST_USER=agent; assert_fails "is the agent's account" cloudinit_validate
  GUEST_USER=roy; cloudinit_validate
}
