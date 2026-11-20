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


def verify_macho(data, min_os, *, file_type=2, platform=2, required_load=None, label="Mach-O"):
    require(len(data) >= 32, "Truncated Mach-O header")
    magic, cpu, subtype, actual_file_type, count, commands_size, _, _ = struct.unpack_from("<8I", data)
    require((magic, cpu, subtype & 0xFFFFFF, actual_file_type) == (0xFEEDFACF, 0x0100000C, 0, file_type),
            f"Expected a single generic arm64 {label}")
    end = 32 + commands_size
    require(end <= len(data) and count <= commands_size // 8, "Truncated Mach-O load commands")
    offset = 32
    platforms = []
    loads = []
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and size % 8 == 0 and offset + size <= end, "Invalid Mach-O load command")
        require(command != 0x1D, "Mach-O still contains a code signature")
        if command == 0x32:
            require(size >= 24, "Invalid Mach-O build version")
            build_platform, version = struct.unpack_from("<II", data, offset + 8)
            platforms.append((build_platform, version))
        if command in (0xC, 0x18, 0x1F, 0x20):
            require(size >= 24, "Invalid Mach-O dylib load command")
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            require(8 <= name_offset < size, "Invalid Mach-O dylib path offset")
            raw_name = data[offset + name_offset:offset + size].split(b"\0", 1)[0]
            loads.append(raw_name.decode("utf-8", errors="strict"))
        offset += size
    require(offset == end, "Invalid Mach-O load command lengths")
    digits = [int(part) for part in min_os.split(".")]
    major, minor, patch = (digits + [0, 0])[:3]
    require(platforms == [(platform, (major << 16) | (minor << 8) | patch)],
            f"Expected an iPhoneOS binary with deployment target {min_os}")
    if required_load:
        require(required_load in loads, f"{label} does not load {required_load}")


REQUIRED_DSH_PACKAGES = {
    "@deepseek-ai/cordis": "4.1.0",
    "@deepseek-ai/dsh-agent": "0.2.2-rc.5",
    "@deepseek-ai/dsh-agent-loop": "0.2.2-rc.5",
    "@deepseek-ai/dsh-llm": "0.2.2-rc.5",
    "@deepseek-ai/dsh-llm-deepseek": "0.2.2-rc.5",
    "@deepseek-ai/dsh-llm-deepseek-api-key": "0.2.2-rc.5",
    "@deepseek-ai/dsh-session": "0.2.2-rc.5",
    "@deepseek-ai/dsh-session-persistence": "0.2.2-rc.5",
    "@deepseek-ai/dsh-session-projection": "0.2.2-rc.5",
    "@deepseek-ai/dsh-system-prompt": "0.2.2-rc.5",
    "@deepseek-ai/dsh-tools": "0.2.2-rc.5",
    "@deepseek-ai/dsh-tool-executor-native": "0.2.2-rc.5",
    "@deepseek-ai/dsh-app-boot": "0.2.2-rc.5",
    "@deepseek-ai/dsh-official-bundles": "0.2.2-rc.5",
    "@deepseek-ai/dsh-http-proxy": "0.2.2-rc.5",
    "@deepseek-ai/dsh-cmdline": "0.2.2-rc.5",
}
MINIMUM_RELEASE_NODE_VERSION = (24, 22, 3)


