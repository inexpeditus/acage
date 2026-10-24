#!/usr/bin/env bash
# Verify the recent changes on the LIBVIRT backend (the default) — the gap the
# qemu checks left open: boot-trims applied, warm-start time, attach auto-start.
#
# Run as your NORMAL user (acage sudo's internally; do NOT prefix sudo):
#     bash bench/verify-libvirt.sh
#
# It builds a throwaway VM, checks it, and deletes it on exit.
set -euo pipefail
[ "$(id -u)" = 0 ] && { echo "run as your normal user, NOT sudo (acage elevates itself)" >&2; exit 1; }

VM=acage-verify-lv
SSHOPT="-F $HOME/.ssh/config -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
LOGDIR=$(mktemp -d)
cd "$(dirname "$0")/.."

# Authenticate sudo once (acage needs it for the libvirt pool), keep it warm.
echo "Enter your sudo password (needed for the libvirt pool):" >&2
sudo -v || { echo "sudo auth failed" >&2; exit 1; }
( while true; do sudo -n true 2>/dev/null; sleep 50; done ) & KA=$!
trap 'kill "$KA" 2>/dev/null || true; ./acage delete "$VM" --backend libvirt -y </dev/null >/dev/null 2>&1 || true' EXIT

pass=0; fail=0
ok() { echo "  PASS $1"; pass=$((pass+1)); }
no() { echo "  FAIL $1"; fail=$((fail+1)); }
run() { ssh $SSHOPT "$VM" "$@" 2>/dev/null; }
state() { ./acage list --backend libvirt 2>/dev/null | awk -v v="$VM" '$1==v{print $2}'; }

echo "== building $VM (libvirt, a few minutes) =="
./acage delete "$VM" --backend libvirt -y </dev/null >/dev/null 2>&1 || true
if ! ./acage install "$VM" --backend libvirt --harness none -y </dev/null >"$LOGDIR/install.log" 2>&1; then
  echo "install FAILED — see $LOGDIR/install.log"; tail -25 "$LOGDIR/install.log"; exit 1
fi
run true || { echo "cannot ssh to $VM; see $LOGDIR/install.log"; exit 1; }

echo "== boot-trim fixes applied? =="
[ "$(run 'rc-update show 2>/dev/null | grep -c cloud')" = 0 ] && ok "cloud-init removed from runlevels" || no "cloud-init removed from runlevels"
run 'grep -q "^noarp" /etc/dhcpcd.conf'       && ok "dhcpcd noarp set"            || no "dhcpcd noarp set"
run 'grep -q "^rc_parallel=YES" /etc/rc.conf' && ok "rc_parallel=YES"             || no "rc_parallel=YES"
[ "$(run 'grep -c inet6 /etc/network/interfaces')" = 0 ] && ok "IPv6 DHCP dropped" || no "IPv6 DHCP dropped"
run 'wget -T4 -qO- http://1.1.1.1/ >/dev/null 2>&1' && ok "internet reachable"     || no "internet reachable"

echo "== warm start timing =="
./acage stop "$VM" --backend libvirt </dev/null >/dev/null 2>&1 || true; sleep 3
t0=$(date +%s.%N); ./acage start "$VM" --backend libvirt </dev/null >/dev/null 2>&1 || true
while ! run true; do sleep 0.3; awk -v n="$(date +%s.%N)" -v t="$t0" 'BEGIN{exit !(n-t>120)}' && break; done
echo "  warm start: $(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')s"

echo "== attach auto-start (stop, then attach must start it) =="
./acage stop "$VM" --backend libvirt </dev/null >/dev/null 2>&1 || true; sleep 3
[ "$(state)" = running ] && no "VM was still running before attach" || true
./acage attach "$VM" --backend libvirt </dev/null >"$LOGDIR/attach.log" 2>&1 || true
[ "$(state)" = running ] && ok "attach started the stopped VM" || no "attach started the stopped VM"

echo
echo "verify-libvirt: $pass passed, $fail failed  (VM will be deleted on exit)"
[ "$fail" = 0 ]
