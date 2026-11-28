import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import struct
from tempfile import TemporaryDirectory
import unittest
from zipfile import ZipFile, ZipInfo

SCRIPT = Path(__file__).resolve().parents[1] / "verify-unsigned-ipa.py"
spec = importlib.util.spec_from_file_location("verify_ipa", SCRIPT)
ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ipa)

PACKAGES = {
    "@deepseek-ai/cordis": "4.1.0",
    "@deepseek-ai/dsh-agent": "0.2.2-rc.5",
    "@deepseek-ai/dsh-agent-loop": "0.2.2-rc.5",
    "@deepseek-ai/dsh-llm": "0.2.2-rc.5",
    "@deepseek-ai/dsh-llm-deepseek": "0.2.2-rc.5",
    "@deepseek-ai/dsh-llm-deepseek-api-key": "0.2.2-rc.5",
    "@deepseek-ai/dsh-app-boot": "0.2.2-rc.5",
    "@deepseek-ai/dsh-official-bundles": "0.2.2-rc.5",
    "@deepseek-ai/dsh-http-proxy": "0.2.2-rc.5",
    "@deepseek-ai/dsh-cmdline": "0.2.2-rc.5",
    "@deepseek-ai/dsh-session": "0.2.2-rc.5",
    "@deepseek-ai/dsh-session-persistence": "0.2.2-rc.5",
    "@deepseek-ai/dsh-session-projection": "0.2.2-rc.5",
    "@deepseek-ai/dsh-system-prompt": "0.2.2-rc.5",
    "@deepseek-ai/dsh-tools": "0.2.2-rc.5",
    "@deepseek-ai/dsh-ptc-runtime": "0.2.2-rc.5",
    "@deepseek-ai/dsh-tool-executor-native": "0.2.2-rc.5",
    "@deepseek-ai/dsh-tool-executor-ptc": "0.2.2-rc.5",
    "@deepseek-ai/dsh-jobs": "0.2.2-rc.5",
    "@deepseek-ai/dsh-jobs-local": "0.2.2-rc.5",
    "@deepseek-ai/dsh-tool-jobs": "0.2.2-rc.5",
}
TOP_LEVEL = {
    **PACKAGES,
    "pyodide": "0.29.5",
    "semver": "7.8.5",
    "@dsbot/dsh-ios-profile": "file:./ios-profile-package",
    "@dsbot/dsh-ios-host": "file:./ios-host-package",
}
PYTHON_ARTIFACTS = {
    "pyodide.mjs": b"pyodide loader fixture",
    "pyodide.asm.js": b"pyodide wasm loader fixture",
    "pyodide.asm.wasm": b"pinned wasm fixture",
    "python_stdlib.zip": b"python standard library fixture",
    "pyodide-lock.json": b"pyodide package lock fixture",
    "full/numpy-2.2.5-cp313-cp313-pyemscripten_2025_0_wasm32.whl": b"numpy wheel fixture",
    "LICENSE-PYODIDE-MPL-2.0.txt": b"Pyodide license fixture",
    "LICENSE-NUMPY-BSD-3-CLAUSE.txt": b"NumPy license fixture",
}
PYTHON_ARTIFACT_HASHES = {name: hashlib.sha256(data).hexdigest() for name, data in PYTHON_ARTIFACTS.items()}


def dylib_command(command, name):
    raw = name.encode() + b"\0"
    size = (24 + len(raw) + 7) & ~7
    return struct.pack("<6I", command, size, 24, 0, 0, 0) + raw + b"\0" * (size - 24 - len(raw))


def macho(file_type, platform, minos, extra_commands=b""):
    build = struct.pack("<6I", 0x32, 24, platform, minos, 0, 0)
    commands = build + extra_commands
    header = struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, file_type,
                         1 + (len(extra_commands) > 0), len(commands), 0, 0)
    return header + commands


class IPARegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "DS-Bot-iOS-Standalone-v1.9.0-unsigned.ipa"
        original_artifacts = ipa.PYTHON_RUNTIME_ARTIFACT_SHA256
        ipa.PYTHON_RUNTIME_ARTIFACT_SHA256 = PYTHON_ARTIFACT_HASHES
        self.addCleanup(setattr, ipa, "PYTHON_RUNTIME_ARTIFACT_SHA256", original_artifacts)

    def make_ipa(self, *, platform=2, signature=False, executable=True, extra=None, sharing=False,
                 guest_runtime=False, guest_bad_hash=False):
        node_load = dylib_command(0xC, "@rpath/NodeMobile.framework/NodeMobile")
        app_commands = struct.pack("<6I", 0x32, 24, platform, 0x100400, 0x1A0500, 0) + node_load
        if signature:
            app_commands += struct.pack("<4I", 0x1D, 16, 0, 0)
        app_binary = struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 2, 2 + signature, len(app_commands), 0, 0) + app_commands
        node_binary = macho(6, 2, 0x000E0000, dylib_command(0xD, "@rpath/NodeMobile.framework/NodeMobile"))
        profile_boot_entry_bytes = b"export { runProfile } from './profile-boot-QhDEDXsF.js';"
        profile_boot_impl_bytes = b"export async function runProfile() {}"
        app_boot_bytes = b'DS_BOT_IOS_HOST platforms.includes("ios")'
        lock = json.dumps({
            "name": "@dsbot/dsh-ios-runtime", "lockfileVersion": 3,
            "packages": {
                "": {"dependencies": TOP_LEVEL},
                "node_modules/pyodide": {
                    "version": "0.29.5", "license": "MPL-2.0",
                    "resolved": "https://registry.npmjs.org/pyodide/-/pyodide-0.29.5.tgz",
                    "integrity": "sha512-TkYrUv9m8QmfImADKRmpwZulL48E0uUaBSO+dvRQKyAJc0qh9gu7jn8btyHPh3NZm1r2IH2YrJhIr7Q2B9urAw==",
                },
            },
        }, sort_keys=True).encode()
        runtime = {
            "dshVersion": "0.2.2-rc.5",
            "dshSourceCommit": "9c2670d3bce5275e0d1610272958121af87787bb",
            "nodeMinimumVersion": "24.9.0",
            "nativePersistence": "node:sqlite DatabaseSync, WAL, synchronous=FULL",
            "releaseEligible": False,
            "launchLifecycle": "official @deepseek-ai/dsh/profile-boot runProfile() from 0.2.2-rc.5",
            "officialProfileBoot": {
                "npmPackage": "@deepseek-ai/dsh@0.2.2-rc.5", "export": "./profile-boot",
                "desktopDependenciesExcluded": True, "license": "MIT",
                "entrySha256": hashlib.sha256(profile_boot_entry_bytes).hexdigest(),
                "implementationSha256": hashlib.sha256(profile_boot_impl_bytes).hexdigest(),
            },
            "iosPlatformLoaderPatch": {
                "package": "@deepseek-ai/dsh-app-boot@0.2.2-rc.5",
                "mapsIosHostToDarwinBundleDeclarations": True,
                "sha256": hashlib.sha256(app_boot_bytes).hexdigest(),
            },
            "iosProfile": {"name": "dsbot-ios", "bundle": "@dsbot/dsh-ios-profile"},
            "packageLockSha256": hashlib.sha256(lock).hexdigest(),
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
            "topLevelPackages": TOP_LEVEL,
            "enabledUpstreamPlugins": ["dsh-agent", "dsh-agent-loop", "dsh-session", "dsh-web-app",
                                       "dsh-session-projection", "dsh-llm", "dsh-llm-deepseek-api-key",
                                       "dsh-system-prompt", "dsh-tools", "dsh-tool-executor-native",
                                       "dsh-jobs-local", "dsh-tool-jobs"],
            "webUI": {"application": "@deepseek-ai/dsh-web-app", "frontend": "@deepseek-ai/dsh-web-frontend",
                      "communityPluginPrefix": "dsh-client-ui-"},
            "iosHostAdapters": ["DSH SQLite SessionPersistence backed by node:sqlite",
                                "iOS Keychain credentials provider",
                                "DSH native tools bridged to iOS capabilities",
                                "DSH Web terminal controller routed exclusively to isolated ARM64 Linux guest PTYs",
                                "offline Pyodide Python and NumPy in a bounded, cancellable Worker",
                                "DSH PTC Python provider with full-source approval and bounded nested-tool bridge",
                                "DSH process-local Jobs registry with session-owned offline Python producer and native output controls",
                                "official DSH profile-boot runProfile lifecycle",
                                "iOS profile bundle source discovery, install, enable, disable, and remove"],
            "pythonRuntime": {
                "engine": "Pyodide", "version": "0.29.5", "license": "MPL-2.0",
                "pythonVersion": "3.13.2", "numpyVersion": "2.2.5", "numpyLicense": "BSD-3-Clause",
                "offline": True, "freshInterpreterPerExecution": True,
                "pythonMemoryLimitBytes": 268435456, "maxExecutionSeconds": 45,
                "maxCodeCharacters": 16000, "maxOutputCharacters": 32000,
                "ptc": {
                    "preset": "ptc-python", "executor": "@deepseek-ai/dsh-tool-executor-ptc@0.2.2-rc.5",
                    "language": "python", "programFormat": "function-body", "approval": "full-source-per-run",
                    "retainsState": False, "maxExecutionSeconds": 120, "maxNestedCalls": 60,
                    "maxParallelNestedCalls": 2, "maxBindingBytes": 262144, "maxBindingValueBytes": 96000,
                    "javascriptGlobals": "frozen-null-prototype-host-call-only",
                    "bindingPromise": "prototype-free-awaitable",
                    "directAppFileAccess": False, "networkBindings": False, "processBindings": False,
                    "sandboxEscalation": False,
                },
                "artifacts": PYTHON_ARTIFACT_HASHES,
            },
            "pluginSources": {
                "indexFormat": 1,
                "defaultSources": ["https://example.invalid/dsh-market.json", "https://example.invalid/dshfind.json"],
                "installer": "exact NPM version, SHA-512 verified tarball, no lifecycle scripts",
            },
            "excludedCapabilities": ["dsh-base", "dsh-shell", "dsh-terminal"],
            "node": {"version": "24.22.1", "minimumReleaseVersion": "24.22.3", "releaseEligible": False, "devicePlatform": "iPhoneOS",
                     "deviceArchitecture": "arm64", "deviceBinarySha256": hashlib.sha256(node_binary).hexdigest(),
                     "releaseBlocker": "NodeMobile needs an updated release build."},
        }
        app_info = {
            "CFBundleExecutable": "DSBotStandalone", "CFBundleIdentifier": "io.github.dsbot.ios.standalone",
            "CFBundleDisplayName": "DS Bot", "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "CFBundleVersion": "27", "CFBundleShortVersionString": "1.9.0", "MinimumOSVersion": "16.4",
            "UIDeviceFamily": [1, 2], "UIFileSharingEnabled": sharing, "LSSupportsOpeningDocumentsInPlace": False,
            "ITSAppUsesNonExemptEncryption": False, "NSFaceIDUsageDescription": "Unlock private conversations.",
            "NSLocalNetworkUsageDescription": "Connect to a local service.",
        }
        guest_assets = {}
        if guest_runtime:
            device_binary = macho(6, 2, 0x000F0000)
            simulator_binary = macho(6, 7, 0x000F0000)
            core_name = "qemu-aarch64-softmmu"
            core_path = f"runtime/Frameworks/{core_name}.framework/{core_name}"
            device_sha = hashlib.sha256(device_binary).hexdigest()
            simulator_sha = hashlib.sha256(simulator_binary).hexdigest()
            source_sha = "a" * 64
            device_report = {
                "platform": "iOS device",
                "toolchain": {"sdk": "iphoneos", "minimumIos": "15.0"},
                "qemu": {"guestTarget": "aarch64-softmmu", "accelerator": "TCG threaded interpreter", "hvf": False},
                "source": {"qemuSourceSha256": source_sha},
                "inProcessEntryPoints": {"verified": ["qemu_cleanup", "qemu_init", "qemu_main_loop", "qemu_system_shutdown_request"]},
                "frameworks": [{"name": core_name, "path": core_path, "sha256": device_sha,
                                 "strippedBytes": len(device_binary), "architectures": ["arm64"]}],
                "sizes": {"frameworkPayloadBytes": 4096},
            }
            simulator_report = {
                "platform": "iOS Simulator",
                "toolchain": {"sdk": "iphonesimulator", "minimumIos": "15.0"},
                "qemu": {"guestTarget": "aarch64-softmmu", "accelerator": "TCG threaded interpreter"},
                "source": {"qemuSourceSha256": source_sha},
                "inProcessEntryPoints": {"verified": ["qemu_cleanup", "qemu_init", "qemu_main_loop", "qemu_system_shutdown_request"]},
                "frameworks": [{"name": core_name, "path": core_path, "sha256": simulator_sha,
                                 "strippedBytes": len(simulator_binary), "architectures": ["arm64"]}],
                "sizes": {"frameworkPayloadBytes": 4096},
            }
            kernel = b"guest kernel fixture"
            rootfs = b"guest rootfs fixture"
            guest_files = {
                "vmlinuz-virt": {"bytes": len(kernel), "sha256": hashlib.sha256(kernel).hexdigest()},
                "rootfs.cpio.gz": {"bytes": len(rootfs), "sha256": hashlib.sha256(rootfs).hexdigest()},
            }
            device_report_bytes = json.dumps(device_report, sort_keys=True).encode()
            simulator_report_bytes = json.dumps(simulator_report, sort_keys=True).encode()
            guest_manifest = {"kernelVersion": "6.18.60", "files": guest_files}
            guest_runtime_manifest = {
                "schema": 1, "architecture": "arm64", "guestKernelVersion": "6.18.60",
                "qemuBuildReportSha256": hashlib.sha256(device_report_bytes).hexdigest(),
                "qemuSimulatorBuildReportSha256": hashlib.sha256(simulator_report_bytes).hexdigest(),
                "guestFiles": guest_files,
                "qemu": {"version": "10.0.12-utm", "guestTarget": "aarch64-softmmu",
                         "accelerator": "TCG threaded interpreter", "framework": core_name,
                         "deviceSHA256": "b" * 64 if guest_bad_hash else device_sha,
                         "simulatorSHA256": simulator_sha, "frameworkPayloadBytes": 4096,
                         "inProcessEntryPoints": ["qemu_cleanup", "qemu_init", "qemu_main_loop", "qemu_system_shutdown_request"],
                         "sourceArchiveSha256": source_sha},
            }
            guest_root = "Payload/DSBotStandalone.app/DSBotGuestRuntime/"
            guest_assets = {
                guest_root + "runtime-manifest.json": json.dumps(guest_runtime_manifest).encode(),
                guest_root + "qemu-build-report.json": device_report_bytes,
                guest_root + "qemu-simulator-build-report.json": simulator_report_bytes,
                guest_root + "manifest.json": json.dumps(guest_manifest).encode(),
                guest_root + "vmlinuz-virt": kernel,
                guest_root + "rootfs.cpio.gz": rootfs,
                guest_root + "THIRD-PARTY-NOTICES.txt": b"Alpine Linux guest license notices",
                guest_root + "THIRD-PARTY-NOTICES-QEMU.md": b"QEMU license notices",
                "Payload/DSBotStandalone.app/Frameworks/" + core_name + ".framework/" + core_name: device_binary,
            }
        base = "Payload/DSBotStandalone.app/"
        framework = base + "Frameworks/NodeMobile.framework/"
        with ZipFile(self.path, "w") as archive:
            executable_entry = ZipInfo(base + "DSBotStandalone")
            executable_entry.create_system = 3
            executable_entry.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
            archive.writestr(executable_entry, app_binary)
            archive.writestr(base + "Info.plist", plistlib.dumps(app_info, fmt=plistlib.FMT_BINARY))
            archive.writestr(base + "Assets.car", b"asset")
            archive.writestr(base + "QuickJS-LICENSE.txt", b"NOTICE")
            archive.writestr(base + "NodeMobile-LICENSE.txt", b"NOTICE")
            archive.writestr(base + "DSHRuntime/runtime-manifest.json", json.dumps(runtime).encode())
            archive.writestr(base + "DSHRuntime/package.json", json.dumps({"dependencies": TOP_LEVEL}).encode())
            archive.writestr(base + "DSHRuntime/package-lock.json", lock)
            archive.writestr(base + "DSHRuntime/THIRD-PARTY-NOTICES.txt",
                             "Pyodide 0.29.5 — MPL-2.0\nNumPy 2.2.5 WebAssembly wheel — BSD-3-Clause\n")
            archive.writestr(base + "DSHRuntime/ios-supervisor.mjs", b"// supervisor")
            archive.writestr(base + "DSHRuntime/dsh-ios-entry.mjs",
                             b"import { mountIOSPythonJobTool } from '@dsbot/dsh-ios-host/ios-python-jobs'; mountIOSPythonJobTool(ctx)")
            archive.writestr(base + "DSHRuntime/ios-plugin-manager.mjs", b"// plugin manager")
            archive.writestr(base + "DSHRuntime/ios-openai-compat-adapter.mjs", b"// compat adapter")
            archive.writestr(base + "DSHRuntime/sqlite-session-persistence.mjs", b"// persistence")
            archive.writestr(base + "DSHRuntime/ipc-protocol.mjs", b"// protocol")
            archive.writestr(base + "DSHRuntime/vendor/dsh-profile-boot/lib/profile-boot.js", profile_boot_entry_bytes)
            archive.writestr(base + "DSHRuntime/vendor/dsh-profile-boot/lib/profile-boot-QhDEDXsF.js", profile_boot_impl_bytes)
            archive.writestr(base + "DSHRuntime/vendor/dsh-profile-boot/LICENSE", b"MIT")
            archive.writestr(base + "DSHRuntime/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js", app_boot_bytes)
            archive.writestr(base + "DSHRuntime/node_modules/@dsbot/dsh-ios-profile/package.json", json.dumps({
                "name": "@dsbot/dsh-ios-profile", "dsh": {"bundle": {"patch": "./cordis.patch.yml"}},
            }).encode())
            archive.writestr(base + "DSHRuntime/node_modules/@dsbot/dsh-ios-profile/cordis.patch.yml",
                             b"@deepseek-ai/dsh-agent @deepseek-ai/dsh-agent-loop @deepseek-ai/dsh-session @deepseek-ai/dsh-session-projection @deepseek-ai/dsh-llm-deepseek-api-key @deepseek-ai/dsh-web-app @deepseek-ai/dsh-jobs-local @deepseek-ai/dsh-tool-jobs @dsbot/dsh-ios-host/native-tools @dsbot/dsh-ios-host/session-persistence @dsbot/dsh-ios-host/ios-subprocess @dsbot/dsh-ios-host/ios-ptc-runtime @dsbot/dsh-ios-host/ios-ptc-executor ptc-python tool/ptc-dispatch")
            archive.writestr(base + "DSHRuntime/node_modules/@dsbot/dsh-ios-host/package.json",
                             json.dumps({"name": "@dsbot/dsh-ios-host", "dependencies": {
                                 "@deepseek-ai/dsh-ptc-runtime": "0.2.2-rc.5",
                                 "@deepseek-ai/dsh-subprocess": "0.2.2-rc.5",
                                 "@deepseek-ai/dsh-tool-executor-ptc": "0.2.2-rc.5",
                             }}).encode())
            archive.writestr(base + "DSHRuntime/node_modules/@deepseek-ai/dsh-subprocess/package.json",
                             json.dumps({"version": "0.2.2-rc.5"}).encode())
            for name in ["index.mjs", "credentials.mjs", "session-persistence.mjs", "native-tools.mjs",
                         "approval.mjs", "ios-python-tool.mjs", "python-execution.mjs", "python-worker.mjs",
                         "python-worker-gate.mjs", "ios-python-jobs.mjs", "ios-ptc-runtime.mjs", "ios-ptc-python-worker.mjs", "ios-ptc-executor.mjs"] + sorted(
                    {item.name for item in (Path(__file__).resolve().parents[2] / "kernel" / "runtime" / "ios-host-package").glob("*.mjs")}
                    - {"index.mjs", "credentials.mjs", "session-persistence.mjs", "native-tools.mjs", "approval.mjs", "ios-python-tool.mjs",
                       "python-execution.mjs", "python-worker.mjs", "python-worker-gate.mjs", "ios-python-jobs.mjs", "ios-ptc-runtime.mjs",
                       "ios-ptc-python-worker.mjs", "ios-ptc-executor.mjs"}):
                archive.writestr(base + "DSHRuntime/node_modules/@dsbot/dsh-ios-host/" + name, b"// adapter")
            for package, version in PACKAGES.items():
                archive.writestr(base + "DSHRuntime/node_modules/" + package + "/package.json", json.dumps({"version": version}).encode())
            for name, data in PYTHON_ARTIFACTS.items():
                archive.writestr(base + "DSHRuntime/python-runtime/" + name, data)
            archive.writestr(base + "Frameworks/", b"")
            archive.writestr(framework + "NodeMobile", node_binary)
            archive.writestr(framework + "Info.plist", plistlib.dumps({
                "CFBundlePackageType": "FMWK", "CFBundleExecutable": "NodeMobile", "MinimumOSVersion": "14.0",
            }))
            for name, data in guest_assets.items():
                archive.writestr(name, data)
            if extra:
                archive.writestr(base + extra, b"unexpected")

    def test_feed_matches_verified_archive(self):
        self.make_ipa()
        report = ipa.inspect(self.path)
        app = ipa.source(report, "joeshu/dsh-bot", "a" * 40)["apps"][0]
        version = app["versions"][0]
        self.assertEqual(report["build"], "27")
        self.assertFalse(report["releaseEligible"])
        self.assertEqual(version["size"], self.path.stat().st_size)
        self.assertEqual(version["sha256"], report["sha256"])
        self.assertEqual(version["releaseEligible"], report["releaseEligible"])
        self.assertEqual(app["appPermissions"]["privacy"], report["privacy"])
        self.assertTrue(app["iconURL"].endswith("/AppIcon.png"))

    def test_accepts_audited_arm64_guest_terminal_runtime(self):
        self.make_ipa(guest_runtime=True)
        report = ipa.inspect(self.path)
        self.assertEqual(report["guestRuntime"]["architecture"], "arm64")
        self.assertEqual(report["guestRuntime"]["guestTarget"], "aarch64-softmmu")
        self.assertGreater(report["componentSizes"]["qemuFrameworks"]["uncompressedBytes"], 0)
        self.assertGreater(report["componentSizes"]["guestRuntime"]["uncompressedBytes"], 0)

    def test_rejects_guest_runtime_framework_digest_mismatch(self):
        self.make_ipa(guest_runtime=True, guest_bad_hash=True)
        with self.assertRaisesRegex(ValueError, "manifest does not match the audited QEMU build"):
            ipa.inspect(self.path)

    def test_rejects_bad_release_inputs(self):
        for fields, message in [
            ({"platform": 7}, "iPhoneOS binary"),
            ({"signature": True}, "code signature"),
            ({"executable": False}, "executable permissions"),
            ({"extra": "KernelAssets/dsh.bundle"}, "Unexpected payload entry"),
            ({"extra": "../other"}, "Invalid archive path"),
            ({"sharing": True}, "workspace must stay inside"),
        ]:
            with self.subTest(fields=fields):
                self.make_ipa(**fields)
                with self.assertRaisesRegex(ValueError, message):
                    ipa.inspect(self.path)


if __name__ == "__main__":
    unittest.main()
