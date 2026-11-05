#!/usr/bin/env bash
# Project mode: one cage per git project. 'acage' in a repository (or
# 'acage URL') copies the committed code into the cage, installs its
# dependencies, starts its dev server with a preview on localhost, and opens
# the agent in the project folder. 'acage pull' fetches the agent's commits
# back as branch acage/NAME. Sourced by acage.
#
# Saved per cage in the config file: project_NAME (the host path),
# project_copied_NAME, project_setup_NAME and preview_port_NAME.

# Every VM name acage knows about, from its saved settings and its SSH config.
acage_vm_names() {
  { [ -f "$CONFIG_FILE" ] && sed -n 's/^\(user\|project\)_\([a-z][a-z0-9-]*\)=.*/\2/p' "$CONFIG_FILE"
    [ -f "$HOME/.ssh/config" ] && sed -n 's/^# acage:begin //p' "$HOME/.ssh/config"
    true   # keep the group's status zero for the pipe under set -e
  } 2>/dev/null | sort -u
}

# is_repo_url ARG -> true if ARG looks like a git URL rather than a subcommand.
is_repo_url() {
  case "$1" in *://*|git@*:*|*.git) return 0 ;; esac
  return 1
}

# project_dir_from_url URL -> the folder name 'git clone URL' would create.
project_dir_from_url() {
  local u=${1%/}
  u=${u%.git}; u=${u%/}; u=${u##*/}; u=${u##*:}
  echo "$u"
}

# project_base_name DIR -> a valid VM name made from the folder's name.
project_base_name() {
  local n
  n=$(basename "$1" | tr 'A-Z' 'a-z' \
    | sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^[^a-z]*//' | cut -c1-50 | sed 's/-*$//')
  echo "${n:-project}"
}

# project_name_for PATH -> the cage already made for the project at PATH.
project_name_for() {
  [ -f "$CONFIG_FILE" ] || return 0
  P=$1 awk 'index($0, "project_") == 1 {
      k = substr($0, 9); i = index(k, "=")
      if (substr(k, i + 1) == ENVIRON["P"]) { print substr(k, 1, i - 1); exit }
    }' "$CONFIG_FILE"
}

# project_pick_name PATH -> a free name for a new project's cage: the folder
# name, or NAME-2, NAME-3... when another VM already has it.
project_pick_name() {
  local base cand n=2 taken
  base=$(project_base_name "$1")
  taken=$(acage_vm_names)
  cand=$base
  while printf '%s\n' "$taken" | grep -qxF -- "$cand"; do cand="$base-$n"; n=$((n + 1)); done
  echo "$cand"
}

# project_clone -> clones PROJECT_URL here with your own git credentials and
# moves into it, so project mode continues as if run inside the checkout.
project_clone() {
  local dir
  need git
  dir=$(project_dir_from_url "$PROJECT_URL")
  case "$dir" in ""|.|..) die "Can't tell a folder name from '$PROJECT_URL'" ;; esac
  [ ! -e "$dir" ] || die "$dir already exists here; cd into it and run 'acage'"
  if dry; then
    run git clone -- "$PROJECT_URL" "$dir"
    echo "(dry-run) would then continue in $PWD/$dir as 'acage' does in a repository" >&2
    exit 0
  fi
  git clone -- "$PROJECT_URL" "$dir" || die "Cloning $PROJECT_URL failed"
  cd "$dir" || die "Can't enter $dir"
}

