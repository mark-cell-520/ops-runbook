# hermes 搬迁到 /root/hermes1 与 2026-10-29 冻结修复

同一次维护里做的另一件事：把 hermes 从 `/root/.hermes` 整体搬到 `/root/hermes1`，
修掉搬迁引入的三个故障，再解决一个让整台机器"卡死"的 glibc arena 问题。

> 如果只关心 NasCabOS，这个文件可以跳过；它记录的是同机的 hermes 侧工作，
> 因为两者共用同一份 `/etc/supervisord.conf`。

---

## 1. 搬迁本身

| 项 | 旧 | 新 |
|---|---|---|
| 安装目录 | `/root/.hermes` | `/root/hermes1` |
| `HERMES_HOME` | 默认 `$HOME/.hermes` | `/root/hermes1` |
| 启动器 | `/root/.local/bin/hermes`（真身） | `/root/.local/bin/hermes`（**stub**） |
| 真正的入口 | — | `/root/hermes1/hermes` |

### 为什么要加 stub

顶层容器入口脚本（PID 1）每次重启都会执行
`hermes config set model.*` / `hermes dashboard` / `hermes gateway` 之类，
其中 `model.*` 那几条会把模型**重置回 cephalon/minimax**。

`/root/.local/bin/hermes` 换成一个只拦这几条命令的 stub（原文件备份为 `hermes.orig-20261029`）：

```bash
case "$1" in
  config)
    case "$2" in
      set)
        case "$3" in
          model.base_url|model.api_key|model.default) refuse "$@" ;;
        esac ;;
    esac ;;
  dashboard|gateway) refuse "$@" ;;
esac
exec /root/hermes1/hermes "$@"
```

效果：入口脚本照样"成功"执行（exit 0），但模型不会被改，gateway 也不会被它以错误的
`HERMES_HOME` 拉起。要手动起 gateway 就用 `/root/hermes1/hermes gateway`。

### 搬迁时最容易踩的一点：install_key 是路径派生的

hermes 的 `install_key` 由安装路径推导。用 `tar` 复制目录过去，key 还是旧路径算出来的，
各种状态校验会对不上。搬完必须重新生成/校正 install_key。

---

## 2. 搬迁引入的三个故障

### (a) hermes-dashboard 一直 STOPPED

`supervisorctl` 显示 `hermes-dashboard STOPPED Oct 29 04:55 PM`。
原因是 supervisord 里还在用 `/root/.local/bin/hermes dashboard`——而那是 stub，
碰到 `dashboard` 直接 exit 0，supervisord 认为它"启动即退出"。

**修**：`command=/root/hermes1/hermes dashboard --port 9119 --no-open --skip-build`。

### (b) 没有任何东西在开机时拉起 gateway

`service-watchdog.sh` 里管 hermes-gateway 的整段（`fix_model_config` / `gateway_up` /
冷却闸门）在迁移时被删掉了，而 PID 1 的入口脚本又够不到 `/root/hermes1`。
结果：飞书长连接、cron、本地会话恢复全都没有。

**修**：在 supervisord 里补 `[program:hermes-gateway]`，直接指向 `/root/hermes1/hermes gateway`。
`startsecs=15`（冷启动到连上飞书要 10s+，给少了会被判启动失败而反复重启）、
`stopwaitsecs=90`（优雅停机要跑完 drain）。

### (c) hermes-webui 进 BACKOFF 反复重启 —— venv-sync 的 relaunch 陷阱

这个最隐蔽。原来 `command=` 用的是旧安装的
`/root/.hermes/tools/.../bin/python3`，而 `HERMES_HOME` 指向了 `/root/hermes1`。

hermes 的 `venv_sync.prepare_launch` 会拿"当前解释器 vs 目标 venv"做版本比对：
`hermes1/hermes-agent/venv` 是 python3.11 的，而这个解释器是 3.14 → 判定 venv 不是当前状态 →
`os.execv` 把自己重启成：

```
python3 -I -c '…runpy.run_path("/app/hermes-webui/server.py", run_name="__main__")'
```

`-I`（isolated）隐含 `-E`：既丢掉 `PYTHONPATH`，**也不把脚本所在目录放进 `sys.path`**
（实测 `sys.path[:4]` 只有 `/root/hermes1/hermes-agent` 加 stdlib zip）。
于是 `server.py:17` 的 `from api.auth import check_auth` 直接
`ModuleNotFoundError: No module named 'api'`，进 BACKOFF 反复重启。

**修**：解释器必须和 `HERMES_HOME` 一起换——
`command=/root/hermes1/tools/python-3.14.9+20261021-linux-x64/bin/python3 /app/hermes-webui/server.py`。
版本一致后 `prepare_launch` 返回 `None`（不重启），脚本按普通方式跑，`sys.path[0]` 就是
`/app/hermes-webui`，一切正常。

> **只改 `HERMES_HOME` 不改解释器是不够的**，这是这个坑的全部要点。
>
> 另外 `hermes-webui` 是**独立项目**（自带 `.git/README/Dockerfile`），不随 hermes 升级，
> 所以没有搬进 `/root/hermes1`；但它读的 `HERMES_HOME` 默认值是 `$HOME/.hermes`，
> 不显式指定的话，8787 端口那个服务一直在读旧安装的状态。
> 搬迁时把 `hermes1/webui/` 一并复制了（`.signing_key` / `settings.json` / `sessions` /
> `workspace` 都在），所以切过去不丢 webui 自己的状态。

