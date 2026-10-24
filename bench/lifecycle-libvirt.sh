#!/usr/bin/env bash
# Lifecycle benchmark — acage-libvirt column.
# Run as your NORMAL user (NOT sudo): acage refuses to run as root, and its
# libvirt backend elevates with sudo itself only for the pool. It will prompt
# for your sudo password once (cached for the rest of the run).
#
#     bash bench/lifecycle-libvirt.sh
set -euo pipefail

[ "$(id -u)" = 0 ] && { echo "run as your normal user, NOT sudo (acage sudo's internally)" >&2; exit 1; }

# acage prompts for sudo (libvirt pool) from inside calls whose output we
# redirect to a log, so the prompt would be invisible and hang. Authenticate
# up front (visible), then keep the credential warm for the whole run.
echo "Enter your sudo password (needed for the libvirt pool):" >&2
sudo -v || { echo "sudo authentication failed" >&2; exit 1; }
( while true; do sudo -n true 2>/dev/null; sleep 50; done ) & SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT

case "${1:-}" in -v|--verbose|"") VM=benchvm-lv ;; *) VM=$1 ;; esac   # ignore a stray -v
DAEMON_RSS_MB=50   # libvirtd + dnsmasq standing cost, from Test 1
CPU_JS='let x=0;for(let i=0;i<1e9;i++){x+=i};console.log(x)'
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/agentcage/images"
LOGDIR=$(mktemp -d)   # user-owned, avoids root-owned leftover log files

