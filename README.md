# 本机运维 Runbook

这台机器的部署过程、配置和踩坑记录。所有内容都是**可复现的方法与配置结构**，
不含任何真实密钥——需要本机值的地方用 `<REDACTED:...>` 占位，补齐位置见
[secrets/README.md](secrets/README.md)。

## 内容

| 文档 | 讲什么 |
|---|---|
| [docs/nascab-headless-deploy.md](docs/nascab-headless-deploy.md) | NasCabOS 以后端服务方式部署的全过程（非 Docker）：依赖安装、资源解包、数据目录、Flutter web 客户端编译、supervisord、nginx 反代、验证、踩坑速查表 |
| [docs/nascab-initial-admin.md](docs/nascab-initial-admin.md) | 为什么没有"设置账号密码"向导、初始 super_admin 的机制、三种取凭据的渠道、密码的现场解密方法、以及哪些"修复"思路是错的 |
| [docs/hermes1-migration-freeze-fix.md](docs/hermes1-migration-freeze-fix.md) | hermes 从 `/root/.hermes` 迁到 `/root/hermes1`，搬迁引入的三个故障，glibc arena 收敛，watchdog respawn 风暴与 `/tmp` 冷却陷阱 |

## 目录

```
config/
  supervisord.conf      全部服务的 supervisord 配置（含大量根因注释）
  nginx-default         nginx 站点配置，含 /nascab/ 反代
scripts/
  nascab/               NasCabOS 安装、构建、启动脚本
    install-deps.sh       装依赖（删 postinstall、NODE_USE_ENV_PROXY）
    install-flutter.sh    装 Flutter 3.38.10
    build-webui.sh        编译 web 客户端（--base-href /nascab/ --no-wasm-dry-run）
    download-assets.sh    下载发行版 zip
    extract-assets.py     解包（本机没有 unzip，用 stdlib zipfile）
    start-nascab.sh       以前台方式启动（调试用）
    memmon-build.sh       编译期间每 5s 采一次 cgroup 内存
    recover-admin-credentials.sh   ★ 现场解出当前 super_admin 明文凭据
  hermes/
    service-watchdog.sh   feishu-bridge / nginx / filebrowser 的守护（含冷却闸门）
  scan-secrets.sh        提交前的密钥自查
docs/                    见上
secrets/README.md        哪些值需要在本机补齐、去哪取
local/                   本机私有覆盖，已被 git 忽略（模板见 known-values.txt.example）
```

## 快速上手

```bash
# 1. 把要补的值看一遍
cat secrets/README.md

# 2. 让密钥扫描认识你这台机器的真实值（可选但强烈建议）
cp local/known-values.txt.example local/known-values.txt
# 然后照格式把本机的特征串填进去，这个文件不会被提交

# 3. 拿到 NasCabOS 管理员凭据（最常用的一条）
bash scripts/nascab/recover-admin-credentials.sh --verify
# → username: <...>
# → password: <...>
# → 登录成功

# 4. 提交前自查
bash scripts/scan-secrets.sh
```

## 这个仓库应该是 private

`config/` 下的两份文件完整描述了这台机器的服务拓扑、端口、路径，以及一个对外暴露的
NAS 入口（`/nascab/` 带文件读写、远程终端、docker 管理）。public 等于把攻击面说明书公开。

## 约定

- 提交信息用中文。
- 只提交"怎么拿到值"的方法，不提交值本身。
- 配置副本里凡是 `<REDACTED:...>` 的地方，说明那里原本有真实值，`secrets/README.md` 里有取法。
