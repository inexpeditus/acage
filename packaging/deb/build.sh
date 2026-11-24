#!/usr/bin/env bash
# Builds acage_VERSION_ARCH.deb, so that 'sudo apt install ./acage_*.deb'
# installs acage and the host tools it needs in one go (Debian, Ubuntu,
# Raspberry Pi OS). acage itself never installs packages; the package manager
# does, from the Depends below.
#
#   packaging/deb/build.sh [ARCH] [OUTDIR]
#
# ARCH is amd64 or arm64 (default: this machine's), since QEMU and the UEFI
# firmware come in different packages per architecture. Needs only tar and ar
# (dpkg-deb is used when present).
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
arch=${1:-$(dpkg --print-architecture 2>/dev/null || uname -m)}
out=$(cd "${2:-$root}" && pwd)
case "$arch" in
  amd64|x86_64)  arch=amd64; qemu="qemu-system-x86, ovmf" ;;
  arm64|aarch64) arch=arm64; qemu="qemu-system-arm, qemu-efi-aarch64" ;;
  *) echo "error: unsupported architecture '$arch' (amd64 or arm64)" >&2; exit 1 ;;
esac
version=$(sed -n 's/^VERSION=//p' "$root/acage")
[ -n "$version" ] || { echo "error: no VERSION= in acage" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pkg=$work/pkg
make -s -C "$root" install PREFIX=/usr DESTDIR="$pkg" >/dev/null

mkdir -p "$pkg/DEBIAN"
# Depends: what every cage needs (the qemu backend, which 'acage quick' and
# project mode use). Recommends: git for project mode and netcat for a clean
# qemu shutdown. Suggests: the libvirt backend and the optional extras.
cat >"$pkg/DEBIAN/control" <<EOF
Package: acage
Version: $version
Architecture: $arch
Maintainer: inexpeditus <inexpeditus@users.noreply.github.com>
Section: utils
Priority: optional
Homepage: https://github.com/inexpeditus/acage
Installed-Size: $(du -sk "$pkg" | cut -f1)
Depends: bash, coreutils, util-linux, curl, gnupg, openssh-client, xorriso, qemu-utils, $qemu
Recommends: git, netcat-openbsd
Suggests: libvirt-daemon-system, libvirt-clients, perl, sudo, openssl, tmux, wl-clipboard, xclip, libnotify-bin
Description: run AI coding agents in disposable, hardened Alpine VMs
 acage boots a coding agent (Claude Code, Codex or Pi) in its own Alpine
 Linux VM with its own kernel, a firewall that keeps it off your network,
 and no access to your files or credentials unless you hand them in.
EOF

deb=$out/acage_${version}_${arch}.deb
if command -v dpkg-deb >/dev/null; then
  dpkg-deb --root-owner-group --build "$pkg" "$deb" >/dev/null
else
  # The same format by hand: an ar archive of debian-binary, control and data.
  (cd "$pkg/DEBIAN" && tar --owner=0 --group=0 -czf "$work/control.tar.gz" ./*)
  (cd "$pkg" && tar --owner=0 --group=0 --exclude=./DEBIAN -czf "$work/data.tar.gz" .)
  echo 2.0 >"$work/debian-binary"
  rm -f "$deb"
  (cd "$work" && ar rc "$deb" debian-binary control.tar.gz data.tar.gz)
fi
echo "$deb"
