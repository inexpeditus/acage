#!/usr/bin/env bash
# libvirt backend (Linux): VMs on the system connection, defined from
# share/domain.xml, with disks in a root-owned pool directory.
# Sourced by agentcage; every backend defines the same backend_* functions.

URI=qemu:///system

backend_init() {
  POOL_DEFAULT=/var/lib/libvirt/images/agentcage
  POOL_ROOT=1
  SHARE_FSTYPE=virtiofs
  case "$(uname -m)" in
    x86_64|amd64) IMAGE_ARCH=x86_64 ;;
    *) die "The libvirt backend supports x86_64 hosts only; try --backend qemu" ;;
  esac
}

backend_check_deps() {
  need virsh "libvirt"
  need qemu-img
  need perl "to render the domain XML"
  need sudo
  if [ -n "$SHARE_DIR" ] && ! lv_have_virtiofsd; then
    die "Sharing a folder needs virtiofsd (Arch: pacman -S virtiofsd; Ubuntu: apt install virtiofsd)"
  fi
}

lv_have_virtiofsd() {
  local p
  command -v virtiofsd >/dev/null && return 0
  for p in /usr/lib/virtiofsd /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd; do
    [ -x "$p" ] && return 0
  done
  return 1
}

virsh_() {
  case "$1" in
    dominfo|domstate|domblklist|domifaddr|dumpxml|desc|pool-info|pool-list|list)
      if dry; then
        command -v virsh >/dev/null && sudo -n virsh -c "$URI" "$@" 2>/dev/null
      else
        sudo virsh -c "$URI" "$@"
      fi ;;
    *) run sudo virsh -c "$URI" "$@" ;;
  esac
}

# Pool owned by root and only traversable by others, matching libvirt's own layout.
pool_ensure() {
  run sudo mkdir -p "$POOL_DIR"
  run sudo chown root:root "$POOL_DIR"
  run sudo chmod 711 "$POOL_DIR"
}
pool_exists() { sudo test -e "$1"; }

lv_disk() { echo "$POOL_DIR/$1.qcow2"; }
lv_seed() { echo "$POOL_DIR/$1-seed.iso"; }

backend_exists() { virsh_ dominfo "$1" >/dev/null 2>&1; }
backend_running() { [ "$(virsh_ domstate "$1" 2>/dev/null | head -1)" = running ]; }

