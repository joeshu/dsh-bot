#!/usr/bin/env python3
"""Stage and audit the separate ARM64 iOS TCI/QEMU CI artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path


QEMU_TARBALL_SHA256 = "7c9605290b34152debb842e965a55d2e4fbba4793e536ab677b4027e5dc0ba1a"
LIBUCONTEXT_COMMIT = "9b1d8f01a6e99166f9808c79966abe10786de8b6"
UTM_COMMIT = "3d4b8d8cb1ce93a8b1a9610695c12487685f0c15"
LICENSES = {
    "qemu": "GPL-2.0-or-later",
    "glib": "LGPL-2.1-or-later",
    "ffi": "MIT",
    "iconv": "LGPL-2.1-or-later",
    "pixman": "MIT",
    "slirp": "BSD-3-Clause",
    "libucontext": "ISC",
    "pcre2": "BSD-3-Clause",
}


def run(command: list[str], *, capture: bool = True) -> str:
    result = subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    return result.stdout.strip() if capture else ""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(relative + b"\0")
        if path.is_symlink():
            digest.update(b"link\0" + os.readlink(path).encode("utf-8"))
        elif path.is_file():
            digest.update(b"file\0")
            with path.open("rb") as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
        elif path.is_dir():
            digest.update(b"dir\0")
    return digest.hexdigest()


def copy_file(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise SystemExit(f"Required build input is missing: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def regular_file_bytes(root: Path) -> int:
    return sum(path.stat().st_size for path in root.rglob("*") if path.is_file() and not path.is_symlink())


def parse_source_lock(lock_path: Path) -> list[tuple[str, str]]:
    sources: list[tuple[str, str]] = []
    for line in lock_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        digest, filename = line.split()
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise SystemExit(f"Invalid SHA-256 entry for {filename}")
        sources.append((filename, digest))
    return sources


def meson_options(qemu_dir: Path) -> dict[str, object]:
    path = qemu_dir / "meson-info" / "intro-buildoptions.json"
    if not path.is_file():
        raise SystemExit(f"QEMU Meson build options are missing: {path}")
    return {item["name"]: item.get("value") for item in json.loads(path.read_text())}


def find_tcg_config(qemu_dir: Path) -> Path:
    candidates = list(qemu_dir.rglob("config-host.h"))
    for candidate in candidates:
        contents = candidate.read_text(errors="ignore")
        if "CONFIG_TCG_THREADED_INTERPRETER" in contents:
            return candidate
    raise SystemExit("Could not find QEMU's generated host TCI configuration")


def find_framework_binary(framework: Path) -> Path:
    expected = framework / framework.stem
    if expected.is_file():
        return expected
    matches = [path for path in framework.rglob("*") if path.is_file() and path.name == framework.stem]
    if len(matches) != 1:
        raise SystemExit(f"Could not identify one binary in {framework}")
    return matches[0]


def framework_license(name: str) -> str:
    lowered = name.lower()
    if "qemu" in lowered:
        return LICENSES["qemu"]
    if lowered.startswith(("glib-", "gobject-", "gio-", "gmodule-", "gthread-")):
        return LICENSES["glib"]
    for component in ("ffi", "iconv", "pixman", "slirp", "pcre2"):
        if component in lowered:
            return LICENSES[component]
    raise SystemExit(f"No reviewed license mapping exists for framework {name}")


def dynamic_dependencies(binary: Path, frameworks: Path) -> list[str]:
    output = run(["otool", "-L", str(binary)])
    dependencies = []
    for line in output.splitlines()[1:]:
        dependency = line.strip().split(" (compatibility version", 1)[0]
        if not dependency:
            continue
        if dependency.startswith(("/usr/lib/", "/System/Library/")):
            dependencies.append(dependency)
            continue
        if dependency.startswith("@rpath/"):
            resolved = frameworks / dependency.removeprefix("@rpath/")
        elif dependency.startswith("@loader_path/"):
            resolved = binary.parent / dependency.removeprefix("@loader_path/")
        else:
            raise SystemExit(f"Unreviewed dynamic load path in {binary}: {dependency}")
        if not resolved.exists():
            raise SystemExit(f"Unresolved framework dependency in {binary}: {dependency}")
        dependencies.append(dependency)
    return dependencies


def stage_sources(
    *,
    repo: Path,
    upstream: Path,
    build_dir: Path,
    qemu_dir: Path,
    output: Path,
    lock_path: Path,
) -> dict[str, object]:
    source_root = output / "source"
    archives = source_root / "archives"
    patches = source_root / "utm-patches"
    archives.mkdir(parents=True, exist_ok=True)
    patches.mkdir(parents=True, exist_ok=True)

    source_records = []
    for filename, expected in parse_source_lock(lock_path):
        source_archive = build_dir / filename
        if not source_archive.is_file():
            raise SystemExit(f"Pinned source archive missing from build cache: {filename}")
        actual = sha256(source_archive)
        if actual != expected:
            raise SystemExit(f"Source checksum mismatch for {filename}: {actual}")
        copy_file(source_archive, archives / filename)
        source_records.append({"filename": filename, "sha256": actual})

    copy_file(lock_path, source_root / "qemu-ios-tci-sources.sha256")
    with (source_root / "utmapp-utm-v5.0.9-2.tar").open("wb") as destination:
        subprocess.run(
            ["git", "-C", str(upstream), "archive", "--format=tar", "--prefix=UTM/", UTM_COMMIT],
            check=True,
            stdout=destination,
        )
    copy_file(upstream / "LICENSE", source_root / "UTM-LICENSE")
    copy_file(upstream / "scripts" / "build_dependencies.sh", source_root / "build_dependencies.sh")
    copy_file(upstream / "scripts" / "fixup.sh", source_root / "fixup.sh")
    copy_file(upstream / "patches" / "sources", source_root / "upstream-sources.sh")
    copy_file(repo / "scripts" / "patch-utm-qemu-ios-tci.py", source_root / "patch-utm-qemu-ios-tci.py")
    copy_file(repo / "scripts" / "package-qemu-ios-tci.py", source_root / "package-qemu-ios-tci.py")
    copy_file(repo / "scripts" / "qemu-ios-tci-host-requirements.txt", source_root / "qemu-ios-tci-host-requirements.txt")
    copy_file(repo / ".github" / "workflows" / "qemu-ios-tci-runtime.yml", source_root / "qemu-ios-tci-runtime.yml")
    for filename in (
        "glib-2.83.0.patch",
        "libslirp-v4.9.1.patch",
        "pixman-0.38.0.patch",
        "qemu-10.0.12-utm.patch",
    ):
        copy_file(upstream / "patches" / filename, patches / filename)

    qemu_source = qemu_dir / "subprojects" / "libucontext"
    if not qemu_source.is_dir() or not (qemu_source / ".git").exists():
        raise SystemExit("QEMU did not resolve its pinned libucontext Meson subproject")
    subproject_commit = run(["git", "-C", str(qemu_source), "rev-parse", "HEAD"])
    if subproject_commit != LIBUCONTEXT_COMMIT:
        raise SystemExit(f"Unexpected libucontext revision: {subproject_commit}")
    libucontext_out = source_root / "libucontext"
    shutil.copytree(qemu_source, libucontext_out, ignore=shutil.ignore_patterns(".git"))

    glib_dir = build_dir / "glib-2.83.0"
    pcre2_source = glib_dir / "subprojects" / "pcre2-10.44"
    if not pcre2_source.is_dir() or not (pcre2_source / "LICENCE").is_file():
        raise SystemExit("GLib did not resolve and stage its pinned PCRE2 source and license")
    shutil.copytree(pcre2_source, source_root / "pcre2-10.44", dirs_exist_ok=True)

    notices = """# Third-party notices for the ARM64 iOS TCI/QEMU artifact