def verify_runtime(archive, prefix, names):
    runtime_path = prefix + "DSHRuntime/runtime-manifest.json"
    package_path = prefix + "DSHRuntime/package.json"
    lock_path = prefix + "DSHRuntime/package-lock.json"
    notices_path = prefix + "DSHRuntime/THIRD-PARTY-NOTICES.txt"
    supervisor_path = prefix + "DSHRuntime/ios-supervisor.mjs"
    entry_path = prefix + "DSHRuntime/dsh-ios-entry.mjs"
    plugin_manager_path = prefix + "DSHRuntime/ios-plugin-manager.mjs"
    persistence_path = prefix + "DSHRuntime/sqlite-session-persistence.mjs"
    protocol_path = prefix + "DSHRuntime/ipc-protocol.mjs"
    profile_boot_entry = prefix + "DSHRuntime/vendor/dsh-profile-boot/lib/profile-boot.js"
    profile_boot_impl = prefix + "DSHRuntime/vendor/dsh-profile-boot/lib/profile-boot-QhDEDXsF.js"
    profile_boot_license = prefix + "DSHRuntime/vendor/dsh-profile-boot/LICENSE"
    app_boot_path = prefix + "DSHRuntime/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js"
    ios_profile_package = prefix + "DSHRuntime/node_modules/@dsbot/dsh-ios-profile/package.json"
    ios_profile_patch = prefix + "DSHRuntime/node_modules/@dsbot/dsh-ios-profile/cordis.patch.yml"
    ios_host_package = prefix + "DSHRuntime/node_modules/@dsbot/dsh-ios-host/package.json"
    ios_host_files = [prefix + "DSHRuntime/node_modules/@dsbot/dsh-ios-host/" + name
                      for name in ["index.mjs", "credentials.mjs", "session-persistence.mjs", "native-tools.mjs"]]
    framework_root = prefix + "Frameworks/NodeMobile.framework/"
    framework_binary_path = framework_root + "NodeMobile"
    for required in [runtime_path, package_path, lock_path, notices_path, supervisor_path, entry_path, plugin_manager_path,
                     persistence_path, protocol_path, profile_boot_entry, profile_boot_impl, profile_boot_license,
                     app_boot_path, ios_profile_package, ios_profile_patch, ios_host_package, framework_binary_path,
                     framework_root + "Info.plist", prefix + "NodeMobile-LICENSE.txt"]:
        require(required in names and archive.getinfo(required).file_size > 0, f"Missing embedded runtime component: {required}")
    for required in ios_host_files:
        require(required in names and archive.getinfo(required).file_size > 0, f"Missing iOS profile adapter module: {required}")
    manifest = json.loads(archive.read(runtime_path))
    require(manifest.get("dshVersion") == "0.2.2-rc.5", "Expected the exact DSH 0.2.2-rc.5 core")
    require(manifest.get("dshSourceCommit") == "9c2670d3bce5275e0d1610272958121af87787bb", "Unexpected DSH upstream source commit")
    require(manifest.get("nodeMinimumVersion") == "24.9.0", "Unexpected DSH minimum Node version")
    require(manifest.get("nativePersistence") == "node:sqlite DatabaseSync, WAL, synchronous=FULL", "Missing the native DSH SQLite persistence implementation")
    boot = manifest.get("officialProfileBoot", {})
    require(manifest.get("launchLifecycle") == "official @deepseek-ai/dsh/profile-boot runProfile() from 0.2.2-rc.5",
            "The iOS runtime does not use the official DSH profile boot lifecycle")
    require(boot.get("npmPackage") == "@deepseek-ai/dsh@0.2.2-rc.5" and boot.get("export") == "./profile-boot"
            and boot.get("desktopDependenciesExcluded") is True and boot.get("license") == "MIT",
            "The vendored profile boot must come from the exact official DSH subpath, without the desktop umbrella graph")
    require(hashlib.sha256(archive.read(profile_boot_entry)).hexdigest() == boot.get("entrySha256"),
            "Official DSH profile boot entry digest mismatch")
    require(hashlib.sha256(archive.read(profile_boot_impl)).hexdigest() == boot.get("implementationSha256"),
            "Official DSH profile boot implementation digest mismatch")
    profile = manifest.get("iosProfile", {})
    require(profile.get("name") == "dsbot-ios" and profile.get("bundle") == "@dsbot/dsh-ios-profile",
            "The runtime does not declare its dedicated iOS profile")
    require(manifest.get("launchLifecycle") and "runProfile()" in manifest.get("launchLifecycle"),
            "Missing official DSH profile lifecycle declaration")
    app_boot_bytes = archive.read(app_boot_path)
    require(b"DS_BOT_IOS_HOST" in app_boot_bytes and b"platforms.includes(\"ios\")" in app_boot_bytes,
            "The official profile loader does not include the explicit iOS platform admission shim")
    platform_patch = manifest.get("iosPlatformLoaderPatch", {})
    require(platform_patch.get("package") == "@deepseek-ai/dsh-app-boot@0.2.2-rc.5"
            and platform_patch.get("mapsIosHostToDarwinBundleDeclarations") is True
            and hashlib.sha256(app_boot_bytes).hexdigest() == platform_patch.get("sha256"),
            "The exact rc.5 iOS platform compatibility patch is missing or has changed")
    profile_manifest = json.loads(archive.read(ios_profile_package))
    require(profile_manifest.get("name") == "@dsbot/dsh-ios-profile"
            and profile_manifest.get("dsh", {}).get("bundle", {}).get("patch") == "./cordis.patch.yml",
            "The dedicated iOS profile is not an official DSH bundle")
    profile_patch = archive.read(ios_profile_patch)
    for name in [b"@deepseek-ai/dsh-agent", b"@deepseek-ai/dsh-agent-loop", b"@deepseek-ai/dsh-session",
                 b"@deepseek-ai/dsh-session-projection", b"@deepseek-ai/dsh-llm-deepseek-api-key",
                 b"@dsbot/dsh-ios-host/native-tools", b"@dsbot/dsh-ios-host/session-persistence"]:
        require(name in profile_patch, f"Dedicated iOS DSH profile is missing {name.decode()}")
    host_manifest = json.loads(archive.read(ios_host_package))
    require(host_manifest.get("name") == "@dsbot/dsh-ios-host", "Missing the app-owned iOS adapter plugin package")
    require(re.fullmatch(r"[a-f0-9]{64}", manifest.get("packageLockSha256", "")) is not None, "Missing DSH package lock digest")
    lock_bytes = archive.read(lock_path)
    require(hashlib.sha256(lock_bytes).hexdigest() == manifest["packageLockSha256"], "DSH package lock digest mismatch")
    top_level = manifest.get("topLevelPackages", {})
    package_manifest = json.loads(archive.read(package_path))
    lock = json.loads(lock_bytes)
    require(package_manifest.get("dependencies") == top_level
            and lock.get("packages", {}).get("", {}).get("dependencies") == top_level,
            "Embedded DSH manifest, package.json, and lockfile dependencies do not match")
    require(top_level.get("@dsbot/dsh-ios-profile") == "file:./ios-profile-package"
            and top_level.get("@dsbot/dsh-ios-host") == "file:./ios-host-package",
            "The application-owned iOS profile and adapters are not pinned into the runtime graph")
    for package, version in REQUIRED_DSH_PACKAGES.items():
        require(top_level.get(package) == version, f"Missing pinned DSH dependency {package}@{version}")
    dsh_packages = {package: version for package, version in top_level.items()
                     if package.startswith("@deepseek-ai/dsh-")}
    require(dsh_packages and all(version == "0.2.2-rc.5" for version in dsh_packages.values()),
            "Every direct DSH package must be pinned to 0.2.2-rc.5")
    for package, version in dsh_packages.items():
        package_path = prefix + "DSHRuntime/node_modules/" + package + "/package.json"
        require(package_path in names, f"DSH package is absent from the IPA: {package}")
        metadata = json.loads(archive.read(package_path))
        require(metadata.get("version") == version, f"Embedded package version mismatch: {package}")
    require("@deepseek-ai/dsh" not in top_level and "@deepseek-ai/dsh-base" not in top_level,
            "The full desktop DSH umbrella/base profile must not be embedded")
    for desktop_package in ["@deepseek-ai/dsh", "@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]:
        require(prefix + "DSHRuntime/node_modules/" + desktop_package + "/package.json" not in names,
                f"The desktop bundle {desktop_package} must not be embedded")
    forbidden_packages = [
        "@deepseek-ai/dsh", "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app", "@deepseek-ai/dsh-web-frontend",
        "@deepseek-ai/dsh-shell", "@deepseek-ai/dsh-terminal",
        "@deepseek-ai/dsh-cordis-client-runner", "@deepseek-ai/dsh-cordis-host-runner",
        "@deepseek-ai/dsh-experimental-terminal-bundle", "@deepseek-ai/dsh-cua-bundle",
    ]
    runtime_files = [name for name in names if name.startswith(prefix + "DSHRuntime/")]
    for package in forbidden_packages:
        marker = "/node_modules/" + package + "/package.json"
        require(not any(marker in name for name in runtime_files),
                f"Desktop DSH package {package} must not be embedded at any dependency depth")
    require(not any("/nodejs-project/" in name for name in names),
            "The legacy desktop Node project must not be embedded")
    require(not any("/Frameworks/Python.framework/" in name or "/Frameworks/FFmpeg.framework/" in name
                    for name in names),
            "The native iOS runtime must not carry the legacy Python or FFmpeg frameworks")
    enabled = set(manifest.get("enabledUpstreamPlugins", []))
    require({"dsh-agent", "dsh-agent-loop", "dsh-session",
             "dsh-session-projection", "dsh-llm", "dsh-llm-deepseek-api-key",
             "dsh-system-prompt", "dsh-tools", "dsh-tool-executor-native"}.issubset(enabled),
            "The runtime manifest does not declare the required upstream DSH core plugins")
    host_adapters = set(manifest.get("iosHostAdapters", []))
    require({"DSH SQLite SessionPersistence backed by node:sqlite",
             "iOS Keychain credentials provider",
             "DSH native tools bridged to iOS capabilities",
             "official DSH profile-boot runProfile lifecycle",
             "iOS profile bundle source discovery, install, enable, disable, and remove"}.issubset(host_adapters),
            "The runtime manifest does not declare the iOS host adapters")
    plugin_sources = manifest.get("pluginSources", {})
    require(plugin_sources.get("indexFormat") == 1
            and len(plugin_sources.get("defaultSources", [])) >= 2
            and "SHA-512" in plugin_sources.get("installer", "")
            and "no lifecycle scripts" in plugin_sources.get("installer", ""),
            "The iOS profile does not declare its constrained DSH index and package installer")
    require({"dsh-base", "dsh-web-app", "dsh-shell", "dsh-terminal"}.issubset(
                set(manifest.get("excludedCapabilities", []))),
            "The iOS profile must explicitly exclude the desktop bundles")

    node = manifest.get("node")
    require(isinstance(node, dict) and re.fullmatch(r"\d+\.\d+\.\d+", node.get("version", "")) is not None,
            "Unexpected or missing NodeMobile runtime version")
    require(node.get("minimumReleaseVersion") == ".".join(str(part) for part in MINIMUM_RELEASE_NODE_VERSION),
            "Unexpected NodeMobile release security floor")
    node_version = tuple(int(part) for part in node["version"].split("."))
    require(node_version >= (24, 9, 0), "NodeMobile is below the DSH runtime minimum Node version")
    require(type(node.get("releaseEligible")) is bool and type(manifest.get("releaseEligible")) is bool,
            "NodeMobile release eligibility flags must be booleans")
    node_release_eligible = node.get("releaseEligible") is True
    require(manifest.get("releaseEligible") is node_release_eligible,
            "The runtime release gate must match the NodeMobile release gate")
    if node_release_eligible:
        require(node_version >= MINIMUM_RELEASE_NODE_VERSION,
                "NodeMobile is marked release eligible below the current Node security floor")
    else:
        require(isinstance(node.get("releaseBlocker"), str) and bool(node["releaseBlocker"].strip()),
                "A preview NodeMobile binary must state its release blocker")
    require(node.get("devicePlatform") == "iPhoneOS" and node.get("deviceArchitecture") == "arm64",
            "NodeMobile must be an iPhoneOS arm64 binary")
    binary = archive.read(framework_binary_path)
    require(hashlib.sha256(binary).hexdigest() == node.get("deviceBinarySha256"), "Embedded NodeMobile binary digest mismatch")
    framework_info = plistlib.loads(archive.read(framework_root + "Info.plist"))
    require(framework_info.get("CFBundlePackageType") == "FMWK" and framework_info.get("CFBundleExecutable") == "NodeMobile",
            "Unexpected embedded NodeMobile framework metadata")
    require(framework_info.get("MinimumOSVersion") == "14.0", "Unexpected NodeMobile deployment target")
    verify_macho(binary, "14.0", file_type=6, platform=2, label="NodeMobile dynamic library")

    framework_entries = {name for name in names if "/Frameworks/" in name and name != prefix + "Frameworks/"}
    require(framework_entries and all("/Frameworks/NodeMobile.framework/" in name for name in framework_entries),
            "Only the NodeMobile.framework may be embedded")
    for name in names:
        if name.endswith((".node", ".dylib", ".so", ".wasm")):
            require(name.startswith(framework_root), f"Unexpected native or WebAssembly runtime component: {name}")
    return manifest


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
            require(not {"_CodeSignature", "embedded.mobileprovision", "SC_Info", ".DS_Store", "KernelAssets",
                         "PlugIns", "kernel-manifest.json"}.intersection(parts), f"Unexpected payload entry: {name}")
            require(not name.endswith(".xctest"), f"Unexpected executable component: {name}")
            if "Frameworks" in parts:
                framework_index = parts.index("Frameworks")
                framework_dir = entry.is_dir() and name.rstrip("/").endswith("/Frameworks")
                require(framework_dir or (len(parts) > framework_index + 1 and parts[framework_index + 1] == "NodeMobile.framework"),
                        f"Unexpected framework component: {name}")
        require(archive.testzip() is None, "ZIP CRC verification failed")
        app_roots = {PurePosixPath(name).parts[1] for name in names if len(PurePosixPath(name).parts) > 1}
        require(len(app_roots) == 1 and next(iter(app_roots)).endswith(".app"), "Expected exactly one Payload/*.app")
        prefix = "Payload/" + next(iter(app_roots)) + "/"
        for required in ["Info.plist", "Assets.car", "QuickJS-LICENSE.txt", "DSHRuntime/runtime-manifest.json"]:
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
        runtime = verify_runtime(archive, prefix, names)
        verify_macho(archive.read(entry), min_os, required_load="@rpath/NodeMobile.framework/NodeMobile")
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
    def component_size(predicate):
        selected = [item for item in files if predicate(item["path"])]
        return {
            "files": len(selected),
            "uncompressedBytes": sum(item["bytes"] for item in selected),
            "compressedBytes": sum(item["compressedBytes"] for item in selected),
        }

    component_sizes = {
        "appExecutable": component_size(lambda name: name == prefix + executable),
        "nodeMobileFramework": component_size(lambda name: "/Frameworks/NodeMobile.framework/" in name),
        "dshRuntime": component_size(lambda name: "/DSHRuntime/" in name),
        "assets": component_size(lambda name: name == prefix + "Assets.car"),
    }
    with path.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    release_eligible = runtime.get("releaseEligible") is True
    release_blockers = [] if release_eligible else [runtime["node"]["releaseBlocker"]]
    return {
        "name": info["CFBundleDisplayName"], "bundleIdentifier": info["CFBundleIdentifier"],
        "version": version, "build": build, "minOSVersion": min_os, "platform": "iPhoneOS", "architecture": "arm64",
        "file": path.name, "size": path.stat().st_size, "sha256": digest, "privacy": privacy,
        "runtime": runtime,
        "releaseEligible": release_eligible,
        "releaseBlockers": release_blockers,
        "requiredDeviceAcceptance": "Physical iPhone install, upgrade, chat, cancellation, approval, and rejection validation.",
        "uncompressedBytes": sum(file["bytes"] for file in files), "componentSizes": component_sizes, "files": files,
    }


def source(report, repo, ref):
    tag = "v" + report["version"]
    node_release_status = ("NodeMobile meets the configured Node security floor; re-signed device acceptance is still required."
                          if report["releaseEligible"] else report["runtime"]["node"]["releaseBlocker"])
    return {
        "name": "DS Bot iOS Standalone",
        "identifier": "io.github.dsbot.ios.standalone.source",
        "apps": [{
            "name": report["name"],
            "bundleIdentifier": report["bundleIdentifier"],
            "developerName": "DS Bot Standalone Contributors",
            "subtitle": "内嵌 DSH 0.2.2-rc.5 候选",
            "localizedDescription": f"内嵌 Node.js 与 DeepSeek Harness Core 0.2.2-rc.5，包含事件日志会话存储和原生 iOS 工具桥。{node_release_status}",
            "iconURL": f"https://raw.githubusercontent.com/{repo}/{ref}/ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
            "tintColor": "#2563EB",
            "versions": [{
                "version": report["version"],
                "date": datetime.now(timezone.utc).date().isoformat(),
                "localizedDescription": f"Node.js + DSH 0.2.2-rc.5 内嵌运行候选。{node_release_status}",
                "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/{report['file']}",
                "size": report["size"],
                "sha256": report["sha256"],
                "minOSVersion": report["minOSVersion"],
                "releaseEligible": report["releaseEligible"],
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
