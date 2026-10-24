#!/usr/bin/env bash
# Lifecycle benchmark — docker & gVisor columns. Run as root: sudo bash bench/lifecycle-docker.sh
# Workloads identical to bench/lifecycle-acage.sh so the columns line up.
set -euo pipefail

IMAGE=${IMAGE:-node:22-alpine}
RES=${RES:-"--cpus=2 --memory=2g"}
RUNSC=${RUNSC:-runsc}
CPU_JS='let x=0;for(let i=0;i<1e9;i++){x+=i};console.log(x)'
DAEMON_RSS_MB=143   # measured standing cost (dockerd+containerd), from Test 1

now()  { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'; }
# host CPU-usec of a running container's cgroup (cgroup v2), via its main pid
cg_cpu() { local pid cg; pid=$(docker inspect -f '{{.State.Pid}}' "$1" 2>/dev/null) || return
           cg=$(awk -F: '{print $3}' "/proc/$pid/cgroup" 2>/dev/null | head -1)
           awk '/usage_usec/{print $2}' "/sys/fs/cgroup$cg/cpu.stat" 2>/dev/null || echo 0; }
mem_mb() { awk '{v=$1;n=v;sub(/[A-Za-z]+/,"",n);n=n+0;
                 if(v~/GiB/)printf"%.1f",n*1024;else if(v~/MiB/)printf"%.1f",n;
                 else if(v~/KiB/)printf"%.1f",n/1024;else printf"%.1f",n/1048576}' <<<"$(docker stats --no-stream --format '{{.MemUsage}}' "$1")"; }
rx_mb()  { awk -v b="$(docker exec "$1" sh -c 'cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null||echo 0')" 'BEGIN{printf "%.1f", b/1048576}'; }

docker info >/dev/null 2>&1 || { echo "run with sudo" >&2; exit 1; }
HAVE_RUNSC=0; docker info 2>/dev/null | grep -qiw "$RUNSC" && HAVE_RUNSC=1 || echo "note: no gVisor '$RUNSC'; skipping" >&2
subjects=(docker); [ "$HAVE_RUNSC" = 1 ] && subjects+=(gvisor)
flag() { [ "$1" = gvisor ] && echo "--runtime=$RUNSC" || echo ""; }

declare -A R
for s in "${subjects[@]}"; do
  f=$(flag "$s"); echo "-- $s" >&2

  # warm start: run cached image to command-ready, 5x median
  st=(); for _ in 1 2 3 4 5; do t0=$(now); docker run --rm $f $RES "$IMAGE" true >/dev/null 2>&1; t1=$(now); st+=("$(secs "$t0" "$t1")"); done
  R["$s|start"]=$(printf '%s\n' "${st[@]}" | sort -n | awk '{a[NR]=$1}END{print a[3]}')

  # a long-lived idle box for the runtime rows
  cid=$(docker run -d $f $RES "$IMAGE" sleep 600); sleep 3

  # provision parity: install git+openssh+sshd into the idle box, time + net
  rx0=$(rx_mb "$cid"); t0=$(now)
  docker exec "$cid" sh -c 'apk add --no-cache git openssh >/dev/null 2>&1' || true
  t1=$(now); R["$s|prov_parity"]=$(secs "$t0" "$t1"); R["$s|prov_net"]=$(awk -v a="$rx0" -v b="$(rx_mb "$cid")" 'BEGIN{printf "%.1f",b-a}')

  # idle: box RAM (docker stats) + daemon share; idle CPU over 30s
  R["$s|idle_ram"]=$(awk -v b="$(mem_mb "$cid")" -v d="$DAEMON_RSS_MB" 'BEGIN{printf "%.0f", b+d}')
  c0=$(cg_cpu "$cid"); sleep 30; c1=$(cg_cpu "$cid"); R["$s|idle_cpu"]=$(awk -v a="$c0" -v b="$c1" 'BEGIN{printf "%d",(b-a)/1000}')

  # CPU task: wall + host CPU-s (cgroup)
  c0=$(cg_cpu "$cid"); t0=$(now); docker exec "$cid" node -e "$CPU_JS" >/dev/null 2>&1 || true; t1=$(now); c1=$(cg_cpu "$cid")
  R["$s|cpu_wall"]=$(secs "$t0" "$t1"); R["$s|cpu_host"]=$(awk -v a="$c0" -v b="$c1" 'BEGIN{printf "%.2f",(b-a)/1e6}')

  # npm install: wall + host CPU-s + net
  rx0=$(rx_mb "$cid"); c0=$(cg_cpu "$cid"); t0=$(now)
  docker exec "$cid" sh -c 'cd /tmp && npm cache clean --force >/dev/null 2>&1; npm init -y >/dev/null 2>&1; npm install express --no-audit --no-fund >/dev/null 2>&1' || true
  t1=$(now); c1=$(cg_cpu "$cid")
  R["$s|npm_wall"]=$(secs "$t0" "$t1"); R["$s|npm_host"]=$(awk -v a="$c0" -v b="$c1" 'BEGIN{printf "%.2f",(b-a)/1e6}')
  R["$s|npm_net"]=$(awk -v a="$rx0" -v b="$(rx_mb "$cid")" 'BEGIN{printf "%.1f",b-a}')

  # per-box disk: writable layer
  R["$s|box_disk"]=$(docker ps -s --format '{{.Size}}' --filter "id=$cid" | awk '{print $1}')

  # teardown
  t0=$(now); docker rm -f "$cid" >/dev/null 2>&1 || true; t1=$(now); R["$s|teardown"]=$(secs "$t0" "$t1")
done

echo
echo "### docker / gVisor lifecycle"
printf '| metric'; for s in "${subjects[@]}"; do printf ' | %s' "$s"; done; echo ' |'
printf '|---'; for _ in "${subjects[@]}"; do printf '|---'; done; echo '|'
row() { printf '| %s' "$1"; for s in "${subjects[@]}"; do printf ' | %s' "${R["$s|$2"]:-?}"; done; echo ' |'; }
row "warm start -> ready, s" start
row "provision parity (apk git+ssh), s" prov_parity
row "provision network, MB" prov_net
row "idle total RAM (box+daemon), MB" idle_ram
row "idle CPU /30s, ms" idle_cpu
row "CPU task wall, s" cpu_wall
row "CPU task host CPU, s" cpu_host
row "npm install wall, s" npm_wall
row "npm install host CPU, s" npm_host
row "npm install network, MB" npm_net
row "per-box disk (writable layer)" box_disk
row "teardown, s" teardown
