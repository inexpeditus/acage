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
  if [ -n "$secrets" ]; then
    warn "These look like secrets, and the agent can read everything you push:
$(printf '%s\n' "$secrets" | sed 's/^/    /')"
    # A secret match is a speed bump, not a silent warning: confirm before
    # sending. --yes proceeds; a non-interactive run without it refuses.
    [ "${ASSUME_YES:-0}" = 1 ] && return 0
    interactive || die "Refusing to push files that look like secrets; pass --yes to send them anyway"
    yesno "Push these anyway?" n || die "Aborted; nothing was pushed"
  fi
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

# acage paste: the image on this computer's clipboard, into the agent's home.
# Claude's own Ctrl-V reads the clipboard of the machine it runs on, and a cage
# has none, so this reads yours, copies the image in over SSH and leaves its
# path on your clipboard to paste to the agent instead.

# clip_tool -> wl (Wayland) or x (X11), or records the missing tool and dies.
clip_tool() {
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    want wl-paste; want wl-copy; report_missing; echo wl
  elif [ -n "${DISPLAY:-}" ]; then
    want xclip; report_missing; echo x
  else
    die "No graphical session (neither WAYLAND_DISPLAY nor DISPLAY is set), so there's no clipboard to read"
  fi
}

# paste_image VM -> copies the clipboard image to ~/pastes in VM as the agent,
# prints its path and puts the path on the clipboard.
paste_image() {
  local vm=$1 tool types t type="" name path
  tool=$(clip_tool)
  if [ "$tool" = wl ]; then types=$(wl-paste --list-types 2>/dev/null || true)
  else types=$(xclip -selection clipboard -t TARGETS -o 2>/dev/null || true); fi
  # The formats Claude reads; PNG first, as it's lossless.
  for t in png jpeg webp gif; do
    printf '%s\n' "$types" | grep -qx "image/$t" && { type=image/$t; break; }
  done
  [ -n "$type" ] || die "The clipboard holds no image (PNG, JPEG, WebP or GIF)"
  t=${type#image/}; [ "$t" != jpeg ] || t=jpg
  name=paste-$(date +%Y%m%d-%H%M%S).$t
  path=/home/$AGENT_USER/pastes/$name
  if dry; then run "clipboard $type | ssh $AGENT_USER@$vm 'cat >~/pastes/$name'"; return 0; fi
  if [ "$tool" = wl ]; then wl-paste --no-newline --type "$type"
  else xclip -selection clipboard -t "$type" -o; fi \
    | vm_ssh "$vm" "$AGENT_USER" "mkdir -p pastes && cat >pastes/$name" \
    || die "Copying the image into $vm failed"
  # The copy tools stay running to serve the clipboard; detach their output so
  # a caller reading ours doesn't wait on them.
  if [ "$tool" = wl ]; then printf '%s' "$path" | wl-copy >/dev/null 2>&1
  else printf '%s' "$path" | xclip -selection clipboard -i >/dev/null 2>&1; fi \
    || warn "Couldn't put the path on the clipboard"
  log "Pasted into $vm: $path (the path is on your clipboard now)"
  echo "$path"
}
