#!/usr/bin/env bash
# qemu backend (Linux without libvirt): runs QEMU directly as your user, with
# KVM acceleration. Each VM lives in
# $POOL_DIR/vms/NAME; SSH reaches it through a port forwarded on 127.0.0.1.
# Sourced by agentcage; every backend defines the same backend_* functions.

backend_init() {
  POOL_DEFAULT=${XDG_DATA_HOME:-$HOME/.local/share}/agentcage
  POOL_ROOT=0
  SHARE_FSTYPE=9p
  case "$(uname -m)" in
    x86_64|amd64) IMAGE_ARCH=x86_64 ;;
    arm64|aarch64) IMAGE_ARCH=aarch64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  QEMU_ACCEL=kvm
  QEMU_BIN=qemu-system-$IMAGE_ARCH
}

# Collects every missing tool (via want) and reports them together, then
# checks the things no package install fixes: KVM access and UEFI firmware.
backend_check_deps() {
  want "$QEMU_BIN"; want qemu-img
  report_missing
  [ -r /dev/kvm ] && [ -w /dev/kvm ] || die "No access to /dev/kvm (add yourself to the 'kvm' group and log in again)"
  qemu_firmware
}

pool_ensure() { run mkdir -p "$POOL_DIR/vms"; run chmod 700 "$POOL_DIR"; }
pool_exists() { [ -e "$1" ]; }

vm_dir() { echo "$POOL_DIR/vms/$1"; }

