#!/bin/bash
# Sample the container cgroup every 5s while the Flutter web build runs.
# Logs memory.current / anon / file / slab plus the top-6 RSS processes, so an
# approaching OOM can be caught before it SIGKILLs dart2js.
OUT=/var/log/memmon-build.log
LIMIT=$(cat /sys/fs/cgroup/memory.max)
echo "$(date +%FT%T) monitor start limit=$LIMIT" >"$OUT"
while true; do
  cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null)
  [ -z "$cur" ] && break
  anon=$(awk '/^anon /{print $2}' /sys/fs/cgroup/memory.stat 2>/dev/null)
  file=$(awk '/^file /{print $2}' /sys/fs/cgroup/memory.stat 2>/dev/null)
  slab=$(awk '/^slab /{print $2}' /sys/fs/cgroup/memory.stat 2>/dev/null)
  oomk=$(awk '/^oom_kill /{print $2}' /sys/fs/cgroup/memory.events 2>/dev/null)
  top=$(ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -6 \
        | awk '{printf "%s=%.0fM,",$2,$1/1024}' | sed 's/,$//')
  pct=$(( cur * 100 / LIMIT ))
  echo "$(date +%FT%T) cur=$((cur/1048576))MiB/${pct}% anon=$((anon/1048576))MiB file=$((file/1048576))MiB slab=$((slab/1048576))MiB oom_kill=$oomk top[$top]" >>"$OUT"
  # alert at 90% of the cap
  if [ "$pct" -ge 90 ]; then
    echo "$(date +%FT%T) *** WARNING ${pct}% of memory.max ***" >>"$OUT"
  fi
  sleep 5
done
