#!/usr/bin/env bash
# acage isolation benchmark — the acage (VM) column.
#
# Runs the same probes as bench/run.sh, but inside a running acage VM over SSH.
# This half needs NO sudo: the qemu backend runs as your user. Point it at a
# VM you have already created, e.g.:
#
#     ./acage install benchvm --backend qemu --harness none -y
#     bash bench/acage-column.sh benchvm
#
# It is read-only against the VM and non-destructive on the host (one scratch
# listener, killed on exit).
set -euo pipefail

VM=${1:-benchvm}
SSH="ssh -F $HOME/.ssh/config -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new $VM"

cleanup() { [ -n "${LISTENER_PID:-}" ] && kill "$LISTENER_PID" 2>/dev/null || true; }
trap cleanup EXIT

$SSH true 2>/dev/null || { echo "cannot ssh to '$VM' (is it running? 'acage list --backend qemu')" >&2; exit 1; }

declare -A r

# P1 shared kernel: the VM runs its own kernel, so uname differs from the host.
guest_kern=$($SSH 'uname -r' 2>/dev/null || echo '?')
[ "$guest_kern" = "$(uname -r)" ] && r[kernel]=yes || r[kernel]="no ($guest_kern)"

# P2 host FS beyond mount: a separate machine; the VM's /etc/hostname is its own.
host_hn=$(cat /etc/hostname 2>/dev/null || echo host)
guest_hn=$($SSH 'cat /etc/hostname 2>/dev/null || echo none' 2>/dev/null || echo none)
[ "$guest_hn" = "$host_hn" ] && r[fs]=yes || r[fs]=no

# P3 mounted project: nothing is shared by default (--share is opt-in, warns,
# and refuses home/credential dirs), so there is no host path to write.
r[mount]="n/a (no share by default)"

# P4 reach host network: start a host listener; from the VM the host is the
# SLIRP gateway 10.0.2.2. The in-VM firewall should drop it. Also confirm the
# internet IS reachable, so we are measuring the firewall, not a dead network.
LISTEN_PORT=$(( (RANDOM % 20000) + 20000 ))
python3 -m http.server "$LISTEN_PORT" --bind 0.0.0.0 >/dev/null 2>&1 &
LISTENER_PID=$!
sleep 1
r[host]=$($SSH "wget -T 3 -q -O- http://10.0.2.2:$LISTEN_PORT/ >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null || echo no)
r[inet]=$($SSH 'wget -T 5 -q -O- http://1.1.1.1/ >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null || echo no)

# P5 docker API: not applicable; the VM runs no docker and exposes no socket.
r[sock]="n/a"

echo
echo "### acage column (VM '$VM', live over SSH)"
echo
echo "| probe | acage |"
echo "|---|---|"
echo "| shared kernel | ${r[kernel]} |"
echo "| host FS beyond mount | ${r[fs]} |"
echo "| mounted project writable | ${r[mount]} |"
echo "| reach host network | ${r[host]} |"
echo "| docker API (=host root) | ${r[sock]} |"
echo
echo "(sanity: internet reachable from the VM = ${r[inet]} — so 'reach host network = ${r[host]}' is the firewall, not a dead link.)"