# project_resolve -> sets PROJECT_ROOT, VM and NAME_SET for the project
# commands. 'pull NAME' (and preview/status) look NAME up; otherwise the git
# repository around the current folder decides, and project mode picks a name
# for a project it hasn't seen before.
project_resolve() {
  local mapped
  if [ "$cmd" != project ] && [ "$NAME_SET" = 1 ]; then
    check_name
    PROJECT_ROOT=$(config_get "project_$VM")
    [ -n "$PROJECT_ROOT" ] || die "'$VM' isn't a project cage (those are made by running 'acage' in a git repository)"
    git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
      || die "The project folder for '$VM' is gone: $PROJECT_ROOT"
    return 0
  fi
  need git
  PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "Not in a git repository (cd into a project, or: acage URL)"
  [[ "$PROJECT_ROOT" != *[$'\n\r']* ]] || die "Refusing a project path with line breaks"
  mapped=$(project_name_for "$PROJECT_ROOT")
  if [ -n "$mapped" ]; then
    [ "$NAME_SET" = 0 ] || [ "$VM" = "$mapped" ] \
      || die "This project already has the cage '$mapped'"
    VM=$mapped
  elif [ "$cmd" != project ]; then
    die "No cage for this project yet; run 'acage' here first"
  elif [ "$NAME_SET" = 0 ]; then
    VM=$(project_pick_name "$PROJECT_ROOT")
  fi
  NAME_SET=1
  check_name
}

# Ceilings for a new project's cage: about half the host's RAM (at least
# 2 GB) and every host core (at most 64). KVM only backs memory the guest
# touches, so the RAM ceiling isn't reserved up front.
project_default_ram() {
  awk '/^MemTotal:/ { m = int($2 / 2048); print (m < 2048 ? 2048 : m) }' /proc/meminfo
}
project_default_vcpus() {
  local n
  n=$(nproc 2>/dev/null || echo 2)
  [ "$n" -le 64 ] || n=64
  echo "$n"
}

# GIT_SSH_COMMAND that reaches the agent account in the cage.
project_git_ssh() {
  printf 'ssh -o HostName=%q -o Port=%q -o User=%q -o HostKeyAlias=%q -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o IdentityFile=%q -o BatchMode=yes -o ControlPath=none' \
    "$SSH_HOST" "$SSH_PORT" "$AGENT_USER" "$VM" "$(image_privkey_file)"
}

# project_git ARGS... -> git in the project on the host, talking to the cage.
# The cage's repository is "$VM:$VM", i.e. ~/NAME in the agent's home.
project_git() { GIT_SSH_COMMAND=$(project_git_ssh) git -C "$PROJECT_ROOT" "$@"; }

# project_create -> makes the project's cage with no questions: the project
# defaults, then the same steps as 'acage create'.
project_create() {
  QUICK=1; ASSUME_YES=1
  [ "$HARNESS_SET" = 1 ]   || HARNESS=claude-code
  [ "$AUTOSTART_SET" = 1 ] || AUTOSTART=0   # the agent opens in the project folder instead
  [ "$RAM_SET" = 1 ]       || RAM_MB=$(project_default_ram)
  [ "$VCPUS_SET" = 1 ]     || VCPUS=$(project_default_vcpus)
  [ "$DISK_SET" = 1 ]      || DISK_GB=20
  [ -n "$AGENT_MD" ]       || AGENT_MD=$DATA_DIR/project-agent.md
  validate_settings
  log "New cage '$VM' for $PROJECT_ROOT ($BACKEND backend; at most $RAM_MB MB RAM, $VCPUS vCPUs, $DISK_GB GB disk)"
  if ! dry; then
    want git; want xorriso; want ssh-keygen; want curl; want gpg; backend_check_deps
  fi
  check_space "$DISK_GB" "a ${DISK_GB} GB VM disk"
  check_space 1 "the Alpine image" "$IMAGE_CACHE"
  pool_remember
  # Saved first, so a create that fails half-way is retried under this name.
  # A fresh cage starts with none of an earlier cage's progress.
  if ! dry; then
    config_set "project_$VM" "$PROJECT_ROOT"
    config_unset "project_copied_$VM"; config_unset "project_setup_$VM"; config_unset "preview_port_$VM"
  fi
  cmd_image
  cmd_create
}

