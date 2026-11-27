#!/usr/bin/env python3
"""Create a small, reproducible Alpine ARM64 serial-shell guest image.

This is a guest-image build step only. It does not embed a hypervisor or make
the iOS app claim to support a Linux terminal; the app still needs a native
QEMU SE backend and an authenticated PTY bridge before these images are used.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import pathlib
import shutil
import stat
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request


ALPINE_VERSION = "3.23.8"
KERNEL_VERSION = "6.18.60-0-virt"
KERNEL_APORTS_COMMIT = "942251c9a4cb77b6d34ecbce4c293f96abfecce5"
BASE_URL = "https://dl-cdn.alpinelinux.org/alpine"
ARTIFACTS = {
    "minirootfs": {
        "filename": f"alpine-minirootfs-{ALPINE_VERSION}-aarch64.tar.gz",
        "url": f"{BASE_URL}/v3.23/releases/aarch64/alpine-minirootfs-{ALPINE_VERSION}-aarch64.tar.gz",
        "sha256": "3f1bd6811370264cc363bb991ff15ac67621b239ea6e25ff2eb22af3d0641473",
        "maxBytes": 16 * 1024 * 1024,
    },
    "kernel": {
        "filename": "vmlinuz-virt",
        "url": f"{BASE_URL}/v3.23/releases/aarch64/netboot/vmlinuz-virt",
        "sha256": "4ac63d06e6cf5820905ffa7741292cfbe90fb0cf1edba4c42e871f6daf699437",
        "maxBytes": 32 * 1024 * 1024,
    },
    "kernelConfig": {
        "filename": "config-6.18.60-0-virt",
        "url": f"{BASE_URL}/v3.23/releases/aarch64/netboot/config-{KERNEL_VERSION}",
        "sha256": "b0e46b4fbde5e9972148d6e675123654241268c7391e20738fda03634112fa94",
        "maxBytes": 2 * 1024 * 1024,
    },
}

INIT = b"""#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=${TERM:-vt100}
export PS1='dsbot# '
mkdir -p /proc /sys /dev /dev/pts /run /tmp /root
mount -t proc -o nosuid,nodev,noexec proc /proc 2>/dev/null || true
mount -t sysfs -o nosuid,nodev,noexec sysfs /sys 2>/dev/null || true
mount -t devtmpfs -o nosuid devtmpfs /dev 2>/dev/null || true
mount -t devpts -o nosuid,noexec,mode=0620 devpts /dev/pts 2>/dev/null || true
chmod 1777 /tmp
echo dsbot-arm64 > /proc/sys/kernel/hostname 2>/dev/null || true
echo 'DS Bot ARM64 Linux guest (Alpine Linux, BusyBox ash).'
echo 'Network is disabled. The root filesystem is volatile in this image build.'
echo 'Type exit to close the guest shell.'
exec /bin/ash -i
"""


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_artifact(name: str, cache_dir: pathlib.Path) -> pathlib.Path:
    spec = ARTIFACTS[name]
    path = cache_dir / spec["filename"]
    if path.is_file() and sha256_file(path) == spec["sha256"]:
        return path
    path.unlink(missing_ok=True)
    parsed = urllib.parse.urlparse(spec["url"])
    if parsed.scheme != "https" or parsed.hostname != "dl-cdn.alpinelinux.org":
        raise RuntimeError(f"Refusing untrusted upstream URL for {name}")
    request = urllib.request.Request(
        spec["url"], headers={"User-Agent": "DSBot-ARM64-guest-builder/1"}
    )
    cache_dir.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(request, timeout=45) as response:
        final = urllib.parse.urlparse(response.geturl())
        if final.scheme != "https" or final.hostname != parsed.hostname:
            raise RuntimeError(f"Refusing redirected upstream URL for {name}")
        fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=cache_dir)
        temporary = pathlib.Path(temporary_name)
        digest = hashlib.sha256()
        total = 0
        try:
            with os.fdopen(fd, "wb") as output:
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > spec["maxBytes"]:
                        raise RuntimeError(f"{name} exceeded its {spec['maxBytes']} byte download limit")
                    digest.update(chunk)
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
            actual = digest.hexdigest()
            if actual != spec["sha256"]:
                raise RuntimeError(
                    f"{name} SHA-256 mismatch: expected {spec['sha256']}, got {actual}"
                )
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    return path


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


def cpio_newc(entries: list[tuple[str, int, bytes]]) -> bytes:
    output = bytearray()

    def align4() -> None:
        output.extend(b"\0" * ((-len(output)) & 3))

    for inode, (name, mode, data) in enumerate(entries, start=1):
        encoded_name = name.encode("utf-8") + b"\0"
        fields = (
            inode,
            mode,
            0,  # root uid
            0,  # root gid
            2 if stat.S_ISDIR(mode) else 1,
            0,  # fixed mtime keeps the initramfs reproducible
            len(data),
            0,
            0,
            0,
            0,
            len(encoded_name),
            0,
        )
        output.extend(b"070701")
        output.extend(b"".join(f"{value:08x}".encode("ascii") for value in fields))
        output.extend(encoded_name)
        align4()
        output.extend(data)
        align4()

    trailer = "TRAILER!!!"
    encoded_name = trailer.encode("ascii") + b"\0"
    fields = (0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(encoded_name), 0)
    output.extend(b"070701")
    output.extend(b"".join(f"{value:08x}".encode("ascii") for value in fields))
    output.extend(encoded_name)
    align4()
    return bytes(output)


def rootfs_entries(minirootfs: pathlib.Path) -> tuple[list[tuple[str, int, bytes]], list[dict[str, str]]]:
    items: dict[str, tuple[int, bytes]] = {}
    with tarfile.open(minirootfs, mode="r:gz") as archive:
        members = archive.getmembers()
        if len(members) > 20_000:
            raise RuntimeError("Alpine root archive has an unreasonable number of entries")
        by_name = {safe_archive_path(member.name): member for member in members}
        total_uncompressed = 0
        for member in members:
            name = safe_archive_path(member.name)
            if not name:
                continue
            # /dev is recreated by devtmpfs at boot; avoid shipping archive nodes.
            if name == "dev" or name.startswith("dev/"):
                continue
            if name == "var/cache/apk" or name.startswith("var/cache/apk/"):
                continue
            if member.isdir():
                mode, data = stat.S_IFDIR | (member.mode & 0o7777), b""
            elif member.issym():
                link = member.linkname
                if "\0" in link:
                    raise RuntimeError(f"Invalid symlink in Alpine root archive: {name}")
                mode, data = stat.S_IFLNK | (member.mode & 0o7777), link.encode("utf-8")
            elif member.isfile() or member.islnk():
                source = member
                if member.islnk():
                    target = safe_archive_path(member.linkname)
                    source = by_name.get(target)
                    if source is None or not source.isfile():
                        raise RuntimeError(f"Unresolved hard link in Alpine root archive: {name}")
                stream = archive.extractfile(source)
                if stream is None:
                    raise RuntimeError(f"Could not read Alpine root file: {name}")
                data = stream.read()
                total_uncompressed += len(data)
                if total_uncompressed > 64 * 1024 * 1024:
                    raise RuntimeError("Alpine root archive exceeds the 64 MiB expanded-file limit")
                if member.issym() or member.islnk():
                    mode = stat.S_IFREG | (source.mode & 0o7777)
                else:
                    mode = stat.S_IFREG | (member.mode & 0o7777)
            else:
                raise RuntimeError(f"Unsupported file type in Alpine root archive: {name}")
            items[name] = (mode, data)

    items["init"] = (stat.S_IFREG | 0o755, INIT)
    for directory in ("dev", "dev/pts", "proc", "sys", "run", "tmp", "root"):
        items[directory] = (stat.S_IFDIR | (0o1777 if directory == "tmp" else 0o755), b"")
    entries = [(name, mode, data) for name, (mode, data) in sorted(items.items())]
    packages: list[dict[str, str]] = []
    installed = items.get("lib/apk/db/installed")
    if installed:
        current: dict[str, str] = {}
        for line in installed[1].decode("utf-8", "replace").splitlines():
            if not line:
                if current.get("P"):
                    packages.append(current)
                current = {}
            elif len(line) > 2 and line[1] == ":":
                current[line[0]] = line[2:]
        if current.get("P"):
            packages.append(current)
    for package in packages:
        source = package.get("U", "")
        commit = package.get("c", "")
        if source and commit:
            package["sourceCommit"] = commit
            package["upstreamHomepage"] = source
            package["sourceURL"] = (
                "https://gitlab.alpinelinux.org/alpine/aports/"
                f"-/archive/{commit}/aports-{commit}.tar.gz"
            )
            package["sourceCommitURL"] = (
                f"https://gitlab.alpinelinux.org/alpine/aports/-/commit/{commit}"
            )
    return entries, packages


def write_guest(
    rootfs: pathlib.Path, kernel: pathlib.Path, kernel_config: pathlib.Path, output: pathlib.Path
) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    kernel_output = output / "vmlinuz-virt"
    config_output = output / f"config-{KERNEL_VERSION}"
    rootfs_output = output / "rootfs.cpio.gz"
    shutil.copyfile(kernel, kernel_output)
    shutil.copyfile(kernel_config, config_output)
    entries, packages = rootfs_entries(rootfs)
    cpio = cpio_newc(entries)
    with rootfs_output.open("wb") as stream:
        with gzip.GzipFile(filename="", mode="wb", compresslevel=9, fileobj=stream, mtime=0) as zipped:
            zipped.write(cpio)
    manifest: dict[str, object] = {
        "format": 1,
        "guestArchitecture": "aarch64",
        "distribution": "Alpine Linux",
        "alpineVersion": ALPINE_VERSION,
        "kernelVersion": KERNEL_VERSION,
        "kernelLicense": "GPL-2.0-only",
        "kernelSource": {
            "alpineAportsCommit": KERNEL_APORTS_COMMIT,
            "sourceArchive": (
                "https://gitlab.alpinelinux.org/alpine/aports/"
                f"-/archive/{KERNEL_APORTS_COMMIT}/aports-{KERNEL_APORTS_COMMIT}.tar.gz"
            ),
        },
        "boot": {
            "machine": "virt",
            "cpu": "max",
            "memoryMiB": 512,
            "network": "disabled",
            "kernelArguments": "console=ttyAMA0,115200 rdinit=/init panic=10",
            "serial": "PL011 UART, 115200 8N1",
        },
        "scope": "serial shell bootstrap image; no persistent block disk or QEMU runtime",
        "upstream": {
            name: {
                "url": spec["url"],
                "sha256": spec["sha256"],
            }
            for name, spec in ARTIFACTS.items()
        },
        "files": {
            kernel_output.name: {
                "bytes": kernel_output.stat().st_size,
                "sha256": sha256_file(kernel_output),
            },
            config_output.name: {
                "bytes": config_output.stat().st_size,
                "sha256": sha256_file(config_output),
            },
            rootfs_output.name: {
                "bytes": rootfs_output.stat().st_size,
                "sha256": sha256_file(rootfs_output),
            },
        },
        "initramfsEntryCount": len(entries),
        "basePackages": [
            {"name": package.get("P", ""), "version": package.get("V", ""), "license": package.get("L", "")}
            for package in packages
        ],
        "notices": "Alpine Linux packages are identified in basePackages; source is Alpine v3.23.8 minirootfs.",
    }
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    notice_lines = [
        "DS Bot ARM64 guest bootstrap image — third-party notices",
        "",
        f"Alpine Linux {ALPINE_VERSION} aarch64 minirootfs and Linux kernel {KERNEL_VERSION}.",
        "Upstream files are pinned by SHA-256 in manifest.json.",
        "Package metadata below comes from the installed-package database inside the SHA-256-pinned minirootfs.",
        "sourceURL points to the package's exact Alpine aports commit archive; its APKBUILD records upstream source URLs and hashes.",
        "The kernel is GPL-2.0-only; its pinned Alpine packaging source archive is listed in manifest.json.",
        "",
        "Package | Version | SPDX license | Alpine aports source archive",
    ]
    for package in packages:
        notice_lines.append(
            " | ".join(
                (
                    package.get("P", ""),
                    package.get("V", ""),
                    package.get("L", "unknown"),
                    package.get("sourceURL", package.get("U", "source URL unavailable")),
                )
            )
        )
    (output / "THIRD-PARTY-NOTICES.txt").write_text(
        "\n".join(notice_lines) + "\n", encoding="utf-8"
    )
    checksum_files = sorted(
        path
        for path in output.iterdir()
        if path.is_file() and path.name != "SHA256SUMS.txt"
    )
    (output / "SHA256SUMS.txt").write_text(
        "".join(f"{sha256_file(path)}  {path.name}\n" for path in checksum_files),
        encoding="ascii",
    )
    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True, help="Directory for the guest image files")
    parser.add_argument(
        "--cache",
        type=pathlib.Path,
        default=pathlib.Path.home() / ".cache" / "dsbot-arm64-guest",
        help="Upstream download cache",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    cache = args.cache.resolve()
    output = args.output.resolve()
    minirootfs = download_artifact("minirootfs", cache)
    kernel = download_artifact("kernel", cache)
    kernel_config = download_artifact("kernelConfig", cache)
    manifest = write_guest(minirootfs, kernel, kernel_config, output)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ARM64 guest build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
