# agentcage

> **TODO**
> 1. Remove humanly unreadable AI bloat.
> 2. Ubuntu testing.
> 3. Manual audit.
> 4. Remove bloat.
> 5. Redo 4.

Run a coding agent in a disposable, locked-down VM instead of on your own
machine.

agentcage (command: `acage`) boots a hardened Alpine Linux VM from Alpine's
official cloud image, which it verifies first. The agent runs on its own
kernel, in its own no-root account — it can't see your files (unless you share
a folder), your keys, your clipboard, your local network or your host, and it
can't become root in the VM to change that. See [SECURITY.md](SECURITY.md).

| Harness | Installs | Logs in with |
|---|---|---|
| `pi` (default) | [Pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) | Anthropic API key |
| `claude-code` | [Claude Code](https://www.npmjs.com/package/@anthropic-ai/claude-code) | Claude account or Anthropic API key |
| `codex` | [Codex CLI](https://www.npmjs.com/package/@openai/codex) | ChatGPT account or OpenAI API key |

## Install

You need a Linux host with KVM. The default libvirt backend runs x86_64 VMs.

**Arch** — `cd packaging/arch && makepkg -si`

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
acage install mybox --harness claude-code   # verify image, boot VM, connect
acage attach mybox                           # log in: agent, or you (--user)
acage push mybox ~/projects/app              # copy a project into the agent's home
```

Run the AI as `agent`; install software as yourself (`acage attach mybox
--user`, then `doas apk add …`). Settings you don't pass are asked for when
you run in a terminal, and your VM account defaults to your username.

For everything else:

- **`acage --help`** — every command and option.
- **`man acage`** — the full manual.
- **[SECURITY.md](SECURITY.md)** — the threat model, the known weaknesses, and
  how to report a vulnerability.

## Developing

`make check` runs `bash -n` and shellcheck; `make test` runs the suite in
`tests/` (no VMs, network or root). `make e2e` creates a real VM and checks it
end to end (needs KVM, the network and, for libvirt, `sudo`); run it before a
release. `make install PREFIX=/usr DESTDIR=…` installs the command, its
libraries under `lib/agentcage/`, `share/agentcage/` and the man page.

## License

MIT; see [LICENSE](LICENSE).
