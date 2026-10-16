# alpine-image/

A self-contained copy of this repo's Alpine preinstalled-image install method:
download Alpine's official cloud image, verify it, and boot a hardened libvirt
VM from it with a first-boot (cloud-init) config that creates a user with your
SSH key and installs `git`, `openssh`, `nodejs`, `npm` and the Pi agent. No
installer, no manual OS install step.

Nothing here talks to a cloud provider. "Cloud image" just means a disk with
the OS already installed, and "cloud-init" is the small program that reads a
first-boot config from a seed ISO this script builds locally; see the main
repo's `README.md` ("On portability" / install-methods section) for more on
that terminology.

## Usage

```bash
./create.sh --name mybox --user agent install
```

That downloads and verifies the image, then creates and boots the VM. Run the
two steps separately if you'd rather review the download first:

```bash
./create.sh --name mybox image    # download + verify only
./create.sh --name mybox --user agent create
```

See `./create.sh --help` for all options (RAM, vCPUs, disk size, pool
directory, an existing SSH public key, `--password`, `--no-doas`, `--dry-run`).

The guest user gets root through `doas` (for example `doas apk add neovim`).
Without `--password` the account has no password, so `doas` doesn't ask for one.
With `--password` you're prompted on the host (only a hash goes into the VM),
`doas` asks for that password, and it also works for console login and `su`.
SSH stays key-only either way. `--no-doas` creates a user with no root access.

Once it's running:

```bash
ip=$(virsh -c qemu:///system domifaddr mybox --source lease | awk '/ipv4/{split($4,a,"/");print a[1]}')
ssh -i ~/.ssh/id_agentbox -o HostName="$ip" agent@mybox   # or just use the IP directly
```

First boot takes a minute or two (installing packages and the agent). `cloud-init status --wait` over SSH blocks until it's done.

## What's in this folder

| File | Purpose |
|---|---|
| `create.sh` | Entry point: argument parsing and orchestration (download, disk prep, seed, define, start) |
| `common.sh` | `log`/`die`/`run`/`dry`/`virsh_` helpers |
| `profile.sh` | Alpine-specific bits: where to find the image, its packages, its signing key |
| `image-helpers.sh` | Generic preinstalled-image logic: signature verification, disk prep, cloud-config, seed ISO |
| `image-signing.asc` | Alpine's cloud-image signing public key, pinned by fingerprint (published at https://alpinelinux.org/cloud/) |
| `domain.xml` | Hardened libvirt domain template (no shared folders, clipboard, audio, USB; includes the `ds=nocloud` SMBIOS hint so cloud-init skips several minutes of EC2/OpenStack metadata probing on a local network) |

## Relationship to the main repo

This is a **snapshot**, copied out of:

- `../lib/image.sh` → `image-helpers.sh`
- `../guests/alpine/profile.sh` (its `alpine_image_*` functions) → `profile.sh`
- `../agent_box.xml` → `domain.xml`
- `../lib/common.sh` (the small subset needed here) → `common.sh`

It duplicates that logic rather than sourcing it, so it works without the rest
of the repo (no `install.sh`, no `wizard.sh`, no multi-guest dispatch). The
trade-off is that it can drift: a fix made in `../lib/image.sh` or
`../guests/alpine/profile.sh` is not automatically reflected here and has to
be re-applied by hand if you want it in both places.

Arch's image method, the ISO install method for either guest, and the wizard
are not duplicated here; use the main repo (`../install.sh`, `../wizard.sh`)
for those.

## Tested

Real download and signature verification of the Alpine image, a tampered
file being rejected, disk copy and resize, seed ISO generation and valid
cloud-config YAML, and a full VM boot (key login, cloud-init, hostname,
package install, Pi) using the equivalent logic in the main repo.
