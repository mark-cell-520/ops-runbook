#!/bin/bash
# service-watchdog: keeps feishu-bridge + nginx/filebrowser alive (guarded, idempotent)
#
# 2026-10-29：hermes 已整体搬迁到 /root/hermes1（自带 HERMES_HOME=/root/hermes1 与
# 自己的启动器），顶层容器入口脚本（PID 1）再也够不到它，因此本脚本不再管理 hermes：
#   - 删掉 fix_model_config / model_config_ok / gateway_up / gateway 启动段及其冷却闸门
#   - /root/.local/bin/hermes 换成拦掉入口脚本那几条命令的 stub（原文件备份为
#     hermes.orig-20261029），重启后不会有 gateway 被拉起，模型也不会再被重置成
#     cephalon/minimax-m2.7
# 现在只剩 feishu-bridge 与 nginx/filebrowser 的守护。要把 hermes 拉起来，用
# /root/hermes1/hermes gateway（它有自己的 HERMES_HOME，与这里互不干扰）。
LOG=/var/log/service-watchdog.log
BRIDGE_DIR=/root/.local/share/feishu-bridge
log(){ echo $(date +%F_%T) "$*" >> $LOG; }

# 2026-10-29 冻结修复：glibc arena 收敛。
# 本脚本是 feishu-bridge 的父进程，环境变量经 exec 传给它——它才是 arena 大头。
# 证据与机理见 /etc/supervisord.conf [supervisord] 段注释
# （malloc_trim 单次 duration_ms=205612.3）。hermes-gateway 曾是另一个大头，但它已
# 迁往 /root/hermes1 且不再由这里启动；若日后重新拉起，需自行带上这组变量。
# supervisord 的 [program:service-watchdog] 也设了同一组变量，这里再 export
# 一次做双保险：脚本若被手工从别处拉起（不经 supervisord），行为不变。
export MALLOC_ARENA_MAX=${MALLOC_ARENA_MAX:-2}
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-2}
export OPENBLAS_NUM_THREADS=${OPENBLAS_NUM_THREADS:-2}
export MKL_NUM_THREADS=${MKL_NUM_THREADS:-2}
export NUMEXPR_NUM_THREADS=${NUMEXPR_NUM_THREADS:-2}

# 一个"正在启动"的服务是活的但还没监听端口，每次轮询都以为它死了、再拉一个，就会
# 堆出一堆同等规模的进程，把真正在跑的那个挤进 reclaim thrash。所以启动要限速：
# 一旦发起过一次，就在冷却期内按住，等它自己起来，而不是再叠一个。
#
# 冷却闸门原来靠 /tmp 在容器重启时被清空来重置——这个前提在本机是错的（/tmp 挂在
# 容器可写层上，重启后照样存活），flag 于是永远比冷却期旧，等于从没真正限速过。
# 现在 flag 里记录它属于哪次启动（PID 1 的启动时间）：不同的一次启动意味着冷却已
# 耗尽、确实该重新拉，不管 /tmp 留下了什么。
BOOT_EPOCH=$(stat -c %Y /proc/1 2>/dev/null || echo 0)

start_allowed(){  # $1 = flag file, $2 = cooldown seconds
  local last now
  [ "$(cat "$1" 2>/dev/null)" = "$BOOT_EPOCH" ] || return 0
  last=$(stat -c %Y "$1" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ $(( now - last )) -ge "$2" ]
}

mark_start(){ printf '%s\n' "$BOOT_EPOCH" > "$1"; }

# ---------------------------------------------------------------------------
# nginx / filebrowser port guard (2026-10-29)
#
# Both of these are started by the container entrypoint (PID 1), not by
# supervisord: `service nginx restart` and its own authenticated filebrowser.
# The supervisord copies of both were removed from autostart because they can
# only ever lose the race for the port — see the comments in /etc/supervisord.conf.
# The nginx one alone had failed 18054 times by 07:27, forking 129 workers each
# time on a 2-core cgroup; the filebrowser one sat at 6 fds with no listening
# socket while supervisord reported it RUNNING, and its `rm -f /app/filebrowser.db`
# kept deleting the database the live instance was using.
#
# With autostart off, nothing would restart them if the entrypoint's copy dies,
# so this loop guards the ports instead. Same cooldown trick as above: if a start
# is issued and the port still isn't there, wait rather than hammering it.
NGINX_COOLDOWN=${WD_NGINX_COOLDOWN:-300}
FILEBROWSER_COOLDOWN=${WD_FILEBROWSER_COOLDOWN:-300}
LAST_NGINX_START=/tmp/.service-watchdog-last-nginx-start
LAST_FILEBROWSER_START=/tmp/.service-watchdog-last-filebrowser-start

# True when something is LISTENing on $1 (tcp or tcp6). Parsing /proc/net rather
# than shelling out to ss/netstat keeps this to one awk per poll.
port_listening(){
  local hex
  printf -v hex '%04X' "$1"
  awk -v h=":$hex" '$4 == "0A" && $2 ~ h"$" { f = 1; exit } END { exit !f }' \
    /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# Reproduces the entrypoint's command (same bcrypt hash as /proc/1/cmdline) so
# the fallback start keeps the same auth behaviour. Deliberately no
# `rm -f /app/filebrowser.db` — that is what corrupted the live database.
start_filebrowser(){
  /app/filebrowser -a 0.0.0.0 -r /root -d /app/filebrowser.db \
    --baseurl /fb --username '<REDACTED:与 PID 1 入口脚本一致>' \
    --password '<REDACTED:同上，bcrypt 哈希，见 secrets/README.md>' \
    >> $LOG 2>&1 &
}

sleep ${WD_INITIAL_DELAY:-15}
log "watchdog started pid=$$ interval=${WD_INTERVAL:-30}s boot=${BOOT_EPOCH} (hermes migrated to /root/hermes1; gateway no longer managed here)"
while true; do
  if ! pgrep -f 'bin/feishu-bridge --config' >/dev/null; then
    log "bridge down -> starting"
    cd $BRIDGE_DIR && setsid --fork bash start-bridge.sh >> $LOG 2>&1
    log "bridge start issued"
  fi
  if ! port_listening 80 && ! port_listening 443; then
    if start_allowed "$LAST_NGINX_START" "$NGINX_COOLDOWN"; then
      log "nginx 80/443 not listening -> starting"
      mark_start "$LAST_NGINX_START"
      /usr/sbin/nginx >> $LOG 2>&1
      log "nginx start issued"
    else
      log "nginx 80/443 still not listening, but a start was issued <${NGINX_COOLDOWN}s ago; holding off (cooldown)"
    fi
  fi
  if ! port_listening 8080; then
    if start_allowed "$LAST_FILEBROWSER_START" "$FILEBROWSER_COOLDOWN"; then
      log "filebrowser 8080 not listening -> starting"
      mark_start "$LAST_FILEBROWSER_START"
      start_filebrowser
      log "filebrowser start issued"
    else
      log "filebrowser 8080 still not listening, but a start was issued <${FILEBROWSER_COOLDOWN}s ago; holding off (cooldown)"
    fi
  fi
  sleep ${WD_INTERVAL:-30}
done
