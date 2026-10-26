# Changelog

All notable changes to agentcage are listed here. Versions follow
[semantic versioning](https://semver.org/); until 1.0.0, minor versions may
change behaviour.

## [Unreleased]

### Added

- `-v`/`--verbose`: print each command acage runs, and show cloud-init's
  progress and the tail of its log during first boot instead of waiting
  silently.
- `acage uninstall`: removes every VM and all of acage's data (SSH key, config
  entries, host keys, image cache, settings and pool directory), then prints a
  reviewed command to remove the acage program and the host packages nothing
  else needs. It never removes packages itself.
- `install` and `create` check all required host tools up front and report
  every missing one at once, with a single `apt`/`pacman` install command,
  instead of failing one tool at a time.
- `acage bake`: pre-build a reusable "golden" image with the packages and the
  chosen harness already installed, so later `create`s for the same harness set
  skip the apk/npm work (about 15 seconds faster per VM). The bake provisions
  once in a throwaway VM, strips its per-instance identity (host keys,
  machine-id) so every cage stays unique, and `create` uses the golden image
  automatically when one is cached for that harness set.

### Changed

- `acage attach` now starts a stopped VM first instead of failing with "not
  running"; you just exit the machine when you're done.
- Your account in the VM now defaults to your host username without asking, so
  interactive `install`/`create` has one fewer question; `--user` still
  overrides it.
- The README is trimmed to an overview; the full command and option reference
  lives in `acage --help` and the `acage(1)` man page.
- Interactive `install`/`create` no longer asks whether to set an account
  password; it is a niche, hard-to-judge choice for a disposable VM, so it is
  left to the `--password` flag for those who want it.
- The qemu backend disables the emulated HPET timer, matching the libvirt
  backend: a slightly smaller device surface and fewer timer-driven VM exits.
- cloud-init is disabled after the first boot. It only has work to do once (at
  provision), so later boots skip it, which is faster and keeps a large
  root-privileged tool out of the steady-state boot path.
- VMs no longer sit on GRUB's boot menu (`GRUB_TIMEOUT=0`). The menu waited ten
  seconds for a keypress on a headless machine, which was about half the warm
  start; booting straight into Alpine cuts it to ~10 s.
- A qemu-backend VM's disk is now a copy-on-write overlay on the shared cached
  base image instead of a full copy: each VM holds only its own writes (~140 MB
  vs ~310 MB) and many VMs share one base. A cached base is never pruned while
  a VM still overlays it. (libvirt still uses a full copy.)
- Later boots are trimmed further, so a VM warm-starts in ~6 s instead of ~10 s
  (and ~21 s before any of this): after first boot cloud-init is removed from
  the runlevels (its Python stages no longer run every boot), the DHCP client
  skips the duplicate-address ARP probe that only times out on a NAT and IPv6
  DHCP is dropped, and OpenRC starts services in parallel.

### Security

- `acage` refuses to run as root, which would otherwise place your SSH key,
  settings and the VM login in root's home and undo the isolation.

### Fixed

- `attach`, `ssh` and `push` refresh the VM's saved `~/.ssh/config` address
  when it has changed (e.g. a new DHCP lease after a network reset), so plain
  `ssh <name>` keeps working too; they already connected to the current
  address themselves.
- The libvirt backend talks to the system connection unprivileged when you are
  in the `libvirt` group, falling back to `sudo` only when the daemon refuses,
  so `list`, `console` and status checks no longer prompt for a password on a
  normal desktop setup. `list` reads the disk's used size from libvirt instead
  of `du`, and prints the whole table at once so a `sudo` prompt (when one is
  still needed) can't split it.

## [0.2.0] - 2026-10-17

### Added

- Downloaded Alpine images are cached in `~/.cache/agentcage/images` and
  reused instead of re-downloaded; a newer release replaces the old one, and
  a cached image is used when Alpine is unreachable.
- An Arch Linux package (`packaging/arch/PKGBUILD`, package name `acage`).
- `make e2e`: an end-to-end test on a real VM, verified on both backends.

### Changed

- The README is shorter and gains a Security section; the full threat model
  and shared-folder detail stay in `SECURITY.md`.

### Note

- Upgrading from 0.1.0: the image moved from the pool directory to the cache,
  so the first `image`/`install` downloads once more. The old pool copy, if
  any, can be deleted by hand.

## [0.1.0] - 2026-10-16

First release.

### Added

- `acage` command: `install`, `image`, `create`, `ssh`, `start`, `stop`,
  `console`, `list` and `delete`.
- Alpine Linux VMs from the official cloud image, verified by SHA-512
  checksum and Alpine's pinned GPG signing key.
- Agent harnesses: Pi, Claude Code and Codex (`--harness`), with API keys
  stored in the VM over SSH.
- Two accounts in every VM: `agent`, which runs the AI and has no root, and
  yours, with root through `doas` (optionally behind a password with
  `--password`, or none with `--no-doas`). `acage attach` asks which one to
  log in as.
- A firewall in the VM: internet yes, local network and host no
  (`--allow-lan` to turn it off).
- libvirt backend with a hardened domain template, and a `qemu` backend
  that runs QEMU directly without libvirt.
- Optional shared folder (`--share`) with a confirmation warning, refusal
  of home and credential folders, and matching uids on both sides.
- Free-space checks before anything is created, a 5 GB reserve on the root
  filesystem, and a remembered pool folder that defaults to
  `/home/agentcage` when `/` is the smaller partition.
- `acage push` copies files and folders into a VM over SSH, refusing the
  home folder and credential folders and warning about likely secrets.
- Generated `~/.ssh/config` entries. `delete` lists what it will remove, asks
  first, and cleans up the VM, its SSH entry and host key, its settings, and
  (only on an explicit yes) a shared folder acage created.
- `make install` / `uninstall`, the `acage(1)` man page, a test suite
  (`make test`) and CI.

[Unreleased]: https://github.com/inexpeditus/acage/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/inexpeditus/acage/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/inexpeditus/acage/releases/tag/v0.1.0
