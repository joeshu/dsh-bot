#!/usr/bin/env python3
"""Verify the pinned iSH ARM64 build artifact before CI publishes it."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import zipfile

from prepare_arm64_guest import ALPINE_VERSION, ARTIFACTS


LIBRARIES = ("libish.a", "libish_emu.a", "libfakefs.a", "libish_aot.a")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--lock", type=Path, default=Path(__file__).with_name("ish-arm64-sources.lock.json"))
    args = parser.parse_args()
    root = args.artifact.resolve()
    lock = json.loads(args.lock.read_text(encoding="utf-8"))
    manifest_path = root / "runtime-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    require(manifest.get("schemaVersion") == 1, "Unsupported iSH artifact manifest schema")
    require(manifest.get("architecture") == "arm64", "iSH artifact is not ARM64")
    require(manifest.get("artifactKind") == "static-libraries-and-pinned-fakefs-rootfs-build-only; not yet linked into DSBotStandalone",
            "Unexpected artifact kind; update this gate before linking iSH into the app")
    source = manifest.get("source", {})
    require(source.get("distributionCommit") == lock["distribution"]["commit"], "OpenMinis build source pin mismatch")
    require(source.get("engineCommit") == lock["engine"]["commit"], "iSH engine source pin mismatch")
    require(source.get("submodules") == lock["engine"]["submodules"], "iSH submodule source pins mismatch")
    require(manifest.get("license") == lock["license"], "iSH license terms differ from the source lock")

    rootfs = manifest.get("baseRootfs", {})
    rootfs_manifest_path = root / "rootfs/rootfs-manifest.json"
    require(rootfs_manifest_path.is_file(), "Missing iSH fakefs rootfs manifest")
    rootfs_detail = json.loads(rootfs_manifest_path.read_text(encoding="utf-8"))
    require(rootfs == rootfs_detail, "Runtime and rootfs manifests disagree")
    require(rootfs_detail.get("schemaVersion") == 1, "Unsupported iSH rootfs manifest schema")
    require(rootfs_detail.get("format") == "iSH fakefs rootfs ZIP", "Unexpected iSH rootfs format")
    require(rootfs_detail.get("distributionVersion") == ALPINE_VERSION, "Unexpected Alpine rootfs version")
    require(rootfs_detail.get("architecture") == "aarch64", "Alpine rootfs is not ARM64")
    source_detail = rootfs_detail.get("source", {})
    require(source_detail.get("url") == ARTIFACTS["minirootfs"]["url"], "Alpine source URL is not pinned")
    require(source_detail.get("sha256") == ARTIFACTS["minirootfs"]["sha256"], "Alpine source hash is not pinned")
    require(isinstance(source_detail.get("bytes"), int) and source_detail["bytes"] > 0,
            "Alpine source size is missing")
    image_detail = rootfs_detail.get("image", {})
    require(manifest.get("componentSizes", {}).get("baseRootfs") == image_detail,
            "Rootfs component sizes disagree with the rootfs manifest")
    image_relative = PurePosixPath(image_detail.get("path", ""))
    require(not image_relative.is_absolute() and ".." not in image_relative.parts,
            "Unsafe iSH rootfs archive path")
    image_path = root.joinpath(*image_relative.parts)
    require(image_path.is_file() and not image_path.is_symlink(), "Missing iSH fakefs ZIP")
    require(image_path.stat().st_size == image_detail.get("bytes") and sha256(image_path) == image_detail.get("sha256"),
            "iSH fakefs ZIP hash/size mismatch")
    require((root / "rootfs/THIRD-PARTY-NOTICES.txt").is_file(), "Missing Alpine package notices")
    packages_path = root / rootfs_detail.get("basePackagesFile", "")
    require(packages_path == root / "rootfs/base-packages.json" and packages_path.is_file(),
            "Missing or unexpected Alpine package inventory")
    packages = json.loads(packages_path.read_text(encoding="utf-8"))
    require(isinstance(packages, list) and len(packages) == image_detail.get("basePackageCount"),
            "Alpine package count does not match the rootfs manifest")
    require(all(package.get("P") and package.get("V") for package in packages),
            "Alpine package inventory has an entry without name/version")
    require(len({package["P"] for package in packages}) == len(packages),
            "Alpine package inventory contains duplicate package names")
    require(all(package.get("L") for package in packages),
            "Alpine package inventory must state a license or 'unknown'")
    with zipfile.ZipFile(image_path) as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        require(len(names) == len(set(names)), "iSH rootfs ZIP contains duplicate paths")
        for name, info in zip(names, infos):
            path = PurePosixPath(name)
            require(not path.is_absolute() and ".." not in path.parts,
                    f"Unsafe path in iSH rootfs ZIP: {name}")
            mode = (info.external_attr >> 16) & 0xFFFF
            require(not stat.S_ISLNK(mode), f"Unexpected symbolic link in fakefs ZIP: {name}")
        require("alpine-rootfs/meta.db" in names, "iSH fakefs ZIP is missing meta.db")
        require("alpine-rootfs/data/bin/ash" in names, "iSH fakefs ZIP is missing /bin/ash")
        require("alpine-rootfs/data/bin/busybox" in names, "iSH fakefs ZIP is missing BusyBox")
        require("alpine-rootfs/data/lib/apk/db/installed" in names, "iSH fakefs ZIP is missing Alpine package metadata")
        require(not any(name.endswith(("-wal", "-shm")) for name in names),
                "iSH fakefs ZIP contains a transient SQLite WAL/SHM file")
        require(archive.testzip() is None, "iSH fakefs ZIP has a CRC failure")
        meta_bytes = archive.read("alpine-rootfs/meta.db")
        with tempfile.TemporaryDirectory(prefix="dsbot-verify-ish-rootfs-") as temporary:
            database = Path(temporary) / "meta.db"
            database.write_bytes(meta_bytes)
            connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
            try:
                require(connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok",
                        "iSH fakefs metadata database failed integrity_check")
                path_count = connection.execute("SELECT count(*) FROM paths").fetchone()[0]
            finally:
                connection.close()
        require(path_count == image_detail.get("metadataPathCount"),
                "iSH fakefs metadata path count does not match its manifest")
        expanded = sum(info.file_size for info in infos if not info.is_dir())
        require(expanded == image_detail.get("expandedFakefsBytes"),
                "iSH fakefs expanded byte count does not match its manifest")
        data_bytes = sum(
            info.file_size for info in infos
            if info.filename.startswith("alpine-rootfs/data/") and not info.is_dir()
        )
        require(data_bytes == image_detail.get("dataBytes"), "iSH fakefs data size does not match its manifest")
        meta_info = archive.getinfo("alpine-rootfs/meta.db")
        require(meta_info.file_size == image_detail.get("metaDatabaseBytes"),
                "iSH fakefs metadata database size does not match its manifest")
        require(len(infos) - 1 == image_detail.get("archiveEntryCount"),
                "iSH fakefs ZIP entry count does not match its manifest")

    expected_archives = {"ish-arm64", *(path.replace("/", "-") for path in lock["engine"]["submodules"])}
    archive_records = source.get("archives", [])
    require({record.get("name") for record in archive_records} == expected_archives,
            "The artifact does not include the full pinned source dependency set")
    expected_commits = {
        "ish-arm64": lock["engine"]["commit"],
        **{path.replace("/", "-"): commit for path, commit in lock["engine"]["submodules"].items()},
    }
    for record in archive_records:
        relative = PurePosixPath(record["file"])
        require(not relative.is_absolute() and ".." not in relative.parts,
                f"Unsafe source archive path: {record['file']}")
        require(record.get("commit") == expected_commits[record["name"]],
                f"Source archive commit mismatch: {record['name']}")
        path = root.joinpath(*relative.parts)
        require(path.is_file() and not path.is_symlink(), f"Missing source archive: {record['file']}")
        require(path.stat().st_size == record.get("bytes") and sha256(path) == record.get("sha256"),
                f"Source archive hash/size mismatch: {record['file']}")

    build_script = root / "source/OpenMinis-build_ish.sh"
    require(build_script.is_file() and sha256(build_script) == lock["distribution"]["buildScriptSha256"],
            "Packaged OpenMinis build script does not match the source lock")
    for relative in (
        "licenses/LICENSE.md",
        "licenses/LICENSE.IOS",
        "licenses/OpenMinis-LICENSE",
        "licenses/OpenMinis-THIRD_PARTY_LICENSES.md",
        "THIRD-PARTY-NOTICES.txt",
        "include/ish/ish.h",
    ):
        require((root / relative).is_file(), f"Missing required source/license/build file: {relative}")

    lipo = shutil.which("lipo")
    require(lipo is not None, "Xcode lipo is required to verify ARM64 static-library slices")
    sizes = manifest.get("componentSizes", {})
    for platform in ("device", "simulator"):
        component = sizes.get(f"{platform}Libraries", {})
        records = {Path(record["path"]).name: record for record in component.get("files", [])}
        require(set(records) == set(LIBRARIES), f"Missing {platform} iSH library records")
        total = 0
        for name in LIBRARIES:
            relative = f"libraries/{platform}/{name}"
            path = root / relative
            require(path.is_file() and not path.is_symlink() and path.stat().st_size > 0,
                    f"Missing or empty ARM64 library: {relative}")
            record = records[name]
            require(path.stat().st_size == record.get("bytes") and sha256(path) == record.get("sha256"),
                    f"Library hash/size mismatch: {relative}")
            architectures = subprocess.check_output([lipo, "-archs", str(path)], text=True).split()
            require(architectures == ["arm64"], f"Unexpected architectures in {relative}: {architectures}")
            total += path.stat().st_size
        require(total == component.get("uncompressedBytes"), f"Incorrect {platform} component byte total")

    sums_path = root / "SHA256SUMS.txt"
    require(sums_path.is_file(), "Missing SHA256SUMS.txt")
    listed = set()
    for line in sums_path.read_text(encoding="utf-8").splitlines():
        digest, separator, relative = line.partition("  ")
        require(separator and len(digest) == 64, "Malformed SHA256SUMS.txt entry")
        name = PurePosixPath(relative)
        require(not name.is_absolute() and ".." not in name.parts, f"Unsafe checksum path: {relative}")
        path = root.joinpath(*name.parts)
        require(path.is_file() and not path.is_symlink() and sha256(path) == digest,
                f"Artifact checksum mismatch: {relative}")
        listed.add(relative)
    expected_files = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path.name != "SHA256SUMS.txt"
    }
    require(listed == expected_files, "SHA256SUMS.txt does not cover every artifact file exactly once")
    print("Verified locked iSH ARM64 libraries, Alpine fakefs rootfs, source archives, notices, and checksums.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, ValueError, json.JSONDecodeError) as error:
        print(f"iSH artifact verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
