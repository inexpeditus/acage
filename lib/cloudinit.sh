#!/usr/bin/env bash
# The first-boot (cloud-init) config: everything that goes into a new VM.
# Users, root access, packages, the agent harnesses and the shared-folder
# mount are all decided here. Sourced by acage.

# Validate everything that ends up inside the generated YAML.
cloudinit_validate() {
  [ -n "$GUEST_USER" ] || die "--user is required (the account to create in the VM)"
  [[ "$GUEST_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid guest user '$GUEST_USER' (lowercase letters, digits, _ and -)"
  [ "$GUEST_USER" != root ] || die "Choose a regular user, not root"
}

# cloud-config for the first boot, written to stdout.
cloudinit_userdata() {
  local key=$1 p h rule uid
  # Same uid as on the host, so files in a shared folder have the right owner
  # on both sides. Only for regular host accounts (500 and up).
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
  - name: $GUEST_USER
EOF
  [ "$uid" -lt 500 ] || echo "    uid: $uid"
  cat <<EOF
    shell: $(alpine_image_shell)
    groups: [wheel]
    # Never "locked": a locked account ('!' in shadow) is refused by sshd builds
    # without PAM (Alpine), even for key logins. '*' matches no password.
    lock_passwd: false
    passwd: "${GUEST_PW_HASH:-*}"
    ssh_authorized_keys:
      - "$key"
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
  # Root access: a rule appended to /etc/doas.conf itself (not /etc/doas.d), and
  # deferred until after the doas package is installed so apk doesn't replace it.
  # With a password set, doas asks for it ('persist' caches it for a few minutes).
  # Without one, there is nothing to ask for, so the rule is 'nopass'.
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
  echo "packages:"
  {
    alpine_base_packages
    [ "$GUEST_DOAS" != 1 ] || alpine_doas_packages
    for h in $(harness_list); do harness_packages "$h"; done
  } | tr ' ' '\n' | awk 'NF && !seen[$0]++ {print "  - " $0}'
  cat <<EOF
runcmd:
  # Belt-and-suspenders: Alpine's cloud-init does not reliably set the live
  # hostname, which otherwise shows up as '(none)' in the shell prompt.
  - hostname $VM
  - echo $VM >/etc/hostname
EOF
  [ -z "$SHARE_DIR" ] || share_guest_runcmd "$GUEST_USER"
  for h in $(harness_list); do
    p=$(harness_npm_package "$h")
    if harness_needs_scripts "$h"; then
      echo "  - [npm, install, -g, \"$p\"]"
    else
      echo "  - [npm, install, -g, --ignore-scripts, \"$p\"]"
    fi
  done
}
