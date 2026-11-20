#!/usr/bin/env python3
"""Verify a DS Bot native IPA and derive release metadata from its bytes."""
import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
from zipfile import BadZipFile, ZipFile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_macho(data, min_os):
    require(len(data) >= 32, "Truncated Mach-O header")
    magic, cpu, subtype, kind, count, commands_size, _, _ = struct.unpack_from("<8I", data)
    require((magic, cpu, subtype & 0xFFFFFF, kind) == (0xFEEDFACF, 0x0100000C, 0, 2),
            "Expected a single generic arm64 Mach-O executable")
    end = 32 + commands_size
    require(end <= len(data) and count <= commands_size // 8, "Truncated Mach-O load commands")
    offset = 32
    platforms = []
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and size % 8 == 0 and offset + size <= end, "Invalid Mach-O load command")
        require(command != 0x1D, "Mach-O still contains a code signature")
        if command == 0x32:
            require(size >= 24, "Invalid Mach-O build version")
            platform, version = struct.unpack_from("<II", data, offset + 8)
            platforms.append((platform, version))
        offset += size
    require(offset == end, "Invalid Mach-O load command lengths")
    digits = [int(part) for part in min_os.split(".")]
    major, minor, patch = (digits + [0, 0])[:3]
    require(platforms == [(2, (major << 16) | (minor << 8) | patch)], "Expected an iPhoneOS executable with the declared deployment target")


def inspect(path):
    with ZipFile(path) as archive:
        entries = archive.infolist()
        names = {entry.filename for entry in entries}
        require(len(names) == len(entries), "Duplicate ZIP entries")
        for entry in entries:
            name = entry.filename
            parts = PurePosixPath(name).parts
            require(bool(parts) and parts[0] == "Payload" and "\\" not in name
                    and all(part not in ("", ".", "..") for part in name.rstrip("/").split("/")),
                    f"Invalid archive path: {name}")
            require(not stat.S_ISLNK(entry.external_attr >> 16), f"Unexpected symbolic link: {name}")
            require(not {"_CodeSignature", "embedded.mobileprovision", "SC_Info", ".DS_Store", "KernelAssets", "Frameworks",
                         "PlugIns", "kernel-manifest.json", "node_modules"}.intersection(parts),
                    f"Unexpected payload entry: {name}")
            require(not name.endswith(".dylib") and not name.endswith(".xctest"), f"Unexpected executable component: {name}")
        require(archive.testzip() is None, "ZIP CRC verification failed")
        app_roots = {PurePosixPath(name).parts[1] for name in names if len(PurePosixPath(name).parts) > 1}
        require(len(app_roots) == 1 and next(iter(app_roots)).endswith(".app"), "Expected exactly one Payload/*.app")
        prefix = "Payload/" + next(iter(app_roots)) + "/"
        for required in ["Info.plist", "Assets.car", "QuickJS-LICENSE.txt"]:
            require(prefix + required in names and archive.getinfo(prefix + required).file_size > 0, f"Missing {required}")
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        require(info.get("CFBundleIdentifier") == "io.github.dsbot.ios.standalone", "Unexpected bundle identifier")
        require(info.get("CFBundlePackageType") == "APPL", "Unexpected CFBundlePackageType")
        require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "Unexpected platform in Info.plist")
        require(info.get("UIDeviceFamily") == [1, 2], "Expected iPhone and iPad device families")
        min_os = info.get("MinimumOSVersion", "")
        require(min_os == "16.4", "Unexpected deployment target")
        executable = info.get("CFBundleExecutable", "")
        require(re.fullmatch(r"[A-Za-z0-9_-]+", executable) is not None, "Invalid CFBundleExecutable")
        entry = archive.getinfo(prefix + executable)
        mode = entry.external_attr >> 16
        require(stat.S_ISREG(mode) and mode & stat.S_IXUSR != 0, "App executable lacks executable permissions")
        verify_macho(archive.read(entry), min_os)
        privacy = {key: value for key, value in info.items() if key.endswith("UsageDescription")}
        for key in ("NSFaceIDUsageDescription", "NSLocalNetworkUsageDescription"):
            require(isinstance(privacy.get(key), str) and bool(privacy[key].strip()), f"Missing {key}")
        require(info.get("UIFileSharingEnabled") is False and info.get("LSSupportsOpeningDocumentsInPlace") is False,
                "The workspace must stay inside the app")
        require(info.get("ITSAppUsesNonExemptEncryption") is False, "Unexpected encryption declaration")
        version = info.get("CFBundleShortVersionString", "")
        build = info.get("CFBundleVersion", "")
        require(re.fullmatch(r"\d+\.\d+\.\d+", version) and re.fullmatch(r"\d+", build), "Invalid app version or build number")
        files = [{"path": entry.filename, "bytes": entry.file_size, "compressedBytes": entry.compress_size}
                 for entry in entries if not entry.is_dir()]
    with path.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    return {
        "name": info["CFBundleDisplayName"], "bundleIdentifier": info["CFBundleIdentifier"],
        "version": version, "build": build, "minOSVersion": min_os, "platform": "iPhoneOS", "architecture": "arm64",
        "file": path.name, "size": path.stat().st_size, "sha256": digest, "privacy": privacy,
        "uncompressedBytes": sum(file["bytes"] for file in files), "files": files,
    }


