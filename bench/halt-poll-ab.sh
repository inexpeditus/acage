#!/usr/bin/env bash
# Idle-CPU experiment: does KVM halt-polling cause acage's idle CPU?
# Measures benchvm's idle CPU at the current halt_poll_ns, then at 0, then
# restores the original value. Run as root (writes a KVM module param):
#
#     sudo bash bench/halt-poll-ab.sh
#
# Non-destructive: only touches /sys/module/kvm/parameters/halt_poll_ns and
# restores it on exit. Needs an idle benchvm already running (qemu backend).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo (writes a KVM module param)" >&2; exit 1; }

USER_HOME=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6); USER_HOME=${USER_HOME:-/home/roy}
PIDFILE="$USER_HOME/.local/share/agentcage/vms/benchvm/qemu.pid"
[ -f "$PIDFILE" ] || { echo "benchvm not found/running ($PIDFILE)" >&2; exit 1; }
P=$(cat "$PIDFILE"); HZ=$(getconf CLK_TCK)
KNOB=/sys/module/kvm/parameters/halt_poll_ns
ORIG=$(cat "$KNOB")
restore() { echo "$ORIG" >"$KNOB"; echo "restored halt_poll_ns=$ORIG" >&2; }
trap restore EXIT

cpu_ms() { awk -v hz="$HZ" '{printf "%d",($14+$15)*1000/hz}' "/proc/$P/stat"; }
sample() { local c0 c1; c0=$(cpu_ms); sleep 20; c1=$(cpu_ms); echo $((c1 - c0)); }

echo "benchvm qemu pid: $P ; measuring idle CPU over 20s per setting" >&2
echo "-- halt_poll_ns=$ORIG (current)" >&2
A=$(sample)
echo 0 >"$KNOB"
echo "-- halt_poll_ns=0" >&2
B=$(sample)

echo
echo "### idle CPU vs halt_poll_ns (benchvm, 20s samples)"
echo "| halt_poll_ns | idle CPU, ms/20s | % of one core |"
echo "|---|---|---|"
printf '| %s (default) | %s | %.1f%% |\n' "$ORIG" "$A" "$(awk -v d="$A" 'BEGIN{print d/200}')"
printf '| 0 | %s | %.1f%% |\n' "$B" "$(awk -v d="$B" 'BEGIN{print d/200}')"
