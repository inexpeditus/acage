#!/usr/bin/env bash
# Post-boot automation: wait for key login and first-boot setup (cloud-init),
# add an SSH config entry, then (interactively) store API keys, offer a
# deploy key and connect. Sourced by agentcage.
#
# The backend sets SSH_HOST and SSH_PORT before any of this runs.

# Options for talking to a VM whose host key isn't recorded yet.
probe_opts() {
  printf '%s\n' -o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no -o LogLevel=ERROR -o IdentitiesOnly=yes \
    -o "IdentityFile=$(image_privkey_file)" -o "HostName=$SSH_HOST" -o "Port=$SSH_PORT"
}

# wait_for_key_login VM USER -> waits for sshd to accept the seeded key.
# Gives up early (instead of spinning for minutes) if sshd is reachable but
# rejects the key outright, since that means first-boot setup did not apply it.
wait_for_key_login() {
  local vm=$1 user=$2 n out denied=0 opts
  opts=$(probe_opts)
  echo -n "Waiting for key login to work in the VM" >&2
  for n in $(seq 1 100); do
    # shellcheck disable=SC2086 # one option per line, none contain spaces
    if out=$(IFS=$'\n'; ssh $opts "${user}@${vm}" true 2>&1); then
      echo >&2
      return 0
    fi
    case "$out" in *"Permission denied"*) denied=$((denied + 1)) ;; *) denied=0 ;; esac
    if [ "$denied" -ge 30 ]; then
      echo >&2
      echo "sshd is up but refuses the key for '$user'; first-boot setup likely failed." >&2
      echo "Look at the boot output:  acage console $vm" >&2
      return 1
    fi
    echo -n "." >&2
    sleep 3
  done
  echo >&2
  echo "No key login after five minutes. Look at the boot output:  acage console $vm" >&2
  return 1
}

# ssh_probe VM USER CMD... -> runs CMD in the VM without recording a host key.
ssh_probe() {
  local vm=$1 user=$2 opts; shift 2
  opts=$(probe_opts)
  # shellcheck disable=SC2086
  (IFS=$'\n'; exec ssh $opts -o BatchMode=no "${user}@${vm}" "$@")
}

# The block agentcage manages in ~/.ssh/config is fenced by these markers.
ssh_marker_begin() { echo "# agentcage:begin $1"; }
ssh_marker_end()   { echo "# agentcage:end $1"; }

# remove_ssh_config_entry VM -> deletes agentcage's block for VM, if any.
remove_ssh_config_entry() {
  local vm=$1 cfg="$HOME/.ssh/config" tmp
  [ -f "$cfg" ] && grep -qxF "$(ssh_marker_begin "$vm")" "$cfg" || return 0
  tmp=$(mktemp)
  # Also drops the blank line written in front of the block.
  awk -v b="$(ssh_marker_begin "$vm")" -v e="$(ssh_marker_end "$vm")" '
    skip { if ($0 == e) skip = 0; next }
    $0 == b { skip = 1; held = 0; next }
    { if (held) print ""; held = 0 }
    $0 == "" { held = 1; next }
    { print }
    END { if (held) print "" }' "$cfg" >"$tmp"
  cat "$tmp" >"$cfg"   # keeps the file's mode, owner and any symlink
  rm -f "$tmp"
}

# write_ssh_config_entry VM USER -> ~/.ssh/config entry keyed by HostKeyAlias,
# so the host key stays valid even when the VM's address changes.
# 'acage ssh VM' always passes the current address.
write_ssh_config_entry() {
  local vm=$1 user=$2 cfg="$HOME/.ssh/config" key
  key=$(image_privkey_file)
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  remove_ssh_config_entry "$vm"
  if grep -qixF "Host $vm" "$cfg" 2>/dev/null; then
    warn "$cfg already has its own 'Host $vm' entry; leaving it alone. Use 'acage ssh $vm'."
    return 0
  fi
  cat >>"$cfg" <<EOF

$(ssh_marker_begin "$vm")
Host $vm
    HostName $SSH_HOST
    Port $SSH_PORT
    User $user
    IdentityFile $key
    IdentitiesOnly yes
    HostKeyAlias $vm
    ForwardAgent no
    ForwardX11 no
$(ssh_marker_end "$vm")
EOF
  chmod 600 "$cfg"
  log "Added 'Host $vm' to $cfg"
}

# vm_ssh VM ARGS... -> ssh through the config entry, with the current address.
vm_ssh() {
  local vm=$1; shift
  ssh -o "HostName=$SSH_HOST" -o "Port=$SSH_PORT" -o HostKeyAlias="$vm" \
      -o StrictHostKeyChecking=accept-new "$vm" "$@"
}

