#!/usr/bin/env python3
"""Prepare the pinned, interpreter-only QuickJS source used by the iOS target."""
import hashlib
import io
from pathlib import Path
from urllib.request import urlopen
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1] / "ios"
URL = "https://github.com/quickjs-ng/quickjs/releases/download/v0.18.0/quickjs-amalgam.zip"
DIGEST = "6c05066a6b62b483e2ba0f83d7a16688c6958182b214bfd693529434cef84a9e"
NAMES = ("quickjs-amalgam.c", "quickjs.h")
DEST = ROOT / "Vendor" / "QuickJS"


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    archive = DEST / "quickjs.zip"
    data = archive.read_bytes() if archive.is_file() else b""
    if hashlib.sha256(data).hexdigest() != DIGEST:
        with urlopen(URL, timeout=60) as response:
            data = response.read(1_000_000)
        if hashlib.sha256(data).hexdigest() != DIGEST:
            raise SystemExit("QuickJS download SHA-256 mismatch")
        archive.write_bytes(data)
    with ZipFile(io.BytesIO(data)) as source:
        for name in NAMES:
            target = DEST / name
            contents = source.read(name)
            if not target.is_file() or target.read_bytes() != contents:
                target.write_bytes(contents)


if __name__ == "__main__":
    main()
