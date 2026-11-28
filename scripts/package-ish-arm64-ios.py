#!/usr/bin/env python3
"""Package pinned iSH ARM64 libraries, notices, source, and a size report."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path, PurePosixPath
import sqlite3
import stat
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

from arm64_guest_common import ALPINE_VERSION, MINIROOTFS_ARTIFACT, safe_archive_path


LIBRARIES = ("libish.a", "libish_emu.a", "libfakefs.a", "libish_aot.a")
PLATFORMS = {
    "iphoneos": "device",
    "iphonesimulator": "simulator",
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_archive(repo, output):
    process = subprocess.Popen(
        ["git", "-C", str(repo), "archive", "--format=tar", "HEAD"],
        stdout=subprocess.PIPE,
    )
    try:
        with output.open("wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", compresslevel=9, mtime=0) as zipped:
            shutil.copyfileobj(process.stdout, zipped, 1024 * 1024)
    finally:
        if process.stdout:
            process.stdout.close()
    if process.wait() != 0:
        output.unlink(missing_ok=True)
        raise RuntimeError(f"git archive failed for {repo}")


def copy_required(source, destination):
    if not source.exists():
        raise SystemExit(f"Missing iSH build output: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, destination, dirs_exist_ok=True)
    else:
        shutil.copy2(source, destination)


def read_alpine_packages(rootfs_archive):
    installed = None
    with tarfile.open(rootfs_archive, "r:gz") as archive:
        for member in archive.getmembers():
            if safe_archive_path(member.name) == "lib/apk/db/installed":
                if not member.isfile():
                    raise RuntimeError("Alpine installed-package database is not a regular file")
                stream = archive.extractfile(member)
                if stream is None:
                    raise RuntimeError("Could not read Alpine installed-package database")
                installed = stream.read(4 * 1024 * 1024 + 1)
                if len(installed) > 4 * 1024 * 1024:
                    raise RuntimeError("Alpine installed-package database exceeds 4 MiB")
                break
    if installed is None:
        raise RuntimeError("Pinned Alpine minirootfs has no installed-package database")

    packages = []
    current = {}
    for line in installed.decode("utf-8", "replace").splitlines():
        if not line:
            if current.get("P"):
                packages.append(current)
            current = {}
        elif len(line) > 2 and line[1] == ":":
            current[line[0]] = line[2:]
    if current.get("P"):
        packages.append(current)
    for package in packages:
        package.setdefault("L", "unknown")
        commit = package.get("c", "")
        if commit:
            package["sourceCommit"] = commit
            package["sourceCommitURL"] = (
                f"https://gitlab.alpinelinux.org/alpine/aports/-/commit/{commit}"
            )
            package["sourceArchiveURL"] = (
                "https://gitlab.alpinelinux.org/alpine/aports/"
                f"-/archive/{commit}/aports-{commit}.tar.gz"
            )
    return packages


def deterministic_zipinfo(name, mode, is_directory=False):
    if is_directory and not name.endswith("/"):
        name += "/"
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED
    file_type = stat.S_IFDIR if is_directory else stat.S_IFREG
    info.external_attr = (file_type | stat.S_IMODE(mode)) << 16
    return info


def write_fakefs_zip(fakefs_root, archive_path):
    """Package the exact directory shape consumed by RootfsManager's unzipper."""
    entries = []
    total_file_bytes = 0
    with zipfile.ZipFile(
        archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9, allowZip64=True
    ) as archive:
        archive.writestr(deterministic_zipinfo("alpine-rootfs", 0o755, True), b"")
        for path in sorted(fakefs_root.rglob("*"), key=lambda item: item.relative_to(fakefs_root).as_posix()):
            if path.is_symlink():
                raise RuntimeError(f"Unexpected host symlink in fakefs image: {path}")
            relative = (Path("alpine-rootfs") / path.relative_to(fakefs_root)).as_posix()
            mode = path.stat().st_mode
            if path.is_dir():
                archive.writestr(deterministic_zipinfo(relative, mode, True), b"")
                entries.append({"path": relative + "/", "kind": "directory"})
            elif path.is_file():
                info = deterministic_zipinfo(relative, mode)
                with path.open("rb") as source, archive.open(info, "w") as target:
                    shutil.copyfileobj(source, target, 1024 * 1024)
                size = path.stat().st_size
                total_file_bytes += size
                entries.append({"path": relative, "kind": "file", "bytes": size})
            else:
                raise RuntimeError(f"Unsupported host file type in fakefs image: {path}")
    return entries, total_file_bytes


