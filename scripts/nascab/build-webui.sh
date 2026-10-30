#!/bin/bash
# Build the NasCabOS Flutter web client into electron_server/web/main.
#
# Why this exists: upstream ships only `electron .` (desktop). The server does
# serve `web/main` at `/` (src/api/app.js), but the repo has no prebuilt web
# client, so a headless install has no UI until this runs.
#
# Subpath adaptation: built with --base-href /nascab/ so it can live behind
# nginx at https://<your-host>:<port>/nascab. lib/core/api/api_controller.dart
# is patched so the API base URL carries the same prefix (upstream takes origin only,
# which would send /api/... to whatever else nginx serves at /).
#
# Memory: this container has a 4GiB cgroup cap (memory.max). Without
# --no-wasm-dry-run, flutter runs a *concurrent* dart2wasm compile alongside the
# dart2js one (~1.5GB on top of ~1.3GB), the OOM killer SIGKILLs dart2js
# ("Process exited abnormally with exit code -9"), main.dart.js is never emitted,
# and /nascab/ then hangs forever on the Flutter loading state. We only ship the
# dart2js output (flutter_bootstrap.js pins compileTarget dart2js), so the dry run
# is pure overhead here.
#
# Run:  bash /root/nascab-scripts/build-webui.sh
set -uo pipefail

FLUTTER=/opt/flutter/flutter/bin/flutter
CLIENT=/app/nascab/repo/flutter_client
SERVER=/app/nascab/repo/electron_server
OUT=$SERVER/web/main
LOG=/root/flutter-dl/build.log

export FLUTTER_SUPPRESS_ANALYTICS=true
export NODE_USE_ENV_PROXY=1          # flutter's pub uses dart:io HttpClient, but be explicit

cd "$CLIENT" || exit 1

echo "[$(date +%T)] flutter --version"
"$FLUTTER" --version 2>&1 | tail -5

echo "[$(date +%T)] flutter pub get"
if ! "$FLUTTER" pub get >>"$LOG" 2>&1; then
  echo "[$(date +%T)] pub get FAILED — tail of $LOG:"
  tail -40 "$LOG"
  exit 1
fi
echo "[$(date +%T)] pub get ok"

echo "[$(date +%T)] flutter build web --release --base-href /nascab/ --no-wasm-dry-run"
if ! "$FLUTTER" build web --release --base-href /nascab/ --no-wasm-dry-run >>"$LOG" 2>&1; then
  echo "[$(date +%T)] build FAILED — tail of $LOG:"
  tail -60 "$LOG"
  exit 1
fi
echo "[$(date +%T)] build ok"

echo "[$(date +%T)] publishing to $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$CLIENT/build/web/." "$OUT/"
echo "[$(date +%T)] published:"
ls -la "$OUT"
du -sh "$OUT"
echo "WEBUI_BUILD_DONE"
