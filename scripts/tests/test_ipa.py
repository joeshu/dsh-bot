import importlib.util
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


class IPARegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "DS-Bot-iOS-Standalone-v1.8.3-unsigned.ipa"

    def make_ipa(self, *, platform=2, signature=False, executable=True, extra=None, sharing=False):
        commands = struct.pack("<6I", 0x32, 24, platform, 0x100400, 0x1A0500, 0)
        if signature:
            commands += struct.pack("<4I", 0x1D, 16, 0, 0)
        binary = struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 2, 1 + signature, len(commands), 0, 0) + commands
        plist = {
            "CFBundleExecutable": "DSBotStandalone", "CFBundleIdentifier": "io.github.dsbot.ios.standalone",
            "CFBundleDisplayName": "DS Bot", "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "CFBundleVersion": "26", "CFBundleShortVersionString": "1.8.3", "MinimumOSVersion": "16.4",
            "UIDeviceFamily": [1, 2], "UIFileSharingEnabled": sharing, "LSSupportsOpeningDocumentsInPlace": False,
            "ITSAppUsesNonExemptEncryption": False, "NSFaceIDUsageDescription": "Unlock private conversations.",
            "NSLocalNetworkUsageDescription": "Connect to a local service.",
        }
        base = "Payload/DSBotStandalone.app/"
        with ZipFile(self.path, "w") as archive:
            app = ZipInfo(base + "DSBotStandalone")
            app.create_system = 3
            app.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
            archive.writestr(app, binary)
            archive.writestr(base + "Info.plist", plistlib.dumps(plist, fmt=plistlib.FMT_BINARY))
            archive.writestr(base + "Assets.car", b"asset")
            archive.writestr(base + "QuickJS-LICENSE.txt", b"NOTICE")
            if extra:
                archive.writestr(base + extra, b"unexpected")

    def test_feed_matches_verified_archive(self):
        self.make_ipa()
        report = ipa.inspect(self.path)
        app = ipa.source(report, "joeshu/dsh-bot", "a" * 40)["apps"][0]
        version = app["versions"][0]
        self.assertEqual(report["build"], "26")
        self.assertEqual(version["size"], self.path.stat().st_size)
        self.assertEqual(version["sha256"], report["sha256"])
        self.assertEqual(app["appPermissions"]["privacy"], report["privacy"])
        self.assertTrue(app["iconURL"].endswith("/AppIcon.png"))

    def test_rejects_bad_release_inputs(self):
        for fields, message in [
            ({"platform": 7}, "iPhoneOS executable"),
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
