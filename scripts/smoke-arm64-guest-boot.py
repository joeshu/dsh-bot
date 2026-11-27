#!/usr/bin/env python3
"""Boot the pinned ARM64 guest to its serial shell using host QEMU TCG."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import time
from pathlib import Path


BOOT_MARKER = b"DS Bot ARM64 Linux guest"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--guest-dir", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()

    guest_dir = args.guest_dir.resolve()
    qemu = shutil.which("qemu-system-aarch64")
    if not qemu:
        raise SystemExit("qemu-system-aarch64 is not installed")
    for name in ("vmlinuz-virt", "rootfs.cpio.gz"):
        if not (guest_dir / name).is_file():
            raise SystemExit(f"Guest boot input is missing: {guest_dir / name}")

    serial_log = guest_dir / "serial-smoke.log"
    serial_log.unlink(missing_ok=True)
    command = [
        qemu,
        "-machine", "virt,gic-version=2",
        "-cpu", "max",
        "-m", "512M",
        "-smp", "2",
        "-accel", "tcg,thread=single",
        "-kernel", str(guest_dir / "vmlinuz-virt"),
        "-initrd", str(guest_dir / "rootfs.cpio.gz"),
        "-append", "console=ttyAMA0,115200 rdinit=/init panic=10",
        "-display", "none",
        "-monitor", "none",
        "-serial", f"file:{serial_log}",
        "-no-reboot",
    ]
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + max(1, args.timeout)
    booted = False
    try:
        while time.monotonic() < deadline:
            if serial_log.is_file() and BOOT_MARKER in serial_log.read_bytes():
                booted = True
                break
            if process.poll() is not None:
                break
            time.sleep(0.25)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    output = serial_log.read_bytes() if serial_log.is_file() else b""
    print(output[-8192:].decode("utf-8", "replace"), end="")
    if not booted:
        raise SystemExit(f"ARM64 guest did not reach its serial shell marker within {args.timeout}s")
    print("ARM64 guest reached the serial shell boot marker.")


if __name__ == "__main__":
    main()
