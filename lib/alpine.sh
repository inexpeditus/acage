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

alpine_image_shell()         { echo /bin/ash; }   # bash is not installed by default
alpine_base_packages()       { echo "git openssh nodejs npm vim"; }
alpine_doas_packages()       { echo doas; }
alpine_image_cloudinit_extra() { echo "package_update: true"; }

# alpine_latest_image_name ARCH < index.html -> newest matching image file name.
alpine_latest_image_name() {
  grep -oE "generic_alpine-[0-9]+\.[0-9]+\.[0-9]+-$1-uefi-cloudinit-r[0-9]+\.qcow2" \
    | sort -uV | tail -1
}

# Images are cached under their own versioned Alpine file name, so a new
# release lands beside the old one and the version is visible in the name.
# alpine_cached_image ARCH -> newest cached image for ARCH, or nothing.
alpine_cached_image() {
  # The leading '|| true' keeps an empty cache from tripping set -o pipefail.
  { ls -1 "$IMAGE_CACHE"/generic_alpine-*-"$1"-uefi-cloudinit-r*.qcow2 2>/dev/null || true; } | sort -V | tail -1
}

# alpine_harness_tag HARNESS_CSV -> the harness set, deduped and sorted, joined
# with '+', or 'none'. Used to name a golden image for exactly that set.
alpine_harness_tag() {
  local t
  t=$(printf '%s\n' "${1//,/ }" | tr ' ' '\n' | awk 'NF' | sort -u | paste -sd+ -)
  printf '%s' "${t:-none}"
}

# alpine_golden_name ARCH HARNESS_CSV -> the golden-image path for the cached
# base of ARCH plus this harness set, or nothing if no base is cached. A golden
# image is a flattened base with the packages and harness(es) pre-installed, so
# a create from it skips the apk/npm work (see 'acage bake').
alpine_golden_name() {
  local base stem
  base=$(alpine_cached_image "$1"); [ -n "$base" ] || return 0
  stem=$(basename "$base" .qcow2)
  echo "$IMAGE_CACHE/golden-${stem}__$(alpine_harness_tag "$2").qcow2"
}

# alpine_cached_golden ARCH HARNESS_CSV -> the golden-image path if it exists.
alpine_cached_golden() {
  local g; g=$(alpine_golden_name "$1" "$2") || return 0
  [ -n "$g" ] && [ -f "$g" ] && echo "$g"
}

# alpine_prune_cache ARCH KEEP -> deletes cached images for ARCH other than KEEP.
alpine_prune_cache() {
  local arch=$1 keep=$2 f
  for f in "$IMAGE_CACHE"/generic_alpine-*-"$arch"-uefi-cloudinit-r*.qcow2; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "$keep" ] && continue
    if image_base_in_use "$f"; then
      log "Keeping $(basename "$f"): a VM still overlays it"
    else
      rm -f "$f" && log "Removed the older cached image $(basename "$f")"
    fi
  done
}

# alpine_image_ensure ARCH -> makes sure the latest Alpine image is cached,
# downloading and verifying it only when a newer one is published. Prints the
# cached path on stdout. Falls back to the newest cached image when Alpine
# can't be reached. The cache is $IMAGE_CACHE, owned by you (no sudo).
alpine_image_ensure() {
  local arch=$1 tmp name cached want got
  if dry; then
    run curl -fsSL "$ALPINE_IMAGE_BASE/ (pick the newest generic_alpine-*-$arch-uefi-cloudinit-r*.qcow2)"
    echo "(dry-run) would reuse it from $IMAGE_CACHE if already there, else download and verify it" >&2
    echo "$IMAGE_CACHE/generic_alpine-<latest>-$arch-uefi-cloudinit-r0.qcow2"
    return
  fi
  need curl; need gpg
  mkdir -p "$IMAGE_CACHE"
  tmp=$IMG_TMP
  log "Resolving the latest Alpine UEFI cloud image ($arch)"
  if ! curl -fsSL --max-time 30 -o "$tmp/index.html" "$ALPINE_IMAGE_BASE/"; then
    cached=$(alpine_cached_image "$arch")
    [ -n "$cached" ] || die "Could not fetch Alpine's image list, and no image is cached"
    warn "Could not reach Alpine; using the cached image $(basename "$cached")"
    echo "$cached"; return
  fi
  name=$(alpine_latest_image_name "$arch" <"$tmp/index.html")
  [[ "$name" =~ ^generic_alpine-[0-9]+\.[0-9]+\.[0-9]+-$arch-uefi-cloudinit-r[0-9]+\.qcow2$ ]] \
    || die "Could not determine the Alpine image name (got '$name')"
  if [ -e "$IMAGE_CACHE/$name" ]; then
    log "$name is already downloaded and verified"
    echo "$IMAGE_CACHE/$name"; return
  fi
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
  # Move into place only once fully verified, so a cached file is always good.
  install -m 0644 "$tmp/img" "$IMAGE_CACHE/$name"
  log "Verified image cached at $IMAGE_CACHE/$name"
  alpine_prune_cache "$arch" "$name"
  echo "$IMAGE_CACHE/$name"
}
