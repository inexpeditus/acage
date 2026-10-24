#!/usr/bin/env bash
# acage isolation benchmark — phase 1: container and gVisor columns.
#
# Runs the same set of "try to reach the host" probes inside each sandbox and
# reports, per probe, whether the host was reachable. This measures isolation,
# not performance. The acage (VM) column and the performance numbers are added
# in later phases.
#
# Run it as root (Docker needs it here; we deliberately do not add anyone to
# the root-equivalent 'docker' group):
#
#     sudo bash bench/run.sh
#
# It is non-destructive: every host-side artifact is a timestamped sentinel
# under a scratch dir that is created and removed by the script. The socket and
# privileged probes are demonstrated by *reachability* (proving the escape is
# available), not by actually writing to the real host with root.
set -euo pipefail

IMAGE=${IMAGE:-node:22-alpine}
RES=${RES:-"--cpus=2 --memory=2g"}         # match acage's default 2 vCPU / 2 GB
HOST_GW=${HOST_GW:-172.17.0.1}             # docker0: the host as seen from a container
RUNSC=${RUNSC:-runsc}                      # gVisor runtime name (from 'runsc install')

TS=$(date +%s)
SCRATCH=$(mktemp -d /tmp/acage-bench.XXXXXX)
PROJECT="$SCRATCH/project"                 # stands in for a mounted project dir
mkdir -p "$PROJECT"
echo "a real host file the agent should never be able to leak" >"$PROJECT/source.txt"

cleanup() { rm -rf "$SCRATCH"; [ -n "${LISTENER_PID:-}" ] && kill "$LISTENER_PID" 2>/dev/null || true; }
trap cleanup EXIT

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "cannot talk to the docker daemon (run with sudo)" >&2; exit 1; }
HAVE_RUNSC=0
docker info 2>/dev/null | grep -qiw "$RUNSC" && HAVE_RUNSC=1 || \
  echo "note: gVisor runtime '$RUNSC' not registered; skipping the gVisor column" >&2

# results["subject|probe"] = yes|no|n/a  (yes = the host was reachable = worse)
declare -A results

# run_in SUBJECT CMD -> runs CMD (sh -c) inside the subject, stdout passed through.
# Subjects differ only in how the box is configured, so the probes stay identical.
run_in() {
  local subj=$1 cmd=$2 t=${PROBE_TIMEOUT:-45}
  case "$subj" in
    container)                 # typical agent run: project mounted, default network
      timeout "$t" docker run --rm $RES -v "$PROJECT:/work" "$IMAGE" sh -c "$cmd" ;;
    container-sock)            # dangerous-but-common: docker socket mounted in
      timeout "$t" docker run --rm $RES -v "$PROJECT:/work" \
        -v /var/run/docker.sock:/var/run/docker.sock "$IMAGE" sh -c "$cmd" ;;
    gvisor)                    # same as typical, but gVisor's userspace kernel
      timeout "$t" docker run --rm --runtime="$RUNSC" $RES -v "$PROJECT:/work" "$IMAGE" sh -c "$cmd" ;;
  esac
}

subjects=(container container-sock)
[ "$HAVE_RUNSC" = 1 ] && subjects+=(gvisor)

# --- a host listener, so "reach the host network" is a real connection -------
start_listener() {
  LISTEN_PORT=$(( (RANDOM % 20000) + 20000 ))
  python3 -m http.server "$LISTEN_PORT" --bind 0.0.0.0 >/dev/null 2>&1 &
  LISTENER_PID=$!
  sleep 1
}
start_listener

echo "== running probes (image=$IMAGE, host-gw=$HOST_GW) ==" >&2

for subj in "${subjects[@]}"; do
  echo "-- $subj" >&2

  # P1 kernel: is the guest running the host's own kernel?
  # container shares it (identical uname); gVisor reports its own; a VM differs.
  guest_kern=$(run_in "$subj" 'uname -r' 2>/dev/null || echo "?")
  if [ "$guest_kern" = "$(uname -r)" ]; then results["$subj|shared kernel"]=yes
  else results["$subj|shared kernel"]="no ($guest_kern)"; fi

  # P2 host FS beyond the mount: can it read host files that were NOT shared?
  # Only /work is mounted, so the host's /etc/hostname should be the image's.
  host_hn=$(cat /etc/hostname 2>/dev/null || echo host)
  guest_hn=$(run_in "$subj" 'cat /etc/hostname 2>/dev/null || echo none' 2>/dev/null || echo none)
  [ "$guest_hn" = "$host_hn" ] && results["$subj|host FS beyond mount"]=yes \
                               || results["$subj|host FS beyond mount"]=no

  # P3 mounted project: anything you mount in is fully writable (mount working).
  run_in "$subj" "echo escaped-$TS > /work/ESCAPED-$TS" 2>/dev/null || true
  [ -f "$PROJECT/ESCAPED-$TS" ] && results["$subj|mounted project writable"]=yes \
                                || results["$subj|mounted project writable"]=no
  rm -f "$PROJECT/ESCAPED-$TS"

  # P4 host network: can the box open a TCP connection to a host service?
  reach=$(run_in "$subj" "wget -T 3 -q -O- http://$HOST_GW:$LISTEN_PORT/ >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null || echo no)
  results["$subj|reach host network"]=$reach

  # P5 docker socket: if the socket is in the box, the Docker API answers ->
  # a privileged container mounting / is one call away (we prove reachability).
  sock=$(run_in "$subj" '
    [ -S /var/run/docker.sock ] || { echo no; exit 0; }
    node -e "const http=require(\"http\");const done=v=>{process.stdout.write(v);process.exit(0)};const r=http.request({socketPath:\"/var/run/docker.sock\",path:\"/version\",timeout:3000},s=>{s.resume();done(s.statusCode==200?\"yes\":\"no\")});r.on(\"timeout\",()=>done(\"no\"));r.on(\"error\",()=>done(\"no\"));r.end()"
  ' 2>/dev/null || echo no)
  results["$subj|docker API (=host root)"]=$sock
done

# --- print the markdown table -----------------------------------------------
probes=("shared kernel" "host FS beyond mount" "mounted project writable" "reach host network" "docker API (=host root)")

echo
echo "### Isolation — host reachable from inside? (yes = worse)"
echo
printf '| probe | %s |\n' "$(IFS='|'; echo "${subjects[*]}" | sed 's/|/ | /g')"
printf '|---%s\n' "$(for _ in "${subjects[@]}"; do printf '|---'; done)|"
for p in "${probes[@]}"; do
  row="| $p "
  for subj in "${subjects[@]}"; do row+="| ${results["$subj|$p"]:-n/a} "; done
  echo "$row|"
done
echo
echo "(image userland held constant at $IMAGE so the only variable is the sandbox.)"
