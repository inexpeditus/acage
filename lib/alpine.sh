#!/usr/bin/env bash
# Alpine-specific pieces: where the image comes from, how it is signed, and
# which packages the guest gets. Sourced by agentcage.
#
# Alpine's official UEFI "cloudinit" qcow2 is a ready-made disk (no cloud
# provider involved). It is signed by Alpine's cloud-image key, whose
# fingerprint is published at https://alpinelinux.org/cloud/ and which ships
# with agentcage as share/image-signing.asc.

ALPINE_IMAGE_BASE=https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud
ALPINE_IMAGE_KEY_FPR=F26ADFADBAE702EF7AF637459DA7EF23BFFCDF22   # Tomalok, Alpine cloud images
ALPINE_IMAGE_KEY_URL=https://alpinelinux.org/cloud/

alpine_image_file()          { echo "alpine-cloudimg-$1.qcow2"; }   # ARCH
alpine_image_shell()         { echo /bin/ash; }   # bash is not installed by default
alpine_base_packages()       { echo "git openssh nodejs npm vim"; }
alpine_doas_packages()       { echo doas; }
alpine_image_cloudinit_extra() { echo "package_update: true"; }

# alpine_latest_image_name ARCH < index.html -> newest matching image file name.
alpine_latest_image_name() {
  grep -oE "generic_alpine-[0-9]+\.[0-9]+\.[0-9]+-$1-uefi-cloudinit-r[0-9]+\.qcow2" \
    | sort -uV | tail -1
}

# alpine_image_fetch ARCH -> downloads, verifies and installs the latest Alpine
# UEFI cloud image for ARCH at $POOL_DIR/$(alpine_image_file ARCH).
alpine_image_fetch() {
  local arch=$1 dest tmp name want got
  dest="$POOL_DIR/$(alpine_image_file "$arch")"
  if dry; then
    run curl -fsSL "$ALPINE_IMAGE_BASE/ (pick the newest generic_alpine-*-$arch-uefi-cloudinit-r*.qcow2)"
    run curl -fL -o "$dest" "$ALPINE_IMAGE_BASE/<image>.qcow2"
    run curl -fsSL "$ALPINE_IMAGE_BASE/<image>.qcow2.{asc,sha512}"
    run gpg "(throwaway keyring) import image-signing.asc; verify .asc against $ALPINE_IMAGE_KEY_FPR"
    echo "(dry-run) would verify the signature and install the image at $dest" >&2
    return
  fi
  need curl; need gpg
  tmp=$IMG_TMP
  log "Resolving the latest Alpine UEFI cloud image ($arch)"
  curl -fsSL --max-time 30 -o "$tmp/index.html" "$ALPINE_IMAGE_BASE/" || die "Could not fetch Alpine's image list"
  name=$(alpine_latest_image_name "$arch" <"$tmp/index.html")
  [[ "$name" =~ ^generic_alpine-[0-9]+\.[0-9]+\.[0-9]+-$arch-uefi-cloudinit-r[0-9]+\.qcow2$ ]] \
    || die "Could not determine the Alpine image name (got '$name')"
  echo "Latest: $name" >&2
  curl -fsSL --max-time 30 -o "$tmp/img.sha512" "$ALPINE_IMAGE_BASE/$name.sha512" || die "Could not fetch the checksum"
  curl -fsSL --max-time 30 -o "$tmp/img.asc" "$ALPINE_IMAGE_BASE/$name.asc" || die "Could not fetch the signature"
  want=$(awk '{print $1; exit}' "$tmp/img.sha512")
  [[ "$want" =~ ^[0-9a-f]{128}$ ]] || die "Unexpected checksum file format"

  log "Downloading $name"
  curl -fL --retry 3 -o "$tmp/img" "$ALPINE_IMAGE_BASE/$name" || die "Download failed"

  log "Verifying checksum and signature"
  got=$(sha512_of "$tmp/img")
  [ "$got" = "$want" ] || die "SHA-512 mismatch; the download was discarded"
  image_verify_signature "$ALPINE_IMAGE_KEY_FPR" "$DATA_DIR/image-signing.asc" "$tmp/img.asc" "$tmp/img" \
    || die "Signature verification FAILED; the download was discarded"
  image_confirm_key "Alpine (cloud images)" "$ALPINE_IMAGE_KEY_FPR" "$ALPINE_IMAGE_KEY_URL" || die "Aborted; the download was discarded"
  pool_ensure
  prun install -m 0644 "$tmp/img" "$dest"
  log "Verified image: $dest"
}
