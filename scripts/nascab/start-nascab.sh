#!/bin/bash
# Start NasCabOS server in headless (clientless) mode.
#
# The upstream entry point is `electron .`; here require('electron') fails and
# main_nascab_os.js falls into its built-in "Clientless service mode", running
# only the backend. So we invoke the same file under plain node.
#
# The native modules (nodejieba / better-sqlite3 / sharp / node-pty / ...) are
# compiled against node v22's ABI, so anything else fails at require() time with
# a message that does not obviously point at the node version. Hence the check
# below — it is the single most common way this breaks after an upgrade.
#
# Note config/supervisord.conf pins an absolute node path rather than relying on
# PATH; that is deliberate (supervisord's environment is minimal), but it does
# mean the pin has to be updated when node moves. This script uses PATH's `node`
# by default; override with NODE_BIN to match the pin.
#
# Run:  bash start-nascab.sh
set -euo pipefail

SERVER=${NASCAB_SERVER:-/app/nascab/repo/electron_server}
NODE_BIN=${NODE_BIN:-node}
REQUIRED_MAJOR=${NODE_REQUIRED_MAJOR:-22}

cd "$SERVER" || exit 1

# Node's fetch ignores proxy env vars by default; the app reaches external
# services (metadata lookups etc.) at runtime too.
export NODE_USE_ENV_PROXY=1
export NODE_ENV=production

command -v "$NODE_BIN" >/dev/null 2>&1 || {
  echo "[$(date +%T)] 找不到 node: $NODE_BIN（设 NODE_BIN 覆盖）" >&2
  exit 1
}

NODE_VERSION=$("$NODE_BIN" --version 2>/dev/null) || {
  echo "[$(date +%T)] $NODE_BIN --version 失败" >&2
  exit 1
}
NODE_MAJOR=${NODE_VERSION#v}
NODE_MAJOR=${NODE_MAJOR%%.*}
if [ "$NODE_MAJOR" != "$REQUIRED_MAJOR" ]; then
  echo "[$(date +%T)] node 版本不对：$NODE_VERSION，需要 v${REQUIRED_MAJOR}.x" >&2
  echo "  原生模块（nodejieba/better-sqlite3/sharp/node-pty）是按 v22 的 ABI 编的，" >&2
  echo "  用别的版本会在 require 时加载失败。" >&2
  exit 1
fi

echo "[$(date +%T)] starting NasCabOS server (clientless mode) pid=$$"
echo "[$(date +%T)] cwd=$(pwd) node=$NODE_VERSION ($NODE_BIN)"
exec "$NODE_BIN" src/main_nascab_os.js
