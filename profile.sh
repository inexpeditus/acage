#!/usr/bin/env bash
# Alpine-specific pieces of the preinstalled-image method. Private copy of the
# image_* functions in ../guests/alpine/profile.sh. Sourced by create.sh.
#
# Alpine's official UEFI "cloudinit" qcow2 (a ready-made disk; no cloud provider
# involved). Signed by Alpine's cloud-image key, whose fingerprint is published at
# https://alpinelinux.org/cloud/ and which ships alongside this file as
# image-signing.asc.

ALPINE_IMAGE_BASE=https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud
ALPINE_IMAGE_KEY_FPR=F26ADFADBAE702EF7AF637459DA7EF23BFFCDF22   # Tomalok, Alpine cloud images
ALPINE_IMAGE_KEY_URL=https://alpinelinux.org/cloud/

alpine_image_file()          { echo "alpine-cloudimg.qcow2"; }
alpine_image_est_gb()        { echo 1; }
alpine_image_shell()         { echo /bin/ash; }   # bash is not installed by default
alpine_image_packages()      { echo "git openssh nodejs npm"; }
alpine_image_doas_packages() { echo doas; }
alpine_image_cloudinit_extra() { echo "package_update: true"; }

# Download, verify and install the latest Alpine UEFI cloud image at $POOL_DIR/$(alpine_image_file).
alpine_image_fetch() {
  local dest tmp name want got
  dest="$POOL_DIR/$(alpine_image_file)"
  if dry; then
    run curl -fsSL "$ALPINE_IMAGE_BASE/ (pick the newest generic_alpine-*-x86_64-uefi-cloudinit-r*.qcow2)"
    run curl -fL -o "$dest" "$ALPINE_IMAGE_BASE/<image>.qcow2"
    run curl -fsSL "$ALPINE_IMAGE_BASE/<image>.qcow2.{asc,sha512}"
    run gpg "(throwaway keyring) import image-signing.asc; verify .asc against $ALPINE_IMAGE_KEY_FPR"
    image_dry_run_note "$dest"
    return
  fi
  tmp=$IMG_TMP
  log "Resolving the latest Alpine UEFI cloud image"
  curl -fsSL --max-time 30 -o "$tmp/index.html" "$ALPINE_IMAGE_BASE/" || die "Could not fetch Alpine's image list"
  name=$(grep -oE 'generic_alpine-[0-9][0-9.]*-x86_64-uefi-cloudinit-r[0-9]+\.qcow2' "$tmp/index.html" | sort -uV | tail -1)
  [[ "$name" =~ ^generic_alpine-[0-9][0-9.]*-x86_64-uefi-cloudinit-r[0-9]+\.qcow2$ ]] \
    || die "Could not determine the Alpine image name (got '$name')"
  echo "Latest: $name"
  curl -fsSL --max-time 30 -o "$tmp/img.sha512" "$ALPINE_IMAGE_BASE/$name.sha512" || die "Could not fetch the checksum"
  curl -fsSL --max-time 30 -o "$tmp/img.asc" "$ALPINE_IMAGE_BASE/$name.asc" || die "Could not fetch the signature"
  want=$(awk '{print $1; exit}' "$tmp/img.sha512")
  [[ "$want" =~ ^[0-9a-f]{128}$ ]] || die "Unexpected checksum file format"

  log "Downloading $name"
  curl -fL --retry 3 -o "$tmp/img" "$ALPINE_IMAGE_BASE/$name" || die "Download failed"

  log "Verifying checksum and signature"
  got=$(sha512sum "$tmp/img" | awk '{print $1}')
  [ "$got" = "$want" ] || die "SHA-512 mismatch; the download was discarded"
  image_verify_signature "$ALPINE_IMAGE_KEY_FPR" "$DIR/image-signing.asc" "$tmp/img.asc" "$tmp/img" \
    || die "Signature verification FAILED; the download was discarded"
  image_confirm_key "Alpine (cloud images)" "$ALPINE_IMAGE_KEY_FPR" "$ALPINE_IMAGE_KEY_URL" || die "Aborted; the download was discarded"
  image_accept "$tmp/img" "$dest"
}
