#!/usr/bin/env python3
"""Build a minimal ARM64 Linux guest kernel and a statically linked PTY agent."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request


KERNEL_VERSION = "6.18.60"
KERNEL_BASE_URL = "https://cdn.kernel.org/pub/linux/kernel/v6.x"
MAX_DOWNLOAD_BYTES = 256 * 1024 * 1024

SOURCES = {
    "linux-6.18.tar.xz": {
        "url": f"{KERNEL_BASE_URL}/linux-6.18.tar.xz",
        "sha512": "88599ffdec96d150c1feb9b261ba93bb0301a9d0e1ad6bef7aeab1f5372cbfc57d8b43c7e902bd8f76921d1dbd8189663c142ea869e51d0e2b483b150ee00fe0",
    },
    "patch-6.18.60.patch.xz": {
        "url": f"{KERNEL_BASE_URL}/patch-6.18.60.xz",
        "sha512": "fce959c563635d4374cba148b7f1b8b64a143e5b42bd8e86afee7dfdc76b9d887afb5a032249ac16518ee95e73b3c1a459f15926a035780493c5b3b9fbd3b51b",
    },
}

BUILTIN_OPTIONS = (
    "EXPERT",
    "BLOCK",
    "BLK_DEV",
    "VIRTIO_MENU",
    "TTY",
    "SHMEM",
    "BLK_DEV_INITRD",
    "RD_GZIP",
    "BINFMT_ELF",
    "BINFMT_SCRIPT",
    "VIRTIO_MMIO",
    "VIRTIO_BLK",
    "EXT4_FS",
    "UNIX98_PTYS",
    "SERIAL_AMBA_PL011",
    "SERIAL_AMBA_PL011_CONSOLE",
    "SERIAL_EARLYCON",
    "DEVTMPFS",
    "DEVTMPFS_MOUNT",
    "TMPFS",
    "PROC_FS",
    "SYSFS",
    "SMP",
)
DISABLED_OPTIONS = (
    "DEBUG_INFO",
    "DEBUG_INFO_BTF",
    "DEBUG_INFO_DWARF5",
    "GCC_PLUGIN_LATENT_ENTROPY",
    "MODULES",
)


def sha512_file(path: pathlib.Path) -> str:
    digest = hashlib.sha512()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_static_aarch64_elf(path: pathlib.Path) -> None:
    data = path.read_bytes()
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", data, 18)[0] != 183:
        raise SystemExit("Guest PTY agent is not a little-endian AArch64 ELF64 executable")
    program_offset = struct.unpack_from("<Q", data, 32)[0]
    program_entry_size = struct.unpack_from("<H", data, 54)[0]
    program_count = struct.unpack_from("<H", data, 56)[0]
    if program_entry_size < 4 or program_offset + program_entry_size * program_count > len(data):
        raise SystemExit("Guest PTY agent has an invalid ELF program header table")
    for index in range(program_count):
        entry = program_offset + index * program_entry_size
        if struct.unpack_from("<I", data, entry)[0] == 3:  # PT_INTERP
            raise SystemExit("Guest PTY agent must be statically linked for Alpine musl")


def download(name: str, spec: dict[str, str], cache: pathlib.Path) -> pathlib.Path:
    path = cache / name
    if path.is_file() and sha512_file(path) == spec["sha512"]:
        return path
    path.unlink(missing_ok=True)
    requested = urllib.parse.urlparse(spec["url"])
    allowed_hosts = {"cdn.kernel.org", "raw.githubusercontent.com"}
    if requested.scheme != "https" or requested.hostname not in allowed_hosts:
        raise RuntimeError(f"Refusing untrusted source URL for {name}")
    cache.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(spec["url"], headers={"User-Agent": "DSBot-ARM64-kernel-builder/1"})
    try:
        response_context = urllib.request.urlopen(request, timeout=60)
    except Exception as error:
        raise RuntimeError(f"Could not download pinned kernel input {name}: {error}") from error
    with response_context as response:
        final = urllib.parse.urlparse(response.geturl())
        if final.scheme != "https" or final.hostname not in allowed_hosts:
            raise RuntimeError(f"Refusing redirected source URL for {name}")
        fd, temporary_name = tempfile.mkstemp(prefix=f".{name}.", dir=cache)
        temporary = pathlib.Path(temporary_name)
        digest = hashlib.sha512()
        total = 0
        try:
            with os.fdopen(fd, "wb") as output:
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > MAX_DOWNLOAD_BYTES:
                        raise RuntimeError(f"{name} exceeded the {MAX_DOWNLOAD_BYTES} byte download limit")
                    digest.update(chunk)
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
            if digest.hexdigest() != spec["sha512"]:
                raise RuntimeError(f"SHA-512 mismatch for {name}")
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    return path


def run(command: list[str], *, cwd: pathlib.Path | None = None, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, env=env, check=True, text=True, stdout=subprocess.PIPE)
    return result.stdout.strip()


def apply_patch_file(source: pathlib.Path, patch_path: pathlib.Path, *, xz_compressed: bool = False) -> None:
    command = ["patch", "-p1", "--batch", "--fuzz=0"]
    if xz_compressed:
        decompressor = subprocess.Popen(["xz", "-dc", str(patch_path)], stdout=subprocess.PIPE)
        assert decompressor.stdout is not None
        try:
            subprocess.run(command, cwd=source, stdin=decompressor.stdout, check=True)
        finally:
            decompressor.stdout.close()
        if decompressor.wait() != 0:
            raise RuntimeError(f"Could not decompress pinned kernel patch {patch_path.name}")
        return
    with patch_path.open("rb") as patch_stream:
        subprocess.run(command, cwd=source, stdin=patch_stream, check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--cache", type=pathlib.Path, default=pathlib.Path.home() / ".cache" / "dsbot-arm64-kernel")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    output = args.output.resolve()
    cache = args.cache.resolve()
    output.mkdir(parents=True, exist_ok=True)
    downloaded = {name: download(name, spec, cache) for name, spec in SOURCES.items()}

    with tempfile.TemporaryDirectory(prefix="dsbot-arm64-kernel-") as temporary:
        work = pathlib.Path(temporary)
        source = work / f"linux-{KERNEL_VERSION}"
        source.mkdir()
        subprocess.run(
            ["tar", "-xJf", str(downloaded["linux-6.18.tar.xz"]), "--strip-components=1", "-C", str(source)],
            check=True,
        )
        apply_patch_file(source, downloaded["patch-6.18.60.patch.xz"], xz_compressed=True)
        build = work / "build"
        build.mkdir()
        cross = "aarch64-linux-gnu-"
        make_env = {
            **os.environ,
            "ARCH": "arm64",
            "CROSS_COMPILE": cross,
            "KBUILD_BUILD_USER": "dsbot",
            "KBUILD_BUILD_HOST": "guest-kernel-builder",
            "KBUILD_BUILD_TIMESTAMP": "2026-10-30 19:05:20 UTC",
            "KBUILD_BUILD_VERSION": "1-DSBot",
            "SOURCE_DATE_EPOCH": "1793387120",
        }
        make_base = ["make", "-C", str(source), f"O={build}", f"-j{max(1, args.jobs)}", "LOCALVERSION=-0-virt"]
        run([*make_base, "tinyconfig"], env=make_env)
        run(
            [
                str(source / "scripts" / "config"),
                "--file",
                str(build / ".config"),
                *[argument for option in BUILTIN_OPTIONS for argument in ("--enable", option)],
                *[argument for option in DISABLED_OPTIONS for argument in ("--disable", option)],
            ],
            cwd=source,
        )
        run([*make_base, "olddefconfig"], env=make_env)
        config_text = (build / ".config").read_text(encoding="utf-8")
        missing = [option for option in BUILTIN_OPTIONS if f"CONFIG_{option}=y" not in config_text]
        if missing:
            raise SystemExit(f"Required built-in kernel options were disabled by Kconfig: {', '.join(missing)}")
        subprocess.run([*make_base, "Image"], env=make_env, check=True)
        kernel = build / "arch" / "arm64" / "boot" / "Image"
        if not kernel.is_file():
            raise SystemExit("The ARM64 kernel Image was not produced")
        kernel_release = run([*make_base, "-s", "kernelrelease"], env=make_env)
        config_output = output / f"config-{kernel_release}"
        shutil.copyfile(build / ".config", config_output)
        agent_source = pathlib.Path(__file__).resolve().with_name("arm64-guest-pty-agent.c")
        agent_output = output / "dsbot-guest-pty-agent"
        agent_env = {**os.environ, "SOURCE_DATE_EPOCH": make_env["SOURCE_DATE_EPOCH"]}
        subprocess.run(
            [
                f"{cross}gcc",
                "-std=gnu11",
                "-Os",
                "-fstack-protector-strong",
                "-D_FORTIFY_SOURCE=2",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-static",
                "-s",
                "-Wl,--build-id=none",
                str(agent_source),
                "-lutil",
                "-o",
                str(agent_output),
            ],
            env=agent_env,
            check=True,
        )
        verify_static_aarch64_elf(agent_output)
        compressed = output / "vmlinuz-dsbot-arm64"
        with kernel.open("rb") as source_image, compressed.open("wb") as destination:
            with gzip.GzipFile(filename="", mode="wb", compresslevel=9, fileobj=destination, mtime=0) as zipped:
                shutil.copyfileobj(source_image, zipped)

        manifest = {
            "format": 1,
            "guestArchitecture": "aarch64",
            "kernelVersion": kernel_release,
            "baseConfig": "upstream arm64 tinyconfig",
            "guestUserland": "Alpine Linux 3.23.8 minirootfs",
            "distributionPatchSeriesApplied": False,
            "distributionPatchPolicy": (
                "Alpine's kernel package patches and broad virt config are not applied. The kernel uses upstream "
                "ARM64 tinyconfig plus only the built-in boot, virtio block, ext4, tmpfs, serial console, and PTY options "
                "required by this guest."
            ),
            "license": "GPL-2.0-only",
            "bootImage": {
                "filename": compressed.name,
                "bytes": compressed.stat().st_size,
                "sha256": sha256_file(compressed),
            },
            "config": {
                "filename": config_output.name,
                "bytes": config_output.stat().st_size,
                "sha256": sha256_file(config_output),
                "builtInOptions": list(BUILTIN_OPTIONS),
                "disabledOptions": list(DISABLED_OPTIONS),
            },
            "guestPtyAgent": {
                "filename": agent_output.name,
                "bytes": agent_output.stat().st_size,
                "sha256": sha256_file(agent_output),
                "sourceFilename": agent_source.name,
                "sourceSha256": sha256_file(agent_source),
                "license": "MIT",
                "protocolVersion": 1,
                "staticAarch64Elf": True,
            },
            "toolchain": {
                "compiler": run([f"{cross}gcc", "--version"]).splitlines()[0],
                "make": run(["make", "--version"]).splitlines()[0],
            },
            "configGenerator": "Linux kernel make tinyconfig plus scripts/config and olddefconfig",
            "sources": [
                {"filename": name, "url": SOURCES[name]["url"], "sha512": SOURCES[name]["sha512"]}
                for name in SOURCES
            ],
        }
        (output / "kernel-build-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        (output / "THIRD-PARTY-NOTICES.txt").write_text(
            "DS Bot ARM64 guest kernel\n"
            f"Linux {kernel_release}, GPL-2.0-only.\n"
            "Built from pinned kernel.org Linux 6.18.60 sources with upstream arm64 tinyconfig and a minimal recorded driver set.\n"
            "The guest userland is Alpine Linux; Alpine's kernel package patches and broad virt config are not applied.\n"
            "Source URLs and SHA-512 values are recorded in kernel-build-manifest.json.\n"
            "The bundled guest PTY agent is original DS Bot code under MIT; its source hash is recorded in the manifest.\n"
            "Build and configuration scripts are in the repository.\n"
        )
        checksums = []
        for path in sorted(output.iterdir()):
            if path.is_file() and path.name != "SHA256SUMS.txt":
                checksums.append(f"{sha256_file(path)}  {path.name}")
        (output / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n")
        print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ARM64 guest kernel build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
