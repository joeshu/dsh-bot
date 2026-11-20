#!/usr/bin/env python3
"""Stage the lockfile-pinned upstream DSH core beside the NodeMobile app."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "kernel" / "runtime"
DESTINATION = ROOT / "ios" / "Sources" / "Resources" / "DSHRuntime"
FILES = {
    "package.json": SOURCE / "package.json",
    "package-lock.json": SOURCE / "package-lock.json",
    "ios-supervisor.mjs": SOURCE / "ios-supervisor.mjs",
    "dsh-ios-entry.mjs": SOURCE / "dsh-ios-entry.mjs",
    "ios-plugin-manager.mjs": SOURCE / "ios-plugin-manager.mjs",
    "sqlite-session-persistence.mjs": SOURCE / "sqlite-session-persistence.mjs",
    "ipc-protocol.mjs": ROOT / "kernel" / "src" / "ipc-protocol.mjs",
}
UPSTREAM_COMMIT = "9c2670d3bce5275e0d1610272958121af87787bb"
IOS_PROFILE_BUNDLE = "@dsbot/dsh-ios-profile"
PROFILE_BOOT_ENTRY = "vendor/dsh-profile-boot/lib/profile-boot.js"
PROFILE_BOOT_IMPLEMENTATION = "vendor/dsh-profile-boot/lib/profile-boot-QhDEDXsF.js"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def add_ios_platform_to_official_profile_loader(path):
    source = path.read_text(encoding="utf-8")
    if "DS_BOT_IOS_HOST" in source:
        return
    platform_marker = '\t"android",\n'
    platform_replacement = platform_marker + '\t"ios",\n'
    if source.count(platform_marker) != 1:
        raise SystemExit("Unexpected dsh-app-boot platform table; review the iOS compatibility patch")
    source = source.replace(platform_marker, platform_replacement, 1)
    admission = 'if (!platforms.includes(platform) && !(platforms.includes("wsl") && isWsl({'
    ios_admission = ('const iosHost = process.env.DS_BOT_IOS_HOST === "1";\n'
                    '\tif (!platforms.includes(platform) && !(iosHost && (platforms.includes("ios") || platforms.includes("darwin"))) && !(platforms.includes("wsl") && isWsl({')
    if source.count(admission) != 1:
        raise SystemExit("Unexpected dsh-app-boot platform admission; review the iOS compatibility patch")
    resolver = 'const addon = createRequire(import.meta.url)("node-addon-require-builtin");'
    ios_resolver = ('const require = createRequire(import.meta.url);\n'
                    '\tconst addon = process.env.DS_BOT_IOS_HOST === "1" && process.execArgv.includes("--expose-internals")\n'
                    '\t\t? { requireBuiltin: require } : require("node-addon-require-builtin");')
    if source.count(resolver) != 1:
        raise SystemExit("Unexpected dsh-app-boot native resolver; review the iOS compatibility patch")
    source = source.replace(resolver, ios_resolver, 1)
    path.write_text(source.replace(admission, ios_admission, 1), encoding="utf-8")


def main():
    lockfile = SOURCE / "package-lock.json"
    node_modules = SOURCE / "node_modules"
    if not lockfile.is_file() or not node_modules.is_dir():
        raise SystemExit("Install the pinned runtime dependencies with npm ci before staging")
    for name, source in FILES.items():
        if not source.is_file():
            raise SystemExit(f"Missing DSH runtime input: {source}")
    shutil.rmtree(DESTINATION, ignore_errors=True)
    DESTINATION.mkdir(parents=True)
    for name, source in FILES.items():
        shutil.copy2(source, DESTINATION / name)
    shutil.copytree(node_modules, DESTINATION / "node_modules", ignore=shutil.ignore_patterns("*.map", ".DS_Store"))
    vendor_source = SOURCE / "vendor" / "dsh-profile-boot"
    vendor_destination = DESTINATION / "vendor" / "dsh-profile-boot"
    vendor_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(vendor_source, vendor_destination, ignore=shutil.ignore_patterns("*.map", ".DS_Store"))
    profile_loader = DESTINATION / "node_modules" / "@deepseek-ai" / "dsh-app-boot" / "lib" / "index.js"
    add_ios_platform_to_official_profile_loader(profile_loader)

    package = json.loads((SOURCE / "package.json").read_text(encoding="utf-8"))
    lock = json.loads(lockfile.read_text(encoding="utf-8"))
    manifest = {
        "schemaVersion": 1,
        "engine": "DeepSeek Harness Core",
        "dshVersion": "0.2.2-rc.5",
        "dshRepository": "https://github.com/deepseek-ai/deepseek-harness",
        "dshSourceCommit": UPSTREAM_COMMIT,
        "launchLifecycle": "official @deepseek-ai/dsh/profile-boot runProfile() from 0.2.2-rc.5",
        "officialProfileBoot": {
            "npmPackage": "@deepseek-ai/dsh@0.2.2-rc.5",
            "export": "./profile-boot",
            "entry": PROFILE_BOOT_ENTRY,
            "entrySha256": digest(vendor_destination / "lib" / "profile-boot.js"),
            "implementation": PROFILE_BOOT_IMPLEMENTATION,
            "implementationSha256": digest(vendor_destination / "lib" / "profile-boot-QhDEDXsF.js"),
            "license": "MIT",
            "desktopDependenciesExcluded": True,
        },
        "iosPlatformLoaderPatch": {
            "package": "@deepseek-ai/dsh-app-boot@0.2.2-rc.5",
            "file": "node_modules/@deepseek-ai/dsh-app-boot/lib/index.js",
            "sha256": digest(profile_loader),
            "mapsIosHostToDarwinBundleDeclarations": True,
        },
        "iosProfile": {
            "name": "dsbot-ios",
            "bundle": IOS_PROFILE_BUNDLE,
            "directory": "$DSH_HOME/profiles/dsbot-ios",
            "composition": "Profile Loader rows from ios-profile-package/cordis.patch.yml",
        },
        "nodeMinimumVersion": "24.9.0",
        "node": None,
        "packageLockSha256": digest(lockfile),
        "packageManager": package.get("packageManager", f"npm (lockfile v{lock.get('lockfileVersion')})"),
        "topLevelPackages": package["dependencies"],
        "enabledUpstreamPlugins": [
            "dsh-session", "dsh-session-projection",
            "dsh-llm", "dsh-llm-deepseek-api-key", "dsh-system-prompt", "dsh-tools",
            "dsh-tool-executor-native", "dsh-agent", "dsh-agent-loop",
            "dsh-web", "dsh-fs-local", "dsh-working-directory", "dsh-subagent",
            "dsh-subagent-spawn-in-process", "dsh-tool-subagent",
        ],
        "iosHostAdapters": [
            "official DSH profile-boot runProfile lifecycle",
            "DSH SQLite SessionPersistence backed by node:sqlite",
            "iOS Keychain credentials provider",
            "DSH native tools bridged to iOS capabilities",
            "iOS profile bundle source discovery, install, enable, disable, and remove",
        ],
        "nativePersistence": "node:sqlite DatabaseSync, WAL, synchronous=FULL",
        "pluginSources": {
            "indexFormat": 1,
            "defaultSources": [
                "https://cdn.jsdelivr.net/npm/dsh-plugin-catalog/index.json",
                "https://api.dshfind.com/market/dsh-index.json",
            ],
            "installer": "exact NPM version, SHA-512 verified tarball, no lifecycle scripts",
            "dependencyPolicy": "all runtime and peer dependencies must already be available in the embedded iOS DSH graph",
            "nativeAddonPolicy": "reject .node, .dylib, .so, .wasm, symlinks, and special files",
        },
        "excludedCapabilities": [
            "@deepseek-ai/dsh desktop umbrella package", "dsh-base", "dsh-web-app",
            "dsh-web-frontend", "dsh-shell", "dsh-terminal", "dsh-cordis-client-runner",
            "dsh-cordis-host-runner", "shell", "desktop", "browser automation",
            "npm lifecycle scripts", "unbundled dependency installation",
        ],
        "releaseEligible": False,
    }
    (DESTINATION / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    notice_lines = [
        "DS Bot iOS embedded runtime third-party components",
        "",
        "The following runtime packages are shipped in DSHRuntime/node_modules.",
        "Their upstream package licenses and notices are retained in each package directory.",
        "",
        "The DSH profile-boot subpath is vendored from @deepseek-ai/dsh 0.2.2-rc.5 (MIT).",
        "The package's desktop CLI dependency graph is not included.",
        "",
    ]
    for name, version in sorted(lock.get("packages", {}).items()):
        if not name.startswith("node_modules/"):
            continue
        package_name = name.removeprefix("node_modules/")
        package_json = DESTINATION / "node_modules" / package_name / "package.json"
        if not package_json.is_file():
            continue
        metadata = json.loads(package_json.read_text(encoding="utf-8"))
        license_name = metadata.get("license", "SEE PACKAGE LICENSE")
        if isinstance(license_name, dict):
            license_name = license_name.get("type", "SEE PACKAGE LICENSE")
        notice_lines.append(f"- {package_name}@{metadata.get('version', version)} — {license_name}")
    (DESTINATION / "THIRD-PARTY-NOTICES.txt").write_text("\n".join(notice_lines) + "\n", encoding="utf-8")
    print(f"Staged DSH {manifest['dshVersion']} with {len(package['dependencies'])} direct pinned packages ({DESTINATION})")


if __name__ == "__main__":
    main()