# project_copy_in -> copies the committed state of the current branch into
# ~/NAME in the cage, history included. Uncommitted and untracked files (a
# gitignored .env, say) stay on the host. The cage gets no git credentials.
project_copy_in() {
  local br dirty qbr size prog=""
  git -C "$PROJECT_ROOT" rev-parse -q --verify HEAD >/dev/null \
    || die "This repository has no commits yet; commit something first"
  br=$(git -C "$PROJECT_ROOT" symbolic-ref --short -q HEAD) || br=main
  dirty=$(git -C "$PROJECT_ROOT" status --porcelain)
  [ -z "$dirty" ] || warn "Only committed work is copied into the cage; these uncommitted changes stay here:
$(printf '%s\n' "$dirty" | head -10 | sed 's/^/    /')"
  if dry; then run git push "$VM:$VM" "HEAD:refs/heads/$br"; return 0; fi
  qbr=$(printf '%q' "$br")
  # updateInstead: a later push from the host updates the agent's checkout.
  vm_ssh "$VM" "$AGENT_USER" "git init -q -b $qbr ~/$VM && cd ~/$VM \
    && git config receive.denyCurrentBranch updateInstead \
    && git config user.name 'acage agent' && git config user.email agent@acage.invalid" \
    || die "Couldn't make the repository in the cage"
  size=$(git -C "$PROJECT_ROOT" rev-list --disk-usage --objects HEAD 2>/dev/null | numfmt --to=iec 2>/dev/null) || size=""
  log "Copying '$br' and its history${size:+ (${size}B)} into the cage"
  # Big files (artwork, videos) skip git's delta search, which is most of the
  # CPU time when a history holds several of them.
  [ -t 2 ] && prog=--progress
  project_git -c core.bigFileThreshold=50m push -q $prog "$VM:$VM" "HEAD:refs/heads/$br" \
    || die "Copying the code into the cage failed"
  log "Copied '$br' ($(git -C "$PROJECT_ROOT" rev-list --count HEAD) commits) into $VM:~/$VM"
}

# project_setup -> installs the project's dependencies in the cage, once.
# Phase 1 knows npm projects; anything else is left to you.
project_setup() {
  local rc=0
  [ "$(config_get "project_setup_$VM")" != 1 ] || return 0
  vm_ssh "$VM" "$AGENT_USER" "cd ~/$VM || exit 1
if [ ! -f package.json ]; then exit 3; fi
if [ -f yarn.lock ] || [ -f pnpm-lock.yaml ]; then exit 4; fi
echo '==> Installing the dependencies (npm) in the cage' >&2
if [ -f package-lock.json ]; then npm ci; else npm install; fi" || rc=$?
  case "$rc" in
    0) log "Dependencies installed" ;;
    3) log "No package.json, so no dependencies were installed" ;;
    4) warn "yarn and pnpm projects aren't set up automatically yet; install the dependencies in the cage (acage attach $VM)" ;;
    *) warn "Installing the dependencies failed; fix it in the cage (acage attach $VM) and run 'acage' again"; return 0 ;;
  esac
  config_set "project_setup_$VM" 1
}

# project_preview_start -> makes sure the dev server runs in the cage (tmux
# session 'preview', as the agent) and sets PREVIEW_PORT to the port it
# listens on. Returns 1 when there's no preview to show.
project_preview_start() {
  local out rc=0 known
  known=$(config_get "preview_port_$VM")
  out=$(vm_ssh "$VM" "$AGENT_USER" "known=$(printf '%q' "$known"); cd ~/$VM || exit 1
$(cat <<'EOF'
ports() { netstat -ltn 2>/dev/null | awk 'NR > 2 { n = split($4, a, ":"); print a[n] }' | grep -vx 22 | sort -un; }
if tmux has-session -t preview 2>/dev/null; then
  if [ -n "$known" ]; then echo "$known"; else ports | head -1; fi
  exit 0
fi
[ -f package.json ] || exit 3
node -e 'process.exit(((require("./package.json").scripts || {}).dev) ? 0 : 1)' 2>/dev/null || exit 3
ports >/tmp/acage-ports.before
tmux new-session -d -s preview -c "$PWD" 'npm run dev 2>&1 | tee /tmp/acage-preview.log'
echo '==> Starting the dev server (npm run dev) and waiting for it to listen' >&2
for i in $(seq 1 90); do
  # The ports that weren't open before (awk: BusyBox grep -vf prints nothing
  # when the pattern file is empty).
  p=$(ports | awk -v b="$(cat /tmp/acage-ports.before)" \
    'BEGIN { n = split(b, a, "\n"); for (i = 1; i <= n; i++) s[a[i]] = 1 } !($0 in s)' | head -1)
  [ -z "$p" ] || { echo "$p"; exit 0; }
  tmux has-session -t preview 2>/dev/null || { tail -n 15 /tmp/acage-preview.log >&2; exit 5; }
  sleep 1
done
exit 6
EOF
)") || rc=$?
  case "$rc" in
    0) ;;
    3) log "No 'dev' script in package.json, so there's no preview"; return 1 ;;
    5) warn "The dev server exited (output above)"; return 1 ;;
    6) warn "The dev server started but didn't open a port within 90 s; see 'tmux attach -t preview' in the cage"; return 1 ;;
    *) warn "Couldn't start the dev server in the cage"; return 1 ;;
  esac
  [[ "$out" =~ ^[0-9]+$ ]] || { warn "The dev server's port couldn't be read"; return 1; }
  PREVIEW_PORT=$out
  config_set "preview_port_$VM" "$PREVIEW_PORT"
}