---

## 3. 2026-10-29 冻结修复：glibc arena 收敛

### 症状

- `memory trim: ... malloc_trim=1 ... duration_ms=205612.3`（单次 **205 秒**）
- `web_server: event loop stalled 205.0s / 282.2s`
- `gateway.shutdown_watchdog: missed 3 consecutive liveness probes; exit 75`
- 用户侧感受：**整体环境卡死**

### 根因

`MALLOC_ARENA_MAX` 没设 → glibc 默认 `8 × nproc` = `8 × 128` = **1024 个 arena**，
每个在 64MB 边界扩展 → 堆膨胀。hermes 的 `mem_trim` 每 60s 调一次 `malloc_trim(0)`，
要遍历全部 1024 个 arena 并 `madvise` → 单次 205 秒 → gateway liveness 连续 3 次没响应 →
`exit 75` 自杀重启；dashboard 事件循环 drift 最大 282 秒。

### 为什么不能从内核态治理

这台机器是个容器，内核态手段 **100% 不可行**：

- `/sys/fs/cgroup` 挂载为 **ro**（写不了 `memory.high`）
- `/proc/sys/vm/{swappiness,overcommit_memory,drop_caches,compact_memory}` 全部 **READONLY**
- `cgroup memory.swap.max=0` → **无 swap**

所以只能用户态收敛：把 arena 数压到 2，堆面积缩到 1/512，`malloc_trim` 从 205 秒降到毫秒级。
同时把 BLAS/OpenMP 线程数压进 `cpu.max` 的 2 核配额（`200000/100000`）——
实测 `nr_throttled/nr_periods = 92/71127 = 0.13%`，CPU 本身不是瓶颈，
这么做是为了避免线程爆炸叠加内存膨胀。

统一加的这一组（`config/supervisord.conf` 里每个相关段都有）：

```ini
MALLOC_ARENA_MAX="2",OMP_NUM_THREADS="2",OPENBLAS_NUM_THREADS="2",
MKL_NUM_THREADS="2",NUMEXPR_NUM_THREADS="2"
```

`service-watchdog.sh` 内部还额外 `export` 了同一组做双保险（脚本若被手工从别处拉起，
不经 supervisord，行为不变）。

### 已否决的方案

`/etc/ld.so.preload` 注入 `mallopt(M_ARENA_MAX)`——一个不兼容的 `.so` 会让容器内
**所有**二进制启动失败，风险过高。

---

## 4. watchdog respawn 风暴：冷却闸门为什么不能用 `/tmp`

`service-watchdog.sh` 每 30s 轮询一次。问题是**一个"正在启动"的服务是活的但还没监听端口**，
`kill -0` 看得到进程、看不到端口，于是每次轮询都以为它死了、再拉一个——
实测堆到 ~190MB 的解释器实例，把真正在跑的那个挤进 reclaim thrash，每一轮对话都被饿死。

修法是加冷却：一旦发起过一次启动，就在冷却期内按住，等它自己起来，而不是再叠一个。

**关键细节：冷却闸门原来靠 `/tmp` 在容器重启时被清空来重置。这个前提在这台机器上是错的**——
`/tmp` 挂在容器可写层上，重启后照样存活，flag 于是永远比冷却期旧，等于从没真正限速过。

现在 flag 里记录它属于哪次启动：

```bash
BOOT_EPOCH=$(stat -c %Y /proc/1 2>/dev/null || echo 0)   # 不是 /tmp

start_allowed(){  # $1 = flag file, $2 = cooldown seconds
  local last now
  [ "$(cat "$1" 2>/dev/null)" = "$BOOT_EPOCH" ] || return 0   # 不同一次启动 → 冷却已耗尽
  last=$(stat -c %Y "$1" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ $(( now - last )) -ge "$2" ]
}
```

---

## 5. supervisord 里被关掉 autostart 的两个段

`[program:nginx]` 和 `[program:filebrowser]` 都设了 `autostart=false`，
因为这两个服务由容器入口脚本（PID 1）自己拉起来（`service nginx restart` + 它自己的
带认证的 filebrowser）。supervisord 里再来一份只会输掉端口竞争：

- **nginx**：`EADDRINUSE` → 退出 → `autorestart=true` 每 ~3.5s 重试，到 2026-10-29 07:27
  已经失败 **18054 次**，每次 fork `worker_processes auto` = 129 个 worker，跑在 2 核 cgroup 上
  ——约 230 万个短命进程，零流量。
- **filebrowser**：supervisord 那一份是 `--noauth` 且什么都没绑定（6 个 fd、无监听 socket、
  停在 futex_wait），而 supervisord 报它 RUNNING。更糟的是它的 `rm -f /app/filebrowser.db`
  每次（重）启动都执行，反复删掉正在用的那个实例的数据库。

关掉 autostart 后由 `service-watchdog.sh` 的端口守护兜底（同样带冷却闸门），保护不丢失。

---

## 6. 本机约束

- **不要对 feishu-bridge 执行 `systemctl restart/stop/reload`。** 当前会话是它的子进程，
  杀了父进程会引发无限重启循环。要动它走 supervisord。
- **判断内存压力要看 `/sys/fs/cgroup/memory.events` 和 `memory.pressure`**，
  不要看 `memory.current`/`memory.max`——4GiB 里 95% 基本是可回收的 page cache。
