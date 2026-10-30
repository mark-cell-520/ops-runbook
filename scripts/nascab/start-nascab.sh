#!/bin/bash
# Start NasCabOS server in headless (clientless) mode.
#
# The upstream entry point is `electron .`; here require('electron') fails and
# main_nascab_os.js falls into its built-in "Clientless service mode", running
# only the backend. So we invoke the same file under plain node.
#
# Run:  bash /root/nascab-scripts/start-nascab.sh
set -uo pipefail

SERVER=/app/nascab/repo/electron_server
cd "$SERVER" || exit 1

# Node's fetch ignores proxy env vars by default; the app reaches external
# services (metadata lookups etc.) at runtime too.
export NODE_USE_ENV_PROXY=1
export NODE_ENV=production

echo "[$(date +%T)] starting NasCabOS server (clientless mode) pid=$$"
echo "[$(date +%T)] cwd=$(pwd) node=$(node --version)"
exec node src/main_nascab_os.js
