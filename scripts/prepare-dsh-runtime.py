#!/usr/bin/env python3
"""Stage the lockfile-pinned upstream DSH core beside the NodeMobile app."""
import hashlib
import json
from pathlib import Path
import re
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
    "ios-openai-compat-adapter.mjs": SOURCE / "ios-openai-compat-adapter.mjs",
    "sqlite-session-persistence.mjs": SOURCE / "sqlite-session-persistence.mjs",
    "ios-host-package/virtual-terminal-policy.mjs": SOURCE / "ios-host-package" / "virtual-terminal-policy.mjs",
    "ipc-protocol.mjs": ROOT / "kernel" / "runtime" / "ipc-protocol.mjs",
}
UPSTREAM_COMMIT = "9c2670d3bce5275e0d1610272958121af87787bb"
IOS_PROFILE_BUNDLE = "@dsbot/dsh-ios-profile"
PROFILE_BOOT_ENTRY = "vendor/dsh-profile-boot/lib/profile-boot.js"
PROFILE_BOOT_IMPLEMENTATION = "vendor/dsh-profile-boot/lib/profile-boot-QhDEDXsF.js"
PROFILE_PATCH = SOURCE / "ios-profile-package" / "cordis.patch.yml"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def enabled_profile_plugins():
    source = PROFILE_PATCH.read_text(encoding="utf-8")
    names = re.findall(r"^\s+name:\s+['\"]?@deepseek-ai/(dsh-[A-Za-z0-9._-]+)['\"]?\s*$", source, re.MULTILINE)
    if "dsh-web-app" not in names:
        raise SystemExit("The iOS DSH profile must explicitly mount dsh-web-app")
    return list(dict.fromkeys(names))


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


