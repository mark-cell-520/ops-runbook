# NasCabOS headless 部署全过程（非 Docker）

在这台机器上把 [NasCabOS](https://github.com/nascab/NasCabOS) 以后端服务方式跑起来的完整过程。
上游只提供 `electron .`（桌面端）；这里改用 `node src/main_nascab_os.js`，利用它内置的
"Clientless service mode" 只跑后端，用 supervisord 守护，再用 nginx 反代到 `/nascab/` 子路径。

**最终形态**

| 项 | 值 |
|---|---|
| supervisord 段 | `[program:nascab]`，`priority=45`，`autostart=true` |
| 代码目录 | `/app/nascab/repo/electron_server` |
| 数据目录 | `/app/nascab/data`（**在代码树之外**，见 §4） |
| 端口 | HTTP `6789` / HTTPS `6799`（自签证书） |
| 对外入口 | `https://<host>:<port>/nascab/`，nginx 反代，`auth_basic off` |
| 进程 | `node src/main_nascab_os.js`（clientless），下挂 4 个 worker |

---

## 1. 为什么不用 Docker

- 官方镜像 `ypptec/nascab` 停在 **3.6.1（2025-08-21）**，而源码仓库已经走到 2026-10，
  上 Docker 等于回退 14 个月。
- 这台机器本身是个**非特权容器**（没有 `CAP_SYS_ADMIN`），Docker-in-Docker 在这里根本跑不起来。

所以照官方 Docker 文档的**原则**（数据挂卷到代码树外）做，但不用 Docker。

---

## 2. 安装依赖：`scripts/nascab/install-deps.sh`

```bash
bash /root/nascab-scripts/install-deps.sh      # 或仓库副本 scripts/nascab/install-deps.sh
```

这一步做两件关键的事：

1. **删掉根 `package.json` 的 `postinstall`**（`npx @electron/rebuild`）。
   它需要 electron 在场，会把原生模块按 electron 的 ABI 重编一遍——而我们是要用 plain node 跑，
   编错了反而加载不上。`electron` 是 devDependency，`npm ci --omit=dev` 会自然把它排除。
2. **`export NODE_USE_ENV_PROXY=1`**。Node 的全局 `fetch` **不读** `http_proxy`/`https_proxy`，
   而 `onnxruntime-node` 的安装脚本要从 github.com 拉 ~100MB，没有这个变量就会卡死。
   运行时需要出网的步骤同样需要它（`start-nascab.sh` 里也设了）。

### 必须留在 node v22

用 `/root/.hermes/node/bin/node`（v22）。原生模块 nodejieba / better-sqlite3 / sharp /
node-pty 等都是按 v22 的 ABI 编译的；换到 node 26 会全部加载失败。

### nodejieba 要从源码重编

它的预编译二进制要求 `GLIBC_2.38`，而这个镜像是 2.35：

```bash
cd /app/nascab/repo/electron_server
node_modules/.bin/node-pre-gyp install --build-from-source --module=nodejieba
```

它是唯一有这个问题的模块。

---

## 3. 拉取发行版资源：`extract-assets.py`

`unzip` 在这台机器上**没有安装**，所以用 Python 标准库：

```bash
python3 /root/nascab-scripts/download-assets.sh   # 下载 libs-linux.zip + onnx_models.zip
python3 /root/nascab-scripts/extract-assets.py    # 用 zipfile 模块解包
```

两个坑：

- 发行版 zip **会丢掉可执行位**，解出来后必须 `chmod +x` 每一个 `libs/` 下的 ELF。
- zip 内的条目带 `libs-linux/` 前缀，解到目标目录后会多一层，注意路径。

---

## 4. 数据目录必须在代码树之外

通过 supervisord 的 `environment=` 传 **`userDataFolder="/app/nascab/data"`**。

注意这个名字是**小写的 `userDataFolder`**，不是 Electron 标准的 `userData`，很容易看漏。
不设的话应用默认用 `<cwd>/data`，也就是 git checkout 里面——那样每次更新代码都会把数据库
（用户、账号、`config.serverId`）一起毁掉。

官方 Docker 文档也是同一个意思（把卷挂到 `/root/.local/share/nascab`）。

---

## 5. 端口会被悄悄改掉

端口持久化在数据库的 `config` 表里，键名 `apiPortHttp` / `apiPortHttps`。
端口被占用时应用会退到 +1，**并且把退避值写回数据库**——所以一次临时的端口冲突会永久改变端口，
之后所有配置都和实际不符。归一化办法：把这两行改回 6789/6799 然后重启。

---

## 6. 编译 Web 客户端：`install-flutter.sh` + `build-webui.sh`

上游只发桌面端，仓库里没有预构建的 web 客户端，而服务端是会 serve `web/main` 的
（`src/api/app.js`）。headless 安装不跑这一步就没有 UI。

```bash
bash /root/nascab-scripts/install-flutter.sh   # Flutter 3.38.10 → /opt/flutter
bash /root/nascab-scripts/build-webui.sh       # → electron_server/web/main
```

**为什么是 3.38.10**：`flutter_client/pubspec.yaml` 声明 `environment: sdk: ^3.10.1`，
3.38.10 是最后一个内置 Dart 还在 3.10 线（3.10.9）的 stable。更新的 stable
（3.47.x / Dart 3.13）会拉到这个项目约束从没见过的传递依赖。

### 两个非显然的适配

**子路径。** 用 `--base-href /nascab/` 构建，让它能活在 nginx 的 `/nascab` 下；
同时要 patch `lib/core/api/api_controller.dart`，让 API base URL 带上同样的前缀——
上游只取 origin，那样 `/api/...` 会被送到 nginx 在 `/` 上代理的其他服务去。

**`--no-wasm-dry-run`。** 这台机器有 4GiB 的 cgroup 上限。不关掉 wasm dry run 的话，
Flutter 会在 dart2js 旁边**并发**跑一个 dart2wasm 编译（在 ~1.3GB 之上再加 ~1.5GB），
OOM killer 直接 SIGKILL 掉 dart2js（报 `Process exited abnormally with exit code -9`），
`main.dart.js` 永远不生成，然后 `/nascab/` 就永远卡在 Flutter 的 loading 状态。
我们只交付 dart2js 产物（`flutter_bootstrap.js` 也钉死了 `compileTarget dart2js`），
dry run 在这里是纯开销。

编译期间可以跑 `scripts/nascab/memmon-build.sh` 每 5s 采一次 cgroup 内存，提前发现要 OOM。

---

## 7. supervisord：`config/supervisord.conf`

```bash
cp config/supervisord.conf /etc/supervisord.conf
supervisorctl -c /etc/supervisord.conf reread
supervisorctl -c /etc/supervisord.conf update
supervisorctl -c /etc/supervisord.conf status nascab
```

`[program:nascab]` 段（完整见 `config/supervisord.conf`）：

```ini
[program:nascab]
command=/root/.hermes/node/bin/node src/main_nascab_os.js
directory=/app/nascab/repo/electron_server
environment=NODE_USE_ENV_PROXY="1",NODE_ENV="production",userDataFolder="/app/nascab/data",MALLOC_ARENA_MAX="2",UV_THREADPOOL_SIZE="2",...
priority=45
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=30
```

> 提交到仓库的副本里，`[program:heartflow-mcp]` 的 `HEARTFLOW_MCP_TOKEN` 是 `<REDACTED>`，
> 用之前按 `secrets/README.md` 补回。

日志按 20MB × 3 轮转（这台机器没有 logrotate，而官方 Docker 文档也警告过 nascab 的日志
在真实 NAS 使用下会膨胀）。

---

## 8. nginx：`config/nginx-default`

```bash
cp config/nginx-default /etc/nginx/sites-available/default
nginx -t && nginx -s reload
```

两个 location，**80 和 443 两个 server 块里都要有**：

```nginx
location = /nascab { return 308 /nascab/; }     # 补尾部斜杠，否则相对路径解析错
location /nascab/ {
    auth_basic off;                              # 账号由 NasCabOS 自己管，与 /fb 同一套路
    proxy_pass http://127.0.0.1:6789/;           # 尾部斜杠会剥掉 /nascab 前缀
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 128g;                   # 上传大文件
}
```

`proxy_pass` 末尾那个斜杠是关键：它把 `/nascab` 前缀剥掉，Flutter 客户端里那些
绝对的 `/api/...` 和资源 URL 才能正确落到应用根上。

> **注意这把一个完整的 NAS（文件读写、远程终端、docker 管理）放在了和 `/`、`/shell`
> 同一个对外入口上。** 如果这台机器是公网可达的，这值得单独评估一次。

---

## 9. 验证

```bash
# 1. 进程与端口
supervisorctl -c /etc/supervisord.conf status nascab
ss -lntp | grep -E ':(6789|6799)'

# 2. 接口活着
curl -s http://127.0.0.1:6789/api/auth/hasSuperAdmin

# 3. 走 nginx 反代（应返回 Flutter 的 index.html，约 16KB）
curl -skI https://127.0.0.1/nascab/ | head -3

# 4. 登录（凭据见 docs/nascab-initial-admin.md）
curl -s -X POST http://127.0.0.1:6789/api/auth/login \
     -H 'Content-Type: application/json' \
     -d '{"username":"<user>","password":"<pass>"}'
# → {"success":true,"message":"登录成功","data":{...,"accessToken":"...","refreshToken":"..."}}
```

预期进程树：`node src/main_nascab_os.js` 下挂
`expressWorker` ×2 + `backgroundTaskWorker` + `expressBroadcastWorker`。

---

## 10. 踩坑速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `npm ci` 卡住不动 | Node `fetch` 不读代理 | `export NODE_USE_ENV_PROXY=1` |
| 原生模块加载失败 | node 版本不是 22 | 用 `/root/.hermes/node/bin/node` |
| `nodejieba` 报 GLIBC_2.38 | 预编译二进制不匹配 | `node-pre-gyp install --build-from-source` |
| `unzip: command not found` | 容器里没装 | 用 `extract-assets.py`（stdlib zipfile） |
| 端口莫名变成 6790 | 端口冲突后被写回数据库 | 改回 `config` 表 + 重启 |
| `/nascab/` 永远转圈 | wasm dry run 并发编译 OOM，dart2js 被杀 | `--no-wasm-dry-run` 重编 |
| `/nascab`（无斜杠）404 | Flutter 相对路径解析错 | `location = /nascab { return 308 /nascab/; }` |
| 数据库突然空了 | 数据目录落在代码树内，被更新覆盖 | 设 `userDataFolder` |

相关：[docs/nascab-initial-admin.md](nascab-initial-admin.md)（初始账号）、
[docs/hermes1-migration-freeze-fix.md](hermes1-migration-freeze-fix.md)（同机的 hermes 侧工作）
