#!/usr/bin/env bash
# The first-boot (cloud-init) config: everything that goes into a new VM.
# Accounts, root access, packages, the firewall, the agent harnesses and the
# shared-folder mount are all decided here. Sourced by acage.
#
# Every VM has two accounts, both reached directly over SSH with your key:
#   GUEST_USER  you: root through doas (unless --no-doas)
#   agent       runs the AI: no root, owns ~/shared, holds the API keys
# The agent can't run anything as you, so it can't use your doas, and with
# no root it can't switch off the firewall.

AGENT_USER=agent

# Validate everything that ends up inside the generated YAML.
cloudinit_validate() {
  [ -n "$GUEST_USER" ] || die "--user is required (the account to create in the VM)"
  [[ "$GUEST_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid guest user '$GUEST_USER' (lowercase letters, digits, _ and -)"
  [ "$GUEST_USER" != root ] || die "Choose a regular user, not root"
  [ "$GUEST_USER" != "$AGENT_USER" ] || die "'$AGENT_USER' is the agent's account; pick another name for yours"
}

# cloudinit_user NAME KEY -> one entry for the users: list.
cloudinit_user() {
  cat <<EOF
  - name: $1
    shell: $(alpine_image_shell)
    # Never "locked": a locked account ('!' in shadow) is refused by sshd builds
    # without PAM (Alpine), even for key logins. '*' matches no password.
    lock_passwd: false
    ssh_authorized_keys:
      - "$2"
EOF
}

# cloud-config for the first boot, written to stdout.
cloudinit_userdata() {
  local key=$1 p h rule uid
  uid=$(id -u)
  cat <<EOF
#cloud-config
hostname: $VM
manage_etc_hosts: true
# Alpine's image ships an unused default account, 'alpine' (uid 1000, no
# password, no keys). Remove it before users are created: it would hold
# uid 1000, which is usually the host user's uid.
bootcmd:
  - "if id alpine >/dev/null 2>&1; then deluser --remove-home alpine; delgroup alpine 2>/dev/null; fi; true"
users:
EOF
  # The agent comes first and gets your host uid (for regular host accounts,
  # 500 and up), so files in a shared folder have the same owner on both
  # sides. Your account then gets the next free uid.
  cloudinit_user "$AGENT_USER" "$key"
  [ "$uid" -lt 500 ] || echo "    uid: $uid"
  echo '    passwd: "*"'
  cloudinit_user "$GUEST_USER" "$key"
  echo "    groups: [wheel]"
  echo "    passwd: \"${GUEST_PW_HASH:-*}\""
  cat <<EOF
ssh_pwauth: false
disable_root: true
$(alpine_image_cloudinit_extra)
write_files:
  - path: /etc/profile.d/agentcage.sh
    permissions: "0644"
    content: |
      export EDITOR=vim
EOF
  for h in $(harness_list); do harness_profile_lines "$h" | sed 's/^/      /'; done
  # Per-user settings such as API keys (written later, mode 600).
  echo '      [ -r "$HOME/.config/agentcage/env" ] && . "$HOME/.config/agentcage/env"'
  # Login message for interactive logins, depending on the account.
  cat <<'EOF'
      case $- in *i*)
        if [ "$(id -un)" = agent ]; then cat /etc/agentcage/motd.agent; else cat /etc/agentcage/motd.user; fi 2>/dev/null ;;
      esac
EOF
  # The messages themselves (base64, so any text survives YAML), and an empty
  # /etc/motd so Alpine's default greeting doesn't show as well.
  cat <<EOF
  - path: /etc/agentcage/motd.agent
    permissions: "0644"
    encoding: b64
    content: $(base64 -w0 "$DATA_DIR/motd.agent")
  - path: /etc/agentcage/motd.user
    permissions: "0644"
    encoding: b64
    content: $(base64 -w0 "$DATA_DIR/motd.user")
  - path: /etc/motd
    permissions: "0644"
    content: ""
EOF
  # Root access for you: a rule appended to /etc/doas.conf itself (not
  # /etc/doas.d), deferred until after the doas package is installed so apk
  # doesn't replace it. With a password, doas asks for it ('persist' caches
  # it for a few minutes); without one the rule is 'nopass'.
  if [ "$GUEST_DOAS" = 1 ]; then
    rule="permit nopass $GUEST_USER"
    [ -z "$GUEST_PW_HASH" ] || rule="permit persist $GUEST_USER"
    cat <<EOF
  - path: /etc/doas.conf
    owner: root:root
    permissions: "0600"
    append: true
    defer: true
    content: |
      $rule
EOF
  fi
  # The firewall, base64 so the file survives the trip through YAML as is.
  # Deferred so it replaces the default config the nftables package installs.
  if [ "$ALLOW_LAN" != 1 ]; then
    cat <<EOF
  - path: /etc/nftables.nft
    owner: root:root
    permissions: "0644"
    encoding: b64
    defer: true
    content: $(base64 -w0 "$DATA_DIR/firewall.nft")
EOF
  fi
  echo "packages:"
  {
    alpine_base_packages
    [ "$GUEST_DOAS" != 1 ] || alpine_doas_packages
    [ "$ALLOW_LAN" = 1 ] || echo nftables
    for h in $(harness_list); do harness_packages "$h"; done
  } | tr ' ' '\n' | awk 'NF && !seen[$0]++ {print "  - " $0}'
  # runcmd runs at the end of first boot, after packages and deferred files.
  cat <<EOF
runcmd:
  # Belt-and-suspenders: Alpine's cloud-init does not reliably set the live
  # hostname, which otherwise shows up as '(none)' in the shell prompt.
  - hostname $VM
  - echo $VM >/etc/hostname
  # Neither account can look into the other's home.
  - chmod 700 /home/$GUEST_USER /home/$AGENT_USER
EOF
  if [ "$ALLOW_LAN" != 1 ]; then
    cat <<EOF
  - rc-update add nftables default
  - rc-service nftables restart
EOF
  fi
  [ -z "$SHARE_DIR" ] || share_guest_runcmd "$AGENT_USER"
  for h in $(harness_list); do
    p=$(harness_npm_package "$h")
    if harness_needs_scripts "$h"; then
      echo "  - [npm, install, -g, \"$p\"]"
    else
      echo "  - [npm, install, -g, --ignore-scripts, \"$p\"]"
    fi
  done
  # cloud-init only needs to run once, at first boot. This runcmd is the last
  # thing it does, so everything above is already applied; disabling it here
  # trims several seconds off every later boot and takes a large,
  # root-privileged tool out of the boot path. The accounts, keys and firewall
  # it set up are persistent, so nothing is lost by not re-running it.
  echo "  - touch /etc/cloud/cloud-init.disabled"
}
