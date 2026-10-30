#!/bin/bash
# Sample the container cgroup every 5s while the Flutter web build runs.
# Logs memory.current / anon / file / slab plus the top-6 RSS processes, so an
# approaching OOM can be caught before it SIGKILLs dart2js.
#
# 注意：current/max 的百分比只说明"占了额度"，不等于有内存压力——4GiB 里大部分是
# 可回收的 page cache（file）。真正判断会不会被 OOM kill 看 memory.events 的
# oom_kill 计数（下面每行都打）和 memory.pressure，别看到 90% 就以为要炸。
set -uo pipefail

OUT=${MEMMON_OUT:-/var/log/memmon-build.log}
INTERVAL=${MEMMON_INTERVAL:-5}

LIMIT=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
# cgroup v1 或没设上限时这里是 "max"，算术展开会直接报错
case "$LIMIT" in
  ''|max|*[!0-9]*) LIMIT= ;;
esac
if [ -z "$LIMIT" ]; then
  echo "$(date +%FT%T) monitor start limit=<unset, 不计算百分比>" >"$OUT"
else
  echo "$(date +%FT%T) monitor start limit=$LIMIT" >"$OUT"
fi

while true; do
  cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null)
  [ -z "$cur" ] && break
  anon=$(awk '/^anon /{print $2}' /sys/fs/cgroup/memory.stat 2>/dev/null)
  file=$(awk '/^file /{print $2}' /sys/fs/cgroup/memory.stat 2>/dev/null)
  slab=$(awk '/^slab /{print $2}' /sys/fs/cgroup/memory.stat 2>/dev/null)
  oomk=$(awk '/^oom_kill /{print $2}' /sys/fs/cgroup/memory.events 2>/dev/null)
  # comm 理论上可能含空格（内核线程），把第 2 个字段之后全并回去
  top=$(ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -6 \
        | awk '{c=$2; for(i=3;i<=NF;i++) c=c" "$i; printf "%s=%.0fM,",c,$1/1024}' \
        | sed 's/,$//')
  if [ -n "$LIMIT" ]; then
    pct=$(( cur * 100 / LIMIT ))
    echo "$(date +%FT%T) cur=$((cur/1048576))MiB/${pct}% anon=$((anon/1048576))MiB file=$((file/1048576))MiB slab=$((slab/1048576))MiB oom_kill=$oomk top[$top]" >>"$OUT"
    # alert at 90% of the cap
    if [ "$pct" -ge 90 ]; then
      echo "$(date +%FT%T) *** WARNING ${pct}% of memory.max (大部分可能是可回收 page cache，看 oom_kill 有没有涨) ***" >>"$OUT"
    fi
  else
    echo "$(date +%FT%T) cur=$((cur/1048576))MiB anon=$((anon/1048576))MiB file=$((file/1048576))MiB slab=$((slab/1048576))MiB oom_kill=$oomk top[$top]" >>"$OUT"
  fi
  sleep "$INTERVAL"
done
