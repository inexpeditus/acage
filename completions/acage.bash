# bash completion for acage.  Installed as
#   $PREFIX/share/bash-completion/completions/acage
# Dynamic VM-name completion comes from `acage _complete` (config + ~/.ssh/config
# only, so it is instant and never prompts or needs sudo).

_acage() {
  local cur prev words cword
  if declare -F _init_completion >/dev/null 2>&1; then
    _init_completion || return
  else
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD
  fi

  local commands="image create quick bake attach tmux push ssh start stop console list delete uninstall help"
  local name_cmds=" attach tmux push ssh start stop console delete "

  # Values expected right after certain flags.
  case "$prev" in
    --backend) COMPREPLY=($(compgen -W "libvirt qemu" -- "$cur")); return ;;
    --harness) COMPREPLY=($(compgen -W "claude-code pi codex none" -- "$cur")); return ;;
    --ssh-pubkey|--share|--pool-dir|--to|--agent-md)
      if declare -F _filedir >/dev/null 2>&1; then _filedir
      else COMPREPLY=($(compgen -f -- "$cur")); fi
      return ;;
    --name|--user|--ram|--vcpus|--disk) return ;;  # free-form value
  esac

  # Locate the subcommand (first non-option word) and where it sits.
  local i cmd="" cmd_i=0
  for ((i=1; i<cword; i++)); do
    case "${words[i]}" in -*) ;; *) cmd=${words[i]}; cmd_i=$i; break ;; esac
  done

  # No subcommand yet: complete commands, or global flags if the word is a dash.
  if [ -z "$cmd" ]; then
    if [[ "$cur" == -* ]]; then
      COMPREPLY=($(compgen -W "--backend --pool-dir -y --yes -n --dry-run -v --verbose -h --help --version" -- "$cur"))
    else
      COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    fi
    return
  fi

  # Flags, scoped to the subcommand.
  if [[ "$cur" == -* ]]; then
    local flags="--backend --pool-dir -y --yes -n --dry-run -v --verbose -h --help"
    case "$cmd" in
      create) flags+=" --name --user --harness --agent-md --share --no-share --password --no-doas --autostart --no-autostart --allow-lan --no-lan --ram --vcpus --disk --ssh-pubkey --no-wait" ;;
      quick) flags+=" --name --user --harness --agent-md --no-doas --no-autostart --allow-lan --ram --vcpus --disk --ssh-pubkey" ;;
      bake) flags+=" --harness --disk" ;;
      attach|ssh) flags+=" --agent --user" ;;
      push) flags+=" --agent --user --to" ;;
    esac
    COMPREPLY=($(compgen -W "$flags" -- "$cur"))
    return
  fi

  # Has a VM name already been given after the subcommand?
  local j seen_name=""
  for ((j=cmd_i+1; j<cword; j++)); do
    case "${words[j]}" in
      -*) ;;
      --) break ;;
      *) seen_name=${words[j]}; break ;;
    esac
  done

  case "$name_cmds" in
    *" $cmd "*)
      if [ -z "$seen_name" ]; then
        COMPREPLY=($(compgen -W "$(acage _complete 2>/dev/null)" -- "$cur"))
      elif [ "$cmd" = push ]; then
        # After the VM name, push takes local paths to copy in.
        if declare -F _filedir >/dev/null 2>&1; then _filedir
        else COMPREPLY=($(compgen -f -- "$cur")); fi
      fi
      return ;;
  esac
}
complete -F _acage acage
