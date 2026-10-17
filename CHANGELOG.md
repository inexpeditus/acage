# Changelog

All notable changes to agentcage are listed here. Versions follow
[semantic versioning](https://semver.org/); until 1.0.0, minor versions may
change behaviour.

## [Unreleased]

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
