import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "package-qemu-ios-tci.py"
spec = importlib.util.spec_from_file_location("package_qemu_ios_tci", SCRIPT)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class QEMUSourceReferenceTests(unittest.TestCase):
    def make_reference(self, root: Path, *, platform="iOS device") -> Path:
        root.mkdir(parents=True, exist_ok=True)
        report = {
            "platform": platform,
            "source": {
                "utmCommit": package.UTM_COMMIT,
                "qemuSourceSha256": package.QEMU_TARBALL_SHA256,
                "utmSourceSha256": "b" * 64,
            },
        }
        (root / "build-report.json").write_text(json.dumps(report), encoding="utf-8")
        (root / "THIRD-PARTY-NOTICES.md").write_text(
            "This is a separate research build artifact. It is not yet linked into the app.\n"
            "Source archives are in this artifact's `source/` directory.\n",
            encoding="utf-8",
        )
        return root

    def test_reuses_and_relabels_device_source_provenance(self):
        with TemporaryDirectory() as temporary:
            records, utm_hash, notice = package.load_source_reference(
                self.make_reference(Path(temporary) / "device")
            )
        self.assertEqual(records["utmCommit"], package.UTM_COMMIT)
        self.assertEqual(utm_hash, "b" * 64)
        self.assertIn("paired with the iOS device QEMU artifact", notice)
        self.assertIn("paired `qemu-ios-tci-aarch64` artifact's `source/`", notice)

    def test_rejects_simulator_or_unpinned_source_reference(self):
        with TemporaryDirectory() as temporary:
            reference = self.make_reference(Path(temporary) / "simulator", platform="iOS Simulator")
            with self.assertRaisesRegex(SystemExit, "paired iOS device"):
                package.load_source_reference(reference)

            reference = self.make_reference(Path(temporary) / "bad-qemu")
            report_path = reference / "build-report.json"
            report = json.loads(report_path.read_text(encoding="utf-8"))
            report["source"]["qemuSourceSha256"] = "c" * 64
            report_path.write_text(json.dumps(report), encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "QEMU archive hash"):
                package.load_source_reference(reference)


if __name__ == "__main__":
    unittest.main()
