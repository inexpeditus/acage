#!/usr/bin/env bash
# Generic preinstalled-image helpers. Private copy of the relevant parts of
# ../lib/image.sh, adapted to call the alpine_image_* functions in profile.sh
# directly (no multi-guest dispatch layer, since this folder is Alpine-only).
# Sourced by create.sh; do not run directly.

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
  local label=$1 fpr=$2 url=$3 ok
  echo "Signature is valid and made by this $label image-signing key:"
  echo "    $(fpr_pretty "$fpr")"
  echo "The key ships alongside this script; compare it with $url"
  [ "$ASSUME_YES" = 1 ] && return 0
  read -rp "Fingerprint matches? [y/N] " ok
  [ "${ok,,}" = y ]
}

# Move a verified image into the pool.
image_accept() {
  local src=$1 dest=$2
  ensure_pool_dir
  sudo install -m 0644 "$src" "$dest"
  log "Verified image: $dest"
}

image_dry_run_note() { echo "(dry-run) would verify the signature and install the image at $1"; }

# Public key that will be authorized for the guest user (generated if missing).
image_pubkey_file() {
  local pub=${SSH_PUBKEY:-$HOME/.ssh/id_agentbox.pub}
  if [ ! -f "$pub" ] && [ -z "$SSH_PUBKEY" ]; then
    if dry; then
      run ssh-keygen -t ed25519 -f "${pub%.pub}" -C "$VM" -N ""
    else
      mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
      ssh-keygen -t ed25519 -f "${pub%.pub}" -C "$VM" -N "" >/dev/null
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
  local key=$1 p
  cat <<EOF
#cloud-config
hostname: $VM
manage_etc_hosts: true
users:
  - name: $GUEST_USER
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
EOF
  # Root access: a rule appended to /etc/doas.conf itself (not /etc/doas.d), and
  # deferred until after the doas package is installed so apk doesn't replace it.
  # With a password set, doas asks for it ('persist' caches it for a few minutes).
  # Without one, there is nothing to ask for, so the rule is 'nopass'.
  local rule="permit nopass $GUEST_USER"
  [ -z "$GUEST_PW_HASH" ] || rule="permit persist $GUEST_USER"
  [ "$GUEST_DOAS" != 1 ] || cat <<EOF
write_files:
  - path: /etc/doas.conf
    owner: root:root
    permissions: "0600"
    append: true
    defer: true
    content: |
      $rule
EOF
  echo "packages:"
  for p in $(alpine_image_packages); do echo "  - $p"; done
  [ "$GUEST_DOAS" != 1 ] || alpine_image_doas_packages | sed 's/^/  - /'
  cat <<EOF
runcmd:
  # Belt-and-suspenders: Alpine's cloud-init does not reliably set the live
  # hostname, which otherwise shows up as '(none)' in the shell prompt.
  - hostname $VM
  - echo $VM >/etc/hostname
  - [npm, install, -g, --ignore-scripts, "@earendil-works/pi-coding-agent"]
EOF
}

# Copy the verified image to the VM disk and grow it to --disk GB.
image_prepare_disk() {
  local disk=$1 img vsize
  img="$POOL_DIR/$(alpine_image_file)"
  if ! dry; then
    sudo test -f "$img" || die "Image not found: $img (run '$0 image' first, or pass --image PATH support if you add it)"
    vsize=$(sudo qemu-img info --output=json "$img" | sed -n 's/.*"virtual-size": *\([0-9]*\).*/\1/p' | head -1)
    if [ -n "$vsize" ] && [ "$vsize" -gt $((DISK_GB * 1073741824)) ]; then
      die "--disk ${DISK_GB} GB is smaller than the image ($((vsize / 1073741824)) GB); use a larger size"
    fi
  fi
  log "Copying the image to $disk and growing it to ${DISK_GB} GB"
  run sudo qemu-img convert -O qcow2 "$img" "$disk"
  run sudo qemu-img resize "$disk" "${DISK_GB}G"
}

# Build the seed ISO and put it in the pool; its path is left in SEED_ISO.
image_make_seed() {
  local pub key tmp
  pub=$(image_pubkey_file)
  SEED_ISO="$POOL_DIR/$VM-seed.iso"
  if dry; then
    key="$(cat "$pub" 2>/dev/null || echo "ssh-ed25519 AAAA...your-public-key")"
    echo "(dry-run) first-boot config that would go into $SEED_ISO:"
    image_userdata "$key" | sed 's/^/    | /'
    run xorriso -as mkisofs -o "$SEED_ISO" -V cidata -J -r user-data meta-data
    return
  fi
  [ -f "$pub" ] || die "SSH public key not found: $pub"
  key=$(head -1 "$pub")
  [[ "$key" =~ ^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.+/=\ _:-]+$ ]] || die "$pub does not look like a single-line SSH public key"
  command -v xorriso >/dev/null || die "xorriso is needed to build the seed ISO (Alpine host: apk add xorriso; Arch host: pacman -S libisoburn)"
  tmp=$(mktemp -d)
  image_userdata "$key" >"$tmp/user-data"
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$VM" "$(date +%s)" "$VM" >"$tmp/meta-data"
  (cd "$tmp" && xorriso -as mkisofs -quiet -o seed.iso -V cidata -J -r user-data meta-data) \
    || { rm -rf "$tmp"; die "Could not build the seed ISO"; }
  sudo install -m 0644 "$tmp/seed.iso" "$SEED_ISO"
  rm -rf "$tmp"
  log "First-boot config written to $SEED_ISO (your public key${GUEST_PW_HASH:+ and a password hash}; no plain secrets)"
}

image_next_steps() {
  cat <<EOF
  The VM is booting from the preinstalled Alpine image. First boot takes a
  minute or two: it creates '$GUEST_USER' with your key and installs the packages and Pi.
  1. Find its IP:  virsh -c $URI domifaddr $VM --source lease
  2. Wait for it:  ssh -i ~/.ssh/id_agentbox $GUEST_USER@<ip> cloud-init status --wait
  3. Add an SSH config entry, then connect:  ssh -o HostName=<ip> $GUEST_USER@<ip>
  Add your API key inside the VM:  mkdir -p ~/.pi/agent; edit ~/.pi/agent/auth.json (chmod 600)
EOF
}
