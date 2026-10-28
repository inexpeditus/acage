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
EOF
  # Golden image: regenerate the host keys stripped during bake, so every cage
  # gets unique ones (sshd also regenerates missing keys when it starts).
  [ "${GOLDEN:-0}" != 1 ] || echo '  - "ssh-keygen -A 2>/dev/null || true"'
  echo "users:"
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
  # Login message for interactive logins. When autostart is on, the agent
  # account also launches its harness here; quit the harness to drop to a shell
  # (and `acage ssh NAME -- sh` gives a plain shell without launching it).
  local hcmd=""
  if [ "${AUTOSTART:-0}" = 1 ]; then for h in $(harness_list); do hcmd=$(harness_command "$h"); break; done; fi
  echo '      case $- in *i*)'
  if [ -n "$hcmd" ]; then
    echo '        if [ "$(id -un)" = agent ]; then'
    echo '          cat /etc/agentcage/motd.agent 2>/dev/null'
    echo "          command -v $hcmd >/dev/null 2>&1 && $hcmd"
    echo '        else cat /etc/agentcage/motd.user 2>/dev/null; fi ;;'
  else
    echo '        if [ "$(id -un)" = agent ]; then cat /etc/agentcage/motd.agent; else cat /etc/agentcage/motd.user; fi 2>/dev/null ;;'
  fi
  echo '      esac'
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
  # Optional agent instructions (--agent-md FILE): dropped into the agent's home
  # as both CLAUDE.md and AGENTS.md, so whichever harness runs picks it up.
  # Deferred so /home/$AGENT_USER exists by the time it is written.
  if [ -n "${AGENT_MD:-}" ]; then
    local md f
    md=$(base64 -w0 "$AGENT_MD")
    for f in CLAUDE.md AGENTS.md; do
      cat <<EOF
  - path: /home/$AGENT_USER/$f
    owner: $AGENT_USER:$AGENT_USER
    permissions: "0644"
    defer: true
    encoding: b64
    content: $md
EOF
    done
  fi
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
  # In golden mode the packages are already baked in; skip installing them.
  if [ "${GOLDEN:-0}" != 1 ]; then
    echo "packages:"
    {
      alpine_base_packages
      [ "$GUEST_DOAS" != 1 ] || alpine_doas_packages
      [ "$ALLOW_LAN" = 1 ] || echo nftables
      for h in $(harness_list); do harness_packages "$h"; done
    } | tr ' ' '\n' | awk 'NF && !seen[$0]++ {print "  - " $0}'
  fi
  # runcmd runs at the end of first boot, after packages and deferred files.
  cat <<EOF
runcmd:
  # Belt-and-suspenders: Alpine's cloud-init does not reliably set the live
  # hostname, which otherwise shows up as '(none)' in the shell prompt.
  - hostname $VM
  - echo $VM >/etc/hostname
  # Both homes are private (mode 700), so neither account can look into the
  # other's by default. Then give YOUR account access to the agent's files with
  # POSIX ACLs, so you can inspect and edit everything the agent works on. The
  # reverse stays blocked: the agent still can't read your home, run anything as
  # you, or touch the firewall.
  #
  #  - On the home directory itself you only get r-x (enter and list): a named
  #    ACL raises the dir's ACL mask into the group mode bits, and sshd's
  #    StrictModes refuses key logins for an account whose home is group-
  #    WRITABLE. r-x keeps it unwritable, so the agent can still log in, while
  #    ~/.ssh (created at boot, before this) never inherits an ACL and stays
  #    strict.
  #  - A default ACL of rwX means everything the agent creates afterwards -- its
  #    actual work -- is yours to read and write.
  - chmod 700 /home/$GUEST_USER /home/$AGENT_USER
  - setfacl -m u:$GUEST_USER:rx /home/$AGENT_USER
  - setfacl -d -m u:$GUEST_USER:rwX /home/$AGENT_USER
EOF
  if [ "$ALLOW_LAN" != 1 ]; then
    cat <<EOF
  - rc-update add nftables default
  - rc-service nftables restart
