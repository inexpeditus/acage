#!/usr/bin/env bash
# Image cache (lib/alpine.sh): newest-wins, pruning, and the dry run.

mk_cached() { mkdir -p "$IMAGE_CACHE"; : >"$IMAGE_CACHE/generic_alpine-$1-$2-uefi-cloudinit-r$3.qcow2"; }

test_cached_image_empty() {
  load_libs
  assert_eq "$(alpine_cached_image x86_64)" ""
}

test_cached_image_picks_newest_version() {
  load_libs
  mk_cached 3.21.0 x86_64 0
  mk_cached 3.24.1 x86_64 0
  mk_cached 3.24.10 x86_64 0
  mk_cached 3.9.2 x86_64 1
  mk_cached 3.24.1 aarch64 0   # other arch, ignored
  assert_eq "$(basename "$(alpine_cached_image x86_64)")" generic_alpine-3.24.10-x86_64-uefi-cloudinit-r0.qcow2
  assert_eq "$(basename "$(alpine_cached_image aarch64)")" generic_alpine-3.24.1-aarch64-uefi-cloudinit-r0.qcow2
}

test_prune_keeps_only_the_named_image() {
  load_libs
  mk_cached 3.24.1 x86_64 0
  mk_cached 3.24.10 x86_64 0
  mk_cached 3.24.1 aarch64 0
  alpine_prune_cache x86_64 generic_alpine-3.24.10-x86_64-uefi-cloudinit-r0.qcow2 >/dev/null
  [ -e "$IMAGE_CACHE/generic_alpine-3.24.10-x86_64-uefi-cloudinit-r0.qcow2" ] || fail "kept image was deleted"
  [ ! -e "$IMAGE_CACHE/generic_alpine-3.24.1-x86_64-uefi-cloudinit-r0.qcow2" ] || fail "older image not pruned"
  # Another architecture is left alone.
  [ -e "$IMAGE_CACHE/generic_alpine-3.24.1-aarch64-uefi-cloudinit-r0.qcow2" ] || fail "pruned another arch"
}

test_prepare_disk_needs_a_cached_image() {
  load_libs qemu
  assert_fails "No Alpine image is cached" image_prepare_disk "$TMP/disk.qcow2"
}

test_image_dry_run_downloads_nothing() {
  acage_run image -n --backend qemu --pool-dir "$POOL"
  assert_rc 0
  assert_out "would reuse it from"
  [ ! -e "$XDG_CACHE_HOME/agentcage/images" ] || fail "dry run created the cache"
}
