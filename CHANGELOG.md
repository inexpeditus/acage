# Changelog

All notable changes to agentcage are listed here. Versions follow
[semantic versioning](https://semver.org/); until 1.0.0, minor versions may
change behaviour.

## [Unreleased]

First release, planned as 0.1.0.

### Added

- `acage` command: `install`, `image`, `create`, `ssh`, `start`, `stop`,
  `console`, `list` and `delete`.
- Alpine Linux VMs from the official cloud image, verified by SHA-512
  checksum and Alpine's pinned GPG signing key.
- Agent harnesses: Pi, Claude Code and Codex (`--harness`), with API keys
  stored in the VM over SSH.
- Root in the VM through `doas`, optionally behind a password
  (`--password`), or none at all (`--no-doas`).
- libvirt backend with a hardened domain template, and a `qemu` backend
  that runs QEMU directly without libvirt.
- Optional shared folder (`--share`) with a confirmation warning, refusal
  of home and credential folders, and matching uids on both sides.
- Free-space checks before anything is created, a 5 GB reserve on the root
  filesystem, and a remembered pool folder that defaults to
  `/home/agentcage` when `/` is the smaller partition.
- Generated `~/.ssh/config` entries, removed again by `delete`.
- `make install` / `uninstall`, the `acage(1)` man page, a test suite
  (`make test`) and CI.
