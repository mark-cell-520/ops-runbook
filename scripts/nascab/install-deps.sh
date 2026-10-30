#!/bin/bash
# Install NasCabOS server dependencies for the headless (clientless) mode.
#
# Adaptations for this environment:
#   1. electron is a devDependency and `npm start` is `electron .` — we run
#      `node src/main_nascab_os.js` instead, which makes require('electron')
#      throw and puts the app in its built-in "Clientless service mode".
#   2. The root `postinstall` runs `npx @electron/rebuild`, which needs electron
#      present. It is removed so native modules keep their plain-Node ABI build
#      (correct for running under node, wrong only for electron).
#
# Run:  bash install-deps.sh
set -euo pipefail

SERVER=${NASCAB_SERVER:-/app/nascab/repo/electron_server}
LOG=${NPM_LOG:-/tmp/nascab-npm-install.log}
cd "$SERVER" || exit 1

# Node's global fetch ignores the http_proxy/https_proxy env vars by default;
# package postinstall scripts (onnxruntime-node downloads a ~100MB binary from
# github.com) need this to reach the network here.
export NODE_USE_ENV_PROXY=1

echo "[$(date +%T)] node $(node --version) / npm $(npm --version)"

# 备份紧挨着被改的文件放，别写死一个只在某台机器上存在的路径。
# package.json.orig 已被仓库 .gitignore 的 *.orig 规则覆盖，不会误提交。
cp -p package.json package.json.orig

echo "[$(date +%T)] removing electron-only postinstall hook"
npm pkg delete scripts.postinstall || echo "  (no postinstall to delete)"

echo "[$(date +%T)] npm ci --omit=dev (this takes a while)"
if ! npm ci --omit=dev --no-audit --no-fund >>"$LOG" 2>&1; then
  echo "[$(date +%T)] npm ci failed, falling back to npm install"
  npm install --omit=dev --no-audit --no-fund >>"$LOG" 2>&1 || {
    echo "[$(date +%T)] npm install ALSO failed — see $LOG"
    tail -30 "$LOG"
    exit 1
  }
fi

echo "[$(date +%T)] install finished"
echo "[$(date +%T)] electron present? $(ls -d node_modules/electron 2>/dev/null || echo 'no (expected: clientless mode)')"
du -sh node_modules
echo "[$(date +%T)] native modules:"
for m in better-sqlite3 bcrypt sharp node-pty onnxruntime-node node-datachannel nodejieba; do
  printf "  %-20s " "$m"
  ls -d "node_modules/$m" >/dev/null 2>&1 && echo OK || echo MISSING
done
echo "INSTALL_DONE"
