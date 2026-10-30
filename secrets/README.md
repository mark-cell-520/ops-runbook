# 本机需要自行填的值

这个仓库只保存**方法与配置结构**，不保存任何真实密钥。下面每一项在部署时都需要你
在本机补齐，位置都在 `local/`（已被 `.gitignore` 忽略）或直接写进系统配置。

| 名称 | 用在哪 | 去哪取 / 怎么生成 |
|---|---|---|
| NasCabOS super_admin 用户名 + 密码 | 登录 `/nascab/` | 首次启动随机生成，见 [docs/nascab-initial-admin.md](../docs/nascab-initial-admin.md) 的三种取法；或跑 `scripts/nascab/recover-admin-credentials.sh --verify` 现场解出 |
| nginx Basic Auth 口令 | `/etc/nginx/htpasswd`，保护 `/`、`/shell`、`/fb` | `htpasswd -c /etc/nginx/htpasswd <user>`。文件本身**不要**提交 |
| `HEARTFLOW_MCP_TOKEN` | `[program:heartflow-mcp]` 的 `environment=` | 与 `/root/hermes1/.mcp.env` 里的值保持一致；改的时候两边一起改 |
| hermes `model.api_key` | hermes 的 `config.yaml` | 从 `/root/hermes1/.env` 的 `STEPFUN_API_KEY` 读；`scripts/hermes/hermes-config-patch.sh` 就是干这个的 |
| filebrowser 的 `--username` / `--password` | `scripts/hermes/service-watchdog.sh` 的 `start_filebrowser()` | 必须与容器入口脚本（PID 1 的 `filebrowser` 命令行）一致，否则守护重启出来的实例认证行为和原来不同。仓库里是 `<REDACTED>` |
| nginx 自签证书 | `/etc/ssl/certs/nginx-selfsigned.crt` + `.key` | `openssl req -x509 -nodes -newkey rsa:2048 -days 3650 ...`。私钥绝不提交 |

## 规则

1. **提交前扫一遍。** 每次 `git add` 前跑 `bash scripts/scan-secrets.sh`。
   通用形态（API key、bcrypt、PEM、`enc:v1:` 密文）由脚本内置；**本机已知的真实值**
   要自己放进 `local/known-values.txt`（已被忽略，格式见同目录的 `.example`），
   否则扫不出来。本机的真实值**不要**写进 `.example` 或脚本本身。
2. **不要把数据库提交进来。** `/app/nascab/data/` 整个目录都在 `.gitignore` 里；
   里面有 `config.serverId`，而它就是 NasCabOS 密码的加密密钥来源。
3. **日志不要提交。** `/var/log/nascab.out.log` 每次启动都会打印解密后的管理员密码
   （见 [docs/nascab-initial-admin.md](../docs/nascab-initial-admin.md)）。
4. **这个仓库应该是 private。** 里面的 `config/supervisord.conf` 和
   `config/nginx-default` 完整描述了这台机器的服务拓扑、端口、路径，以及一个对外暴露的
   NAS 入口。public 仓库等于把攻击面说明书公开。
