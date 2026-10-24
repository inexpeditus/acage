#!/usr/bin/env bash
# acage isolation benchmark — the acage (VM) performance column.
# No sudo (qemu backend). Point it at a created VM:  bash bench/acage-perf.sh benchvm
set -euo pipefail

VM=${1:-benchvm}
SSH="ssh -F $HOME/.ssh/config -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new $VM"
VMDIR="$HOME/.local/share/agentcage/vms/$VM"
# The fixed CPU workload, identical to the container side.
CPU_JS='let x=0;for(let i=0;i<1e9;i++){x+=i};console.log(x)'

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }
secs()   { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'; }

$SSH true 2>/dev/null || { echo "cannot ssh to '$VM'" >&2; exit 1; }
echo "== acage perf (VM '$VM') ==" >&2

# --- CPU-bound: fixed node loop, 5 runs, median --------------------------------
cpu=()
for _ in 1 2 3 4 5; do
  t0=$(date +%s.%N); $SSH "node -e '$CPU_JS'" >/dev/null 2>&1; t1=$(date +%s.%N)
  cpu+=("$(secs "$t0" "$t1")")
done
CPU=$(median "${cpu[@]}")

# --- npm install: fixed deps, empty cache (matches a fresh container) ----------
t0=$(date +%s.%N)
$SSH 'rm -rf ~/perf && mkdir ~/perf && cd ~/perf && npm cache clean --force >/dev/null 2>&1; npm init -y >/dev/null 2>&1; npm install express --no-audit --no-fund >/dev/null 2>&1' || true
t1=$(date +%s.%N)
NPM=$(secs "$t0" "$t1")
$SSH 'rm -rf ~/perf' 2>/dev/null || true

# --- idle memory: RSS of the qemu process (host cost) --------------------------
MEM="?"
[ -f "$VMDIR/qemu.pid" ] && MEM=$(awk -v k="$(ps -o rss= -p "$(cat "$VMDIR/qemu.pid")" 2>/dev/null || echo 0)" 'BEGIN{printf "%.0f", k/1024}')

# --- disk: base image + this VM's disk -----------------------------------------
BASE=$(du -m "$HOME"/.cache/agentcage/images/*.qcow2 2>/dev/null | awk '{s+=$1} END{printf "%d", s}')
DISK=$(du -m "$VMDIR/disk.qcow2" 2>/dev/null | awk '{printf "%d", $1}')

# --- start time: stop, then boot a stopped VM until SSH answers ----------------
./acage stop "$VM" --backend qemu >/dev/null 2>&1 || true
sleep 2
t0=$(date +%s.%N)
./acage start "$VM" --backend qemu >/dev/null 2>&1 || true
while ! $SSH true 2>/dev/null; do
  sleep 0.3
  awk -v n="$(date +%s.%N)" -v t="$t0" 'BEGIN{exit !(n-t>120)}' && break   # 120s safety cap
done
t1=$(date +%s.%N)
START=$(secs "$t0" "$t1")

echo
echo "### acage perf"
echo "| metric | acage |"
echo "|---|---|"
echo "| start (stopped VM -> ready), s | $START |"
echo "| idle memory (qemu RSS), MB | $MEM |"
echo "| disk: base image, MB | $BASE |"
echo "| disk: per-VM, MB | $DISK |"
echo "| CPU loop (median of 5), s | $CPU |"
echo "| npm install express, s | $NPM |"
