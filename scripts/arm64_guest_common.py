"""Shared pinned-source and safe-path helpers for ARM64 guest artifacts."""

from __future__ import annotations

import hashlib
import pathlib


ALPINE_VERSION = "3.23.8"
BASE_URL = "https://dl-cdn.alpinelinux.org/alpine"
MINIROOTFS_ARTIFACT = {
    "filename": f"alpine-minirootfs-{ALPINE_VERSION}-aarch64.tar.gz",
    "url": f"{BASE_URL}/v3.23/releases/aarch64/alpine-minirootfs-{ALPINE_VERSION}-aarch64.tar.gz",
    "sha256": "3f1bd6811370264cc363bb991ff15ac67621b239ea6e25ff2eb22af3d0641473",
    "maxBytes": 16 * 1024 * 1024,
}


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_archive_path(name: str) -> str:
    normalized = name.replace("\\", "/")
    if normalized.startswith("/"):
        raise RuntimeError(f"Absolute path in Alpine root archive: {name!r}")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    normalized = normalized.rstrip("/")
    if not normalized:
        return ""
    parts = pathlib.PurePosixPath(normalized).parts
    if any(part in ("", ".", "..") for part in parts):
        raise RuntimeError(f"Unsafe path in Alpine root archive: {name!r}")
    return "/".join(parts)