# provision_api_keys VM -> asks once per provider and stores the key for each harness.
provision_api_keys() {
  local vm=$1 prov label key h
  for prov in anthropic openai; do
    harness_has_provider "$prov" || continue
    case "$prov" in
      anthropic) label="Anthropic API key" ;;
      openai) label="OpenAI API key" ;;
    esac
    key=""
    read -rsp "$label for $(for h in $(harness_list); do [ "$(harness_provider "$h")" = "$prov" ] && printf '%s ' "$h"; done)(Enter to skip): " key || true
    echo >&2
    [ -n "$key" ] || continue
    if [[ ! "$key" =~ ^[A-Za-z0-9._-]+$ ]]; then
      warn "That key has unexpected characters; skipped."
      continue
    fi
    for h in $(harness_list); do
      [ "$(harness_provider "$h")" = "$prov" ] || continue
      if printf '%s\n' "$key" | vm_ssh "$vm" "$(harness_store_key_script "$h")"; then
        log "Stored the $label for $h in the VM (readable only by your user there)"
      else
        warn "Could not store the key for $h"
      fi
    done
  done
  key=""
}

# provision_vm VM USER -> the whole post-boot sequence. Returns 1 if the VM
# never became reachable with the key.
provision_vm() {
  local vm=$1 user=$2 h c v
  wait_for_key_login "$vm" "$user" || return 1

  log "Waiting for first-boot setup (packages, agents) to finish; this can take a few minutes..."
  # Exit status 2 means "done, with recoverable errors": Alpine's image always
  # reports one (a missing console-fingerprint helper), so only 1 is a failure.
  local rc=0
  ssh_probe "$vm" "$user" 'cloud-init status --wait' >/dev/null || rc=$?
  [ "$rc" != 1 ] || warn "First-boot setup failed; look at /var/log/cloud-init-output.log in the VM."

  write_ssh_config_entry "$vm" "$user"

  # First connection that records a host key: by now cloud-init (and any host-key
  # regeneration it does) has finished, so the key is final.
  vm_ssh "$vm" true || return 1
  [ "$GUEST_DOAS" != 1 ] || vm_ssh "$vm" 'doas -n true' 2>/dev/null \
    || [ -n "$GUEST_PW_HASH" ] || warn "doas does not work for '$user'; see /var/log/cloud-init-output.log in the VM."
  [ -z "$SHARE_DIR" ] || vm_ssh "$vm" 'mountpoint -q "$HOME/shared"' \
    || warn "The shared folder is not mounted at ~/shared; see /var/log/cloud-init-output.log in the VM."
  for h in $(harness_list); do
    c=$(harness_command "$h")
    if v=$(vm_ssh "$vm" "sh -lc '$c --version'" 2>/dev/null); then
      log "$h: $v"
    else
      warn "$h ('$c') is not working; check /var/log/cloud-init-output.log in the VM."
    fi
  done

  if ! interactive; then
    echo >&2
    image_next_steps
    return 0
  fi

  provision_api_keys "$vm"

  if yesno "Generate a GitHub deploy key in the VM?" y; then
    echo "Add this key on GitHub (repo -> Settings -> Deploy keys; read-only unless the agent must push):" >&2
    vm_ssh "$vm" 'mkdir -p ~/.ssh; chmod 700 ~/.ssh; [ -f ~/.ssh/id_agent ] || ssh-keygen -q -t ed25519 -f ~/.ssh/id_agent -C agentcage -N ""; grep -q "^Host github.com$" ~/.ssh/config 2>/dev/null || printf "Host github.com\n    IdentityFile ~/.ssh/id_agent\n    IdentitiesOnly yes\n" >>~/.ssh/config; chmod 600 ~/.ssh/config; cat ~/.ssh/id_agent.pub'
  fi

  if yesno "Connect now?" y; then
    exec ssh -o "HostName=$SSH_HOST" -o "Port=$SSH_PORT" "$vm"
  fi
  image_next_steps
}

image_next_steps() {
  local h
  {
    echo "Next steps:"
    echo "  Connect:          acage ssh $VM"
    echo "  Stop / start:     acage stop $VM / acage start $VM"
    echo "  Boot log:         acage console $VM"
    for h in $(harness_list); do echo "  $(harness_login_hint "$h")"; done
    [ -z "$SHARE_DIR" ] || echo "  Shared folder:    $SHARE_DIR  <->  ~/shared in the VM"
  } >&2
}
