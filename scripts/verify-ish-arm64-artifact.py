#!/usr/bin/env python3
"""Verify the pinned iSH ARM64 build artifact before CI publishes it."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys


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
    require(manifest.get("artifactKind") == "static-library-build-only; not yet linked into DSBotStandalone",
            "Unexpected artifact kind; update this gate before linking iSH into the app")
    source = manifest.get("source", {})
    require(source.get("distributionCommit") == lock["distribution"]["commit"], "OpenMinis build source pin mismatch")
    require(source.get("engineCommit") == lock["engine"]["commit"], "iSH engine source pin mismatch")
    require(source.get("submodules") == lock["engine"]["submodules"], "iSH submodule source pins mismatch")
    require(manifest.get("license") == lock["license"], "iSH license terms differ from the source lock")

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
    print("Verified locked iSH ARM64 device/Simulator libraries, source archives, licenses, and checksums.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, ValueError, json.JSONDecodeError) as error:
        print(f"iSH artifact verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
