#!/usr/bin/env bash
# Where images and VM disks are kept (the "pool"), free-space checks, and the
# small config file that remembers the choice. Sourced by acage.

CONFIG_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/agentcage/config

# config_get KEY -> value from the config file, or nothing.
config_get() {
  [ -f "$CONFIG_FILE" ] || return 0
  sed -n "s/^$1=//p" "$CONFIG_FILE" | tail -1
}

# config_set KEY VALUE -> replaces (or adds) KEY in the config file.
config_set() {
  local tmp
  mkdir -p "$(dirname "$CONFIG_FILE")"
  tmp=$(mktemp)
  { [ ! -f "$CONFIG_FILE" ] || grep -v "^$1=" "$CONFIG_FILE" || true; echo "$1=$2"; } >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

# fs_info DIR -> "<free GB> <mount point>" of the filesystem DIR is on (or
# would be on, if it doesn't exist yet).
fs_info() {
  local d=$1
  while [ ! -d "$d" ]; do d=$(dirname "$d"); done
  df -Pk "$d" | awk 'NR==2 {printf "%d %s\n", $4 / 1048576, $6}'
}

# pool_pick_default -> sets POOL_DIR when neither --pool-dir nor the config
# file chose one. With libvirt, a root filesystem that is separate from (and
# smaller than) /home gets /home/agentcage instead of the usual
# /var/lib/libvirt/images/agentcage, so VM disks don't fill up /.
pool_pick_default() {
  local saved free mnt hfree hmnt
  saved=$(config_get "pool_dir_$BACKEND")
  if [ -n "$saved" ]; then POOL_DIR=$saved; return 0; fi
  POOL_DIR=$POOL_DEFAULT
  [ "$BACKEND" = libvirt ] && [ -d /home ] || return 0
  read -r free mnt <<<"$(fs_info "$POOL_DIR")"
  read -r hfree hmnt <<<"$(fs_info /home)"
  if [ "$mnt" = / ] && [ "$hmnt" != / ] && [ "$hfree" -gt "$free" ]; then
    POOL_DIR=/home/agentcage
  fi
}

# pool_validate -> normalizes POOL_DIR and refuses places that can't work.
pool_validate() {
  local home
  POOL_DIR=${POOL_DIR/#\~/$HOME}
  case "$POOL_DIR" in /*) ;; *) die "--pool-dir must be an absolute path (got '$POOL_DIR')" ;; esac
  [[ "$POOL_DIR" != *[$'\n\r']* ]] || die "Refusing a pool folder name with line breaks"
  while [ "$POOL_DIR" != / ] && [ "${POOL_DIR%/}" != "$POOL_DIR" ]; do POOL_DIR=${POOL_DIR%/}; done
  [ "$POOL_DIR" != / ] || die "Refusing to use / as the pool folder"
  if [ "$BACKEND" = libvirt ]; then
    home=$(cd "$HOME" && pwd -P)
    case "$POOL_DIR/" in
      "$home"/*|"$HOME"/*)
        die "With libvirt, VMs run as a separate system user that can't enter your home folder. Pick a folder outside it, e.g. --pool-dir /home/agentcage" ;;
    esac
    case "$POOL_DIR/" in
      /var/lib/libvirt/images/*) ;;
      *)
        if command -v selinuxenabled >/dev/null && selinuxenabled; then
          warn "SELinux is on: label $POOL_DIR for VM images first, or the VM won't start:"
          warn "  sudo semanage fcontext -a -t virt_image_t '$POOL_DIR(/.*)?' && sudo restorecon -R $POOL_DIR"
        fi ;;
    esac
  fi
}

# pool_remember -> saves POOL_DIR as the default for later commands.
pool_remember() {
  dry && return 0
  [ "$(config_get "pool_dir_$BACKEND")" != "$POOL_DIR" ] || return 0
  config_set "pool_dir_$BACKEND" "$POOL_DIR"
  log "Keeping images and VM disks in $POOL_DIR (saved in $CONFIG_FILE for later commands)"
}

# check_space NEED_GB WHAT -> refuses to continue unless the pool's filesystem
# has NEED_GB free, plus 5 GB if it is the root filesystem, which the system
# itself needs room on.
check_space() {
  local need=$1 what=$2 free mnt reserve=0 msg
  read -r free mnt <<<"$(fs_info "$POOL_DIR")"
  [ "$mnt" != / ] || reserve=5
  [ "$free" -lt $((need + reserve)) ] || return 0
  msg="Not enough disk space for $what: $POOL_DIR is on the filesystem mounted at $mnt, which has $free GB free, and this needs $need GB"
  [ "$reserve" = 0 ] || msg="$msg plus 5 GB left free for the system (it's your root filesystem)"
  die "$msg. Use --pool-dir to pick a folder on a filesystem with more room, or a smaller --disk."
}