# preview_free_port PORT -> PORT, or the next free port after it, on 127.0.0.1.
preview_free_port() {
  local p=$1
  while [ "$p" -le $(( $1 + 100 )) ]; do
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { echo "$p"; return 0; }
    p=$((p + 1))
  done
  return 1
}

# project_forward PORT [bg] -> forwards a port on 127.0.0.1 here to PORT in
# the cage, over SSH. It listens on localhost only, so the preview is never
# reachable from your network. With bg it runs in the background
# (FORWARD_PID); otherwise it runs until Ctrl-C.
project_forward() {
  local port=$1 hp n
  hp=$(preview_free_port "$port") || die "No free local port near $port for the preview"
  local args=(-N -o ExitOnForwardFailure=yes -o ControlPath=none
    -o "HostName=$SSH_HOST" -o "Port=$SSH_PORT" -o "User=$AGENT_USER" -o "HostKeyAlias=$VM"
    -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o "IdentityFile=$(image_privkey_file)"
    -L "127.0.0.1:$hp:localhost:$port" "$VM")
  PREVIEW_URL="http://localhost:$hp"
  if [ "${2:-}" != bg ]; then
    log "Preview: $PREVIEW_URL (Ctrl-C to stop)"
    exec ssh "${args[@]}"
  fi
  ssh "${args[@]}" </dev/null &
  FORWARD_PID=$!
  for n in $(seq 1 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/$hp") 2>/dev/null && return 0
    kill -0 "$FORWARD_PID" 2>/dev/null || break
    sleep 0.1
  done
  warn "Couldn't forward the preview port"
  FORWARD_PID=""
  return 1
}

# project_open_agent -> an interactive login as the agent, in the project
# folder, running its harness. Claude Code continues its last session there.
project_open_agent() {
  local h="" c inner
  for h in $(harness_list); do break; done
  case "$h" in
    "") inner="exec \$SHELL -l" ;;
    claude-code)
      inner="if ls ~/.claude/projects/-home-$AGENT_USER-$VM/*.jsonl >/dev/null 2>&1; then exec claude --continue; else exec claude; fi" ;;
    *) c=$(harness_command "$h"); inner="exec $c" ;;
  esac
  ssh -t -o "HostName=$SSH_HOST" -o "Port=$SSH_PORT" -o "User=$AGENT_USER" \
    -o "HostKeyAlias=$VM" -o StrictHostKeyChecking=accept-new "$VM" \
    "exec sh -lc 'cd ~/$VM && $inner'"
}

project_ready() {
  ensure_up "$VM"
  backend_locate "$VM"
  sync_ssh_config_host "$VM"
}

cmd_project() {
  FORWARD_PID=""
  if ! backend_exists "$VM"; then project_create || return 1; fi
  dry && return 0
  project_ready
  if [ "$(config_get "project_copied_$VM")" != 1 ]; then
    project_copy_in
    config_set "project_copied_$VM" 1
  fi
  project_setup
  if project_preview_start; then
    if [ "${NO_ATTACH:-0}" = 1 ]; then
      log "The dev server is running in the cage; open the preview with: acage preview"
    elif project_forward "$PREVIEW_PORT" bg; then
      log "Preview: $PREVIEW_URL (live while this session is open; 'acage preview' reopens it)"
    fi
  fi
  if [ "${NO_ATTACH:-0}" = 1 ]; then
    log "Ready. Open the agent with 'acage' here, or bring its commits back with 'acage pull'"
    return 0
  fi
  project_open_agent || true
  [ -z "$FORWARD_PID" ] || kill "$FORWARD_PID" 2>/dev/null || true
  log "Bring the agent's commits here with: acage pull"
}

