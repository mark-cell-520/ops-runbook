#!/bin/bash
# Download NasCabOS release assets (libs + onnx models) into the electron_server dir.
set -uo pipefail
DEST=/app/nascab/repo/electron_server
cd "$DEST" || exit 1
for u in \
  "https://github.com/nascab/NasCabOS/releases/download/20260824/libs-linux.zip" \
  "https://github.com/nascab/NasCabOS/releases/download/20260824/onnx_models.zip" ; do
  f=$(basename "$u")
  echo "[$(date +%T)] downloading $f"
  curl -fL --retry 3 -o "$f" "$u" || { echo "[$(date +%T)] FAILED $f"; exit 1; }
  echo "[$(date +%T)] got $f ($(du -h "$f" | cut -f1))"
done
echo "[$(date +%T)] extracting"
unzip -q -o libs-linux.zip -d "$DEST" || { echo "unzip libs FAILED"; exit 1; }
unzip -q -o onnx_models.zip -d "$DEST" || { echo "unzip models FAILED"; exit 1; }
echo "[$(date +%T)] done"
ls -d "$DEST"/libs/* "$DEST"/onnx_models 2>/dev/null
