#!/usr/bin/env bash
# Where does acage's ~21s warm start go? Reboots benchvm and wall-clock-stamps
# the phases: qemu launch -> firmware(OVMF) -> kernel start -> login prompt ->
# ssh ready. No sudo (qemu backend). Needs an existing benchvm.
set -euo pipefail

VM=${1:-benchvm}
SSHOPT="-F $HOME/.ssh/config -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
LOG="$HOME/.local/share/agentcage/vms/$VM/console.log"
now()  { date +%s.%N; }
d()    { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }

cd "$(dirname "$0")/.."
./acage stop "$VM" --backend qemu </dev/null >/dev/null 2>&1 || true; sleep 2
: >"$LOG" 2>/dev/null || true   # qemu reopens/truncates on start; read whole file

t0=$(now); ./acage start "$VM" --backend qemu </dev/null >/dev/null 2>&1 || true
tfw="" tkern="" tlogin="" tssh=""
while :; do
  n=$(now)
  if [ -z "$tfw" ]    && [ -s "$LOG" ]; then tfw=$n; fi
  if [ -z "$tkern" ]  && grep -q '\[    0\.000000\]' "$LOG" 2>/dev/null; then tkern=$n; fi
  if [ -z "$tlogin" ] && grep -qi 'login:' "$LOG" 2>/dev/null; then tlogin=$n; fi
  # only probe ssh once the login prompt is up, so the blocking probe can't
  # quantize the console-based phase markers above
  if [ -n "$tlogin" ] && [ -z "$tssh" ] && ssh $SSHOPT "$VM" true 2>/dev/null; then tssh=$n; break; fi
  if awk -v n="$n" -v t="$t0" 'BEGIN{exit !(n-t>90)}'; then break; fi
  sleep 0.2
done

# kernel's own last timestamp = how long the kernel itself ran to its last log
klast=$( { grep -oE '^\[[[:space:]]*[0-9]+\.[0-9]+\]' "$LOG" 2>/dev/null || true; } | tr -d '[] ' | sort -n | tail -1)

echo
echo "### warm-start phase breakdown ($VM), seconds from qemu launch"
echo "| phase | wall @ | duration |"
echo "|---|---|---|"
printf '| firmware (OVMF) starts | %s | %s |\n' "$(d "$t0" "${tfw:-$t0}")" "$(d "$t0" "${tfw:-$t0}")"
printf '| kernel handoff | %s | %s (OVMF+bootloader) |\n' "$(d "$t0" "${tkern:-$t0}")" "$(d "${tfw:-$t0}" "${tkern:-$t0}")"
printf '| login prompt | %s | %s (kernel+userspace) |\n' "$(d "$t0" "${tlogin:-$t0}")" "$(d "${tkern:-$t0}" "${tlogin:-$t0}")"
printf '| ssh ready | %s | %s (sshd+net+poll) |\n' "$(d "$t0" "${tssh:-$t0}")" "$(d "${tlogin:-$t0}" "${tssh:-$t0}")"
echo
echo "kernel's own last timestamp (internal boot time): ${klast:-?} s"
echo "total warm start: $(d "$t0" "${tssh:-$t0}") s"
