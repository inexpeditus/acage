# acage benchmarks

What running an agent in acage costs, and what it buys, measured against the
alternatives people actually reach for: a plain Docker container, a gVisor
(`runsc`) sandboxed container, and acage on both its backends.

Two questions, two tables: **isolation** (what can reach the host from inside?)
and **lifecycle cost** (what does each solution cost the host to install, start,
idle, and work?). The point isn't "acage wins" — it's an honest ledger of the
trade, so the "why a VM and not Docker/gVisor?" question has evidence behind it.

Reproduce with the scripts in [`bench/`](bench/) (see *Reproducing* below).

## Environment (run 1 — baseline, pre-optimization)

| | |
|---|---|
| date | 2026-10-24 |
| host kernel | 7.2.11-arch1-1 (Arch) |
| CPU | Intel i7-10750H, 6c/12t @ 2.6 GHz |
| RAM | 15 GB |
| disk | NVMe |
| qemu | 11.1.2 |
| docker | 29.9.1 |
| gVisor (runsc) | release-20260406.0 |
| guest image | Alpine 3.24.1 (`generic_alpine-…-uefi-cloudinit-r0`) |
| container image | `node:22-alpine` (userland held constant) |
| resource caps | 2 vCPU / 2 GB on every column |
| acage | 0.2.0 |

These are **pre-optimization baselines**. The methodology is re-runnable so
tuning shows up as a diff against this table.

## Isolation — can the host be reached from inside? (yes = worse)

Identical probes run *inside* each sandbox. Container tested in two configs
(typical agent run with a project mounted; and with the Docker socket mounted —
a common footgun).

| probe | container | container+sock | gVisor | **acage** |
|---|---|---|---|---|
| shared kernel | yes | yes | no (4.4.0 fake) | **no (6.18.35-0-virt, real)** |
| host FS beyond mount | no | no | no | **no** |
| mounted project writable | yes | yes | yes | **n/a (no share by default)** |
| reach host network | yes | yes | yes | **no (firewall)** |
| docker API (= host root) | no | **yes** | no | **n/a** |

- **acage is the only option that blocks the host network** (its nftables
  firewall) and runs a **real separate kernel** — gVisor fakes a kernel in
  userspace; containers share yours.
- A plain container isn't "wide open": it contains the non-mounted filesystem
  and host processes. Its real exposures are the **shared kernel** and
  **host-network reachability**. The mounted project is writable because that's
  the mount working as intended.
- gVisor closes only the kernel gap; it still reaches the host network and
  still honors a bind mount.
- Mounting the Docker socket = instant host root. The most dangerous common
  config.

## Lifecycle cost — one box, matched 2 vCPU / 2 GB

| metric | acage-qemu | acage-libvirt | docker | gVisor |
|---|---|---|---|---|
| setup: disk installed, MiB | **103** | 161 | 217 | 279 |
| warm start → ready, s | 20.8 | 24.5 | **0.35** | 0.43 |
| provision (first time), s | 29.7 | 37.3 | 1.6 (apk) | 1.8 (apk) |
| provision network, MB | 45 | 44 | 11.4 | n/a† |
| idle RAM, MB | 362–567‡ | 452 (402+50) | **146** | 171 |
| idle CPU /30 s, ms | ~1100–2200 | ~1090 | **0** | 1514 |
| disk: shared base, MB | **193** | 193 | 227 | 227 |
| disk: per-box, MB | 313 | 305 | 35 | **26** |
| CPU task wall / host, s | 7.9 / 8.0 | —§ | 7.6 / **7.5** | 8.1 / 8.75 |
| npm install wall / host, s | 3.9 / 3.4 | —§ | 3.0 / **2.05** | 4.4 / 5.41 |
| teardown, s | **0.04** | 1.05 | 0.20 | 0.22 |

† gVisor's userspace netstack doesn't populate the container's
  `/sys/class/net` counters, so the probe reads 0; the real value ≈ docker's.
‡ VM idle RAM is history-dependent: ~362 MB fresh after boot, climbing to
  ~567 MB after a workload (guest page cache backs onto host RAM and doesn't
  shrink). A container's cache is reclaimable host page cache.
§ acage-libvirt CPU/npm were measured with other VMs running and are
  contention artifacts (12.2 s / 6.3 s); KVM is KVM, so the true values should
  match acage-qemu. Re-measure on a quiet host. (Kept out rather than mislead.)

**Idle CPU caveat:** the acage idle-CPU figures above (~1100–2200 / ~1090 ms)
were also taken on a contended host and are inflated. On a *quiet* host with
HPET off, acage idles at **~0.3%** — see *Optimization findings* below. The
container's 0 and gVisor's 1514 ms stand.

## What the numbers say

