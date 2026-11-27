#!/usr/bin/env python3
"""Stage a verified ARM64 guest image and QEMU frameworks for an iOS build."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def copy_tree(source: Path, destination: Path) -> None:
    if not source.is_dir():
        raise SystemExit(f"Required runtime directory is missing: {source}")
    shutil.copytree(source, destination, symlinks=True, dirs_exist_ok=True)


def copy_file(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise SystemExit(f"Required runtime file is missing: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def verify_qemu_artifact(artifact: Path, output_frameworks: Path, expected_platform: str) -> dict[str, object]:
    report = json.loads((artifact / "build-report.json").read_text(encoding="utf-8"))
    if report.get("platform") != expected_platform:
        raise SystemExit(f"QEMU artifact platform mismatch: expected {expected_platform}, got {report.get('platform')!r}")
    records = report.get("frameworks", [])
    for record in records:
        name = record.get("name")
        if not isinstance(name, str) or not name:
            raise SystemExit("QEMU build report contains a framework without a name")
        binary = output_frameworks / f"{name}.framework" / name
        if not binary.is_file() or sha256(binary) != record.get("sha256"):
            raise SystemExit(f"Staged framework does not match its build report: {expected_platform}/{name}")
    qemu_record = next((item for item in records if item.get("name") == "qemu-aarch64-softmmu"), None)
    required_symbols = {"qemu_init", "qemu_main_loop", "qemu_cleanup"}
    if not qemu_record or set(report.get("inProcessEntryPoints", {}).get("verified", [])) != required_symbols:
        raise SystemExit(f"QEMU artifact lacks the required in-process entry points: {expected_platform}")
    return {"report": report, "record": qemu_record}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qemu-artifact-device", type=Path, required=True)
    parser.add_argument("--qemu-artifact-simulator", type=Path, required=True)
    parser.add_argument("--guest-image", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    qemu_device = args.qemu_artifact_device.resolve()
    qemu_simulator = args.qemu_artifact_simulator.resolve()
    guest_image = args.guest_image.resolve()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        raise SystemExit(f"Refusing to stage into a non-empty runtime directory: {output}")
    output.mkdir(parents=True, exist_ok=True)

    guest_manifest_path = guest_image / "manifest.json"
    guest_manifest = json.loads(guest_manifest_path.read_text(encoding="utf-8"))
    device_frameworks = output / "Frameworks" / "iphoneos"
    simulator_frameworks = output / "Frameworks" / "iphonesimulator"
    copy_tree(qemu_device / "runtime" / "Frameworks", device_frameworks)
    copy_tree(qemu_simulator / "runtime" / "Frameworks", simulator_frameworks)
    device_record = verify_qemu_artifact(qemu_device, device_frameworks, "iOS device")
    simulator_record = verify_qemu_artifact(qemu_simulator, simulator_frameworks, "iOS Simulator")
    qemu_report = device_record["report"]
    simulator_report = simulator_record["report"]
    qemu_device_record = device_record["record"]
    qemu_simulator_record = simulator_record["record"]
    if qemu_report.get("source", {}).get("qemuSourceSha256") != simulator_report.get("source", {}).get("qemuSourceSha256"):
        raise SystemExit("Device and Simulator QEMU builds do not use the same pinned QEMU source archive")

    guest_output = output / "DSBotGuestRuntime"
    guest_output.mkdir(parents=True, exist_ok=True)
    for filename in ("vmlinuz-virt", "rootfs.cpio.gz", "manifest.json", "THIRD-PARTY-NOTICES.txt"):
        source = guest_image / filename
        copy_file(source, guest_output / filename)
    copy_file(qemu_device / "build-report.json", guest_output / "qemu-build-report.json")
    copy_file(qemu_simulator / "build-report.json", guest_output / "qemu-simulator-build-report.json")
    copy_file(qemu_device / "THIRD-PARTY-NOTICES.md", guest_output / "THIRD-PARTY-NOTICES-QEMU.md")

    expected_guest_files = guest_manifest.get("files", {})
    for filename in ("vmlinuz-virt", "rootfs.cpio.gz"):
        expected = expected_guest_files.get(filename, {}).get("sha256")
        actual = sha256(guest_output / filename)
        if not expected or actual != expected:
            raise SystemExit(f"Guest image checksum mismatch for {filename}: {actual}")

    qemu_device_binary = device_frameworks / "qemu-aarch64-softmmu.framework" / "qemu-aarch64-softmmu"
    qemu_simulator_binary = simulator_frameworks / "qemu-aarch64-softmmu.framework" / "qemu-aarch64-softmmu"
    if set(qemu_report.get("inProcessEntryPoints", {}).get("verified", [])) != {
        "qemu_init", "qemu_main_loop", "qemu_cleanup"
    }:
        raise SystemExit("QEMU build report is missing a required in-process entry point")

    manifest = {
        "schema": 1,
        "architecture": "arm64",
        "guestKernelVersion": guest_manifest.get("kernelVersion"),
        "guestFiles": {
            name: {"bytes": (guest_output / name).stat().st_size, "sha256": sha256(guest_output / name)}
            for name in ("vmlinuz-virt", "rootfs.cpio.gz")
        },
        "qemu": {
            "version": qemu_report.get("qemu", {}).get("version"),
            "guestTarget": qemu_report.get("qemu", {}).get("guestTarget"),
            "accelerator": qemu_report.get("qemu", {}).get("accelerator"),
            "framework": qemu_device_record.get("name"),
            "deviceSHA256": sha256(qemu_device_binary),
            "simulatorSHA256": sha256(qemu_simulator_binary),
            "frameworkPayloadBytes": qemu_report.get("sizes", {}).get("frameworkPayloadBytes"),
            "simulatorFrameworkPayloadBytes": simulator_report.get("sizes", {}).get("frameworkPayloadBytes"),
            "inProcessEntryPoints": sorted(qemu_report.get("inProcessEntryPoints", {}).get("verified", [])),
            "sourceArchiveSha256": qemu_report.get("source", {}).get("qemuSourceSha256"),
        },
    }
    (guest_output / "runtime-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps({
        "deviceFrameworks": sum(1 for path in device_frameworks.glob("*.framework")),
        "simulatorFrameworks": sum(1 for path in simulator_frameworks.glob("*.framework")),
        "frameworkPayloadBytes": manifest["qemu"]["frameworkPayloadBytes"],
        "guestBytes": sum(item["bytes"] for item in manifest["guestFiles"].values()),
        "output": str(output),
    }, indent=2))


if __name__ == "__main__":
    main()
