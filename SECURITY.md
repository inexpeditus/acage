# Security

agentcage runs a coding agent in a virtual machine so that a mistaken,
compromised or prompt-injected agent can't damage or read your computer.
This page says what that does and doesn't protect, so you can decide what
to trust it with.

## What it protects

With the defaults (no shared folder), an agent inside the VM cannot:

- read, change or delete files on your computer, including SSH keys,
  credentials, browser data and other projects
- see or control your other programs, your desktop, clipboard, USB devices
  or audio
- use your SSH agent or X11 display (the SSH entry sets `ForwardAgent no`
  and `ForwardX11 no`)
- reach your machine's kernel: the VM runs its own Linux kernel under KVM

Every image is checked against Alpine's published SHA-512 checksum and
Alpine's GPG signature, with the signing key pinned by fingerprint in
`share/image-signing.asc`.

## What it trusts

- **Your host, KVM, QEMU and libvirt.** A bug that lets code escape a VM
  ("VM escape") breaks the isolation. Keep the host updated.
- **Alpine's image signing key.** A compromised Alpine key could sign a
  malicious image.
- **npm and the agent vendors.** The agent harnesses are installed from npm
  at their latest versions on first boot, as root inside the VM. Claude
  Code's install script runs during that install.

## What it does not protect

- **Anything inside the VM.** The agent has full access to the VM, and with
  the default `doas` setup it is root there. API keys, deploy keys and code
  you put in the VM are readable by the agent.
- **The network.** The VM can reach the internet and your local network,
  so an agent can send out anything it can read in the VM. With libvirt it
  can also reach services on the host's `virbr0` address; with
  `--backend qemu`, services on the host's loopback interface through
  `10.0.2.2`.
- **A shared folder.** `--share` gives the agent read-write access to that
  folder on your computer. Anything the agent writes there (scripts, build
  files, `.git/hooks`, editor config) runs on your computer when you use
  it. With libvirt the folder is served by a root process on the host, so
  root in the VM can create root-owned and setuid files in it.
- **Your terminal.** Output from the VM is shown in your host terminal.
  Terminals that support OSC 52 let programs in the VM overwrite your
  clipboard, and other escape sequences can affect your terminal. Check
  commands before pasting them into a host shell.

## Reducing the risk further

- Use `--no-doas` when the agent doesn't need root in the VM, especially
  with a shared folder on libvirt.
- Move code with Git instead of a shared folder, and give the VM a
  read-only deploy key unless it must push.
- Use API keys that are limited to this purpose and have spending limits.
- Restrict the VM's network (an isolated libvirt network or firewall rules)
  if it doesn't need the internet or your LAN.
- Treat VMs as disposable: `acage delete` and recreate rather than keeping
  one forever.

## Reporting a vulnerability

Please report security problems privately through GitHub: open the
repository's **Security** tab and choose **Report a vulnerability**. Don't
open a public issue for them.
