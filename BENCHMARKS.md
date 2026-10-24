# acage benchmarks

How acage compares to the other ways to sandbox a coding agent: a plain Docker
container, a gVisor (`runsc`) container, and the acage VM on each backend. Two
questions — what can reach the host (**isolation**), and what it costs to run
(**lifecycle**).

Measured on an Intel i7-10750H (6c/12t), 15 GB RAM, NVMe, Arch (kernel 7.2):
qemu 11.1, docker 29.9, runsc 20260406, acage 0.2.0. Every column capped at
2 vCPU / 2 GB, userland held constant (`node:22-alpine` vs Alpine 3.24).
Reproduce with the scripts in [`bench/`](bench/).

## Isolation — can the host be reached from inside? (yes = worse)

| probe | container | + docker.sock | gVisor | acage |
|---|---|---|---|---|
| shares your kernel | yes | yes | no (userspace) | **no (own kernel)** |
| reach the host network | yes | yes | yes | **no (firewall)** |
| read host FS beyond the mount | no | no | no | **no** |
| write the mounted project | yes | yes | yes | **n/a (no mount by default)** |
| Docker API = instant host root | no | **yes** | no | **n/a** |

## Lifecycle — what one box costs the host

| metric | acage-qemu | acage-libvirt | docker | gVisor |
|---|---|---|---|---|
| install size on disk | 103 MiB | 161 MiB | 217 MiB | 279 MiB |
| start a built box | ~6 s | ~10 s \* | 0.35 s | 0.43 s |
| first-time setup | ~30 s | ~38 s \* | 1.6 s | 1.8 s |
| idle RAM | ~360 MB | ~450 MB | 146 MB | 171 MB |
| idle CPU | ~0.3% | ~0.3% \* | 0% | ~5% |
| disk per box | ~136 MB | ~305 MB | 35 MB | 26 MB |
| `npm install` (host CPU) | 3.4 s | ~3.4 s \* | 2.05 s | 5.41 s |

acage VMs share one 193 MB base image, so "disk per box" is only the writes on
top (libvirt copies the full disk instead). \* libvirt is the same KVM guest as
qemu; its time figures track qemu and were not re-measured after the boot
optimizations — run `bench/lifecycle-libvirt.sh` for exact numbers.
