#!/usr/bin/env bash
# Optional shared folder between host and guest. Sourced by agentcage.
#
# The folder shows up in the guest at ~/shared. The libvirt backend serves it
# with virtiofs, the qemu backend with 9p.

SHARE_TAG=agentcage

# share_default_dir VM -> suggested folder.
share_default_dir() { echo "/mnt/acage-shared/$1"; }

# share_create -> creates SHARE_DIR, if missing, owned by you; through sudo if
# its parent isn't writable (e.g. under /mnt). Runs after share_confirm.
share_create() {
  local d=$SHARE_DIR
  [ ! -d "$d" ] || return 0
  if interactive && [ "$ASSUME_YES" != 1 ]; then
    yesno "'$d' doesn't exist. Create it?" y || die "Not sharing; nothing was created"
  fi
  if dry; then run mkdir -p "$d"; return 0; fi
  SHARE_CREATED=1
  mkdir -p "$d" 2>/dev/null && return 0
  log "Creating $d (needs sudo)"
  sudo mkdir -p "$d" && sudo chown "$(id -u):$(id -g)" "$d" || die "Could not create $d"
}

# share_offer_delete DIR CREATED -> after a VM is deleted, offers to delete its
# shared folder. Only folders acage created are offered, only interactively,
# and the answer defaults to no: the folder is on your computer and may hold
# your work. --yes never deletes it.
share_offer_delete() {
  local dir=$1 created=$2 n parent
  [ -d "$dir" ] || return 0
  n=$(find "$dir" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
  if [ "$created" != 1 ] || [ "$ASSUME_YES" = 1 ] || ! interactive || dry; then
    log "Kept the shared folder $dir ($n files and folders)"
    return 0
  fi
  if ! yesno "Also delete the shared folder $dir? It's on your computer and holds $n files and folders" n; then
    log "Kept the shared folder $dir"
    return 0
  fi
  # Files root created in the VM (libvirt) are owned by root on the host too.
  rm -rf "$dir" 2>/dev/null || { warn "Some files in $dir belong to root; using sudo"; sudo rm -rf "$dir"; } \
    || { warn "Could not delete $dir"; return 0; }
  log "Deleted the shared folder $dir"
  parent=$(dirname "$dir")
  if [ "$parent" = /mnt/acage-shared ] && [ -z "$(ls -A "$parent" 2>/dev/null)" ]; then
    rmdir "$parent" 2>/dev/null || sudo rmdir "$parent" 2>/dev/null || true
  fi
}

# share_resolve -> turns SHARE_DIR into an absolute, symlink-free path and
# refuses folders that would hand the agent your home or your credentials.
# A missing folder is only checked here; share_create makes it later.
share_resolve() {
  local d=${SHARE_DIR/#\~/$HOME} home rest=""
  case "$d" in /*) ;; *) d="$PWD/$d" ;; esac
  while [ "$d" != / ] && [ "${d%/}" != "$d" ]; do d=${d%/}; done
  case "$d/" in */../*|*/./*) die "Use a plain path for the shared folder, without . or .." ;; esac
  [ ! -e "$d" ] || [ -d "$d" ] || die "'$d' exists but is not a folder"
  # Resolve the deepest existing part (following symlinks), keep the rest as typed.
  while [ ! -d "$d" ]; do rest="/${d##*/}$rest"; d=${d%/*}; [ -n "$d" ] || d=/; done
  d=$(cd "$d" && pwd -P)
  [ "$d" != / ] || [ -z "$rest" ] || d=""
  d="$d$rest"
  home=$(cd "$HOME" && pwd -P)
  [ "$d" != / ] || die "Refusing to share /"
  case "$home/" in
    "$d"/*) die "Refusing to share '$d': it is your home folder or contains it" ;;
  esac
  case "$d/" in
    "$home"/.ssh/*|"$home"/.gnupg/*|"$home"/.aws/*|"$home"/.azure/*|"$home"/.kube/*|"$home"/.docker/*|"$home"/.password-store/*|"$home"/.config/gcloud/*)
      die "Refusing to share '$d': it holds credentials" ;;
  esac
  [[ "$d" != *[$'\n\r']* ]] || die "Refusing a folder name with line breaks"
  SHARE_DIR=$d
}

# share_confirm -> prints what sharing exposes and asks for an explicit yes.
share_confirm() {
  local reply=""
  {
    printf '\n\033[1;31m!! Shared folder: %s\033[0m\n' "$SHARE_DIR"
    cat <<EOF
   Sharing a folder opens a hole in the VM's isolation. Only share a folder
   you would be fine handing to a stranger's script.

   - The agent can read, change and delete everything in it: subfolders,
     hidden files, .git, and any .env, key or token files.
   - Whatever it writes there ends up on your computer. Code the agent wrote
     runs OUTSIDE the VM when you run, build, test or install it on the host:
     scripts, binaries, Makefiles, package.json scripts, .git/hooks, editor
     and direnv config. Review changes before you do any of that.
EOF
    if [ "$BACKEND" = libvirt ] && [ "$GUEST_DOAS" = 1 ]; then
      cat <<EOF
   - libvirt serves the folder through a root process on the host, so root
     in the VM can create files in it that are owned by root on your host,
     including setuid programs. The agent account has no root, but your
     account does: create the VM with --no-doas if you don't need it.
EOF
    fi
    cat <<EOF
   - Commit and push anything you can't afford to lose first: the agent can
     rewrite or delete history too.

EOF
  } >&2
  if [ "$ASSUME_YES" = 1 ]; then
    warn "--yes given; sharing $SHARE_DIR"
    return 0
  fi
  interactive || die "Sharing a folder needs confirmation: run interactively, or add --yes if you accept the above"
  read -rp "Type 'share' to share this folder with the VM: " reply || true
  [ "$reply" = share ] || die "Not sharing; nothing was created"
}

# share_guest_runcmd USER -> cloud-config runcmd items that mount the share at ~/shared.
share_guest_runcmd() {
  local user=$1 mnt="/home/$1/shared" line mods
  case "$SHARE_FSTYPE" in
    virtiofs)
      line="$SHARE_TAG $mnt virtiofs nofail 0 0"
      mods="virtiofs" ;;
    9p)
      line="$SHARE_TAG $mnt 9p trans=virtio,version=9p2000.L,msize=524288,nofail 0 0"
      mods="9pnet_virtio 9p" ;;
  esac
  cat <<EOF
  - mkdir -p $mnt
  - chown $user:$user $mnt
  - "for m in $mods; do grep -qx \$m /etc/modules || echo \$m >>/etc/modules; modprobe \$m; done"
  - "grep -q ' $mnt ' /etc/fstab || echo '$line' >>/etc/fstab"
  - mount $mnt
EOF
}
