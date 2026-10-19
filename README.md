# agentcage

> **TODO**
> 1. Remove humanly unreadable AI bloat.
> 2. Ubuntu testing.
> 3. Manual audit.
> 4. Remove bloat.
> 5. Redo 4.

Run a coding agent in a disposable, locked-down VM instead of on your own
machine.

agentcage (command: `acage`) downloads Alpine Linux's official cloud image,
verifies it, and boots a hardened VM from it. On first boot the VM creates two
accounts that both accept your SSH key — `agent` for the AI (no root) and one
for you (root through `doas`) — turns on a firewall that keeps the VM off your
local network, and installs `git`, `vim`, Node.js and the agent harness(es)
you pick:

| Harness | Installs | Logs in with |
|---|---|---|
| `pi` (default) | [Pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) | Anthropic API key |
| `claude-code` | [Claude Code](https://www.npmjs.com/package/@anthropic-ai/claude-code) | Claude account or Anthropic API key |
| `codex` | [Codex CLI](https://www.npmjs.com/package/@openai/codex) | ChatGPT account or OpenAI API key |

The agent runs on its own kernel, in its own account. It can't see your files
(unless you share a folder), your clipboard, USB devices, SSH agent, local
network or the services on your machine, and it can't become root in the VM to
change that. See [Security](#security).

## Install

You need a Linux host with KVM. The default libvirt backend runs x86_64 VMs.

**Arch** — build the package:

```bash
cd packaging/arch && makepkg -si
```

**Ubuntu / Debian** — run `./acage` from a checkout (or `sudo make install`),
and install the host tools:

```bash
sudo apt install libvirt-daemon-system qemu-system-x86 qemu-utils ovmf \
                 xorriso perl curl gnupg openssh-client
# optional: virtiofsd (shared folders), openssl (--password)
```

Ubuntu starts libvirt and its `default` network for you; on Arch,
`sudo systemctl enable --now libvirtd` and `sudo virsh net-autostart default`.

Without libvirt, pass `--backend qemu`: you then need only QEMU, UEFI firmware
(`edk2-ovmf` / `ovmf`), `xorriso`, `curl`, `gnupg` and `openssh`, and access to
`/dev/kvm` (usually via the `kvm` group).

## Quick start

```bash
acage install mybox --harness claude-code
```

This verifies the image, boots the VM, waits for first boot, stores an API key
and a GitHub deploy key in the `agent` account if you want, and connects.
Afterwards:

```bash
acage attach mybox          # asks: agent or you (--agent / --user to skip)
```

Run the AI as `agent`; install software as yourself (`acage attach mybox
--user`, then `doas apk add …`). Plain `ssh mybox` logs in as `agent`,
`ssh you@mybox` as you.

Any option you omit is asked for interactively. Run non-interactively (piped
or scripted) and acage uses the defaults and skips the key/connect steps.

## Commands

| Command | What it does |
|---|---|
| `install [NAME]` | `image`, then `create` |
| `image` | Download and verify the latest Alpine image (cached and reused) |
| `create [NAME]` | Create and boot a VM from the cached image |
| `attach NAME` | Log in, choosing `agent` or your account (`--agent` / `--user`) |
| `push NAME PATH...` | Copy files from your computer into the VM ([details](#moving-files-in)) |
| `ssh NAME [-- CMD]` | Run `CMD` in a VM, as `agent` (or you with `--user`) |
| `start NAME` / `stop NAME` | Start or shut down a VM |
| `console NAME` | Serial console (libvirt) or boot output (`--backend qemu`) |
| `list` | List the VMs agentcage created |
| `delete NAME` | Delete a VM and everything acage set up for it (asks first) |

The image is downloaded once into `~/.cache/agentcage/images` and reused by
every VM; `image`/`install` only re-download when Alpine publishes a newer
release, and fall back to the cached copy when offline.

## Options

| Option | Default | |
|---|---|---|
| `--name NAME` | `agentcage` | VM name, hostname and SSH alias; or give it as `NAME` after the command |
| `--user NAME` | your username | Your account in the VM (anything but `agent`) |
| `--harness LIST` | `pi` | `pi`, `claude-code`, `codex` (comma-separated), or `none` |
| `--share DIR` | none | Share a host folder at `~/shared` ([read first](#shared-folder)) |
| `--password` | off | Set a password for your account (doas then asks for it) |
| `--no-doas` | off | Nobody in the VM can become root |
| `--allow-lan` | off | Let the VM reach your LAN and this host (no firewall) |
| `--ram MB` | `2048` | At least 512 |
| `--vcpus N` | `2` | |
| `--disk GB` | `10` | The image is grown to this size |
| `--ssh-pubkey FILE` | `~/.ssh/id_agentcage.pub` | Key to authorize; generated if missing |
| `--no-wait` | off | Start the VM and return without waiting for first boot |
| `--backend NAME` | `libvirt` | `qemu` runs QEMU directly (also `AGENTCAGE_BACKEND`) |
| `--pool-dir DIR` | [see below](#where-things-go) | Where VM disks are kept; remembered |
| `-y`, `--yes` | off | Skip confirmations (key fingerprint, share warning, delete) |
| `-n`, `--dry-run` | off | Print what would change instead of doing it |
| `-h`, `--help` / `--version` | | |

## Accounts in the VM

| | `agent` | Your account |
|---|---|---|
| Runs | the AI | you |
| Root (`doas`) | never | yes, unless `--no-doas` |
| Holds | API keys, deploy key, `~/shared` | whatever you put there |
| Sees the other's home | no | no |

The agent can't act as you, so it can't use your `doas` or switch off the
firewall. When it needs a package, it asks you to install it. With
`--password`, `doas` prompts for a password (only its hash goes into the VM);
without one it doesn't prompt, which is safe because the agent can't reach your
account. SSH is key-only for both, and direct root login is off.

## Moving files in

```bash
acage push mybox ~/projects/app notes.md     # into the agent's home
acage push mybox ~/projects/app --to work    # into ~/work
acage push mybox setup.sh --user             # into your account
```

Your computer starts the copy and data only flows into the VM, over the
existing SSH connection — no shared folder, no open firewall. Symlinks are
copied as links, never followed. `push` refuses your home and credential
folders and warns about likely secrets. There's deliberately no copy-*out*;
to get the agent's work back, have it push to a Git remote and review before
you pull.

## Shared folder

`--share DIR` makes `DIR` appear as `~/shared` in the VM, read-write on both
sides (owned by `agent`, with your uid). It's convenient but **weakens the
isolation**: the agent can read and rewrite everything in it, code it writes
there runs on your machine when you build or run it, and on libvirt it can even
end up as root-owned files on your host. acage prints a warning and makes you
type `share` first, and refuses `/`, your home and credential folders. Prefer
[`acage push`](#moving-files-in) plus Git. Full detail in
[SECURITY.md](SECURITY.md).

## Security

agentcage is built to stop a careless, compromised or prompt-injected agent
from damaging or reading your computer. What's in place:

- **Its own kernel** — a KVM VM, not a container sharing your kernel.
- **A verified image** — Alpine's SHA-512 and GPG signature, key pinned by
  fingerprint (`F26A DFAD BAE7 02EF 7AF6 3745 9DA7 EF23 BFFC DF22`, compared
  against <https://alpinelinux.org/cloud/>).
- **No root for the agent** — its own account without `doas`; can't reach your
  account or home in the VM.
- **Internet only** — a firewall in the VM ([`share/firewall.nft`](share/firewall.nft))
  blocks your LAN and this host (see below).
- **Nothing shared by default** — no folders, clipboard, USB, audio, guest
  agent, SSH agent or X11.
- **One-way file transfer** — `acage push` only copies in; nothing copies out.
- **Locked-down logins** — key-only SSH, no root login, Alpine's default
  account removed.
- **A confined emulator** — on libvirt, QEMU runs as a separate system user,
  confined by AppArmor/SELinux where the distro uses them.

`SECURITY.md` has the full threat model, the known weaknesses, and how to
report a vulnerability.

### Network

| From the VM to | |
|---|---|
| The internet (npm, apk, GitHub, AI APIs) | ✓ |
| DNS, DHCP, replies to your SSH sessions | ✓ |
| Your LAN: router, NAS, printers, other machines | ✗ |
| Services on this host (e.g. a local Ollama) | ✗ |

Only root in the VM can change the firewall, and the agent has no root.
`--allow-lan` creates the VM without it. With `--backend qemu`, the host's
localhost (`10.0.2.2`) is blocked the same way. The generated SSH config entry
sets `ForwardAgent no` and `ForwardX11 no`.

## Where things go

| | libvirt | `--backend qemu` |
|---|---|---|
| Downloaded images | `~/.cache/agentcage/images` | same |
| VM disks | `/var/lib/libvirt/images/agentcage`, or `/home/agentcage` if `/` is a smaller separate partition (root-only) | `~/.local/share/agentcage` |
| SSH key | `~/.ssh/id_agentcage` | same |
| SSH config | `# agentcage:begin NAME` block in `~/.ssh/config` | same |
| Settings | `~/.config/agentcage/config` | same |

Before downloading or creating, acage checks the filesystem has room for the
full `--disk` size, keeping 5 GB free if it's your root partition. On libvirt
the pool can't be inside your home (the VM's system user can't enter it), so
`/home/agentcage` is used when `/` is small; `--pool-dir` overrides it and is
remembered. `acage ssh NAME` always uses the VM's current address; plain
`ssh NAME` uses the one saved at creation, which can change on libvirt after a
reboot.

## Troubleshooting

- **"Not enough disk space"** — use `--pool-dir` on a bigger filesystem, or a
  smaller `--disk`.
- **"No access to /dev/kvm"** (`--backend qemu`) — join the `kvm` group and log
  in again.
- **First boot seems slow** — it's installing packages; inside the VM,
  `cloud-init status --wait` blocks until done and
  `/var/log/cloud-init-output.log` shows why.
- **SSH refuses your key** — first-boot setup failed; see `acage console NAME`.
- **`doas: Operation not permitted` as `agent`** — intended; log in with
  `--user` to install things.
- **The agent can't reach something on your network** — the firewall blocks it;
  recreate with `--allow-lan` if it truly needs it.

## Developing

`make check` runs `bash -n` and shellcheck; `make test` runs the suite in
`tests/` (no VMs, network or root — each test gets a temp home and stand-ins
for `virsh`, `sudo` and QEMU). `make e2e` creates a real VM and checks the
accounts, firewall, shared folder, `push`, restart and delete end to end; it
needs KVM, the network and (for libvirt) `sudo`. Run it before a release.
`make install PREFIX=/usr DESTDIR=…` installs `bin/acage`, `lib/agentcage/`,
`share/agentcage/` and the man page; the command finds its files relative to
itself.

| Path | Purpose |
|---|---|
| `acage`, `acage.1` | The command and its man page |
| `lib/backend-libvirt.sh`, `lib/backend-qemu.sh` | The two backends |
| `lib/alpine.sh`, `lib/image.sh`, `lib/cloudinit.sh` | Image fetch/cache, disk + seed, first-boot config |
| `lib/pool.sh`, `lib/harness.sh`, `lib/share.sh`, `lib/push.sh` | Storage, agents, shared folder, file push |
| `lib/provision.sh`, `lib/common.sh` | Post-boot steps, shared helpers |
| `share/` | `domain.xml`, `firewall.nft`, `image-signing.asc`, login messages |
| `packaging/arch/` | Arch `PKGBUILD` |

## License

MIT; see [LICENSE](LICENSE).
