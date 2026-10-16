# agentcage

Run a coding agent in a disposable, locked-down VM instead of on your own
machine.

`agentcage` downloads Alpine Linux's official cloud image, verifies it, and
boots a hardened libvirt VM from it. On first boot the VM creates a user with
your SSH key, gives that user root through `doas`, and installs `git`,
`openssh`, `nodejs`, `npm` and the [Pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
coding agent. There's no installer to click through and no manual OS setup.

The agent can do whatever it likes inside the VM. It can't see your files,
your clipboard, your USB devices or your SSH agent.

## Requirements

A Linux x86_64 host with KVM and:

- libvirt with the system connection (`qemu:///system`), the `default` network,
  and UEFI firmware (OVMF / edk2)
- `virsh`, `qemu-img`, `xorriso`, `perl`, `curl`, `gpg`, `sha512sum`,
  `ssh`, `ssh-keygen`, `sudo`
- `openssl`, only if you use `--password`

On Arch:

```bash
sudo pacman -S libvirt qemu-base edk2-ovmf dnsmasq libisoburn perl curl gnupg openssh openssl
sudo systemctl enable --now libvirtd
sudo virsh net-start default && sudo virsh net-autostart default
```

## Quick start

```bash
./create.sh --name mybox --user agent install
```

This downloads and verifies the image, creates the VM, waits for first boot to
finish, and then walks you through the last steps:

1. adds a `Host mybox` entry to `~/.ssh/config`
2. offers to store an Anthropic API key for Pi inside the VM
   (`~/.pi/agent/auth.json`, mode 600; the key is sent over SSH, never put in a
   file on the host)
3. offers to generate a GitHub deploy key inside the VM and prints the public
   half for you to add to your repo
4. offers to connect

After that, `ssh mybox` gets you in.

Any setting you don't pass as an option is asked for interactively. When it
isn't run from a terminal (piped or scripted), it uses the flags and defaults
without asking.

## Commands

| Command   | What it does |
|-----------|--------------|
| `install` | `image`, then `create` |
| `image`   | Download the latest Alpine UEFI cloud image and verify it |
| `create`  | Build a VM from the already-downloaded image |

Run `image` again whenever you want a newer Alpine release. VMs you've
already created aren't affected.

## Options

| Option | Default | |
|---|---|---|
| `--name NAME` | `alpine-box` | VM name; also its hostname and SSH alias |
| `--user NAME` | your username (asked) | User to create in the VM; required for `create` |
| `--ram MB` | `2048` | |
| `--vcpus N` | `2` | |
| `--disk GB` | `10` | The image is grown to this size |
| `--pool-dir DIR` | `/home/alpine-sandbox` | Where the image, disks and seed ISOs live (root-owned) |
| `--ssh-pubkey FILE` | `~/.ssh/id_agentbox.pub` | Key to authorize; the default is generated if missing |
| `--password` | off | Set a password for the guest user (see below) |
| `--no-doas` | off | Don't give the guest user root |
| `--no-wait` | off | Start the VM and print next steps instead of waiting |
| `-n`, `--dry-run` | off | Print what would change instead of doing it |
| `-y`, `--yes` | off | Don't ask you to confirm the signing-key fingerprint |

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

## Image verification

Before an image is used, `image`:

1. checks it against the SHA-512 checksum Alpine publishes alongside it
2. checks Alpine's GPG signature on it in a temporary keyring (your own
   keyring isn't touched, and no keyserver is involved). The signature must
   be made by the key in `image-signing.asc`, fingerprint
   `F26A DFAD BAE7 02EF 7AF6 3745 9DA7 EF23 BFFC DF22`
3. shows you that fingerprint and asks you to compare it with the one
   published at <https://alpinelinux.org/cloud/> (skip with `--yes`)

If any step fails, the download is discarded.

## Hardening

The VM template (`domain.xml`) is stripped down by default:

- no shared folders or shared memory
- no clipboard sharing and no guest-agent channel
- no audio, no USB controller, no tablet device
- the SPICE display doesn't listen on the network
- no VMware backdoor port (`vmport`)
- `ForwardAgent no` and `ForwardX11 no` in the generated SSH config entry

The VM is still on libvirt's `default` NAT network, so it can reach the
internet, your LAN, and services on the host's `virbr0` address. Use an
isolated libvirt network or firewall rules if that matters to you.

## Managing VMs

```bash
sudo virsh -c qemu:///system list --all           # list VMs
sudo virsh -c qemu:///system console mybox        # serial console (Ctrl+] to leave)
sudo virsh -c qemu:///system shutdown mybox
sudo virsh -c qemu:///system start mybox
```

Removing a VM:

```bash
sudo virsh -c qemu:///system destroy mybox        # if it's running
sudo virsh -c qemu:///system undefine mybox --nvram
sudo rm /home/alpine-sandbox/mybox.qcow2 /home/alpine-sandbox/mybox-seed.iso
ssh-keygen -R mybox                               # then delete 'Host mybox' from ~/.ssh/config
```

If the VM's IP changes after a reboot, update `HostName` in its
`~/.ssh/config` entry. You can find the new IP with
`virsh -c qemu:///system domifaddr mybox --source lease`.

## Troubleshooting

- **The first boot seems slow.** Installing packages and Pi takes a minute or
  two. Inside the VM, `cloud-init status --wait` blocks until it's done, and
  `/var/log/cloud-init-output.log` shows what happened.
- **SSH refuses your key.** First-boot setup probably failed. Watch it on the
  serial console: `sudo virsh -c qemu:///system console mybox`.
- **`doas: Operation not permitted`.** The VM was created with `--no-doas`, or
  before root access was on by default. Recreate it.

## Files

| File | Purpose |
|---|---|
| `create.sh` | Entry point: options, prompts, and the `image` / `create` steps |
| `profile.sh` | Alpine specifics: image location, packages, signing key fingerprint |
| `image-helpers.sh` | Signature checks, disk preparation, cloud-init config and seed ISO |
| `provision.sh` | After boot: wait for SSH and cloud-init, SSH config entry, API key, deploy key |
| `common.sh` | Shared helpers (logging, dry-run, prompts, `virsh` wrapper) |
| `domain.xml` | libvirt VM template |
| `image-signing.asc` | Alpine's cloud-image signing key |

## License

MIT; see [LICENSE](LICENSE).
