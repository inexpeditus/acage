#!/usr/bin/env bash
# Standalone, self-contained copy of the Alpine preinstalled-image install method.
#
# This folder works without the rest of the repo: it downloads and verifies
# Alpine's official cloud image, builds a small first-boot (cloud-init) config
# with your SSH key, and boots a hardened libvirt VM from it. See README.md.
#
# It is a snapshot taken from ../lib/image.sh, ../guests/alpine/profile.sh and
# ../agent_box.xml. Those files are the maintained originals; fixes made there
# are not automatically reflected here. See README.md.
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
URI=qemu:///system
VM=alpine-box
RAM_MB=2048
VCPUS=2
DISK_GB=10
POOL_DIR=/home/alpine-sandbox
GUEST_USER=""
GUEST_DOAS=1
GUEST_PW_HASH=""
ASK_PW=0
SSH_PUBKEY=""
XML="$DIR/domain.xml"
DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=0
NO_WAIT=0
NAME_SET=0; USER_SET=0; RAM_SET=0; VCPUS_SET=0; DISK_SET=0; POOL_SET=0; KEY_SET=0; DOAS_SET=0; PW_SET=0

usage() {
  cat <<EOF
Usage: $0 [options] <command>

Commands:
  install    Download and verify the image, then create and boot the VM (image + create)
  image      Download and verify the latest Alpine cloud image only
  create     Using an already-downloaded image: prepare the disk, build the
             first-boot seed, define and start the VM

Options:
  --name NAME       VM name (default: $VM)
  --user NAME       Guest username to create (required for 'create')
  --ram MB          RAM in MB (default: $RAM_MB)
  --vcpus N         vCPUs (default: $VCPUS)
  --disk GB         Disk size in GB (default: $DISK_GB)
  --pool-dir DIR    Where the disk, image and seed are stored (default: $POOL_DIR)
  --ssh-pubkey FILE Public key to authorize in the VM (default: ~/.ssh/id_agentbox.pub, created if missing)
  --no-doas         Do not give the guest user root access (default: root via doas)
  --password        Prompt for a password for the guest user. doas then asks for
                    it, and it works for console login and su. Without one, doas
                    runs without a password. SSH stays key-only either way.
  --no-wait         After 'create', print next steps instead of waiting and connecting
  -n, --dry-run     Print state-changing commands instead of running them

Any of the above left unset is asked about interactively before 'create'/'all'
runs (skipped if input isn't a terminal, e.g. when piped or scripted).
  -y, --yes         Do not prompt to confirm the image-signing fingerprint
  -h, --help        Show this help
EOF
}

cmds=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name) VM=$2; NAME_SET=1; shift 2 ;;
    --user) GUEST_USER=$2; USER_SET=1; shift 2 ;;
    --ram) RAM_MB=$2; RAM_SET=1; shift 2 ;;
    --vcpus) VCPUS=$2; VCPUS_SET=1; shift 2 ;;
    --disk) DISK_GB=$2; DISK_SET=1; shift 2 ;;
    --pool-dir) POOL_DIR=$2; POOL_SET=1; shift 2 ;;
    --ssh-pubkey) SSH_PUBKEY=$2; KEY_SET=1; shift 2 ;;
    --doas|--sudo) GUEST_DOAS=1; DOAS_SET=1; shift ;;
    --no-doas) GUEST_DOAS=0; DOAS_SET=1; shift ;;
    --password) ASK_PW=1; PW_SET=1; shift ;;
    --no-wait) NO_WAIT=1; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) cmds+=("$1"); shift ;;
  esac
