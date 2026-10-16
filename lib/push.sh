#!/usr/bin/env bash
# acage push: copy files from this computer into a VM. Sourced by acage.
#
# The host starts the transfer and data only flows into the VM, over the SSH
# connection acage already uses: no shared folder, no service in the VM, and
# the firewall stays closed. Files are packed with tar on the host and
# unpacked by the receiving account in the VM. Symlinks are sent as symlinks,
# never followed, so a link can't pull in files from elsewhere on the host.

# push_check PATH -> refuses paths that would hand the agent your home folder
# or your credentials, and warns about files that look like secrets.
push_check() {
  local p=$1 d home secrets
  [ -e "$p" ] || [ -L "$p" ] || die "No such file or folder: $p"
  [[ "$p" != *[$'\n\r']* ]] || die "Refusing a path with line breaks"
  if [ -d "$p" ] && [ ! -L "$p" ]; then d=$(cd "$p" && pwd -P); else d=$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p"); fi
  home=$(cd "$HOME" && pwd -P)
  [ "$d" != / ] || die "Refusing to push /"
  case "$home/" in
    "$d"/*) die "Refusing to push '$d': it is your home folder or contains it" ;;
  esac
  case "$d/" in
    "$home"/.ssh/*|"$home"/.gnupg/*|"$home"/.aws/*|"$home"/.azure/*|"$home"/.kube/*|"$home"/.docker/*|"$home"/.password-store/*|"$home"/.config/gcloud/*)
      die "Refusing to push '$d': it holds credentials" ;;
  esac
  secrets=$(find "$p" \( -name '.env' -o -name '.env.*' -o -name 'id_rsa' -o -name 'id_ed25519' -o -name 'id_ecdsa' \
    -o -name '*.pem' -o -name '*.key' -o -name '.netrc' -o -name '.npmrc' \) -print 2>/dev/null | head -5)
  [ -z "$secrets" ] || warn "These look like secrets, and the agent can read everything you push:
$(printf '%s\n' "$secrets" | sed 's/^/    /')"
}

# push_paths VM USER DEST PATH... -> copies each PATH into DEST (relative to
# USER's home in the VM; "." for the home itself), keeping its name.
push_paths() {
  local vm=$1 user=$2 dest=$3 p qdest; shift 3
  [[ "$dest" != *[$'\n\r']* ]] || die "Refusing a destination with line breaks"
  qdest=$(printf '%q' "$dest")
  for p in "$@"; do push_check "$p"; done
  if dry; then
    for p in "$@"; do run "tar -C $(dirname "$p") -cf - $(basename "$p") | ssh $user@$vm 'tar -C ~/$dest -xf -'"; done
    return 0
  fi
  for p in "$@"; do
    # One archive per path, so each keeps its own name at the destination.
    # ./NAME, so a name starting with '-' isn't read as an option.
    tar -C "$(dirname "$p")" -cf - "./$(basename "$p")" \
      | vm_ssh "$vm" "$user" "mkdir -p -- $qdest && tar -C $qdest -xf -" \
      || die "Copying $p failed"
  done
  if [ "$dest" = . ]; then dest="~"; else dest="~/$dest"; fi
  log "Copied $# item(s) to $user@$vm:$dest"
}