This is a separate research build artifact. It is not yet linked into the app.
The matching source archives, UTM build script, QEMU patch set and source lock
are in this artifact's `source/` directory.

| Component | License | Source / notice |
| --- | --- | --- |
| QEMU 10.0.12 UTM fork and ARM64 softmmu library | GPL-2.0-or-later | `source/archives/qemu-10.0.12-utm.tar.xz` (`COPYING`, `LICENSE`) plus the included UTM QEMU patch |
| GLib 2.83.0 | LGPL-2.1-or-later | `source/archives/glib-2.83.0.tar.xz` |
| libffi 3.5.0 | MIT | `source/archives/libffi-3.5.0.tar.gz` |
| GNU libiconv 1.16 | LGPL-2.1-or-later | `source/archives/libiconv-1.16.tar.gz` |
| pixman 0.38.0 | MIT | `source/archives/pixman-0.38.0.tar.gz` |
| libslirp 4.9.1 | BSD-3-Clause | `source/archives/libslirp-v4.9.1.tar.gz` |
| libucontext | ISC | `source/libucontext/LICENSE`; source revision is pinned by QEMU's `subprojects/libucontext.wrap` |
| PCRE2 10.44 (GLib fallback) | BSD-3-Clause | `source/pcre2-10.44/LICENCE`; GLib's pinned Meson wrap is in its source archive |
| UTM build helpers and patches | Apache-2.0 | `source/UTM-LICENSE` |