cmd_pull() {
  local old new dirty count
  project_ready
  dirty=$(vm_ssh "$VM" "$AGENT_USER" "git -C ~/$VM status --porcelain") \
    || die "There's no repository at ~/$VM in the cage"
  [ -z "$dirty" ] || warn "The agent has uncommitted changes in the cage, which aren't pulled:
$(printf '%s\n' "$dirty" | head -10 | sed 's/^/    /')"
  old=$(git -C "$PROJECT_ROOT" rev-parse -q --verify "refs/heads/acage/$VM") || old=""
  # Hardened for a cage that may be hostile: objects are checked as they
  # arrive, submodules aren't followed (they could point at other URLs) and
  # the cage's tags are ignored. A fetch never runs the cage's hooks.
  project_git -c fetch.fsckObjects=true fetch -q --no-tags --no-recurse-submodules \
    "$VM:$VM" "+HEAD:refs/heads/acage/$VM" \
    || die "Fetching from the cage failed (if acage/$VM is checked out here, switch to another branch first)"
  new=$(git -C "$PROJECT_ROOT" rev-parse "refs/heads/acage/$VM")
  if [ "$old" = "$new" ]; then
    log "Nothing new: acage/$VM is up to date"
    return 0
  fi
  if [ -n "$old" ] && ! git -C "$PROJECT_ROOT" merge-base --is-ancestor "$old" "$new"; then
    warn "The agent rewrote its history; acage/$VM was replaced (it was ${old:0:12})"
  fi
  count=$(git -C "$PROJECT_ROOT" rev-list --count "HEAD..refs/heads/acage/$VM")
  log "Pulled into branch acage/$VM: $count commit(s) not on your current branch"
  git -C "$PROJECT_ROOT" log --oneline "HEAD..refs/heads/acage/$VM" | head -20 >&2
  {
    echo "Review:  git log -p HEAD..acage/$VM"
    echo "Merge:   git merge acage/$VM   (then push it yourself)"
  } >&2
}

cmd_preview() {
  project_ready
  project_preview_start || die "No preview for '$VM'"
  project_forward "$PREVIEW_PORT"
}

cmd_status() {
  local port remote here dirty
  echo "Project:  $PROJECT_ROOT"
  echo "Cage:     $VM ($BACKEND backend)"
  if ! backend_running "$VM"; then
    echo "State:    stopped ('acage' or 'acage pull' starts it)"
    return 0
  fi
  echo "State:    running"
  backend_locate "$VM"
  sync_ssh_config_host "$VM"
  port=$(config_get "preview_port_$VM")
  if vm_ssh "$VM" "$AGENT_USER" 'tmux has-session -t preview' 2>/dev/null; then
    echo "Preview:  dev server running${port:+ on port $port} in the cage ('acage preview' opens it)"
  else
    echo "Preview:  dev server not running ('acage' or 'acage preview' starts it)"
  fi
  remote=$(project_git ls-remote "$VM:$VM" HEAD 2>/dev/null | cut -f1)
  here=$(git -C "$PROJECT_ROOT" rev-parse -q --verify "refs/heads/acage/$VM") || here=""
  if [ -z "$remote" ]; then echo "Commits:  the cage has no repository yet"
  elif [ "$remote" = "$here" ]; then echo "Commits:  everything is pulled"
  else echo "Commits:  the cage has commits you haven't pulled ('acage pull')"
  fi
  dirty=$(vm_ssh "$VM" "$AGENT_USER" "git -C ~/$VM status --porcelain 2>/dev/null | wc -l")
  echo "Uncommitted in the cage: ${dirty:-0} file(s)"
}