# Unix socket paths must stay under ~104 bytes, which a VM directory under a
# long home folder can exceed, so the sockets live in a short private dir.
qemu_sock_dir() {
  local d="/tmp/agentcage-$(id -u)"
  if dry; then echo "$d"; return; fi
  mkdir -p -m 700 "$d" 2>/dev/null || true
  [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || die "$d is not a private directory owned by you"
  chmod 700 "$d"
  echo "$d"
}

# QEMU option values separate fields with commas; a literal comma is doubled.
qesc() { printf '%s' "${1//,/,,}"; }

# qemu_firmware -> sets FW_CODE and FW_VARS to a matching UEFI code/vars pair.
qemu_firmware() {
  local pairs pair code vars
  if [ "$IMAGE_ARCH" = aarch64 ]; then
    pairs="/usr/share/qemu/edk2-aarch64-code.fd:/usr/share/qemu/edk2-arm-vars.fd
/usr/share/AAVMF/AAVMF_CODE.fd:/usr/share/AAVMF/AAVMF_VARS.fd
/usr/share/edk2/aarch64/QEMU_CODE.fd:/usr/share/edk2/aarch64/QEMU_VARS.fd"
  else
    pairs="/usr/share/qemu/edk2-x86_64-code.fd:/usr/share/qemu/edk2-i386-vars.fd
/usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd
/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd
/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd
/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"
  fi
  while IFS= read -r pair; do
    code=${pair%%:*}; vars=${pair#*:}
    if [ -f "$code" ] && [ -f "$vars" ]; then FW_CODE=$code; FW_VARS=$vars; return 0; fi
  done <<<"$pairs"
  dry && { FW_CODE="<uefi-code.fd>"; FW_VARS="<uefi-vars.fd>"; return 0; }
  die "No UEFI firmware for $IMAGE_ARCH found (Ubuntu: apt install ovmf; Arch: pacman -S edk2-ovmf)"
}

backend_exists() { [ -f "$(vm_dir "$1")/config" ]; }

# Loads a VM's saved settings into C_* variables.
qemu_load() {
  backend_exists "$1" || die "No VM named '$1'"
  # shellcheck source=/dev/null
  . "$(vm_dir "$1")/config"
}

qemu_pid() {
  local f pid
  f="$(vm_dir "$1")/qemu.pid"
  [ -f "$f" ] || return 1
  pid=$(cat "$f")
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o comm= | grep -q qemu || return 1
  echo "$pid"
}
backend_running() { qemu_pid "$1" >/dev/null; }

# A port on 127.0.0.1 that is free now and not reserved by another VM.
qemu_free_port() {
  local p taken
  taken=$(cat "$POOL_DIR"/vms/*/config 2>/dev/null | sed -n 's/^C_SSH_PORT=//p')
  for p in $(seq 2222 2399); do
    printf '%s\n' "$taken" | grep -qx "$p" && continue
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && continue
    echo "$p"; return 0
  done
  die "No free port between 2222 and 2399"
}

backend_create() {
  local vm=$1 dir port
  dir=$(vm_dir "$vm")
  pool_ensure
  [ ! -e "$dir" ] || die "$dir already exists"
  run mkdir -p "$dir"
  image_prepare_disk "$dir/disk.qcow2"
  image_make_seed "$dir/seed.iso"
  [ -n "${FW_VARS:-}" ] || qemu_firmware
  run cp "$FW_VARS" "$dir/vars.fd"
  run chmod 600 "$dir/vars.fd"
  port=$(qemu_free_port)
  if dry; then
    echo "(dry-run) would save settings to $dir/config (SSH on 127.0.0.1:$port)" >&2
    C_RAM_MB=$RAM_MB C_VCPUS=$VCPUS C_SSH_PORT=$port C_SHARE_DIR=$SHARE_DIR
    qemu_launch "$vm"
    return
  fi
  {
    printf 'C_RAM_MB=%q\n' "$RAM_MB"
    printf 'C_VCPUS=%q\n' "$VCPUS"
    printf 'C_SSH_PORT=%q\n' "$port"
    printf 'C_SHARE_DIR=%q\n' "$SHARE_DIR"
  } >"$dir/config"
  if ! backend_start "$vm"; then
    rm -rf "$dir"
    die "QEMU did not start; removed the half-created VM"
  fi
}

qemu_launch() {
  local vm=$1 dir machine sock
  dir=$(vm_dir "$vm")
  sock=$(qemu_sock_dir)
  [ -n "${FW_CODE:-}" ] || qemu_firmware
  # hpet=off removes the emulated HPET timer (x86): smaller device surface and
  # fewer timer-driven VM exits. libvirt's domain template already does this.
  if [ "$IMAGE_ARCH" = aarch64 ]; then machine=virt; else machine=q35,hpet=off; fi
  local args=(
    -name "$vm" -machine "$machine" -accel "$QEMU_ACCEL" -cpu host
    -smp "$C_VCPUS" -m "$C_RAM_MB"
    -nodefaults -no-user-config -display none
    -drive "if=pflash,format=raw,readonly=on,file=$(qesc "$FW_CODE")"
    -drive "if=pflash,format=raw,file=$(qesc "$dir/vars.fd")"
    -drive "if=virtio,format=qcow2,discard=unmap,file=$(qesc "$dir/disk.qcow2")"
    -drive "if=virtio,format=raw,readonly=on,file=$(qesc "$dir/seed.iso")"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$C_SSH_PORT-:22"
    -device virtio-net-pci,netdev=net0
    -device virtio-rng-pci
    -smbios "type=1,serial=ds=nocloud"
    -chardev "socket,id=con0,path=$(qesc "$sock/$vm.console"),server=on,wait=off,logfile=$(qesc "$dir/console.log")"
    -serial chardev:con0
    -monitor "unix:$(qesc "$sock/$vm.monitor"),server=on,wait=off"
    -pidfile "$dir/qemu.pid" -daemonize
  )
  if [ -n "$C_SHARE_DIR" ]; then
    dry || [ -d "$C_SHARE_DIR" ] || die "Shared folder $C_SHARE_DIR no longer exists"
    # security_model=none: files are created as your user on the host, never as root.
    args+=(-virtfs "local,path=$(qesc "$C_SHARE_DIR"),mount_tag=$SHARE_TAG,security_model=none,id=fs0")
  fi
  log "Starting $vm (SSH on 127.0.0.1:$C_SSH_PORT)"
  run "$QEMU_BIN" "${args[@]}"
}

backend_start() {
  qemu_load "$1"
  if backend_running "$1"; then log "$1 is already running"; return 0; fi
  rm -f "$(qemu_sock_dir)/$1".{console,monitor}
  qemu_launch "$1"
}

# backend_wait VM -> sets SSH_HOST/SSH_PORT. The port forward accepts
# connections as soon as QEMU runs, so readiness is left to the key-login wait.
backend_wait() {
  qemu_load "$1"
  SSH_HOST=127.0.0.1; SSH_PORT=$C_SSH_PORT
  sleep 2
  backend_running "$1" || { echo "QEMU exited; see $(vm_dir "$1")/console.log" >&2; return 1; }
}

backend_locate() {
  qemu_load "$1"
  backend_running "$1" || die "'$1' is not running (acage start $1)"
  SSH_HOST=127.0.0.1; SSH_PORT=$C_SSH_PORT
}

# Sends an ACPI power-button press through the QEMU monitor, then waits;
# falls back to terminating QEMU.
backend_stop() {
  local pid n sock
  qemu_load "$1"
  pid=$(qemu_pid "$1") || { log "$1 is not running"; return 0; }
  sock="$(qemu_sock_dir)/$1.monitor"
  if dry; then run kill "$pid"; return 0; fi
  if command -v nc >/dev/null && printf 'system_powerdown\n' | nc -U -w 1 "$sock" >/dev/null 2>&1; then
    echo -n "Waiting for $1 to shut down" >&2
    for n in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || { echo >&2; return 0; }
      echo -n "." >&2; sleep 2
    done
    echo >&2
    warn "$1 did not shut down cleanly; stopping QEMU"
  fi
  kill "$pid" 2>/dev/null || true
  for n in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
  kill -9 "$pid" 2>/dev/null || true
}

backend_delete() {
  local pid
  qemu_load "$1"
  if pid=$(qemu_pid "$1"); then run kill "$pid"; fi
  run rm -rf "$(vm_dir "$1")"
  run rm -f "$(qemu_sock_dir)/$1".{console,monitor}
  dry || rmdir "$(qemu_sock_dir)" 2>/dev/null || true
}

backend_list() {
  local d vm state
  printf '%-20s %-10s %s\n' NAME STATE SSH
  for d in "$POOL_DIR"/vms/*/; do
    [ -f "$d/config" ] || continue
    vm=$(basename "$d")
    (
      qemu_load "$vm"
      if backend_running "$vm"; then state=running; else state=stopped; fi
      printf '%-20s %-10s 127.0.0.1:%s%s\n' "$vm" "$state" "$C_SSH_PORT" "${C_SHARE_DIR:+  shares $C_SHARE_DIR}"
    )
  done
}

backend_console() {
  local log
  qemu_load "$1"
  log="$(vm_dir "$1")/console.log"
  [ -f "$log" ] || die "No console output yet for '$1'"
  echo "Boot/console output of $1 (Ctrl+C to stop following):" >&2
  exec tail -n 100 -f "$log"
}
