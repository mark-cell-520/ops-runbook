# 安全说明

这个仓库记录的是**一台自用 homelab 机器**的部署过程与运维方法。它不是商业产品，
也没有 SLA。公开发布的目的是把这些踩坑结论留给下一个遇到同样问题的人，不是宣称
这套配置适合照搬到生产环境。

## 这个仓库里有什么

| 内容 | 敏感度 |
|---|---|
| 三份部署/排障文档（`docs/`） | 低——都是方法与根因分析，不含凭据 |
| `config/supervisord.conf`、`config/nginx-default` | **中——完整描述了一台机器的服务拓扑、端口、路径** |
| 安装/构建/启动脚本（`scripts/`） | 低 |
| `scripts/scan-secrets.sh` | 低——只含通用密钥形态，真实值在 gitignored 的 `local/` |

不含：任何真实密钥、口令、bcrypt 哈希、私钥、证书、数据库、日志。
`<REDACTED:...>` 占位的地方说明那里原本有真实值，取法见 [secrets/README.md](secrets/README.md)。

## 已知的暴露面（`config/` 描述的就是这个）

同一个对外 Web 入口后面挂着：

- `/nascab/` —— 一个完整的 NAS：文件读写、远程终端、docker 管理
- `/shell` —— Web 终端（root）
- `/fb` —— filebrowser，`-r /root`
- `/` 与上述路径由 nginx Basic Auth 保护（`/etc/nginx/htpasswd`，不在仓库里）

`/nascab/` 和 `/fb` 是 `auth_basic off` 的——账号由应用自己管。也就是说，**只要能访问
这台机器的 80/443，就到达了 NAS 的登录页**。Basic Auth 只挡 `/`、`/shell` 等路径。

这意味着：

- 端口映射到公网之前，值得单独做一次评估。文档
  [docs/nascab-headless-deploy.md](docs/nascab-headless-deploy.md) §8 自己也标了这一点。
- 应用自己的认证强度（初始 super_admin 是随机 6+6 位，见
  [docs/nascab-initial-admin.md](docs/nascab-initial-admin.md)）就是这道防线的强度。

## 如果你要复用这些脚本

- **先把 `<REDACTED:...>` 全部换成你自己的值**，见 [secrets/README.md](secrets/README.md)。
  直接 `cp config/supervisord.conf /etc/supervisord.conf` 会得到一个 `HEARTFLOW_MCP_TOKEN`
  是占位符的配置，heartflow-mcp 会起不来。
- **提交前跑 `bash scripts/scan-secrets.sh`**，并先把本机已知的真实值填进
  `local/known-values.txt`（格式见 `local/known-values.txt.example`），否则脚本只认
  通用密钥形态，认不出你这台机器的特征串。
- `scripts/nascab/install-flutter.sh` 装的是编译器。它支持 `EXPECTED_SHA256` 强制校验，
  **建议每次都设**——一个被动过手脚的 tarball 会在后续每一次构建里执行。

## 报告问题

这是个 homelab runbook，不是一个有支持流程的项目。如果你在里面发现安全问题，
最有用的做法是提 issue 说明"哪一段照做会导致什么后果"；涉及这台具体机器的凭据或
漏洞，请私下联系维护者，不要开公开 issue。
