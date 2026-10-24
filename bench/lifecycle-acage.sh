#!/usr/bin/env bash
# Lifecycle benchmark — acage-qemu column. No sudo (qemu backend runs as you).
# Reuses an existing idle VM for the runtime rows and a throwaway for the
# provision/teardown rows, so your main VM survives.
#
#   ./acage install benchvm --backend qemu --harness none -y   # once, beforehand
#   bash bench/lifecycle-acage.sh benchvm
set -euo pipefail

VM=${1:-benchvm}
TMPVM=benchvm-tmp
SSHOPT="-F $HOME/.ssh/config -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
CPU_JS='let x=0;for(let i=0;i<1e9;i++){x+=i};console.log(x)'
CACHE="$HOME/.cache/agentcage/images"
VMS="$HOME/.local/share/agentcage/vms"

now()  { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'; }
# host CPU (utime+stime, incl. KVM guest time) of a process, in ms
pcpu() { local p=$1 hz; hz=$(getconf CLK_TCK); awk -v hz="$hz" '{printf "%d",($14+$15)*1000/hz}' "/proc/$p/stat" 2>/dev/null || echo 0; }
qpid() { cat "$VMS/$1/qemu.pid" 2>/dev/null || echo ""; }
rxbytes() { ssh $SSHOPT "$1" 'cat /sys/class/net/eth*/statistics/rx_bytes 2>/dev/null | awk "{s+=\$1} END{print s}"' 2>/dev/null || echo 0; }
wait_ready() { local v=$1 t0; t0=$(now); until ssh $SSHOPT "$v" true 2>/dev/null; do sleep 0.3; awk -v n="$(now)" -v t="$t0" 'BEGIN{exit !(n-t>150)}' && return 1; done; }
du_mb() { { du -sm "$1" 2>/dev/null || echo "0 _"; } | awk '{print $1+0; exit}'; }   # pipefail-safe

cd "$(dirname "$0")/.."
ssh $SSHOPT "$VM" true 2>/dev/null || { echo "need a running VM '$VM'" >&2; exit 1; }
declare -A R

# --- provision: fresh create -> ready, plus bytes pulled on first boot --------
echo "-- provision (fresh VM, times apk installs over the network)" >&2
./acage delete "$TMPVM" --backend qemu -y >/dev/null 2>&1 || true
t0=$(now)
./acage install "$TMPVM" --backend qemu --harness none -y >/dev/null 2>&1 || true
wait_ready "$TMPVM" || true
t1=$(now)
R[provision]=$(secs "$t0" "$t1")
R[provision_net]=$(awk -v b="$(rxbytes "$TMPVM")" 'BEGIN{printf "%.0f", b/1048576}')

# --- teardown: delete the fresh VM, reclaimed disk ----------------------------
before=$(du_mb "$VMS/$TMPVM")
t0=$(now); ./acage delete "$TMPVM" --backend qemu -y >/dev/null 2>&1 || true; t1=$(now)
R[teardown]=$(secs "$t0" "$t1"); R[teardown_reclaimed]=${before:-0}

# --- warm start: stop then boot the existing VM -> ready ----------------------
echo "-- warm start" >&2
./acage stop "$VM" --backend qemu >/dev/null 2>&1 || true; sleep 2
t0=$(now); ./acage start "$VM" --backend qemu >/dev/null 2>&1 || true; wait_ready "$VM" || true; t1=$(now)
R[start]=$(secs "$t0" "$t1")

# --- idle: total host RAM (qemu RSS, +0 daemon) and idle CPU over 30s ---------
echo "-- idle (30s)" >&2
p=$(qpid "$VM")
R[idle_ram]=$(awk -v k="$(ps -o rss= -p "$p" 2>/dev/null || echo 0)" 'BEGIN{printf "%.0f", k/1024}')
c0=$(pcpu "$p"); sleep 30; c1=$(pcpu "$p"); R[idle_cpu]=$((c1 - c0))

# --- CPU task: wall + host CPU-seconds (qemu process) -------------------------
echo "-- cpu task" >&2
p=$(qpid "$VM"); c0=$(pcpu "$p"); t0=$(now)
ssh $SSHOPT "$VM" "node -e '$CPU_JS'" >/dev/null 2>&1 || true
t1=$(now); c1=$(pcpu "$p")
R[cpu_wall]=$(secs "$t0" "$t1"); R[cpu_hostcpu]=$(awk -v m="$((c1 - c0))" 'BEGIN{printf "%.2f", m/1000}')

# --- npm install: wall + host CPU-seconds + bytes -----------------------------
echo "-- npm install" >&2
rx0=$(rxbytes "$VM"); p=$(qpid "$VM"); c0=$(pcpu "$p"); t0=$(now)
ssh $SSHOPT "$VM" 'rm -rf ~/perf && mkdir ~/perf && cd ~/perf && npm cache clean --force >/dev/null 2>&1; npm init -y >/dev/null 2>&1; npm install express --no-audit --no-fund >/dev/null 2>&1' || true
t1=$(now); c1=$(pcpu "$p"); rx1=$(rxbytes "$VM")
ssh $SSHOPT "$VM" 'rm -rf ~/perf' 2>/dev/null || true
R[npm_wall]=$(secs "$t0" "$t1"); R[npm_hostcpu]=$(awk -v m="$((c1 - c0))" 'BEGIN{printf "%.2f", m/1000}')
R[npm_net]=$(awk -v b="$((rx1 - rx0))" 'BEGIN{printf "%.1f", b/1048576}')

# --- disk: shared base image + this VM's files --------------------------------
R[base_disk]=$(du_mb "$CACHE")
R[box_disk]=$(du_mb "$VMS/$VM")

echo
echo "### acage-qemu lifecycle"
echo "| metric | acage-qemu |"
echo "|---|---|"
echo "| provision (fresh -> ready), s | ${R[provision]} |"
echo "| provision network, MB | ${R[provision_net]} |"
echo "| warm start -> ready, s | ${R[start]} |"
echo "| idle total RAM, MB | ${R[idle_ram]} |"
echo "| idle CPU /30s, ms | ${R[idle_cpu]} |"
echo "| disk: shared base, MB | ${R[base_disk]} |"
echo "| disk: per-box, MB | ${R[box_disk]} |"
echo "| CPU task wall, s | ${R[cpu_wall]} |"
echo "| CPU task host CPU, s | ${R[cpu_hostcpu]} |"
echo "| npm install wall, s | ${R[npm_wall]} |"
echo "| npm install host CPU, s | ${R[npm_hostcpu]} |"
echo "| npm install network, MB | ${R[npm_net]} |"
echo "| teardown, s | ${R[teardown]} |"
echo "| teardown reclaimed, MB | ${R[teardown_reclaimed]} |"
