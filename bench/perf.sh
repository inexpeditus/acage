#!/usr/bin/env bash
# acage isolation benchmark — container & gVisor performance columns.
# Needs docker, so run as root:   sudo bash bench/perf.sh
# Workloads are identical to bench/acage-perf.sh so the columns are comparable.
set -euo pipefail

IMAGE=${IMAGE:-node:22-alpine}
RES=${RES:-"--cpus=2 --memory=2g"}         # match acage's 2 vCPU / 2 GB
RUNSC=${RUNSC:-runsc}
CPU_JS='let x=0;for(let i=0;i<1e9;i++){x+=i};console.log(x)'

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }
secs()   { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'; }

docker info >/dev/null 2>&1 || { echo "cannot talk to docker (run with sudo)" >&2; exit 1; }
HAVE_RUNSC=0; docker info 2>/dev/null | grep -qiw "$RUNSC" && HAVE_RUNSC=1 || echo "note: gVisor '$RUNSC' not registered; skipping" >&2

subjects=(container); [ "$HAVE_RUNSC" = 1 ] && subjects+=(gvisor)
flag() { [ "$1" = gvisor ] && echo "--runtime=$RUNSC" || echo ""; }

declare -A R
for s in "${subjects[@]}"; do
  f=$(flag "$s")
  echo "-- $s" >&2

  # start: create+start+run+cleanup of a cached image, 5 runs, median
  st=()
  for _ in 1 2 3 4 5; do
    t0=$(date +%s.%N); docker run --rm $f $RES "$IMAGE" true >/dev/null 2>&1; t1=$(date +%s.%N)
    st+=("$(secs "$t0" "$t1")")
  done
  R["$s|start"]=$(median "${st[@]}")

  # idle memory: a detached sleeper, cgroup memory via docker stats
  cid=$(docker run -d $f $RES "$IMAGE" sleep 30)
  sleep 2
  R["$s|mem"]=$(docker stats --no-stream --format '{{.MemUsage}}' "$cid" 2>/dev/null \
                | awk '{v=$1; n=v; sub(/[A-Za-z]+/,"",n); n=n+0;
                        if(v ~ /GiB/) printf "%.1f", n*1024;
                        else if(v ~ /MiB/) printf "%.1f", n;
                        else if(v ~ /KiB/) printf "%.1f", n/1024;
                        else printf "%.1f", n/1048576}')
  docker rm -f "$cid" >/dev/null 2>&1 || true

  # CPU-bound: identical node loop, 5 runs, median
  cpu=()
  for _ in 1 2 3 4 5; do
    t0=$(date +%s.%N); docker run --rm $f $RES "$IMAGE" node -e "$CPU_JS" >/dev/null 2>&1; t1=$(date +%s.%N)
    cpu+=("$(secs "$t0" "$t1")")
  done
  R["$s|cpu"]=$(median "${cpu[@]}")

  # npm install express in a fresh container (empty cache)
  t0=$(date +%s.%N)
  docker run --rm $f $RES "$IMAGE" sh -c 'cd /tmp && npm init -y >/dev/null 2>&1 && npm install express --no-audit --no-fund >/dev/null 2>&1' || true
  t1=$(date +%s.%N)
  R["$s|npm"]=$(secs "$t0" "$t1")
done

# disk: image size is shared across all containers; per-instance layer ~0 here
IMG_MB=$(awk -v b="$(docker image inspect "$IMAGE" --format '{{.Size}}' 2>/dev/null || echo 0)" 'BEGIN{printf "%d", b/1048576}')

echo
echo "### container / gVisor perf"
printf '| metric'; for s in "${subjects[@]}"; do printf ' | %s' "$s"; done; echo ' |'
printf '|---'; for _ in "${subjects[@]}"; do printf '|---'; done; echo '|'
row() { printf '| %s' "$1"; for s in "${subjects[@]}"; do printf ' | %s' "${R["$s|$2"]:-?}"; done; echo ' |'; }
row "start (run cached image), s" start
row "idle memory, MB" mem
row "CPU loop (median of 5), s" cpu
row "npm install express, s" npm
echo
echo "disk: base image ($IMAGE) = ${IMG_MB} MB (shared by all containers); per-container layer ~0 MB for this workload."
