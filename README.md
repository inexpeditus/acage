# acage

**Run an AI coding agent inside a disposable, locked-down virtual computer** — so
it can do its work without being able to touch your real files, your network, or
your credentials.

Letting an AI agent run commands on your machine hands it a lot of power. acage
puts it in a sealed, throwaway "cage" (a small virtual computer) instead. If the
agent misbehaves, gets tricked, or just makes a mess, it stays in the cage — and
you throw the cage away.

<video src="https://github.com/inexpeditus/acage/raw/main/final.mp4" controls width="100%"></video>

## What acage actually does

acage runs an AI coding agent inside a **disposable virtual computer** (a "cage")
on your machine, so the AI can't touch your real files or network.

**When you run `acage create` (once):**

1. **Checks your tools** — makes sure your computer has what it needs, and tells
   you exactly what to install if something's missing.
2. **Downloads a tiny, secure OS** (Alpine Linux) and verifies its signature, so
   you know it's genuine and untampered.
3. **Builds a fresh virtual computer** from it and boots it up.
4. **Creates two logins** inside: **agent** (runs the AI, no admin powers) and
   **you** (can use admin) — and **locks the network** so the cage can reach the
   internet but *not* your home network or your real computer.
5. **Installs your AI tool** (Claude Code by default) inside the cage.

**When you use it:**

- **`acage attach`** — logs you into the cage (starting it first if it was off).
  Pick **agent** to run the AI safely.
- The AI does everything **inside the cage** — its files, commands, and any
  mistakes stay in there, not on your computer.
- **`acage stop`** powers it off · **`acage start`** turns it back on ·
  **`acage delete`** throws the whole cage away.

## Quickstart

Streamlined process for safe(r) use of agentic AI through disposable virtual
machines.

Run

```
acage create
```

Carelessly press enter ten times.

Wait for the download to finish and then verify with `y`.

The virtual machine installs and runs initial boot configurations.

You're prompted for an API key, which is redundant since using user logins
doesn't cost you credits.

Get a deploy key for git operations if you want.

Connect as agent and now you're running a Claude inside a virtual machine that
doesn't share your kernel and has no access to your filesystem.

![acage create](https://github.com/user-attachments/assets/651f0be8-777e-4612-bd5b-33b826cebd96)

![acage create, continued](https://github.com/user-attachments/assets/e8b4a768-5b1a-4fb8-9620-db386d984912)

Use

```
acage push <your-vm> /path/to/file
```

to safely transfer files into the virtual machine, be safe.

There's also opt-in for shared folders that naturally weakens the isolation (man
page for more info).

## acage-tui is in consideration

![acage-tui](https://github.com/user-attachments/assets/12d94511-48cb-445b-8bc6-4c7d46beff19)

## Everyday commands

| command | what it does |
|---|---|
| `acage create` | build and boot a new cage (downloads the image if needed) |
| `acage attach` | log into a cage (starts it if it's off) |
| `acage list` | see your cages |
| `acage stop` / `acage start` | power a cage off / on |
| `acage console` | watch a cage's boot output |
| `acage push FILE` | copy a file or folder into the cage |
| `acage delete` | throw a cage away |

## The two logins

Every cage has two accounts, both reached with your SSH key:

- **agent** — runs the AI. **No admin powers.** It can't read your account, and
  it can't turn off the firewall.
- **you** — your own login, with admin (`doas`) if you want it.

So the AI always runs as the powerless **agent**, while you keep a separate way
in for yourself.

## What it protects

By default a cage can reach **the internet, and nothing else** — not your home
network, and not the computer acage runs on. On top of that it:

- runs a **real, separate OS kernel** (not your computer's), from a
  **signature-verified** Alpine Linux image;
- **never copies your credentials** — no SSH keys, git logins, or API tokens
  from your machine end up inside;
- refuses to share folders that hold secrets, and **warns you** whenever you
  deliberately loosen the isolation (`--allow-lan`, a shared folder).

## Requirements

- A **Linux** computer with **KVM** (hardware virtualization) — this is what makes
  the cage fast.
- acage automatically downloads the right image for your CPU, **Intel/AMD** or
  **ARM**. On an ARM host, add `--backend qemu` (the default libvirt backend is
  Intel/AMD only).

## Running on a Mac

acage needs a **Linux host with hardware KVM**, so it does not run on macOS
directly — macOS has no KVM, and acage refuses to start on a non-Linux host.
From a Mac you have two realistic paths:

- **A remote Linux machine (simplest, most reliable).** Install acage on a
  Linux box or a cloud VM and connect to it from your Mac over SSH. Nothing
  special is needed on the Mac itself.
- **A Linux VM on the Mac.** acage then runs *inside* that VM, so it needs
  **nested virtualization** for KVM to work one level down. That's only
  available on **Apple Silicon M3 or newer running macOS 15+**, and only when
  the Linux-VM tooling (e.g. UTM/Lima) actually enables nesting — support is
  still emerging. Intel Macs and M1/M2 can't pass KVM to a guest, so acage
  won't start there.

A native macOS port (using Apple's Hypervisor framework instead of KVM, qemu
backend only) is possible but **not implemented** today.