done
[ ${#cmds[@]} -gt 0 ] || { usage; exit 1; }
[[ "$VM" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid VM name '$VM'" >&2; exit 1; }

# shellcheck source=/dev/null
source "$DIR/common.sh"
# shellcheck source=/dev/null
source "$DIR/profile.sh"
# shellcheck source=/dev/null
source "$DIR/image-helpers.sh"
# shellcheck source=/dev/null
source "$DIR/provision.sh"

# Ask about anything 'create'/'all' needs that wasn't given on the command line.
# Skipped for 'image' alone, and skipped entirely when not running interactively
# (piped input, cron, etc.), in which case the flags/defaults above are used as-is.
needs_create=0
for c in "${cmds[@]}"; do [ "$c" = create ] || [ "$c" = install ] || [ "$c" = all ] && needs_create=1; done
if [ "$needs_create" = 1 ] && [ -t 0 ]; then
  echo "Settings (press Enter to keep each default):"
  [ "$NAME_SET" = 1 ]  || ask VM "VM name" "$VM"
  [ "$USER_SET" = 1 ]  || ask GUEST_USER "Guest username to create" "${GUEST_USER:-$USER}"
  [ "$RAM_SET" = 1 ]   || ask RAM_MB "RAM in MB" "$RAM_MB"
  [ "$VCPUS_SET" = 1 ] || ask VCPUS "vCPUs" "$VCPUS"
  [ "$DISK_SET" = 1 ]  || ask DISK_GB "Disk size in GB" "$DISK_GB"
  [ "$POOL_SET" = 1 ]  || ask POOL_DIR "Disk/image/seed directory" "$POOL_DIR"
  [ "$KEY_SET" = 1 ]   || ask SSH_PUBKEY "SSH public key to authorize (empty: ~/.ssh/id_agentbox.pub, created if missing)" "$SSH_PUBKEY"
  [ "$DOAS_SET" = 1 ]  || { yesno "Give '$GUEST_USER' root access in the VM (doas)?" y && GUEST_DOAS=1 || GUEST_DOAS=0; }
  [ "$PW_SET" = 1 ]    || { yesno "Set a password for '$GUEST_USER' (doas asks for it; console login)?" n && ASK_PW=1; }
  echo
  [[ "$VM" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid VM name '$VM'" >&2; exit 1; }
fi
if [ "$needs_create" = 1 ] && [ "$ASK_PW" = 1 ]; then
  [ -t 0 ] || die "--password needs an interactive terminal"
  ask_password GUEST_PW_HASH "Password for '$GUEST_USER' in the VM"
fi

cmd_image() {
  log "Guest: Alpine Linux (preinstalled image)"
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}"
  mkdir -p "$cache"
  IMG_TMP=$(mktemp -d -p "$cache" alpine-image.XXXXXX)
  trap 'rm -rf "${IMG_TMP:-}"' EXIT
  alpine_image_fetch
}

cmd_create() {
  image_validate
  virsh_ dominfo "$VM" >/dev/null 2>&1 && { echo "VM '$VM' already exists" >&2; exit 1; }
  [ -f "$HOME/.ssh/known_hosts" ] && run ssh-keygen -R "$VM"

  ensure_pool_dir
  local disk="$POOL_DIR/$VM.qcow2"
  if ! dry && sudo test -e "$disk"; then die "$disk already exists"; fi

  image_prepare_disk "$disk"
  image_make_seed

  command -v perl >/dev/null || die "perl is required to render the domain XML"
  local tmp; tmp=$(mktemp --suffix=.xml)
  cp "$XML" "$tmp"
  DISK=$disk perl -0pi -e '
    s{\s*<uuid>.*?</uuid>}{}s;
    s{\s*<mac address=[^>]*/>}{}g;
    s{\s*<backingStore\b.*?</backingStore>}{}s;
    s{(<disk type="file" device="disk">.*?<source file=")[^"]*(")}{$1$ENV{DISK}$2}s;
  ' "$tmp"
  sed -i \
    -e "s#<name>[^<]*</name>#<name>$VM</name>#" \
    -e "s#<memory unit=\"KiB\">[0-9]*#<memory unit=\"KiB\">$((RAM_MB * 1024))#" \
    -e "s#<currentMemory unit=\"KiB\">[0-9]*#<currentMemory unit=\"KiB\">$((RAM_MB * 1024))#" \
    -e "s#<vcpu placement=\"static\">[0-9]*#<vcpu placement=\"static\">$VCPUS#" \
    -e "s#/var/lib/libvirt/qemu/nvram/[^<]*#/var/lib/libvirt/qemu/nvram/${VM}_VARS.fd#" \
    "$tmp"
  # Hardened by default: no shared folder, clipboard, audio, USB or guest-agent channel.
  perl -0pi -e '
    s{\s*<filesystem\b.*?</filesystem>}{}gs;
    s{\s*<memoryBacking>.*?</memoryBacking>}{}s;
    s{<audio\b[^>]*/>}{<audio id="1" type="none"/>}g;
    s{\s*<channel type="spicevmc">.*?</channel>}{}gs;
    s{\s*<channel type="unix">.*?</channel>}{}gs;
    s{\s*<input type="tablet" bus="usb"/>}{}g;
    s{(\s*)</devices>}{$1  <controller type="usb" model="none"/>$1</devices>}s;
    s{<graphics type="spice"[^>]*>}{<graphics type="spice">};
    s{<listen type="address"[^>]*/>}{<listen type="none"/>};
  ' "$tmp"

  log "Defining $VM from $XML"
  virsh_ define "$tmp"
  dry || rm -f "$tmp"
  log "Attaching the first-boot seed and starting"
  virsh_ change-media "$VM" sda "$SEED_ISO" --insert --config
  virsh_ start "$VM"
  ! dry || echo "(dry-run) rendered XML written to $tmp (review it; nothing was defined)"

  if [ "$NO_WAIT" = 1 ]; then
    echo
    image_next_steps
    return 0
  fi
  if dry; then
    echo
    echo "(dry-run) would wait for the VM, wait for first-boot setup, add an SSH config"
    echo "(dry-run) entry, then offer to write the API key, a deploy key and connect."
    return 0
  fi

  echo
  local ip
  if ! ip=$(wait_for_ip "$VM"); then
    echo "Could not find the VM's IP or sshd is not reachable (is sshd enabled in the image?)." >&2
    image_next_steps
    return 0
  fi
  log "VM IP: $ip"
  provision_vm "$VM" "$ip" "$GUEST_USER"
}

for c in "${cmds[@]}"; do
  case "$c" in
    image) cmd_image ;;
    create) cmd_create ;;
    install|all) cmd_image; cmd_create ;;
    *) echo "Unknown command: $c" >&2; exit 1 ;;
  esac
done