def package_fakefs_rootfs(minirootfs, fakefsify, output):
    expected = MINIROOTFS_ARTIFACT["sha256"]
    if sha256(minirootfs) != expected:
        raise RuntimeError("Alpine minirootfs does not match the pinned upstream SHA-256")
    packages = read_alpine_packages(minirootfs)
    if not packages:
        raise RuntimeError("Pinned Alpine minirootfs contains an empty package inventory")

    output.mkdir(parents=True, exist_ok=True)
    artifact_dir = output / "rootfs"
    artifact_dir.mkdir()
    with tempfile.TemporaryDirectory(prefix="dsbot-ish-rootfs-") as temporary:
        fakefs = Path(temporary) / "alpine-rootfs"
        subprocess.run([str(fakefsify), str(minirootfs), str(fakefs)], check=True)
        data = fakefs / "data"
        metadata = fakefs / "meta.db"
        if not data.is_dir() or not metadata.is_file():
            raise RuntimeError("fakefsify did not produce data/ and meta.db")
        for required in ("bin/ash", "bin/busybox", "lib/apk/db/installed"):
            if not (data / required).is_file():
                raise RuntimeError(f"fakefs image is missing required base path: {required}")

        # fakefsify initializes SQLite in WAL mode. Checkpoint and close it as
        # a single-file database before zipping: a first-install image must not
        # depend on a sidecar WAL/SHM file. iSH switches to WAL again on mount.
        connection = sqlite3.connect(metadata)
        try:
            checkpoint = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
            if checkpoint and checkpoint[0] != 0:
                raise RuntimeError("fakefs metadata database could not checkpoint its WAL")
            journal_mode = connection.execute("PRAGMA journal_mode=DELETE").fetchone()
            if not journal_mode or journal_mode[0].lower() != "delete":
                raise RuntimeError("fakefs metadata database could not switch to single-file mode")
            integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
            if integrity != "ok":
                raise RuntimeError(f"fakefs metadata database integrity check failed: {integrity}")
            fakefs_path_count = connection.execute("SELECT count(*) FROM paths").fetchone()[0]
        finally:
            connection.close()
        for suffix in ("-wal", "-shm"):
            transient = Path(str(metadata) + suffix)
            if transient.exists():
                if suffix == "-wal" and transient.stat().st_size != 0:
                    raise RuntimeError("fakefs metadata WAL remains non-empty after checkpoint")
                transient.unlink()

        image_path = artifact_dir / "alpine-rootfs.zip"
        file_records, expanded_bytes = write_fakefs_zip(fakefs, image_path)
        data_bytes = sum(
            path.stat().st_size
            for path in data.rglob("*")
            if path.is_file() and not path.is_symlink()
        )
        meta_bytes = metadata.stat().st_size
        with zipfile.ZipFile(image_path) as archive:
            bad_entry = archive.testzip()
            if bad_entry:
                raise RuntimeError(f"Generated iSH rootfs ZIP has a corrupt entry: {bad_entry}")

    package_path = artifact_dir / "base-packages.json"
    package_path.write_text(json.dumps(packages, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    notice_lines = [
        "Alpine Linux ARM64 fakefs base — third-party package inventory",
        "",
        f"Source: Alpine Linux {ALPINE_VERSION} aarch64 minirootfs.",
        f"Pinned input SHA-256: {expected}",
        "Package license values are copied from Alpine's installed-package database; unknown means upstream metadata omitted a license.",
        "Source commit and aports archive links are included when present in the installed-package database.",
        "This CI artifact is a build candidate; do not redistribute the rootfs without satisfying each package's source and license obligations.",
        "",
        "Package | Version | License | Source archive",
    ]
    for package in packages:
        notice_lines.append(
            " | ".join(
                (
                    package.get("P", ""),
                    package.get("V", ""),
                    package.get("L", "unknown"),
                    package.get("sourceArchiveURL", "source archive URL unavailable"),
                )
            )
        )
    (artifact_dir / "THIRD-PARTY-NOTICES.txt").write_text(
        "\n".join(notice_lines) + "\n", encoding="utf-8"
    )
    manifest = {
        "schemaVersion": 1,
        "format": "iSH fakefs rootfs ZIP",
        "distribution": "Alpine Linux",
        "distributionVersion": ALPINE_VERSION,
        "architecture": "aarch64",
        "source": {
            "url": MINIROOTFS_ARTIFACT["url"],
            "sha256": expected,
            "bytes": minirootfs.stat().st_size,
        },
        "converter": "fakefsify from the locked iSH ARM64 source revision",
        "image": {
            "path": "rootfs/alpine-rootfs.zip",
            "sha256": sha256(image_path),
            "bytes": image_path.stat().st_size,
            "expandedFakefsBytes": expanded_bytes,
            "dataBytes": data_bytes,
            "metaDatabaseBytes": meta_bytes,
            "metadataPathCount": fakefs_path_count,
            "archiveEntryCount": len(file_records),
            "basePackageCount": len(packages),
        },
        "basePackagesFile": "rootfs/base-packages.json",
    }
    (artifact_dir / "rootfs-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--distribution-root", type=Path, required=True)
    parser.add_argument("--guest-minirootfs", type=Path, required=True)
    parser.add_argument("--fakefsify", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    lock = json.loads(args.lock.read_text(encoding="utf-8"))
    distribution = args.distribution_root.resolve()
    engine = distribution / "deps/ish"
    products = distribution / "deps"
    output = args.output.resolve()
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    copied = []
    for sdk, label in PLATFORMS.items():
        libraries = products / "libs" / sdk if sdk == "iphonesimulator" else products / "libs"
        for filename in LIBRARIES:
            target = output / "libraries" / label / filename
            copy_required(libraries / filename, target)
            copied.append(target)
    copy_required(products / "include" / "ish", output / "include" / "ish")
    copy_required(products / "resources", output / "resources")
    for filename in lock["license"]["requiredFiles"]:
        copy_required(engine / filename, output / "licenses" / filename)
    for filename in ("LICENSE", "THIRD_PARTY_LICENSES.md"):
        copy_required(distribution / filename, output / "licenses" / f"OpenMinis-{filename}")

    source_dir = output / "source"
    source_dir.mkdir()
    source_records = []
    source_repos = [("ish-arm64", engine)]
    for submodule in lock["engine"]["submodules"]:
        source_repos.append((submodule.replace("/", "-"), engine / submodule))
    for name, repo in source_repos:
        for notice in repo.iterdir():
            upper = notice.name.upper()
            if notice.is_file() and (upper.startswith("LICENSE") or upper.startswith("COPYING") or upper.startswith("NOTICE")):
                copy_required(notice, output / "licenses" / name / notice.name)
        archive = source_dir / f"{name}.tar.gz"
        git_archive(repo, archive)
        source_records.append({
            "name": name,
            "commit": subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip(),
            "file": str(archive.relative_to(output)),
            "sha256": sha256(archive),
            "bytes": archive.stat().st_size,
        })
    build_script = distribution / lock["distribution"]["buildScript"]
    copy_required(build_script, source_dir / "OpenMinis-build_ish.sh")
    copy_required(args.lock, source_dir / "ish-arm64-sources.lock.json")
    build_script_hash = sha256(source_dir / "OpenMinis-build_ish.sh")
    if build_script_hash != lock["distribution"]["buildScriptSha256"]:
        raise SystemExit("Packaged build script hash does not match source lock")
    integration_patch_records = []
    for record in lock.get("hostIntegrationPatches", []):
        relative = PurePosixPath(record["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise SystemExit(f"Unsafe iSH integration patch path: {record['path']}")
        patch_source = args.lock.resolve().parent.joinpath(*relative.parts)
        if not patch_source.is_file() or sha256(patch_source) != record["sha256"]:
            raise SystemExit(f"iSH integration patch hash mismatch: {record['path']}")
        patch_destination = source_dir / relative.name
        copy_required(patch_source, patch_destination)
        integration_patch_records.append({
            "path": str(patch_destination.relative_to(output)),
            "sha256": sha256(patch_destination),
            "purpose": record["purpose"],
        })

    rootfs_manifest = package_fakefs_rootfs(
        args.guest_minirootfs.resolve(), args.fakefsify.resolve(), output
    )

    notices = """iSH ARM64 engine source notice\n\nThis artifact contains static libraries built from OpenMinis/ish-arm64 and a pinned Alpine ARM64 fakefs rootfs.\nThe iSH core is licensed under GPLv3, with later contributions also GPLv2;\nLICENSE.IOS applies to iOS builds.\nThe exact source revisions and corresponding source archives are included in\nsource/. The OpenMinis build script and DSH integration patches are included\nwith their pinned source hashes. The Alpine package inventory and notices are\nunder rootfs/. This is a build candidate, not an app-linked or release-cleared\nruntime bundle.\n"""
    (output / "THIRD-PARTY-NOTICES.txt").write_text(notices, encoding="utf-8")

    component_sizes = {}
    for label in PLATFORMS.values():
        files = [path for path in copied if f"/libraries/{label}/" in str(path)]
        component_sizes[f"{label}Libraries"] = {
            "uncompressedBytes": sum(path.stat().st_size for path in files),
            "files": [{"path": str(path.relative_to(output)), "bytes": path.stat().st_size, "sha256": sha256(path)} for path in files],
        }
    component_sizes["baseRootfs"] = rootfs_manifest["image"]
    manifest = {
        "schemaVersion": 1,
        "engine": "iSH ARM64 fakefs library and pinned rootfs build",
        "artifactKind": "static-libraries-and-pinned-fakefs-rootfs-build-only; not yet linked into DSBotStandalone",
        "architecture": "arm64",
        "source": {
            "distributionRepository": lock["distribution"]["repository"],
            "distributionCommit": lock["distribution"]["commit"],
            "engineRepository": lock["engine"]["repository"],
            "engineCommit": lock["engine"]["commit"],
            "buildScriptSha256": build_script_hash,
            "integrationPatches": integration_patch_records,
            "submodules": lock["engine"]["submodules"],
            "archives": source_records,
        },
        "toolchain": {
            "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip().replace("\n", " "),
            "meson": subprocess.check_output(["meson", "--version"], text=True).strip(),
            "ninja": subprocess.check_output(["ninja", "--version"], text=True).strip(),
            "clang": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
            "configuration": "Release",
            "aot": "upstream AOT support library is packaged for measurement; no image ABI or runtime hit is claimed",
            "rootfsConverter": "host-native fakefsify built from the same locked iSH engine commit",
        },
        "license": lock["license"],
        "componentSizes": component_sizes,
        "baseRootfs": rootfs_manifest,
    }
    (output / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    report = [
        "# iSH ARM64 iOS library build",
        "",
        f"- Engine commit: `{lock['engine']['commit']}`",
        f"- Build definition commit: `{lock['distribution']['commit']}`",
        f"- Host integration patches: {len(integration_patch_records)} hash-verified patch(es).",
        "- Artifact status: static libraries and pinned Alpine fakefs ZIP; DSH/NodeMobile runtime wiring and app-size impact are not included.",
        f"- Alpine {ALPINE_VERSION} fakefs ZIP: {rootfs_manifest['image']['bytes']} bytes; expanded fakefs files: {rootfs_manifest['image']['expandedFakefsBytes']} bytes; packages: {rootfs_manifest['image']['basePackageCount']}.",
        "- The rootfs has not been linked into the app and remains a CI build artifact.",
        "- Corresponding source archives and iSH license files are included.",
        "",
    ]
    for label, key in (("Device", "deviceLibraries"), ("Simulator", "simulatorLibraries")):
        details = component_sizes[key]
        report.append(f"## {label} — {details['uncompressedBytes']} uncompressed library bytes")
        report.extend(f"- `{item['path']}`: {item['bytes']} bytes" for item in details["files"])
        report.append("")
    (output / "build-report.md").write_text("\n".join(report), encoding="utf-8")
    files = []
    for path in sorted(output.rglob("*")):
        if path.is_file() and path.name != "SHA256SUMS.txt":
            files.append(f"{sha256(path)}  {path.relative_to(output)}")
    (output / "SHA256SUMS.txt").write_text("\n".join(files) + "\n", encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, RuntimeError, json.JSONDecodeError) as error:
        print(f"iSH artifact packaging failed: {error}", file=sys.stderr)
        raise SystemExit(1)