`pkg-config` is built as a host-only build tool and is not included in the
runtime Frameworks directory. GNU gettext and QEMU's gettext support are
disabled for this build. Verify this report and the actual framework list
before any app redistribution.
"""
    (output / "THIRD-PARTY-NOTICES.md").write_text(notices)

    return {
        "utmCommit": UTM_COMMIT,
        "archives": source_records,
        "subprojects": [
            {
                "name": "libucontext",
                "commit": subproject_commit,
                "sourceTreeSha256": tree_sha256(libucontext_out),
            },
            {
                "name": "PCRE2 10.44",
                "sourceTreeSha256": tree_sha256(source_root / "pcre2-10.44"),
            },
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--sysroot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    repo = args.repo.resolve()
    upstream = args.upstream.resolve()
    build_dir = args.build_dir.resolve()
    sysroot = args.sysroot.resolve()
    output = args.output.resolve()
    qemu_dir = build_dir / "qemu-10.0.12-utm"
    frameworks_src = sysroot / "Frameworks"
    if not frameworks_src.is_dir():
        raise SystemExit(f"iOS Frameworks output is missing: {frameworks_src}")

    source_records = stage_sources(
        repo=repo,
        upstream=upstream,
        build_dir=build_dir,
        qemu_dir=qemu_dir,
        output=output,
        lock_path=repo / "scripts" / "qemu-ios-tci-sources.sha256",
    )
    runtime_frameworks = output / "runtime" / "Frameworks"
    runtime_frameworks.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(frameworks_src, runtime_frameworks, dirs_exist_ok=True, symlinks=True)

    options = meson_options(qemu_dir)
    required_options = {
        "shared_lib": True,
        "hvf": "disabled",
        "slirp": "enabled",
        "slirp_smbd": "disabled",
        "virtfs": "disabled",
        "usb_redir": "disabled",
        "gtk": "disabled",
        "spice": "disabled",
        "vnc": "disabled",
        "opengl": "disabled",
        "gettext": "disabled",
        "docs": "disabled",
        "cocoa": "disabled",
        "sdl": "disabled",
        "coreaudio": "disabled",
        "coroutine_backend": "libucontext",
    }
    for name, expected in required_options.items():
        if options.get(name) != expected:
            raise SystemExit(f"Unexpected QEMU Meson option {name}: {options.get(name)!r}; expected {expected!r}")

    config_mak = qemu_dir / "config-host.mak"
    config_text = config_mak.read_text()
    if not re.search(r"(?m)^TARGET_DIRS=aarch64-softmmu$", config_text):
        raise SystemExit("QEMU target list is not restricted to aarch64-softmmu")
    target_config = find_tcg_config(qemu_dir).read_text(errors="ignore")
    if not re.search(r"(?m)^#define CONFIG_TCG_THREADED_INTERPRETER 1$", target_config):
        raise SystemExit("The ARM64 target was not built with the TCG threaded interpreter")

    frameworks = sorted(path for path in runtime_frameworks.glob("*.framework") if path.is_dir())
    if not frameworks:
        raise SystemExit("The iOS build did not produce any embeddable frameworks")
    framework_records = []
    core_found = False
    for framework in frameworks:
        binary = find_framework_binary(framework)
        run(["xcrun", "--sdk", "iphoneos", "strip", "-S", "-x", str(binary)])
        architectures = run(["xcrun", "--sdk", "iphoneos", "lipo", "-archs", str(binary)]).split()
        if architectures != ["arm64"]:
            raise SystemExit(f"Unexpected framework architecture in {framework.name}: {architectures}")
        name = framework.stem
        if "aarch64-softmmu" in name:
            core_found = True
        framework_records.append(
            {
                "name": name,
                "path": str(binary.relative_to(output)),
                "sha256": sha256(binary),
                "strippedBytes": binary.stat().st_size,
                "architectures": architectures,
                "license": framework_license(name),
                "dynamicDependencies": dynamic_dependencies(binary, runtime_frameworks),
            }
        )
    if not core_found:
        names = ", ".join(item["name"] for item in framework_records)
        raise SystemExit(f"The QEMU ARM64 softmmu framework was not staged. Frameworks: {names}")

    qemu_tar = build_dir / "qemu-10.0.12-utm.tar.xz"
    if sha256(qemu_tar) != QEMU_TARBALL_SHA256:
        raise SystemExit("QEMU source archive no longer matches its pinned SHA-256")
    xcode = run(["xcodebuild", "-version"])
    sdk_version = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"])
    patch_files = [
        repo / "scripts" / "patch-utm-qemu-ios-tci.py",
        upstream / "patches" / "glib-2.83.0.patch",
        upstream / "patches" / "libslirp-v4.9.1.patch",
        upstream / "patches" / "pixman-0.38.0.patch",
        upstream / "patches" / "qemu-10.0.12-utm.patch",
    ]
    source_records.update({
        "qemuSourceSha256": sha256(qemu_tar),
        "utmSourceSha256": sha256(output / "source" / "utmapp-utm-v5.0.9-2.tar"),
        "patches": [
            {"filename": patch.name, "sha256": sha256(patch)} for patch in patch_files
        ],
    })

    report = {
        "schema": 1,
        "builtAt": datetime.now(timezone.utc).isoformat(),
        "source": source_records,
        "toolchain": {
            "xcode": xcode,
            "iphoneosSdk": sdk_version,
            "minimumIos": "15.0",
            "meson": run(["meson", "--version"]),
            "ninja": run(["ninja", "--version"]),
            "bison": run(["bison", "--version"]).splitlines()[0],
            "flex": run(["flex", "--version"]).splitlines()[0],
            "python": run(["python3", "--version"]),
            "homebrewPackages": run(["brew", "list", "--versions", "bison", "flex", "glib"]),
            "hostArchitecture": run(["uname", "-m"]),
        },
        "qemu": {
            "version": "10.0.12-utm",
            "hostArchitecture": "arm64",
            "guestTarget": "aarch64-softmmu",
            "accelerator": "TCG threaded interpreter",
            "hvf": False,
            "sharedLibrary": True,
            "networkBackend": "user-mode libslirp",
            "virtio9p": False,
            "options": required_options,
        },
        "frameworks": framework_records,
        "sizes": {
            "strippedFrameworkMachOBytes": sum(item["strippedBytes"] for item in framework_records),
            "frameworkPayloadBytes": regular_file_bytes(runtime_frameworks),
            "sourcePayloadBytes": regular_file_bytes(output / "source"),
        },
        "licenses": LICENSES,
    }
    (output / "build-report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    summary = [
        "# ARM64 iOS TCI/QEMU build report",
        "",
        f"- QEMU: `{report['qemu']['version']}`; guest target `{report['qemu']['guestTarget']}`; HVF disabled.",
        f"- Toolchain: {sdk_version}, {xcode.splitlines()[0]}, Meson {report['toolchain']['meson']}, Ninja {report['toolchain']['ninja']}.",
        f"- Frameworks: {len(framework_records)}; stripped Mach-O total {report['sizes']['strippedFrameworkMachOBytes']:,} bytes ({report['sizes']['strippedFrameworkMachOBytes'] / 1024 / 1024:.2f} MiB).",
        f"- Framework payload: {report['sizes']['frameworkPayloadBytes']:,} bytes ({report['sizes']['frameworkPayloadBytes'] / 1024 / 1024:.2f} MiB).",
        f"- Source and notices: {report['sizes']['sourcePayloadBytes']:,} bytes ({report['sizes']['sourcePayloadBytes'] / 1024 / 1024:.2f} MiB).",
        "",
        "| Framework | Stripped bytes | License |",
        "| --- | ---: | --- |",
    ]
    summary.extend(
        f"| `{item['name']}` | {item['strippedBytes']:,} | {item['license']} |"
        for item in framework_records
    )
    (output / "build-report.md").write_text("\n".join(summary) + "\n")

    checksum_lines = []
    for path in sorted(output.rglob("*")):
        if path.is_file() and path.name != "SHA256SUMS.txt":
            checksum_lines.append(f"{sha256(path)}  {path.relative_to(output).as_posix()}")
    (output / "SHA256SUMS.txt").write_text("\n".join(checksum_lines) + "\n")
    print((output / "build-report.md").read_text(), end="")


if __name__ == "__main__":
    main()
