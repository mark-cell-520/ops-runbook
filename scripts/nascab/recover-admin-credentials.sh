#!/bin/bash
# recover-admin-credentials.sh — 从 NasCabOS 数据库里现场解出当前 super_admin 的明文凭据。
#
# 背景：首次启动时 ensureInitialSuperAdmin() 会随机生成一对凭据，而 headless 模式下本该
# 把凭据落盘的那一步被 `if (isInitialFlag === '1' && !packageJson.isDocker) return;`
# 跳过了，所以没有任何地方能"看到"它们（详见 docs/nascab-initial-admin.md）。
#
# 但密码在库里是可逆的：
#   enc:v1:<base64(iv || ciphertext)>，aes-256-cbc，key = sha256(config.serverId)
# 因此任何时候都能解出当前明文——有人改过密码，这里解出来的也是新值。
#
# 用法：
#   bash recover-admin-credentials.sh             只解出凭据
#   bash recover-admin-credentials.sh --verify    解出来后再打一次登录接口确认有效
#
# 环境变量覆盖：
#   NASCAB_DB     数据库路径      默认 /app/nascab/data/database/nascab_main.db
#   NASCAB_BASE   接口 base URL   默认 http://127.0.0.1:6789
set -euo pipefail

DB=${NASCAB_DB:-/app/nascab/data/database/nascab_main.db}
BASE=${NASCAB_BASE:-http://127.0.0.1:6789}
VERIFY=0
[ "${1:-}" = "--verify" ] && VERIFY=1

[ -r "$DB" ] || { echo "读不到数据库: $DB" >&2; exit 1; }

# 用 python 读库（nascab 的 node_modules 里没有 sqlite3 模块，别写 node 脚本）
# 输出三行：serverId / username / password(enc:v1:...)
row=$(python3 - "$DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
sid = db.execute("select value from config where key='serverId'").fetchone()
u = db.execute(
    "select username, password from user where type='super_admin' order by id limit 1"
).fetchone()
if not sid or not u:
    sys.exit(3)
print(sid[0]); print(u[0]); print(u[1])
PY
) || { echo "库里没有 super_admin，或没有 config.serverId" >&2; exit 1; }

sid=$(printf '%s\n' "$row" | sed -n 1p)
username=$(printf '%s\n' "$row" | sed -n 2p)
blob=$(printf '%s\n' "$row" | sed -n 3p)

case "$blob" in
  enc:v1:*) blob=${blob#enc:v1:} ;;
  *) echo "密码不是 enc:v1: 格式（旧格式或明文），原值如下：" >&2; printf '%s\n' "$blob"; exit 0 ;;
esac

# 注意：必须用 printf %s，不能 echo——echo 会补换行，sha256 就完全不同了。
# Node 侧是 crypto.createHash('sha256').update(serverId)，用的是字符串本身。
key=$(printf %s "$sid" | sha256sum | cut -d' ' -f1)

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf %s "$blob" | base64 -d > "$tmp/ct.bin"
iv=$(dd if="$tmp/ct.bin" bs=1 count=16 2>/dev/null | od -An -tx1 | tr -d ' \n')
tail -c +17 "$tmp/ct.bin" > "$tmp/body.bin"

password=$(openssl enc -d -aes-256-cbc -K "$key" -iv "$iv" -in "$tmp/body.bin" 2>/dev/null) \
  || { echo "openssl 解密失败（serverId 变过？）" >&2; exit 1; }

echo "username: $username"
echo "password: $password"

if [ "$VERIFY" = 1 ]; then
  echo "--- 验证登录 $BASE/api/auth/login ---"
  curl -sS -X POST "$BASE/api/auth/login" \
       -H 'Content-Type: application/json' \
       -d "{\"username\":\"$username\",\"password\":\"$password\"}" \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit("登录接口没有返回 JSON（服务没起来？）")
print("登录成功" if d.get("success") else "登录失败: %s" % d.get("message"))
'
fi