def source(report, repo, ref):
    tag = "v" + report["version"]
    return {
        "name": "DS Bot iOS Standalone",
        "identifier": "io.github.dsbot.ios.standalone.source",
        "apps": [{
            "name": report["name"],
            "bundleIdentifier": report["bundleIdentifier"],
            "developerName": "DS Bot Standalone Contributors",
            "subtitle": "Swift 原生聊天与端侧工具",
            "localizedDescription": "原生 iOS 应用，直连 DeepSeek 或兼容模型服务，支持流式对话、端侧工具和 Remote MCP。",
            "iconURL": f"https://raw.githubusercontent.com/{repo}/{ref}/ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
            "tintColor": "#2563EB",
            "versions": [{
                "version": report["version"],
                "date": datetime.now(timezone.utc).date().isoformat(),
                "localizedDescription": "Swift 原生引擎、流式对话、调用审批和端侧脚本限制。",
                "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/{report['file']}",
                "size": report["size"],
                "sha256": report["sha256"],
                "minOSVersion": report["minOSVersion"],
            }],
            "appPermissions": {"entitlements": [], "privacy": report["privacy"]},
        }],
    }


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--release-dir", type=Path)
    parser.add_argument("--repo")
    parser.add_argument("--commit")
    options = parser.parse_args()
    try:
        report = inspect(options.ipa)
        if options.release_dir:
            name = f"DS-Bot-iOS-Standalone-v{report['version']}-unsigned.ipa"
            require(options.ipa.name == name, f"Expected candidate filename {name}")
            require(re.fullmatch(r"[^/]+/[^/]+", options.repo or "") is not None, "Expected --repo owner/name")
            require(re.fullmatch(r"[a-f0-9]{40}", options.commit or "") is not None, "Expected a full --commit SHA")
            report["commit"] = options.commit
            output = options.release_dir
            output.mkdir(parents=True, exist_ok=True)
            write_json(output / "ipa-report.json", report)
            write_json(output / "source.json", source(report, options.repo, options.commit))
            (output / "SHA256SUMS.txt").write_text(f"{report['sha256']}  {report['file']}\n", encoding="utf-8")
        print(json.dumps(report, indent=2, ensure_ascii=False))
    except (BadZipFile, AttributeError, KeyError, OSError, TypeError, ValueError, struct.error, plistlib.InvalidFileException) as error:
        parser.exit(1, f"IPA verification failed: {error}\n")


if __name__ == "__main__":
    main()
