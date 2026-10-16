# agentcage

Run a coding agent in a disposable, locked-down VM instead of on your own
machine.

agentcage (command: `acage`) downloads Alpine Linux's official cloud image,
verifies it, and boots a hardened VM from it. On first boot the VM creates a
user with your SSH key, gives that user root through `doas`, and installs
`git`, `vim`, Node.js and the agent harness(es) you pick:

| Harness | Installs | Logs in with |
|---|---|---|
| `pi` (default) | [Pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) | Anthropic API key |
| `claude-code` | [Claude Code](https://www.npmjs.com/package/@anthropic-ai/claude-code) | Claude account or Anthropic API key |
| `codex` | [Codex CLI](https://www.npmjs.com/package/@openai/codex) | ChatGPT account or OpenAI API key |

The agent runs on its own kernel and can do whatever it likes inside the VM.
It can't see your files (unless you share a folder), your clipboard, your USB
devices or your SSH agent.

## Install

You need a Linux host with KVM. The default libvirt backend runs x86_64 VMs.

From a checkout, run `./acage` directly, or install it:

```bash
sudo make install                 # /usr/local/bin/acage
```

Then install the host dependencies:

**Arch**

```bash
sudo pacman -S libvirt qemu-base edk2-ovmf dnsmasq libisoburn perl curl gnupg openssh
sudo pacman -S virtiofsd          # only for --share
sudo systemctl enable --now libvirtd
sudo virsh net-start default && sudo virsh net-autostart default
```

**Ubuntu / Debian**

```bash
sudo apt install libvirt-daemon-system qemu-system-x86 qemu-utils ovmf xorriso perl curl gnupg openssh-client
sudo apt install virtiofsd        # only for --share (Ubuntu 24.04+; older releases ship it in qemu-system-common)
```

Ubuntu starts libvirt and its `default` network for you.

**Without libvirt** (`--backend qemu`), you only need QEMU, UEFI firmware
(`edk2-ovmf` / `ovmf`), `xorriso`, `curl`, `gnupg` and `openssh`, and your user
must be able to use `/dev/kvm` (usually by being in the `kvm` group).

## Quick start

```bash
acage install mybox --harness claude-code
```

This downloads and verifies the image, creates the VM, waits for first boot to
finish, checks that the agent runs, and then:

1. adds a `Host mybox` entry to `~/.ssh/config`
2. offers to store an API key for each harness inside the VM (it goes over
   SSH; nothing is written to disk on the host)
3. offers to generate a GitHub deploy key inside the VM and prints the public
   half for you to add to your repo
4. offers to connect

After that:

```bash
acage ssh mybox
```

Any setting you don't pass as an option is asked for interactively. When
`acage` isn't run from a terminal (piped or scripted), it uses the options
and defaults without asking, and skips the API-key, deploy-key and connect
steps.

## Commands

| Command | What it does |
|---|---|
| `install [NAME]` | `image`, then `create` |
| `image` | Download the latest Alpine cloud image and verify it |
| `create [NAME]` | Create and boot a VM from the downloaded image |
| `ssh NAME [-- CMD]` | Connect to a VM, or run `CMD` in it |
| `start NAME` / `stop NAME` | Start or shut down a VM |
| `console NAME` | Serial console (libvirt) or boot output (`--backend qemu`) |
| `list` | List the VMs agentcage created |
| `delete NAME` | Delete a VM, its disk and its SSH config entry |

Run `image` again whenever you want a newer Alpine release. VMs you've
already created aren't affected.

## Options

| Option | Default | |
|---|---|---|
| `--name NAME` | `agentcage` | VM name; also its hostname and SSH alias. Can be given as `NAME` after the command instead |
| `--user NAME` | your username | User to create in the VM |
| `--harness LIST` | `pi` | `pi`, `claude-code`, `codex`, comma-separated, or `none` |
| `--share DIR` | none | Share a host folder at `~/shared` in the VM, created if missing ([read this first](#shared-folder)) |
| `--password` | off | Set a password for the guest user ([see below](#root-inside-the-vm)) |
| `--no-doas` | off | Don't give the guest user root |
| `--ram MB` | `2048` | At least 512 |
| `--vcpus N` | `2` | |
| `--disk GB` | `10` | The image is grown to this size |
| `--ssh-pubkey FILE` | `~/.ssh/id_agentcage.pub` | Key to authorize; the default is generated if missing |
| `--no-wait` | off | Start the VM and return without waiting for first boot |
| `--backend NAME` | `libvirt` | `qemu` runs QEMU directly, without libvirt. Also settable with `AGENTCAGE_BACKEND` |
| `--pool-dir DIR` | [see below](#where-things-are-kept) | Where images and disks are kept; remembered for later commands |
| `-y`, `--yes` | off | Skip confirmations: image key fingerprint, shared-folder warning, delete |
| `-n`, `--dry-run` | off | Print what would change instead of doing it |
| `-h`, `--help` / `--version` | | |

## Root inside the VM

The guest user gets root through `doas`:

```sh
doas apk add neovim
```

- **Default:** the account has no password, so `doas` doesn't ask for one.
- **`--password`:** you type a password on the host. Only its SHA-512 hash goes
  into the VM. `doas` then asks for it (and remembers it for a few minutes),
  and it also works for console login and `su`.
- **`--no-doas`:** the user has no way to become root.

SSH login is key-only in every case, and direct root login is disabled.

## Shared folder

`--share DIR` makes `DIR` on your computer appear as `~/shared` in the VM,
read-write, on both sides at once. When you're asked interactively, the
suggested folder is `/mnt/acage-shared/NAME`. A folder that doesn't exist yet
is created, owned by you, after you've confirmed the warning below (using
`sudo` under `/mnt`). The guest user gets the same uid as you, so files have
the same owner on both sides.

It's convenient for working on a repo with an agent, but **it weakens the
isolation agentcage exists to provide**:

- The agent can read, change and delete everything in the folder: subfolders,
  hidden files, `.git`, and any `.env`, key or token files.
- Whatever it writes there ends up on your computer. Code the agent wrote runs
  **outside** the VM as soon as you run, build, test or install it on the host:
  scripts, binaries, Makefiles, `package.json` scripts, `.git/hooks`, editor
  and direnv config. Review changes before you do any of that.
- **libvirt:** the folder is served by a root process on the host
  (virtiofsd). Root in the VM can therefore create root-owned files in it,
  including setuid programs. Use `--no-doas` if the agent doesn't need root.
  With `--backend qemu`, QEMU runs as your user, so files are always created
  as you.
- Commit and push anything you can't afford to lose first: the agent can
  rewrite or delete Git history too.

acage prints this warning and asks you to type `share` before creating the
VM (`--yes` skips the question). It refuses to share `/`, your home folder
(or anything containing it), and credential folders such as `~/.ssh`,
`~/.gnupg`, `~/.aws` and `~/.kube`.

The safer way to move code in and out is Git: give the VM a deploy key and
push and pull through a remote.

## Image verification

Before an image is used, `image`:

1. checks it against the SHA-512 checksum Alpine publishes alongside it
2. checks Alpine's GPG signature on it in a temporary keyring (your own
   keyring isn't touched, and no keyserver is involved). The signature must
   be made by the key in `share/image-signing.asc`, fingerprint
   `F26A DFAD BAE7 02EF 7AF6 3745 9DA7 EF23 BFFC DF22`
3. shows you that fingerprint and asks you to compare it with the one
   published at <https://alpinelinux.org/cloud/> (skip with `--yes`)

If any step fails, the download is discarded.

## Hardening and networking

**libvirt.** The VM template (`share/domain.xml`) has no shared
memory (unless you share a folder), no clipboard or guest-agent channel, no
audio, no USB controller and no VMware backdoor port, and its display doesn't
listen on the network. The VM sits on libvirt's `default` NAT network, so it
can reach the internet, your LAN, and services listening on the host's
`virbr0` address.

**`--backend qemu`.** QEMU runs as your user with no display, audio or USB
devices. Networking is QEMU's user-mode NAT; SSH reaches the VM through a port
on `127.0.0.1` only. The VM can reach the internet and your LAN, and **it can
reach services listening on your host's localhost** through the address
`10.0.2.2`. Don't run anything sensitive on localhost without authentication
while a VM is up.

**Both.** The generated SSH config entry sets `ForwardAgent no` and
`ForwardX11 no`, so your SSH agent and display never reach the VM. Alpine's
unused default `alpine` account is removed on first boot, so your user is the
only login.

## Where things are kept

| | libvirt | `--backend qemu` |
|---|---|---|
| Images and disks | `/var/lib/libvirt/images/agentcage`, or `/home/agentcage` when `/` is a smaller, separate partition (root-only) | `~/.local/share/agentcage` |
| SSH key | `~/.ssh/id_agentcage` | same |
| SSH config | fenced `# agentcage:begin NAME` block in `~/.ssh/config` | same |
| Settings | `~/.config/agentcage/config` | same |

Inside the VM, API keys are stored readable only by your user: Pi's in
`~/.pi/agent/auth.json`, Claude Code's in `~/.config/agentcage/env`, and
Codex's by `codex login` in `~/.codex`.

`acage ssh NAME` always looks up the VM's current address. Plain
`ssh NAME` uses the address saved when the VM was created, which on libvirt
can change after the VM restarts.

### Disk space

A VM disk starts at about 200 MB but can grow to its full `--disk` size, so
before downloading or creating anything acage checks that the folder's
filesystem has that much free. If the folder is on your root filesystem, it
also insists on 5 GB staying free for the system, because a full `/` breaks
updates, logging and more.

When you choose a folder (with `--pool-dir` or at the prompt), acage saves it
in `~/.config/agentcage/config`, and later commands use it. With libvirt the
folder can't be inside your home folder, because VMs run as a separate system
user that can't enter it. A folder such as `/home/agentcage` works. On
Fedora and other SELinux systems, label a folder outside
`/var/lib/libvirt/images` first (acage prints the command).

## Troubleshooting

- **"Not enough disk space".** Pick a folder on a bigger filesystem with
  `--pool-dir`, or use a smaller `--disk`.
- **"No access to /dev/kvm"** (`--backend qemu`). Add yourself to the `kvm`
  group and log in again.
- **The first boot seems slow.** Installing packages and agents takes a few
  minutes. Inside the VM, `cloud-init status --wait` blocks until it's done,
  and `/var/log/cloud-init-output.log` shows what happened.
- **SSH refuses your key.** First-boot setup probably failed. Look at the boot
  output: `acage console NAME`.
- **`doas: Operation not permitted`.** The VM was created with `--no-doas`, or
  by an older version of agentcage. Recreate it.

## Packaging

`make install PREFIX=/usr DESTDIR="$pkgdir"` installs the command to
`bin/`, the scripts to `lib/agentcage/` and the data files to
`share/agentcage/`. The command finds them relative to itself, so any prefix
works. `make uninstall` removes them again, and `make check` runs `bash -n`
and shellcheck.

## Files

| File | Purpose |
|---|---|
| `acage` | The command: options, prompts, and dispatch to the backend |
| `lib/backend-libvirt.sh` | Default backend: libvirt VMs from `share/domain.xml` |
| `lib/backend-qemu.sh` | `--backend qemu`: QEMU run directly as your user, with KVM |
| `lib/pool.sh` | Where images and disks go, free-space checks, saved settings |
| `lib/alpine.sh` | Alpine specifics: image download, packages, signing key |
| `lib/image.sh` | Signature checks, disk preparation, cloud-init config and seed ISO |
| `lib/harness.sh` | Agent harnesses: packages, install, API key handling |
| `lib/share.sh` | Shared folder: checks, warning, guest mount |
| `lib/provision.sh` | After boot: wait for SSH and cloud-init, SSH config, keys |
| `lib/common.sh` | Shared helpers (logging, dry-run, prompts) |
| `share/domain.xml` | libvirt VM template |
| `share/image-signing.asc` | Alpine's cloud-image signing key |
| `Makefile` | `install`, `uninstall`, `check` |

## License

MIT; see [LICENSE](LICENSE).
