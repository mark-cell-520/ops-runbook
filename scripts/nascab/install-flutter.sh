#!/bin/bash
# Download + unpack the Flutter SDK used to build NasCabOS's web client.
#
# Why 3.38.10: flutter_client/pubspec.yaml declares `environment: sdk: ^3.10.1`,
# and 3.38.10 is the last stable whose bundled Dart is on the 3.10 line (3.10.9).
# Newer stable (3.47.x / Dart 3.13) can pull transitive deps the project's
# constraints never saw.
set -euo pipefail

URL=https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.38.10-stable.tar.xz
TARBALL=${FLUTTER_TARBALL:-/root/flutter-dl/flutter.tar.xz}
DEST=${FLUTTER_DEST:-/opt/flutter}
# 官方 sha256。设了 EXPECTED_SHA256 就强制校验，没设则只打印（见下）。
EXPECTED_SHA256=${EXPECTED_SHA256:-}

mkdir -p "$(dirname "$TARBALL")" "$DEST"

echo "[$(date +%T)] downloading $URL"
curl -fL --retry 3 --retry-delay 5 -o "$TARBALL.part" "$URL"
mv "$TARBALL.part" "$TARBALL"
echo "[$(date +%T)] downloaded $(du -h "$TARBALL" | cut -f1), sha256:"
ACTUAL=$(sha256sum "$TARBALL" | cut -d' ' -f1)
echo "  $ACTUAL"

if [ -n "$EXPECTED_SHA256" ]; then
  if [ "$ACTUAL" != "$EXPECTED_SHA256" ]; then
    echo "[$(date +%T)] SHA256 不匹配，拒绝继续："
    echo "  期望 $EXPECTED_SHA256"
    echo "  实际 $ACTUAL"
    rm -f "$TARBALL"
    exit 1
  fi
  echo "[$(date +%T)] sha256 校验通过"
else
  # 没提供期望值时不要静默跳过——提示使用者去核对，因为这一步装的是编译器，
  # 一个被动过手脚的 tarball 会在后续每一次构建里执行。
  echo "[$(date +%T)] 未设 EXPECTED_SHA256，跳过校验。请与官方 releases 页面核对上面这个值。" >&2
fi

echo "[$(date +%T)] extracting into $DEST (this takes a few minutes)"
tar -xJf "$TARBALL" -C "$DEST"
echo "[$(date +%T)] extracted. contents:"
ls "$DEST"
echo "[$(date +%T)] version check:"
"$DEST/flutter/bin/flutter" --version
echo "FLUTTER_INSTALL_DONE"
