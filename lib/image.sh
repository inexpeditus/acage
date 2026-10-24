#!/usr/bin/env bash
# Image verification, the SSH key, disk preparation and the first-boot seed
# ISO. The seed's contents come from lib/cloudinit.sh. Sourced by acage.

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

# image_prepare_disk DEST -> copies the verified image to DEST and grows it to --disk GB.
image_prepare_disk() {
  local disk=$1 img vsize
  need qemu-img
  img=$(alpine_cached_image "$IMAGE_ARCH")
  if ! dry; then
    [ -n "$img" ] && [ -f "$img" ] || die "No Alpine image is cached (run 'acage image' first)"
    vsize=$(qemu-img info --output=json "$img" | sed -n 's/.*"virtual-size": *\([0-9]*\).*/\1/p' | head -1)
    if [ -n "$vsize" ] && [ "$vsize" -gt $((DISK_GB * 1073741824)) ]; then
      die "--disk ${DISK_GB} GB is smaller than the image ($((vsize / 1073741824)) GB); use a larger size"
    fi
  fi
  if [ "${DISK_OVERLAY:-0}" = 1 ]; then
    # Copy-on-write overlay: instant to create, and the disk holds only this
    # VM's writes. The base stays read-only and shared; alpine_prune_cache will
    # not delete a base an overlay still references. (Export flattens the
    # overlay into a standalone image so a moved VM stays portable.)
    log "Creating a copy-on-write overlay on $(basename "$img"), sized to ${DISK_GB} GB"
    prun qemu-img create -q -f qcow2 -F qcow2 -b "$img" "$disk" >/dev/null
    prun qemu-img resize -q "$disk" "${DISK_GB}G"
  else
    log "Copying the image to $disk and growing it to ${DISK_GB} GB"
    prun qemu-img convert -O qcow2 "$img" "$disk"
    prun qemu-img resize -q "$disk" "${DISK_GB}G"
  fi
}

# image_base_in_use BASE -> 0 if any VM overlay still has BASE as its backing
# file. Overlays only live in the qemu backend's pool, so scan there (both the
# active pool and the default, to cover a libvirt run that must not prune a
# base the qemu VMs depend on).
image_base_in_use() {
  local base=$1 dir d bf
  for dir in "${POOL_DIR:-}/vms" "${XDG_DATA_HOME:-$HOME/.local/share}/agentcage/vms"; do
    [ -d "$dir" ] || continue
    for d in "$dir"/*/disk.qcow2; do
      [ -e "$d" ] || continue
      bf=$(qemu-img info --output=json "$d" 2>/dev/null \
           | sed -n 's/.*"backing-filename": *"\([^"]*\)".*/\1/p' | head -1)
      [ "$bf" = "$base" ] && return 0
    done
  done
  return 1
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
    cloudinit_userdata "$key" | sed 's/^/    | /' >&2
    run make_iso "<seed dir>" "$dest"
    return
  fi
  [ -f "$pub" ] || die "SSH public key not found: $pub"
  key=$(head -1 "$pub")
  [[ "$key" =~ ^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.+/=\ _:-]+$ ]] || die "$pub does not look like a single-line SSH public key"
  tmp=$(mktemp -d)
  mkdir "$tmp/seed"
  cloudinit_userdata "$key" >"$tmp/seed/user-data"
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$VM" "$(date +%s)" "$VM" >"$tmp/seed/meta-data"
  make_iso "$tmp/seed" "$tmp/seed.iso" || { rm -rf "$tmp"; die "Could not build the seed ISO"; }
  prun install -m 0644 "$tmp/seed.iso" "$dest"
  rm -rf "$tmp"
  log "First-boot config written to $dest (your public key${GUEST_PW_HASH:+ and a password hash}; no plain secrets)"
}