- **There are two camps, not a ranking.** The plain container is cheap but
  barely isolates (shared kernel, reaches host). The two options that *actually*
  isolate — gVisor and the acage VM — **both cost idle CPU** (~5% for gVisor's
  polling sentry, ~5–7% for the VM's timer ticks). The only option that's free
  at idle is the one that doesn't isolate the kernel.
- **gVisor is not a free lunch.** It costs idle CPU like a VM, and on
  syscall/IO-heavy work (`npm`) it burns **more host CPU than the VM**
  (5.4 vs 3.4 s) — KVM's virtio beats userspace syscall emulation. It also
  isolates *less* (shared kernel). acage is competitive-to-better than gVisor
  on nearly everything except cold start.
- **CPU throughput is at parity** for the VM and the plain container (KVM is
  near-native); gVisor is slightly worse even on pure CPU.
- **acage installs the lightest** (103 MiB vs docker's 217) — the "a VM tool
  must be heavy" intuition is false here, because QEMU+OVMF < docker engine +
  containerd + runc, and Alpine is tiny.
- **acage's real costs** are cold start (~21–25 s, one-time per session),
  idle RAM (362+ MB), and idle CPU (~5%). Those are the honest price of booting
  a whole machine with its own kernel.
- **libvirt vs qemu backend:** libvirt ≈ qemu + a ~50 MB daemon + a few seconds
  of start orchestration. Same isolation, same throughput.

## Prediction vs reality (pre-registered before the run)

| I predicted | Reality | Verdict |
|---|---|---|
| acage-qemu lightest to install | 103 MiB, less than half of docker | ✅ (magnitude way off — I guessed ~400) |
| gVisor burns extra host CPU on IO | npm host-CPU 5.4 s vs docker 2.0, vs VM 3.4 | ✅ nailed, and VM beats it |
| CPU throughput parity | VM ≈ container ≈ native | ✅ |
| acage idle CPU ~20 ms/30 s | ~1100–2200 ms (~5–7% of a core) | ❌ ~100× off |
| gVisor idle CPU ~100 ms | ~1500 ms (sentry polls) | ❌ ~15× off |
| acage provision ~90 s | ~30 s (cached image, 45 MB apk) | ❌ faster |

The two big misses — idle CPU on both isolating options — are the most
interesting findings and the clearest optimization targets.

## Optimization findings (run 2, quiet host)

Changes applied so far (security-neutral or security-positive): **HPET off on
the qemu backend**, **cloud-init disabled after first boot**, **`GRUB_TIMEOUT=0`**,
and a **copy-on-write disk overlay** on the qemu backend.

- **Per-VM disk cut ~55% and the base is shared (qemu backend).** The disk is
  now a CoW overlay on the cached base, not a full copy: **136 MiB of writes vs
  a ~313 MiB copy**, and N VMs share one 193 MiB base (3 VMs: ~604 MB total vs
  ~939 MB). Creation no longer copies the image, but provision *wall* time is
  unchanged — it is boot/apk-install bound, not copy-bound. The prune step
  won't delete a base an overlay still references; export will flatten the
  overlay into a standalone image for cross-system portability.

- **Idle CPU is a near-non-issue — the baseline 5–7% was mostly a measurement
  artifact.** On a *quiet* host with HPET off, `benchvm` idles at **~0.3%**
  (60–70 ms / 20 s). A halt-poll A/B (`halt_poll_ns` 200000 vs 0) showed **no
  difference** — halt-polling was a red herring. The earlier high numbers came
  from measuring on a *contended* host (other VMs running), where a descheduled
  guest does timer catch-up that inflates its own CPU, compounded by HPET being
  on. Lesson: idle-CPU numbers must be taken on a quiet host.
- **Warm start: 21 s → ~6 s, and it was never firmware.** The bottlenecks, in
  the order we found and fixed them (`bench/boot-breakdown.sh`; note the tool
  itself had to be fixed first — a blocking ssh probe was quantizing the phase
  markers and made firmware *look* like ~5 s):

  | step | warm start |
  |---|---|
  | original (GRUB menu waits 10 s for a keypress on a headless VM) | ~21 s |
  | `GRUB_TIMEOUT=0` | ~10.5 s |
  | remove cloud-init from the runlevels (its Python stages ran every boot) | ~8.8 s |
  | dhcpcd `noarp` (skip the ARP duplicate-address probe that times out on NAT) + drop IPv6 DHCP | ~7.6 s |
  | `rc_parallel=YES` (OpenRC starts services concurrently) | **~6 s** |

  All applied, all security-neutral/positive. The real cost was **userspace**
  (a GRUB timeout, then a serial chain of services), not firmware — OVMF, after
  the GRUB fix, is negligible (~0.8 s). The remaining ~6 s is ~0.8 s firmware +
  ~1.3 s kernel + ~3 s parallel userspace, near the floor for booting a real
  kernel.
  - **Deferred (`direct-kernel-boot` branch):** booting the extracted kernel
    directly removes OVMF entirely (kernel starts at ~0.7 s) — a surface and
    determinism win, but only ~0.5 s of time, so it's parked until that's worth
    its extraction machinery.
  - Snapshot/restore remains the "make it instant" option, pending a security
    review (RNG/host-key reuse on resume).

## Reproducing

All scripts are in [`bench/`](bench/). acage halves need no root; docker halves
need `sudo` (we deliberately don't join the root-equivalent `docker` group).

| script | column(s) | run as |
|---|---|---|
| `bench/run.sh` | isolation: container, gVisor | `sudo` |
| `bench/acage-column.sh` | isolation: acage (VM) | you |
| `bench/lifecycle-acage.sh` | lifecycle: acage-qemu | you |
| `bench/lifecycle-libvirt.sh` | lifecycle: acage-libvirt | you (sudo prompt for pool) |
| `bench/lifecycle-docker.sh` | lifecycle: docker, gVisor | `sudo` |

Workloads are identical across columns (same `node` loop, same
`npm install express`), userland held constant at `node:22-alpine` vs Alpine so
the sandbox is the only variable. Host-side cost is attributed via process RSS
and cgroup CPU, not wall-time-inside.
