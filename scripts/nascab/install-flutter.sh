#!/bin/bash
# Download + unpack the Flutter SDK used to build NasCabOS's web client.
#
# Why 3.38.10: flutter_client/pubspec.yaml declares `environment: sdk: ^3.10.1`,
# and 3.38.10 is the last stable whose bundled Dart is on the 3.10 line (3.10.9).
# Newer stable (3.47.x / Dart 3.13) can pull transitive deps the project's
# constraints never saw.
set -euo pipefail

URL=https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.38.10-stable.tar.xz
TARBALL=/root/flutter-dl/flutter.tar.xz
DEST=/opt/flutter

echo "[$(date +%T)] downloading $URL"
curl -fL --retry 3 --retry-delay 5 -o "$TARBALL.part" "$URL"
mv "$TARBALL.part" "$TARBALL"
echo "[$(date +%T)] downloaded $(du -h "$TARBALL" | cut -f1), sha256:"
sha256sum "$TARBALL"

echo "[$(date +%T)] extracting into $DEST (this takes a few minutes)"
tar -xJf "$TARBALL" -C "$DEST"
echo "[$(date +%T)] extracted. contents:"
ls "$DEST"
echo "[$(date +%T)] version check:"
"$DEST/flutter/bin/flutter" --version
echo "FLUTTER_INSTALL_DONE"
