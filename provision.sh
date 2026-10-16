#!/usr/bin/env bash
# Post-boot automation: wait for the VM to come up and first-boot setup
# (cloud-init) to finish, add an SSH config entry, then offer to connect.
# Private copy of the equivalent steps in ../wizard.sh (image_provision and the
# IP-wait loop in Step 7). Sourced by create.sh; do not run directly.

# wait_for_ip VM -> prints the IP on stdout, or nothing after ~2 minutes.
wait_for_ip() {
  local vm=$1 n ip
  echo -n "Waiting for an IP" >&2
  for n in $(seq 1 60); do
    ip=$(virsh_ domifaddr "$vm" --source lease 2>/dev/null | awk '/ipv4/{split($4,a,"/"); print a[1]}')
    if [ -n "$ip" ] && timeout 1 bash -c "</dev/tcp/$ip/22" 2>/dev/null; then
      echo >&2
      echo "$ip"
      return 0
    fi
    echo -n "." >&2
    sleep 2
  done
  echo >&2
  return 1
}

# wait_for_key_login VM IP USER -> waits for sshd to accept the seeded key.
# Gives up early (instead of spinning for minutes) if sshd is reachable but
# rejects the key outright, since that means first-boot setup did not apply it.
wait_for_key_login() {
  local vm=$1 ip=$2 user=$3 n out denied=0
  local probe=(-o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR)
  echo -n "Waiting for key login to work in the VM" >&2
  for n in $(seq 1 100); do
    if out=$(ssh "${probe[@]}" -o HostName="$ip" -o IdentityFile="$(image_privkey_file)" -o IdentitiesOnly=yes "${user}@${ip}" true 2>&1); then
      echo >&2
      return 0
    fi
    case "$out" in *"Permission denied"*) denied=$((denied + 1)) ;; *) denied=0 ;; esac
    if [ "$denied" -ge 30 ]; then
      echo >&2
      echo "sshd is up but refuses the key for '$user'; first-boot setup likely failed." >&2
      echo "Watch the boot output:  sudo virsh -c $URI reboot $vm && sudo virsh -c $URI console $vm" >&2
      return 1
    fi
    echo -n "." >&2
    sleep 3
  done
  echo >&2
  echo "No key login after a few minutes. Watch the boot output: sudo virsh -c $URI console $vm" >&2
  return 1
}

# write_ssh_config_entry VM IP USER -> ~/.ssh/config entry keyed by HostKeyAlias,
# matching how bin/vm (in the main repo) connects, so the alias keeps working
# even after the VM's IP changes on a later boot.
write_ssh_config_entry() {
  local vm=$1 ip=$2 user=$3 cfg="$HOME/.ssh/config" key
  key=$(image_privkey_file)
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if grep -qE "^Host $vm\$" "$cfg" 2>/dev/null; then
    echo "Host $vm already in $cfg; leaving it alone."
    return 0
  fi
  cat >>"$cfg" <<EOF

Host $vm
    HostName $ip
    User $user
    IdentityFile $key
    IdentitiesOnly yes
    HostKeyAlias $vm
    ForwardAgent no
    ForwardX11 no
EOF
  chmod 600 "$cfg"
  log "Added 'Host $vm' to $cfg (IdentityFile $key)"
}

# provision_vm VM IP USER -> the whole post-boot sequence, offering to connect at the end.
provision_vm() {
  local vm=$1 ip=$2 user=$3 sshv
  wait_for_key_login "$vm" "$ip" "$user" || return 0

  log "Waiting for first-boot setup (packages, Pi) to finish; this can take a few minutes..."
  ssh -o BatchMode=no -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
      -o LogLevel=ERROR -o HostName="$ip" -o IdentityFile="$(image_privkey_file)" -o IdentitiesOnly=yes \
      "${user}@${ip}" 'cloud-init status --wait' \
    || log "cloud-init reported a problem; look at /var/log/cloud-init-output.log in the VM."

  write_ssh_config_entry "$vm" "$ip" "$user"

  # First connection that records a host key: by now cloud-init (and any host-key
  # regeneration it does) has finished, so the key is final.
  sshv=(ssh -o HostName="$ip" -o HostKeyAlias="$vm" -o StrictHostKeyChecking=accept-new "$vm")
  "${sshv[@]}" 'pi --version' || log "Pi is not installed yet; check /var/log/cloud-init-output.log in the VM."

  local key
  read -rsp "Anthropic API key for Pi (Enter to skip): " key; echo
  if [ -n "$key" ]; then
    if [[ "$key" =~ ^[A-Za-z0-9._-]+$ ]]; then
      printf '%s\n' "$key" | "${sshv[@]}" \
        'umask 077; mkdir -p "$HOME/.pi/agent"; IFS= read -r k; printf "{\n  \"anthropic\": { \"type\": \"api_key\", \"key\": \"%s\" }\n}\n" "$k" >"$HOME/.pi/agent/auth.json"' \
        && log "Wrote ~/.pi/agent/auth.json (mode 600) in the VM."
    else
      log "That key has unexpected characters; skipped. Create ~/.pi/agent/auth.json in the VM by hand."
    fi
  fi
  key=""

  if yesno "Generate a GitHub deploy key in the VM?" y; then
    echo "Add this key on GitHub (repo -> Settings -> Deploy keys; read-only unless the agent must push):"
    "${sshv[@]}" 'mkdir -p ~/.ssh; chmod 700 ~/.ssh; [ -f ~/.ssh/id_agent ] || ssh-keygen -q -t ed25519 -f ~/.ssh/id_agent -C agent-box -N ""; grep -q "^Host github.com$" ~/.ssh/config 2>/dev/null || printf "Host github.com\n    IdentityFile ~/.ssh/id_agent\n    IdentitiesOnly yes\n" >>~/.ssh/config; chmod 600 ~/.ssh/config; cat ~/.ssh/id_agent.pub'
  fi

  if yesno "Connect now?" y; then
    exec "${sshv[@]}"
  fi
}
