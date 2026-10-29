## Disposable virtual machines for agentic AI

- Shares no kernel
- Least privilege approach
- Automated networking configuration
- Yada yada

There's a lot of user-friendly stuff. I'll try to jot it down asap but in the meantime see man pages.

`$ acage create`

1. Check host tools.
2. Download + GPG-verify the Alpine image (reuse if cached).
3. Make the VM disk (copy-on-write overlay on the base - or on the golden, if you ran [_acage bake_](#acage-bake)).
4. Build the cloud-init seed _(prepares first-boot instructions (accounts, SSH key, firewall, packages and harness))_
5. Virtually a power button press
6. Cloud-init seed instructions run: creates agent + user, sets hostname, applies nftables firewall (blocks LAN + host, allows internet), packages + harness dl and install, and lastly mounts any [share](#shared-folders).
7. Wait for SSH + cloud-init to finish - get an IP (libvirt), ~10-40 s (a window for container reconsideration).
8. Add a ~/.ssh/config entry and record the host key. Yes.
9. (interactive) store API keys, offer a deploy key, done.

Lightweight alpine distro _~193 MB DL, ~0.7 GB post-install (including packages git, nodejs, npm, vim, doas, nftables, acl and claude-code)_. Tmux coming

`$ acage quick` or `$ acage quick --backend libvirt`
Runs the install with default answers to every prompt - no interaction, like the example below.

  <img width="800" height="450" alt="final_2" src="https://github.com/user-attachments/assets/281efb99-ac51-4c52-be6b-190839845442" />

## acage bake

`$ acage bake` provisions a VM once, installs the packages and your harness, strips its identity, and flattens the result into a reusable **golden image** (a ready-made master copy). After that, every `acage create` for the same harness builds on the golden instead of installing from scratch - so new cages cost only ~17 MB (qemu backend; libvirt copies the golden), skip the apk/npm step, and build ~15 s faster. Alpine would hardly notice. Still, avoiding mirror abuse is a respectable practice.

## Shared folders

Opt-in: mounts one of your host folders into the cage at `~/shared`. Convenient, but it **weakens isolation** - the agent can then read and write that real folder on your machine. I'm unsure what this means in terms of hypothetical surface area expansion for any malicious agent. Any prompt is experimental at this point but this is likely a tarp for humans. Thus, see [`acage push`](#acage-push)

## acage push

$ acage push <path> copy files/dirs from host into the cage (the agent's home by default; --to DIR for a subpath, --user to target your account instead). One-way: tar piped over the existing SSH connection - no mount, no write-back. It won't follow symlinks, refuses your home and credential dirs (.ssh, .gnupg, .aws…). Prompts for confirmation on suspected secrets _(filenames - NOT file-content)_. Use -y to bypass.

## Summary by bot

**Isolation**

- Full VM, own kernel (KVM) - not a shared-kernel container
- Two accounts: agent (no root) + you (doas); the agent can't use your doas or kill the firewall
- Disposable - delete the cage, damage's gone
- One-way owner access: you can read/write the agent's files; it can't touch yours (ACL)

**Hardening**

- GPG-signature-verified Alpine image (supply-chain)
- cloud-init pulled from the boot path after setup
- key-only SSH, no root, no passwords
- golden/clones get unique host keys + machine-id

**Networking**

- Firewalled: no LAN, host, or cloud-metadata (169.254) - internet only; `--allow-lan` to opt out
- the firewall is root-only to change, and the agent has no root

**Getting files in/out**

- `acage push`: one-way copy, refuses home/credential dirs, won't follow symlinks, confirms on secret filenames
- credentials never enter the cage - a fresh in-VM deploy key is generated instead
- opt-in `--share` (virtiofs/9p) with an isolation warning

**Ergonomics**

- Press play - `acage quick`: one command, zero prompts, drops you into the agent
- `acage work` - tmux split: agent | you
- `--agent-md` - seed a CLAUDE.md / AGENTS.md
- `--autostart`, harness choice (claude-code/pi/codex/none)
- auto `~/.ssh/config` entry (plain `ssh <name>` works), refreshed on IP change
- deps: reports all missing host tools at once with one apt/pacman line, never auto-installs
- `-n` dry-run, `-v` verbose, bash + zsh completion, man page

**Performance** _(approx, qemu backend)_

- Init boot (first install): ~46 s
- Consecutive installs (cached golden): ~31 s
- Warm start: ~6 s
- `acage bake` golden images - ~15 s faster builds, ~17 MB per cage
- trimmed boot: cloud-init off the runlevels, skipped ARP probe, parallel OpenRC

**Backends / housekeeping**

- two backends: libvirt (AppArmor/sVirt-confined) + qemu (rootless, no daemon)
- copy-on-write overlays on a shared, verified base (auto-pruned, never while in use)
- `acage uninstall` wipes everything on both backends and prints a package-removal hint (never removes packages itself)