def relax_loopback_cookie_samesite_for_ios_wkwebview(path):
    source = path.read_text(encoding="utf-8")
    if "DS_BOT_IOS_HOST" in source:
        return
    needle = 'const attributes = `${name}=${value}; Max-Age=${String(maxAgeSeconds)}; Path=/; Expires=${new Date(expiresAt).toUTCString()}; HttpOnly; SameSite=Strict`;'
    replacement = 'const sameSite = process.env.DS_BOT_IOS_HOST === "1" ? "Lax" : "Strict";\n\tconst attributes = `${name}=${value}; Max-Age=${String(maxAgeSeconds)}; Path=/; Expires=${new Date(expiresAt).toUTCString()}; HttpOnly; SameSite=${sameSite}`;'
    if source.count(needle) != 1:
        raise SystemExit("Unexpected dsh-client-connection sessionCookie format; review iOS WKWebView SameSite patch")
    path.write_text(source.replace(needle, replacement, 1), encoding="utf-8")


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
        destination = DESTINATION / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    shutil.copytree(
        node_modules,
        DESTINATION / "node_modules",
        ignore=shutil.ignore_patterns(
            "*.map", ".DS_Store", "*.node", "*.dylib", "*.so", "*.so.*", "*.dll", "*.exe", "*.wasm",
            "pyodide", "*.d.ts", "*.d.mts", "*.d.cts", "*.cc", "*.h",
            "sharp-libvips-*", "sharp-linux-*", "sharp-darwin-*", "sharp-win32-*",
            "libreoffice-kit*", "dsh-office-kit",
        ),
    )
    vendor_source = SOURCE / "vendor" / "dsh-profile-boot"
    vendor_destination = DESTINATION / "vendor" / "dsh-profile-boot"
    vendor_destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(vendor_source, vendor_destination, ignore=shutil.ignore_patterns("*.map", ".DS_Store"))
    profile_loader = DESTINATION / "node_modules" / "@deepseek-ai" / "dsh-app-boot" / "lib" / "index.js"
    add_ios_platform_to_official_profile_loader(profile_loader)
    client_connection = DESTINATION / "node_modules" / "@deepseek-ai" / "dsh-client-connection" / "lib" / "index.js"
    relax_loopback_cookie_samesite_for_ios_wkwebview(client_connection)

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
        "enabledUpstreamPlugins": enabled_profile_plugins(),
        "webUI": {
            "server": "@deepseek-ai/dsh-host-webserver",
            "application": "@deepseek-ai/dsh-web-app",
            "frontend": "@deepseek-ai/dsh-web-frontend",
            "embedding": "WKWebView over authenticated 127.0.0.1 ephemeral port",
            "communityPluginPrefix": "dsh-client-ui-",
        },
        "iosHostAdapters": [
            "official DSH profile-boot runProfile lifecycle",
            "DSH SQLite SessionPersistence backed by node:sqlite",
            "iOS Keychain credentials provider",
            "DSH native tools bridged to iOS capabilities",
            "DSH Web terminal controller routed exclusively to isolated ARM64 Linux guest PTYs",
            "iOS profile bundle source discovery, install, enable, disable, and remove",
            "offline Pyodide Python and NumPy in a bounded, cancellable Worker",
            "DSH PTC Python provider with full-source approval and bounded nested-tool bridge",
            "DSH process-local Jobs registry with session-owned offline Python producer and native output controls",
        ],
        "guestTerminal": {
            "architecture": "arm64",
            "guest": "Alpine Linux ARM64 with BusyBox ash and a real devpts-backed PTY",
            "backend": "in-process aarch64-softmmu QEMU TCI, threaded interpreter, guest NIC disabled",
            "bot": "terminal_exec over a fresh per-turn PTY; one-time approval required for every model command",
            "web": "official DSH Web Terminal Controller over the owner-bound subprocess provider",
            "nativeUI": "interactive owner-bound terminal over the same guest PTY broker",
            "maxWebSessions": 4,
            "maxGuestMemoryMiB": 384,
            "guestNetwork": False,
            "hostFilesystemMounted": False,
            "guestDiskPersistent": False,
            "optionalPackageInstaller": False,
        },
        "pythonRuntime": None,
        "backgroundJobs": {
            "registry": "@deepseek-ai/dsh-jobs-local@0.2.2-rc.5",
            "controls": "@deepseek-ai/dsh-tool-jobs@0.2.2-rc.5",
            "producer": "python_job_start",
            "ownerScope": "one native non-private Bot session",
            "maxConcurrentPerSession": 1,
            "maxConcurrentPythonWorkers": 1,
            "maxExecutionSeconds": 120,
            "outputLimitBytes": 131072,
            "retentionBytes": 262144,
            "settledOutputRetentionBytes": 16384,
            "completionDelivery": "wakeup",
            "nativeCompletionDelivery": "defer-tool-jobs-to-next-user-turn",
            "backgroundBehavior": "defer-native-followups-as-inbox-injections-while-suspended",
            "processLocal": True,
            "survivesHostRestart": False,
            "runsWhileIOSAppSuspended": False,
            "directHostFileAccess": False,
            "networkAccess": False,
            "processAccess": False,
        },
        "nativePersistence": "node:sqlite DatabaseSync, WAL, synchronous=FULL",
        "pluginSources": {
            "indexFormat": 1,
            "defaultSources": [
                "https://cdn.jsdelivr.net/npm/dsh-plugin-catalog/index.json",
                "https://api.dshfind.com/market/dsh-index.json",
            ],
            "installer": "exact NPM version, SHA-512 verified tarball, no lifecycle scripts",
            "dependencyPolicy": "all runtime and peer dependencies must already be available in the embedded iOS DSH graph",
            "nativeAddonPolicy": "reject .node, .dylib, .so, unpinned .wasm, symlinks, and special files; embed only the pinned Pyodide Python core WebAssembly asset",
        },
        "excludedCapabilities": [
            "@deepseek-ai/dsh desktop umbrella package", "dsh-base",
            "dsh-shell", "dsh-terminal", "dsh-experimental-terminal-bundle", "dsh-cua-bundle",
            "shell", "desktop automation",
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
    notice_lines.extend([
        "",
        "Embedded offline Python runtime assets under DSHRuntime/python-runtime:",
        "- Pyodide 0.29.5 — MPL-2.0; https://github.com/pyodide/pyodide",
        "- NumPy 2.2.5 WebAssembly wheel — BSD-3-Clause; https://numpy.org/",
        "The full license texts and pinned runtime artifact digests are included in DSHRuntime/python-runtime.",
    ])
    (DESTINATION / "THIRD-PARTY-NOTICES.txt").write_text("\n".join(notice_lines) + "\n", encoding="utf-8")
    print(f"Staged DSH {manifest['dshVersion']} with {len(package['dependencies'])} direct pinned packages ({DESTINATION})")


if __name__ == "__main__":
    main()
