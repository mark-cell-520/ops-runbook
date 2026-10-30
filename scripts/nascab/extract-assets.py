#!/usr/bin/env python3
"""Extract NasCabOS release zips into electron_server.

Usage:
    python3 extract-assets.py [DEST]

Why Python instead of `unzip`: `unzip` IS available on this box (/usr/bin/unzip,
6.00) and would unpack these in one command. It is not used because it does not
do three things that are required here:

1. **Zip-slip protection**: release entries carry a `libs-linux/` prefix, and if
   upstream ever ships an entry containing `../` or an absolute path, `unzip -o`
   will quietly write it outside DEST. Every entry is resolved and re-checked to
   still be inside DEST, else that entry is refused.
2. **Restore the executable bit**: GitHub Releases strips permissions when it
   builds the zip, so the ELF files under `libs/` (ffmpeg, ffprobe, ...) come out
   0644 and cannot run. `unzip -X` recovers this on some builds but not
   reliably, so ELF payloads are explicitly chmod'ed 0755 after extraction.
3. **Flatten the `libs-linux/` prefix**: entries are `libs-linux/ffmpeg`, which
   would leave an extra directory level, while libsPath looks for `libs/ffmpeg`.
   The first path component is mapped away here.

Run:  python3 extract-assets.py
"""
import os
import stat
import sys
import time
import zipfile
from pathlib import Path

DEFAULT_DEST = Path("/app/nascab/repo/electron_server")
ZIPS = ("libs-linux.zip", "onnx_models.zip")

# top-level prefix inside the zip -> the subdirectory it should land in under DEST
FLATTEN = {"libs-linux": "libs"}


def elf_magic(path: Path) -> bool:
    """True when the file starts with the ELF magic bytes."""
    try:
        with path.open("rb") as fh:
            return fh.read(4) == b"\x7fELF"
    except OSError:
        return False


def resolve_target(dest: Path, name: str) -> Path | None:
    """Map a zip entry to its on-disk path, or None if it escapes DEST.

    Guards against zip-slip (`../`) and absolute paths inside the archive.
    """
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if not parts:
        return None
    if parts[0] in FLATTEN:
        parts = [FLATTEN[parts[0]]] + parts[1:]
    if any(p == ".." for p in parts):
        return None
    target = (dest / Path(*parts)).resolve()
    # resolve() on a not-yet-existing file still resolves its parent, so this
    # comparison holds for new files too.
    if target != dest and dest not in target.parents:
        return None
    return target


def extract_one(dest: Path, name: str) -> int:
    archive = dest / name
    if not archive.is_file():
        print(f"MISSING {archive}", flush=True)
        return 1
    started = time.time()
    chmodded = []
    with zipfile.ZipFile(archive) as zf:
        bad = zf.testzip()
        if bad:
            print(f"CORRUPT entry in {name}: {bad}", flush=True)
            return 1
        count = 0
        for info in zf.infolist():
            target = resolve_target(dest, info.filename)
            if target is None:
                print(f"REFUSED (escapes DEST): {info.filename}", flush=True)
                return 1
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, target.open("wb") as out:
                while chunk := src.read(1 << 20):
                    out.write(chunk)
            # Releases strip the executable bit; restore it for ELF payloads.
            mode = info.external_attr >> 16
            if mode & 0o111 or elf_magic(target):
                target.chmod(0o755)
                chmodded.append(str(target.relative_to(dest)))
            count += 1
    print(
        f"[{time.time() - started:6.1f}s] {name}: {count} entries -> {dest}",
        flush=True,
    )
    if chmodded:
        print(f"  chmod 0755 on {len(chmodded)} ELF file(s)", flush=True)
    return 0


def main() -> int:
    dest = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DEST
    dest = dest.resolve()
    if not dest.is_dir():
        print(f"DEST does not exist or is not a directory: {dest}", flush=True)
        return 1
    print(f"DEST={dest}", flush=True)
    for name in ZIPS:
        rc = extract_one(dest, name)
        if rc:
            return rc
    print("EXTRACT OK", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
