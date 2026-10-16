#!/usr/bin/env bash
# Image verification, disk preparation and the first-boot (cloud-init) seed.
# Sourced by agentcage.

fpr_pretty() { sed -E 's/(.{4})/\1 /g; s/ $//' <<<"$1"; }

# image_verify_signature FPR KEYFILE SIGFILE DATAFILE
# Imports KEYFILE into a throwaway keyring (yours is untouched) and requires a valid
# signature made by exactly the primary key FPR. No keyserver involved.
image_verify_signature() {
  local fpr=$1 keyfile=$2 sig=$3 data=$4 home out
  home=$(mktemp -d); chmod 700 "$home"
  if ! GNUPGHOME=$home gpg --batch --quiet --import "$keyfile" >/dev/null 2>&1; then
    rm -rf "$home"; echo "could not import $keyfile" >&2; return 1
  fi
  out=$(GNUPGHOME=$home gpg --batch --status-fd 1 --verify "$sig" "$data" 2>/dev/null) || true
  GNUPGHOME=$home gpgconf --kill dirmngr gpg-agent >/dev/null 2>&1 || true
  rm -rf "$home"
  awk '$2=="VALIDSIG"{print $NF}' <<<"$out" | grep -qx "$fpr"
}

# Show the pinned fingerprint and where to compare it (skipped with --yes).
image_confirm_key() {
  local label=$1 fpr=$2 url=$3 ok=""
  {
    echo "Signature is valid and made by this $label image-signing key:"
    echo "    $(fpr_pretty "$fpr")"
    echo "The key ships with agentcage; compare it with $url"
  } >&2
  [ "$ASSUME_YES" = 1 ] && return 0
  interactive || { echo "Not a terminal: pass --yes to accept the fingerprint shown above." >&2; return 1; }
  read -rp "Fingerprint matches? [y/N] " ok || true
  is_yes "$ok"
}

# Public key that will be authorized for the guest user (generated if missing).
# Callers capture stdout as the path, so all messages here go to stderr.
image_pubkey_file() {
  local pub=${SSH_PUBKEY:-$HOME/.ssh/id_agentcage.pub}
  if [ ! -f "$pub" ] && [ -z "$SSH_PUBKEY" ]; then
    if dry; then
      run ssh-keygen -t ed25519 -f "${pub%.pub}" -C agentcage -N ""
    else
      mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
      ssh-keygen -q -t ed25519 -f "${pub%.pub}" -C agentcage -N "" </dev/null >/dev/null
      log "Generated SSH key ${pub%.pub}"
    fi
  fi
  echo "$pub"
}

# The matching private key: 'ssh -i'/IdentityFile need this, not the .pub file.
image_privkey_file() { local p; p=$(image_pubkey_file); echo "${p%.pub}"; }

# Validate everything that ends up inside the generated YAML.
image_validate() {
  [ -n "$GUEST_USER" ] || die "--user is required (the account to create in the VM)"
  [[ "$GUEST_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid guest user '$GUEST_USER' (lowercase letters, digits, _ and -)"
  [ "$GUEST_USER" != root ] || die "Choose a regular user, not root"
}

# cloud-config for the first boot, written to stdout.
image_userdata() {
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

# image_prepare_disk DEST -> copies the verified image to DEST and grows it to --disk GB.
image_prepare_disk() {
  local disk=$1 img vsize
  img="$POOL_DIR/$(alpine_image_file "$IMAGE_ARCH")"
  need qemu-img
  if ! dry; then
    pool_exists "$img" || die "Image not found: $img (run 'acage image' first)"
    vsize=$(prun qemu-img info --output=json "$img" | sed -n 's/.*"virtual-size": *\([0-9]*\).*/\1/p' | head -1)
    if [ -n "$vsize" ] && [ "$vsize" -gt $((DISK_GB * 1073741824)) ]; then
      die "--disk ${DISK_GB} GB is smaller than the image ($((vsize / 1073741824)) GB); use a larger size"
    fi
  fi
  log "Copying the image to $disk and growing it to ${DISK_GB} GB"
  prun qemu-img convert -O qcow2 "$img" "$disk"
  prun qemu-img resize -q "$disk" "${DISK_GB}G"
}

# make_iso DIR OUT -> ISO 9660 image labelled 'cidata' holding DIR's files.
make_iso() {
  local src=$1 out=$2
  if command -v xorriso >/dev/null; then
    local out_log
    # xorriso prints a banner even with -quiet; show its output only on failure.
    out_log=$(cd "$src" && xorriso -as mkisofs -quiet -o "$out" -V cidata -J -r user-data meta-data 2>&1) \
      || { printf '%s\n' "$out_log" >&2; return 1; }
  else
    die "xorriso is needed to build the seed ISO (Arch: pacman -S libisoburn; Ubuntu: apt install xorriso)"
  fi
}

# image_make_seed DEST -> builds the first-boot seed ISO at DEST.
image_make_seed() {
  local dest=$1 pub key tmp
  pub=$(image_pubkey_file)
  if dry; then
    key="$(cat "$pub" 2>/dev/null || echo "ssh-ed25519 AAAA...your-public-key")"
    echo "(dry-run) first-boot config that would go into $dest:" >&2
    image_userdata "$key" | sed 's/^/    | /' >&2
    run make_iso "<seed dir>" "$dest"
    return
  fi
  [ -f "$pub" ] || die "SSH public key not found: $pub"
  key=$(head -1 "$pub")
  [[ "$key" =~ ^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.+/=\ _:-]+$ ]] || die "$pub does not look like a single-line SSH public key"
  tmp=$(mktemp -d)
  mkdir "$tmp/seed"
  image_userdata "$key" >"$tmp/seed/user-data"
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$VM" "$(date +%s)" "$VM" >"$tmp/seed/meta-data"
  make_iso "$tmp/seed" "$tmp/seed.iso" || { rm -rf "$tmp"; die "Could not build the seed ISO"; }
  prun install -m 0644 "$tmp/seed.iso" "$dest"
  rm -rf "$tmp"
  log "First-boot config written to $dest (your public key${GUEST_PW_HASH:+ and a password hash}; no plain secrets)"
}