SSHOPT="-F $HOME/.ssh/config -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
now()  { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'; }
pcpu() { local p=$1 hz; hz=$(getconf CLK_TCK); awk -v hz="$hz" '{printf "%d",($14+$15)*1000/hz}' "/proc/$p/stat" 2>/dev/null || echo 0; }
qpid() { pgrep -f "guest=$1," | head -1; }   # libvirt's qemu process for this domain
rxbytes() { ssh $SSHOPT "$1" 'cat /sys/class/net/eth*/statistics/rx_bytes 2>/dev/null | awk "{s+=\$1} END{print s}"' 2>/dev/null || echo 0; }
du_mb()   { { du -scm "$@" 2>/dev/null || echo "0 _"; } | awk 'END{print $1+0}'; }
sdu_mb()  { { sudo du -scm "$@" 2>/dev/null || echo "0 _"; } | awk 'END{print $1+0}'; }  # pool is root-owned
wait_ready() { local v=$1 t0; t0=$(now); until ssh $SSHOPT "$v" true 2>/dev/null; do sleep 0.3; awk -v n="$(now)" -v t="$t0" 'BEGIN{exit !(n-t>180)}' && return 1; done; }

cd "$(dirname "$0")/.."
declare -A R

echo "-- provision  (this is the long silent phase, ~30-100s)" >&2
echo "   watch it live in another terminal:  tail -f $LOGDIR/install.log" >&2
echo "   or:  watch -n1 'sudo virsh list --all'" >&2
./acage delete "$VM" --backend libvirt -y </dev/null >"$LOGDIR/del.log" 2>&1 || true
t0=$(now)
# </dev/null forces non-interactive: use flags + defaults, no prompts, no attach.
./acage -v install "$VM" --backend libvirt --harness none --ram 2048 --vcpus 2 --disk 10 -y </dev/null 2>&1 | tee "$LOGDIR/install.log" || true
wait_ready "$VM" || echo "   (warning: VM not reachable; see $LOGDIR/install.log)" >&2
t1=$(now)
R[provision]=$(secs "$t0" "$t1")
R[provision_net]=$(awk -v b="$(rxbytes "$VM")" 'BEGIN{printf "%.0f", b/1048576}')

echo "-- warm start (stopping, then timing a cold boot to ssh-ready)" >&2
./acage stop "$VM" --backend libvirt </dev/null 2>&1 | tee "$LOGDIR/stop.log" || true; sleep 3
t0=$(now); ./acage -v start "$VM" --backend libvirt </dev/null 2>&1 | tee "$LOGDIR/start.log" || true; wait_ready "$VM" || true; t1=$(now)
R[start]=$(secs "$t0" "$t1")

echo "-- idle (sampling host RAM + CPU for 30s, no activity)" >&2
p=$(qpid "$VM")
box=$(awk -v k="$(ps -o rss= -p "${p:-0}" 2>/dev/null || echo 0)" 'BEGIN{printf "%.0f", k/1024}')
R[idle_box]=$box; R[idle_ram]=$(awk -v b="$box" -v d="$DAEMON_RSS_MB" 'BEGIN{printf "%.0f", b+d}')
c0=$(pcpu "${p:-0}"); sleep 30; c1=$(pcpu "${p:-0}"); R[idle_cpu]=$((c1 - c0))

echo "-- cpu task (running a fixed node loop in the VM over ssh, ~8s)" >&2
p=$(qpid "$VM"); c0=$(pcpu "${p:-0}"); t0=$(now)
ssh $SSHOPT "$VM" "node -e '$CPU_JS'" >/dev/null 2>&1 || true
t1=$(now); c1=$(pcpu "${p:-0}")
R[cpu_wall]=$(secs "$t0" "$t1"); R[cpu_host]=$(awk -v m="$((c1 - c0))" 'BEGIN{printf "%.2f", m/1000}')

echo "-- npm install (installing express in the VM over ssh, ~5s)" >&2
rx0=$(rxbytes "$VM"); p=$(qpid "$VM"); c0=$(pcpu "${p:-0}"); t0=$(now)
ssh $SSHOPT "$VM" 'rm -rf ~/perf && mkdir ~/perf && cd ~/perf && npm cache clean --force >/dev/null 2>&1; npm init -y >/dev/null 2>&1; npm install express --no-audit --no-fund >/dev/null 2>&1' || true
t1=$(now); c1=$(pcpu "${p:-0}"); rx1=$(rxbytes "$VM")
ssh $SSHOPT "$VM" 'rm -rf ~/perf' 2>/dev/null || true
R[npm_wall]=$(secs "$t0" "$t1"); R[npm_host]=$(awk -v m="$((c1 - c0))" 'BEGIN{printf "%.2f", m/1000}')
R[npm_net]=$(awk -v b="$((rx1 - rx0))" 'BEGIN{printf "%.1f", b/1048576}')

R[base_disk]=$(du_mb "$CACHE")
# discover this domain's disk files from libvirt (pool location can vary)
disks=$(sudo virsh -c qemu:///system domblklist "$VM" --details 2>/dev/null | awk '$1=="file" && $4!="-" {print $4}')
# shellcheck disable=SC2086
R[box_disk]=$(sdu_mb $disks)

echo "-- teardown" >&2
t0=$(now); ./acage delete "$VM" --backend libvirt -y </dev/null >/dev/null 2>&1 || true; t1=$(now)
R[teardown]=$(secs "$t0" "$t1"); R[teardown_reclaimed]=${R[box_disk]}

echo
echo "### acage-libvirt lifecycle"
echo "| metric | acage-libvirt |"
echo "|---|---|"
echo "| provision (fresh -> ready), s | ${R[provision]} |"
echo "| provision network, MB | ${R[provision_net]} |"
echo "| warm start -> ready, s | ${R[start]} |"
echo "| idle box RSS (qemu), MB | ${R[idle_box]} |"
echo "| idle total RAM (box+daemon), MB | ${R[idle_ram]} |"
echo "| idle CPU /30s, ms | ${R[idle_cpu]} |"
echo "| disk: shared base, MB | ${R[base_disk]} |"
echo "| disk: per-box, MB | ${R[box_disk]} |"
echo "| CPU task wall, s | ${R[cpu_wall]} |"
echo "| CPU task host CPU, s | ${R[cpu_host]} |"
echo "| npm install wall, s | ${R[npm_wall]} |"
echo "| npm install host CPU, s | ${R[npm_host]} |"
echo "| npm install network, MB | ${R[npm_net]} |"
echo "| teardown, s | ${R[teardown]} |"
echo "| teardown reclaimed, MB | ${R[teardown_reclaimed]} |"
