# agentcage

Run a coding agent in a disposable, locked-down VM instead of on your own
machine.

agentcage (command: `acage`) downloads Alpine Linux's official cloud image,
verifies it, and boots a hardened VM from it. On first boot the VM creates two
accounts that both accept your SSH key, `agent` for the AI (no root) and one
for you (root through `doas`), switches on a firewall that keeps the VM off
your local network, and installs `git`, `vim`, Node.js and the agent
harness(es) you pick:

| Harness | Installs | Logs in with |
|---|---|---|
| `pi` (default) | [Pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) | Anthropic API key |
| `claude-code` | [Claude Code](https://www.npmjs.com/package/@anthropic-ai/claude-code) | Claude account or Anthropic API key |
| `codex` | [Codex CLI](https://www.npmjs.com/package/@openai/codex) | ChatGPT account or OpenAI API key |

The agent runs on its own kernel, in its own account. It can't see your files
(unless you share a folder), your clipboard, your USB devices, your SSH agent,
your local network or the services on your machine, and it can't become root
in the VM to change that. [Security](#security) lists what's in place.

## Install

You need a Linux host with KVM. The default libvirt backend runs x86_64 VMs.

On Arch, build and install the package from
[`packaging/arch`](packaging/arch/PKGBUILD):

```bash
cd packaging/arch && makepkg -si
```

Elsewhere, run `./acage` from a checkout, or install it:

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
2. offers to store an API key for each harness in the `agent` account (it
   goes over SSH; nothing is written to disk on the host)
3. offers to generate a GitHub deploy key for the `agent` account and prints
   the public half for you to add to your repo
4. offers to connect

After that:

```bash
acage attach mybox
```

```
Attach to mybox as:
  1) agent  (runs the AI, no root)
  2) roy  (you, can use doas)
Choice [1]:
```

`--agent` or `--user` skips the question. Run the AI as `agent`, and install
software as yourself (`doas apk add …`). Plain `ssh mybox` logs in as `agent`,
and `ssh roy@mybox` as you.

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
| `attach NAME` | Log in, choosing the `agent` account or yours (`--agent` / `--user` to skip the question) |
| `push NAME PATH...` | Copy files or folders from your computer into the agent's home ([details](#moving-files-into-a-vm)) |
| `ssh NAME [-- CMD]` | Run `CMD` in a VM, as `agent` (or as you with `--user`) |
| `start NAME` / `stop NAME` | Start or shut down a VM |
| `console NAME` | Serial console (libvirt) or boot output (`--backend qemu`) |
| `list` | List the VMs agentcage created |
| `delete NAME` | Delete a VM and everything acage set up for it ([details](#deleting-a-vm)) |

Run `image` again whenever you want a newer Alpine release. VMs you've
already created aren't affected.

## Options

| Option | Default | |
|---|---|---|
| `--name NAME` | `agentcage` | VM name; also its hostname and SSH alias. Can be given as `NAME` after the command instead |
| `--user NAME` | your username | Your account in the VM (anything but `agent`) |
| `--harness LIST` | `pi` | `pi`, `claude-code`, `codex`, comma-separated, or `none` |
| `--share DIR` | none | Share a host folder at `~/shared` in the VM, created if missing ([read this first](#shared-folder)) |
| `--password` | off | Set a password for your account ([see below](#accounts-in-the-vm)) |
| `--no-doas` | off | Don't give your account root either |
| `--allow-lan` | off | Let the VM reach your local network and this host ([see below](#network)) |
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

## Accounts in the VM

| | `agent` | Your account (e.g. `roy`) |
|---|---|---|
| Runs | the AI | you |
| Root (`doas`) | never | yes, unless `--no-doas` |
| Holds | API keys, deploy key, `~/shared` | whatever you put there |
| Can see the other's home | no | no |

The agent can't run anything as you, so it can't use your `doas`, and without
root it can't switch off the VM's firewall or change the system. When it needs
a package, it has to ask you:

```sh
acage attach mybox --user
doas apk add neovim
```

- **Default:** your account has no password, so `doas` doesn't ask for one.
  That's safe because the agent has no way into your account.
- **`--password`:** you type a password on the host. Only its SHA-512 hash goes
  into the VM. `doas` then asks for it (and remembers it for a few minutes),
  and it also works for console login and `su`.
- **`--no-doas`:** nobody in the VM can become root.

SSH login is key-only for both accounts, and direct root login is disabled.

## Moving files into a VM

```bash
acage push mybox ~/projects/app notes.md          # into the agent's home
acage push mybox ~/projects/app --to work         # into ~/work
acage push mybox setup.sh --user                  # into your account instead
```

This is the safest way to get files into a VM. Your computer starts the
copy, data only flows into the VM, and it goes over the SSH connection acage
already uses, so there's no shared folder, no extra service, and the firewall
stays closed. Symlinks are copied as symlinks and never followed, so a link
can't pull in files from elsewhere on your computer.

Everything you push is readable by the agent. `push` refuses your home folder
and credential folders (`~/.ssh`, `~/.aws` and the like), and warns when what
you're pushing contains files that look like secrets (`.env`, private keys).

There's deliberately no way to copy files out of a VM. To get the agent's work
back, have it push to a Git remote with its deploy key, and review the
changes before you pull them.

## Shared folder

`--share DIR` makes `DIR` on your computer appear as `~/shared` in the VM,
read-write, on both sides at once. When you're asked interactively, the
suggested folder is `/mnt/acage-shared/NAME`. A folder that doesn't exist yet
is created, owned by you, after you've confirmed the warning below (using
`sudo` under `/mnt`). The folder belongs to the `agent` account, which gets the
same uid as you, so files have the same owner on both sides.

It's convenient for working on a repo with an agent, but **it weakens the
isolation agentcage exists to provide**:

- The agent can read, change and delete everything in the folder: subfolders,
  hidden files, `.git`, and any `.env`, key or token files.
- Whatever it writes there ends up on your computer. Code the agent wrote runs
  **outside** the VM as soon as you run, build, test or install it on the host:
  scripts, binaries, Makefiles, `package.json` scripts, `.git/hooks`, editor
  and direnv config. Review changes before you do any of that.
- **libvirt:** the folder is served by a root process on the host
  (virtiofsd), so root in the VM can create root-owned files in it, including
  setuid programs. The agent has no root, but your account does: use
  `--no-doas` if you don't need it. With `--backend qemu`, QEMU runs as your
  user, so files are always created as you.
- Commit and push anything you can't afford to lose first: the agent can
  rewrite or delete Git history too.

acage prints this warning and asks you to type `share` before creating the
VM (`--yes` skips the question). It refuses to share `/`, your home folder
(or anything containing it), and credential folders such as `~/.ssh`,
`~/.gnupg`, `~/.aws` and `~/.kube`.

The safer way to move files is [`acage push`](#moving-files-into-a-vm) to
get them in, and Git (with review) to get the agent's work back out.

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

## Security

agentcage is built to stop a careless, compromised or prompt-injected agent
from damaging or reading your computer. This section summarizes what it does;
[SECURITY.md](SECURITY.md) has the full threat model and how to report
problems.

### What's in place

- **Its own kernel.** The agent runs in a KVM virtual machine, not in a
  container sharing your kernel.
- **A verified image.** The Alpine image is checked against Alpine's SHA-512
  checksum and GPG signature, with the signing key pinned by fingerprint
  ([details](#image-verification)).
- **No root for the agent.** It runs in its own `agent` account without
  `doas`, can't use your account, and can't read your home folder in the VM
  ([details](#accounts-in-the-vm)).
- **Internet only.** A firewall in the VM keeps the agent off your local
  network and away from services on your machine ([details](#network)).
- **Nothing shared by default.** No folders, clipboard, USB, audio, guest
  agent, SSH agent or X11. Sharing a folder takes an explicit confirmation,
  and your home and credential folders are refused.
- **One-way file transfer.** `acage push` only copies into the VM, never
  follows symlinks, refuses credential folders and warns about likely
  secrets. Nothing copies files back out ([details](#moving-files-into-a-vm)).
- **Locked-down logins.** SSH is key-only for both accounts, root login is
  disabled, and Alpine's unused default account is removed.
- **A confined emulator.** With libvirt, QEMU runs as a separate system user
  (`libvirt-qemu` on Arch and Ubuntu, `qemu` on Fedora; check `user` in
  `/etc/libvirt/qemu.conf`), confined by AppArmor or SELinux where your
  distribution uses them.
- **Safe defaults for your system.** Free-space checks keep VM disks from
  filling your root partition, and `delete` asks before removing anything.

### Network

The VM can reach the internet (npm, apk, GitHub, AI APIs), but not your local
network or this host:

| From the VM to | |
|---|---|
| The internet | ✓ |
| DNS and DHCP | ✓ (needed to work at all) |
| Your SSH sessions into the VM | ✓ |
| Your LAN: router, NAS, printers, other computers | ✗ |
| Services on your machine (e.g. a local Ollama or database) | ✗ |

A firewall inside the VM ([`share/firewall.nft`](share/firewall.nft)) refuses
connections to private, link-local and multicast addresses. Only root in the
VM can change it, and the agent has no root. `--allow-lan` creates the VM
without it, if the agent needs something on your network.

### The VM itself

**libvirt.** The VM template (`share/domain.xml`) has no shared memory (unless
you share a folder), no clipboard or guest-agent channel, no audio, no USB
controller and no VMware backdoor port, and its display doesn't listen on the
network.

**`--backend qemu`.** QEMU runs as your user with no display, audio or USB
devices. SSH reaches the VM through a port on `127.0.0.1` only. QEMU maps your
host's localhost to `10.0.2.2` in the VM, which the firewall blocks (unless
`--allow-lan`).

**Both.** The generated SSH config entry sets `ForwardAgent no` and
`ForwardX11 no`, so your SSH agent and display never reach the VM.

## Where things are kept

| | libvirt | `--backend qemu` |
|---|---|---|
| Images and disks | `/var/lib/libvirt/images/agentcage`, or `/home/agentcage` when `/` is a smaller, separate partition (root-only) | `~/.local/share/agentcage` |
| SSH key | `~/.ssh/id_agentcage` | same |
| SSH config | fenced `# agentcage:begin NAME` block in `~/.ssh/config` | same |
| Settings | `~/.config/agentcage/config` | same |

Inside the VM, API keys are stored in the `agent` account, readable only
there: Pi's in `~/.pi/agent/auth.json`, Claude Code's in
`~/.config/agentcage/env`, and Codex's by `codex login` in `~/.codex`.

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

## Deleting a VM

`acage delete NAME` lists what it will remove and asks before doing anything:

```
This deletes 'mybox':
  - the VM, its disk and its first-boot config
  - its 'Host mybox' entry in ~/.ssh/config and its host key in ~/.ssh/known_hosts
  - acage's saved settings for it
Your SSH key, the downloaded Alpine image and other VMs are kept.
Are you sure? This can't be undone. [y/N]
```

If acage created the VM's shared folder, it then asks separately whether to
delete that too, defaulting to no: the folder is on your computer and may hold
your work. A folder you pointed `--share` at yourself is never offered, and
`--yes` never deletes a shared folder.

`delete` also cleans up after a create that failed half-way, when only the SSH
entry or settings are left.

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
- **`doas: Operation not permitted` as `agent`.** That's intended: the agent
  has no root. Log in as yourself (`acage attach NAME --user`) to install
  things.
- **`doas: Operation not permitted` in your account.** The VM was created
  with `--no-doas`, or by an older version of agentcage. Recreate it.
- **The agent can't reach something on your network** (a local Git server,
  model server or package mirror). The firewall blocks that by design;
  recreate the VM with `--allow-lan` if it really needs it.

## Packaging

`make install PREFIX=/usr DESTDIR="$pkgdir"` installs the command to
`bin/`, the scripts to `lib/agentcage/`, the data files to
`share/agentcage/` and the man page to `share/man/man1/`. The command finds them relative to itself, so any prefix
works. `make uninstall` removes them again.

`make check` runs `bash -n` and shellcheck, and `make test` runs the tests in
`tests/`. The tests need no VMs, network or root: each one gets a temporary
home folder and stand-ins for `virsh`, `sudo` and QEMU.

## Files

| File | Purpose |
|---|---|
| `acage` | The command: options, prompts, and dispatch to the backend |
| `acage.1` | Man page (`man acage` once installed, or `man ./acage.1`) |
| `lib/backend-libvirt.sh` | Default backend: libvirt VMs from `share/domain.xml` |
| `lib/backend-qemu.sh` | `--backend qemu`: QEMU run directly as your user, with KVM |
| `lib/pool.sh` | Where images and disks go, free-space checks, saved settings |
| `lib/alpine.sh` | Alpine specifics: image download, packages, signing key |
| `lib/cloudinit.sh` | The first-boot config: user, root access, packages, agents, shared folder |
| `lib/image.sh` | Signature checks, SSH key, disk preparation and the seed ISO |
| `lib/harness.sh` | Agent harnesses: packages, install, API key handling |
| `lib/share.sh` | Shared folder: checks, warning, guest mount |
| `lib/provision.sh` | After boot: wait for SSH and cloud-init, SSH config, keys |
| `lib/common.sh` | Shared helpers (logging, dry-run, prompts) |
| `share/domain.xml` | libvirt VM template |
| `share/image-signing.asc` | Alpine's cloud-image signing key |
| `share/firewall.nft` | The VM's firewall: internet yes, LAN and host no |
| `tests/` | Test suite (`tests/run`, one `test-*.sh` file per area) |
| `Makefile` | `install`, `uninstall`, `check`, `test` |
| `SECURITY.md` | Threat model and how to report vulnerabilities |
| `CHANGELOG.md` | Changes per release |

## License

MIT; see [LICENSE](LICENSE).