backend_create() {
  local vm=$1 disk seed tmp
  disk=$(lv_disk "$vm"); seed=$(lv_seed "$vm")
  pool_ensure
  if ! dry && pool_exists "$disk"; then die "$disk already exists"; fi

  image_prepare_disk "$disk"
  image_make_seed "$seed"

  tmp=$(mktemp -d)
  cp "$DATA_DIR/domain.xml" "$tmp/domain.xml"
  DISK=$disk VM=$vm RAM_KIB=$((RAM_MB * 1024)) VCPUS=$VCPUS SHARE=$SHARE_DIR SHARE_TAG=$SHARE_TAG perl -0pi -e '
    sub esc { my $s = shift; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g; $s }
    # Every pattern is anchored to the start of a line, so the header comment
    # is never touched.
    s{^(\s*)<name>[^<]*</name>}{$1<name>$ENV{VM}</name>}m;
    s{^(\s*<memory unit="KiB">)\d+}{$1$ENV{RAM_KIB}}m;
    s{^(\s*<currentMemory unit="KiB">)\d+}{$1$ENV{RAM_KIB}}m;
    s{^(\s*<vcpu placement="static">)\d+}{$1$ENV{VCPUS}}m;
    s{^(\s*<source file=")\@DISK_PATH\@"}{$1 . esc($ENV{DISK}) . q{"}}me;
    if (length $ENV{SHARE}) {
      s{^(\s*<source dir=")\@SHARED_DIR\@"}{$1 . esc($ENV{SHARE}) . q{"}}me;
      s{^(\s*<target dir=")[^"]*("/>\n\s*</filesystem>)}{$1$ENV{SHARE_TAG}$2}m;
    } else {
      # No shared folder: drop it and the shared memory virtiofs needs.
      s{^\s*<filesystem .*?</filesystem>\n}{}ms;
      s{^\s*<memoryBacking>.*?</memoryBacking>\n}{}ms;
    }
  ' "$tmp/domain.xml"

  log "Defining $vm"
  virsh_ define "$tmp/domain.xml"
  log "Attaching the first-boot seed and starting"
  virsh_ change-media "$vm" sda "$seed" --insert --config
  virsh_ start "$vm"
  if dry; then
    echo "(dry-run) rendered domain XML: $tmp/domain.xml (review it; nothing was defined)" >&2
  else
    rm -rf "$tmp"
  fi
}

# backend_wait VM -> sets SSH_HOST/SSH_PORT once the VM has an IP and port 22 answers.
backend_wait() {
  local vm=$1 n ip
  echo -n "Waiting for an IP" >&2
  for n in $(seq 1 60); do
    ip=$(lv_ip "$vm")
    if [ -n "$ip" ] && timeout 1 bash -c "</dev/tcp/$ip/22" 2>/dev/null; then
      echo >&2
      SSH_HOST=$ip; SSH_PORT=22
      log "VM IP: $ip"
      return 0
    fi
    echo -n "." >&2
    sleep 2
  done
  echo >&2
  echo "Could not find the VM's IP, or sshd is not answering on it." >&2
  return 1
}

lv_ip() {
  virsh_ domifaddr "$1" --source lease 2>/dev/null | awk '/ipv4/{split($4,a,"/"); print a[1]; exit}'
}

# backend_locate VM -> sets SSH_HOST/SSH_PORT for a running VM.
backend_locate() {
  backend_exists "$1" || die "No VM named '$1'"
  backend_running "$1" || die "'$1' is not running (acage start $1)"
  SSH_HOST=$(lv_ip "$1"); SSH_PORT=22
  [ -n "$SSH_HOST" ] || die "'$1' has no IP address yet; try again in a few seconds"
}

backend_start() {
  backend_exists "$1" || die "No VM named '$1'"
  if backend_running "$1"; then log "$1 is already running"; return 0; fi
  virsh_ start "$1"
}

backend_stop() {
  local n
  backend_exists "$1" || die "No VM named '$1'"
  backend_running "$1" || { log "$1 is not running"; return 0; }
  virsh_ shutdown "$1"
  dry && return 0
  echo -n "Waiting for $1 to shut down" >&2
  for n in $(seq 1 30); do
    backend_running "$1" || { echo >&2; return 0; }
    echo -n "." >&2; sleep 2
  done
  echo >&2
  warn "$1 did not shut down cleanly; forcing it off"
  virsh_ destroy "$1"
}

# Asks libvirt where the VM's files are, so this works whatever the pool was
# when the VM was created. Only files agentcage made (NAME.qcow2, NAME-seed.iso)
# are deleted.
backend_delete() {
  local vm=$1 files f
  backend_exists "$vm" || die "No VM named '$vm'"
  [ "$(virsh_ desc "$vm" 2>/dev/null)" = "Created by agentcage" ] || die "'$vm' wasn't created by agentcage; not touching it"
  files=$(virsh_ domblklist "$vm" --details 2>/dev/null | awk '$1 == "file" && $4 != "-" {print $4}')
  ! backend_running "$vm" || virsh_ destroy "$vm"
  virsh_ undefine "$vm" --nvram
  while IFS= read -r f; do
    case "$f" in
      */"$vm".qcow2|*/"$vm"-seed.iso) prun rm -f "$f" ;;
    esac
  done <<<"$files"
}

backend_list() {
  local vm state disk size
  printf '%-20s %-12s %s\n' NAME STATE DISK
  for vm in $(virsh_ list --all --name 2>/dev/null); do
    [ "$(virsh_ desc "$vm" 2>/dev/null)" = "Created by agentcage" ] || continue
    state=$(virsh_ domstate "$vm" 2>/dev/null | head -1)
    disk=$(virsh_ domblklist "$vm" --details 2>/dev/null | awk '$3 == "vda" {print $4}')
    size=$(sudo du -h "$disk" 2>/dev/null | cut -f1)
    printf '%-20s %-12s %s\n' "$vm" "$state" "$disk${size:+ ($size used)}"
  done
}

backend_console() {
  backend_exists "$1" || die "No VM named '$1'"
  echo "Serial console of $1; press Ctrl+] to leave." >&2
  exec sudo virsh -c "$URI" console "$1"
}
