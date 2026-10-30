#!/usr/bin/env python3
"""Extract NasCabOS release zips into electron_server.

`unzip` is not installed in this container, so use the stdlib zipfile module.
Run:  python3 /root/nascab-scripts/extract-assets.py
"""
import sys
import time
import zipfile
from pathlib import Path

DEST = Path("/app/nascab/repo/electron_server")
ZIPS = ("libs-linux.zip", "onnx_models.zip")


def main() -> int:
    for name in ZIPS:
        archive = DEST / name
        if not archive.is_file():
            print(f"MISSING {archive}", flush=True)
            return 1
        started = time.time()
        with zipfile.ZipFile(archive) as zf:
            bad = zf.testzip()
            if bad:
                print(f"CORRUPT entry in {name}: {bad}", flush=True)
                return 1
            count = len(zf.namelist())
            zf.extractall(DEST)
        print(f"[{time.time() - started:6.1f}s] {name}: {count} entries -> {DEST}", flush=True)
    print("EXTRACT OK", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