EOF
  fi
  [ -z "$SHARE_DIR" ] || share_guest_runcmd "$AGENT_USER"
  # In golden mode the harness is already installed; skip the npm install.
  if [ "${GOLDEN:-0}" != 1 ]; then
    for h in $(harness_list); do
      p=$(harness_npm_package "$h")
      if harness_needs_scripts "$h"; then
        echo "  - [npm, install, -g, \"$p\"]"
      else
        echo "  - [npm, install, -g, --ignore-scripts, \"$p\"]"
      fi
    done
  fi
  # Trim the boot on every later start (all security-neutral for a disposable
  # VM on a private NAT):
  #  - drop cloud-init from the runlevels; it only has work to do on first boot,
  #    and its Python stages otherwise run (and serialise) every boot;
  #  - skip dhcpcd's duplicate-address ARP probe, which only times out on NAT
  #    (the DHCP server controls allocation), and drop IPv6 DHCP (acage is IPv4);
  #  - start OpenRC services in parallel instead of one at a time.
  echo "  - for s in cloud-init-local cloud-init cloud-config cloud-final cloud-init-hotplugd; do rc-update del \$s boot 2>/dev/null; rc-update del \$s default 2>/dev/null; done"
  echo "  - sed -i -e '/inet6 dhcp/d' -e '/control-alias/d' /etc/network/interfaces"
  echo "  - grep -q '^noarp' /etc/dhcpcd.conf || echo noarp >>/etc/dhcpcd.conf"
  echo "  - sed -i 's/^#*rc_parallel=.*/rc_parallel=YES/' /etc/rc.conf; grep -q '^rc_parallel=' /etc/rc.conf || echo rc_parallel=YES >>/etc/rc.conf"
  echo "  - sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub"
  echo "  - grub-mkconfig -o /boot/grub/grub.cfg"
  # cloud-init only needs to run once, at first boot. This runcmd is the last
  # thing it does, so everything above is already applied; disabling it here
  # trims several seconds off every later boot and takes a large,
  # root-privileged tool out of the boot path. The accounts, keys and firewall
  # it set up are persistent, so nothing is lost by not re-running it.
  echo "  - touch /etc/cloud/cloud-init.disabled"
}

# cloudinit_bake_userdata -> minimal cloud-config for BAKING a golden image:
# install the static packages and harness(es), then strip per-instance identity
# (host keys, machine-id) and cloud-init's own state so a cage made from the
# image is unique and runs its own first-boot config, and finally power off. No
# accounts, keys or firewall here -- those are added per cage in golden mode.
cloudinit_bake_userdata() {
  local h p
  cat <<EOF
#cloud-config
$(alpine_image_cloudinit_extra)
packages:
EOF
  {
    alpine_base_packages
    alpine_doas_packages
    echo nftables
    for h in $(harness_list); do harness_packages "$h"; done
  } | tr ' ' '\n' | awk 'NF && !seen[$0]++ {print "  - " $0}'
  # One shell block run under 'set -e', so the harness install must fully
  # succeed before the strip and power-off: a failed install aborts the block,
  # the VM stays up, and the bake surfaces as a timeout (never a silent, broken
  # golden). npm's output goes to the serial console, so 'acage console' shows
  # bake progress live and any failure is there to read. The explicit sync
  # flushes the install through to the host image before it is flattened.
  cat <<'EOF'
runcmd:
  - |
    set -e
EOF
  for h in $(harness_list); do
    p=$(harness_npm_package "$h")
    if harness_needs_scripts "$h"; then
      echo "    npm install -g \"$p\" >/dev/ttyS0 2>&1"
    else
      echo "    npm install -g --ignore-scripts \"$p\" >/dev/ttyS0 2>&1"
    fi
  done
  cat <<'EOF'
    rm -f /etc/ssh/ssh_host_*
    : > /etc/machine-id
    rm -rf /var/lib/cloud/instances /var/lib/cloud/instance /var/lib/cloud/data/instance-id /var/lib/cloud/sem
    rm -f /etc/cloud/cloud-init.disabled
    rm -rf /var/cache/apk/*
    sync
    poweroff
EOF
}
