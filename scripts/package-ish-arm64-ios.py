#!/usr/bin/env python3
"""Package pinned iSH ARM64 libraries, notices, source, and a size report."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--distribution-root", type=Path, required=True)
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

    notices = """iSH ARM64 engine source notice\n\nThis artifact contains static libraries built from OpenMinis/ish-arm64.\nThe iSH core is licensed under GPLv3, with later contributions also GPLv2;\nLICENSE.IOS applies to iOS builds.\nThe exact source revisions and corresponding source archives are included in\nsource/. The OpenMinis build script is included with its pinned source hash.\nReview each source tree for additional dependency notices before redistribution.\n"""
    (output / "THIRD-PARTY-NOTICES.txt").write_text(notices, encoding="utf-8")

    component_sizes = {}
    for label in PLATFORMS.values():
        files = [path for path in copied if f"/libraries/{label}/" in str(path)]
        component_sizes[f"{label}Libraries"] = {
            "uncompressedBytes": sum(path.stat().st_size for path in files),
            "files": [{"path": str(path.relative_to(output)), "bytes": path.stat().st_size, "sha256": sha256(path)} for path in files],
        }
    manifest = {
        "schemaVersion": 1,
        "engine": "iSH ARM64 fakefs library build",
        "artifactKind": "static-library-build-only; not yet linked into DSBotStandalone",
        "architecture": "arm64",
        "source": {
            "distributionRepository": lock["distribution"]["repository"],
            "distributionCommit": lock["distribution"]["commit"],
            "engineRepository": lock["engine"]["repository"],
            "engineCommit": lock["engine"]["commit"],
            "buildScriptSha256": build_script_hash,
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
        },
        "license": lock["license"],
        "componentSizes": component_sizes,
    }
    (output / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    report = [
        "# iSH ARM64 iOS library build",
        "",
        f"- Engine commit: `{lock['engine']['commit']}`",
        f"- Build definition commit: `{lock['distribution']['commit']}`",
        "- Artifact status: static libraries only; DSH/NodeMobile runtime wiring and app-size impact are not included.",
        f"- Device library bytes: {component_sizes['deviceLibraries']['uncompressedBytes']}",
        f"- Simulator library bytes: {component_sizes['simulatorLibraries']['uncompressedBytes']}",
        "- Corresponding source archives and iSH license files are included.",
        "",
    ]
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
