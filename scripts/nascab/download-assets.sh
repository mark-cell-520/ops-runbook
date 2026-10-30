#!/bin/bash
# Download NasCabOS release assets (libs + onnx models) into the electron_server dir,
# then unpack them.
#
# Unpacking is delegated to extract-assets.py in this same directory. Do NOT add a
# `unzip -o` here as well — that is how this file used to work, and it meant the
# zips got unpacked twice, by two different tools, with different behaviour:
# `unzip` drops the executable bit on the ELF files under libs/ and leaves the
# `libs-linux/` prefix in place, so libsPath could not find ffmpeg/ffprobe.
#
# Run:  bash download-assets.sh
set -euo pipefail

SERVER=${NASCAB_SERVER:-/app/nascab/repo/electron_server}
HERE=$(cd "$(dirname "$0")" && pwd)

cd "$SERVER" || exit 1

for u in \
  "https://github.com/nascab/NasCabOS/releases/download/20260824/libs-linux.zip" \
  "https://github.com/nascab/NasCabOS/releases/download/20260824/onnx_models.zip" ; do
  f=$(basename "$u")
  echo "[$(date +%T)] downloading $f"
  curl -fL --retry 3 -o "$f" "$u" || { echo "[$(date +%T)] FAILED $f"; exit 1; }
  echo "[$(date +%T)] got $f ($(du -h "$f" | cut -f1))"
done

echo "[$(date +%T)] extracting"
python3 -I "$HERE/extract-assets.py" "$SERVER" || {
  echo "[$(date +%T)] extract-assets.py FAILED"; exit 1; }
echo "[$(date +%T)] done"
ls -d "$SERVER"/libs/* "$SERVER"/onnx_models 2>/dev/null
