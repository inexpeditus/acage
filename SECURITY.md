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
- reach your local network or services on your machine: a firewall in the
  VM refuses connections to private, link-local and multicast addresses
- become root in the VM, use your account there, or read your home folder
  in it: the agent runs in its own `agent` account, which has no `doas`

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

- **Anything in the agent account.** API keys, the deploy key, `~/shared`
  and any code you give the agent are readable by it, by design.
- **The internet.** The VM can reach the internet, so an agent can send out
  anything it can read.
- **Root in the VM.** The firewall and the separation between the accounts
  rely on the agent not getting root. A local privilege escalation bug in
  the VM's kernel or software, or a mistake in your account (running
  something the agent wrote with `doas`), would undo both. With
  `--allow-lan` there is no firewall at all.
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

- Don't run code the agent wrote from your own account in the VM, least of
  all with `doas`. Use `--no-doas` if you don't need root there, especially
  with a shared folder on libvirt.
- Move files in with `acage push` instead of a shared folder, and get the
  agent's work back through Git, reviewing it before you pull. Give the VM a
  read-only deploy key unless it must push.
- Use API keys that are limited to this purpose and have spending limits.
- Keep the default firewall. If the agent doesn't need the internet either,
  put the VM on an isolated libvirt network.
- Treat VMs as disposable: `acage delete` and recreate rather than keeping
  one forever.

## Reporting a vulnerability

Please report security problems privately through GitHub: open the
repository's **Security** tab and choose **Report a vulnerability**. Don't
open a public issue for them.
