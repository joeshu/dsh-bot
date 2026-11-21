#!/usr/bin/env python3
"""Stage a pinned, offline Pyodide + NumPy runtime into the iOS app bundle."""
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_SOURCE = ROOT / "kernel" / "runtime" / "node_modules" / "pyodide"
DESTINATION = ROOT / "ios" / "Sources" / "Resources" / "DSHRuntime" / "python-runtime"
PYODIDE_VERSION = "0.29.5"
PYODIDE_ASSET_SHA256 = {
    "pyodide.mjs": "510ca14305230018f50c40fb81be673afd68080e70ce7733fcce6600dd6a1714",
    "pyodide.asm.js": "356c42f69e1695397e9d8670bd3c2e678248cde76e18bdae1731e848537b47d7",
    "pyodide.asm.wasm": "54309a5a2cfd757b1f0fdbc9093c92503f7b341500110329d932487183912718",
    "python_stdlib.zip": "831fd1e535084b972f87c6a35275de3d236efd5166f5e77ce89497710635e73c",
    "pyodide-lock.json": "14d2c2dba101277999e17135e653d8f15389ad1437f53eae213bf0c3cdff723d",
}
NUMPY_SHA256 = "800c98edc0c864dfa49f07005680c699b4b42b84eae1f8cb19d35b3634e7f05c"
PYODIDE_LICENSE_SHA256 = "1f256ecad192880510e84ad60474eab7589218784b9a50bc7ceee34c2b91f1d5"
NUMPY_LICENSE_SHA256 = "01fb016849aa427edb1bbbbd55f91c26ca6cadb32a5b20e7f000655dd05b0760"
MAX_WHEEL_BYTES = 32 * 1024 * 1024


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def main():
    package = json.loads((RUNTIME_SOURCE / "package.json").read_text(encoding="utf-8"))
    if package.get("version") != PYODIDE_VERSION or package.get("license") != "MPL-2.0":
        raise SystemExit("The pinned Pyodide runtime package is missing or changed")
    lock_path = RUNTIME_SOURCE / "pyodide-lock.json"
    pyodide_lock = json.loads(lock_path.read_text(encoding="utf-8"))
    if pyodide_lock.get("info", {}).get("python") != "3.13.2":
        raise SystemExit("Unexpected Python version in the pinned Pyodide lockfile")
    numpy = pyodide_lock.get("packages", {}).get("numpy", {})
    wheel_name = numpy.get("file_name")
    if (numpy.get("version") != "2.2.5" or numpy.get("sha256") != NUMPY_SHA256
            or not isinstance(wheel_name, str) or not wheel_name.endswith(".whl")):
        raise SystemExit("Unexpected NumPy wheel metadata in the pinned Pyodide lockfile")

    shutil.rmtree(DESTINATION, ignore_errors=True)
    (DESTINATION / "full").mkdir(parents=True)
    artifacts = {}
    for name, expected in PYODIDE_ASSET_SHA256.items():
        source = RUNTIME_SOURCE / name
        if not source.is_file():
            raise SystemExit(f"Missing pinned Pyodide runtime asset: {source}")
        data = source.read_bytes()
        if sha256_bytes(data) != expected:
            raise SystemExit(f"Pinned Pyodide asset digest mismatch: {name}")
        shutil.copy2(source, DESTINATION / name)
        artifacts[name] = expected

    wheel_url = f"https://cdn.jsdelivr.net/pyodide/v{PYODIDE_VERSION}/full/{wheel_name}"
    request = urllib.request.Request(wheel_url, headers={"User-Agent": "DSBot-iOS-runtime-builder/1"})
    with urllib.request.urlopen(request, timeout=90) as response:
        wheel = response.read(MAX_WHEEL_BYTES + 1)
    if len(wheel) > MAX_WHEEL_BYTES:
        raise SystemExit("The pinned NumPy wheel exceeds the 32 MiB staging limit")
    if sha256_bytes(wheel) != NUMPY_SHA256:
        raise SystemExit("Pinned NumPy wheel digest mismatch")
    wheel_path = DESTINATION / "full" / wheel_name
    wheel_path.write_bytes(wheel)
    with ZipFile(wheel_path) as archive:
        if archive.testzip() is not None:
            raise SystemExit("The NumPy wheel ZIP failed CRC verification")
        metadata_paths = [name for name in archive.namelist() if name.endswith(".dist-info/METADATA")]
        if len(metadata_paths) != 1:
            raise SystemExit("The NumPy wheel has unexpected package metadata")
        metadata = archive.read(metadata_paths[0]).decode("utf-8", errors="strict")
        if "Name: numpy\n" not in metadata or "Version: 2.2.5\n" not in metadata:
            raise SystemExit("The staged wheel is not the expected NumPy 2.2.5 package")
        numpy_licenses = [name for name in archive.namelist() if name.endswith(".dist-info/LICENSE.txt")]
        if len(numpy_licenses) != 1:
            raise SystemExit("The NumPy wheel is missing its license text")
        numpy_license = archive.read(numpy_licenses[0])
    if sha256_bytes(numpy_license) != NUMPY_LICENSE_SHA256:
        raise SystemExit("NumPy license text does not match the pinned wheel")
    (DESTINATION / "LICENSE-NUMPY-BSD-3-CLAUSE.txt").write_bytes(numpy_license)
    artifacts[f"full/{wheel_name}"] = NUMPY_SHA256
    artifacts["LICENSE-NUMPY-BSD-3-CLAUSE.txt"] = NUMPY_LICENSE_SHA256

    license_url = "https://raw.githubusercontent.com/pyodide/pyodide/0.29.5/LICENSE"
    license_request = urllib.request.Request(license_url, headers={"User-Agent": "DSBot-iOS-runtime-builder/1"})
    with urllib.request.urlopen(license_request, timeout=30) as response:
        pyodide_license = response.read(24 * 1024)
    if sha256_bytes(pyodide_license) != PYODIDE_LICENSE_SHA256:
        raise SystemExit("Pyodide MPL-2.0 license text does not match the pinned release")
    (DESTINATION / "LICENSE-PYODIDE-MPL-2.0.txt").write_bytes(pyodide_license)
    artifacts["LICENSE-PYODIDE-MPL-2.0.txt"] = PYODIDE_LICENSE_SHA256

    manifest_path = DESTINATION.parent / "runtime-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["pythonRuntime"] = {
        "engine": "Pyodide",
        "version": PYODIDE_VERSION,
        "license": "MPL-2.0",
        "pythonVersion": pyodide_lock["info"]["python"],
        "numpyVersion": numpy["version"],
        "numpyLicense": "BSD-3-Clause",
        "offline": True,
        "freshInterpreterPerExecution": True,
        "pythonMemoryLimitBytes": 268435456,
        "maxExecutionSeconds": 45,
        "maxCodeCharacters": 16000,
        "maxOutputCharacters": 32000,
        "ptc": {
            "preset": "ptc-python",
            "executor": "@deepseek-ai/dsh-tool-executor-ptc@0.2.2-rc.5",
            "language": "python",
            "programFormat": "function-body",
            "approval": "full-source-per-run",
            "retainsState": False,
            "maxExecutionSeconds": 120,
            "maxNestedCalls": 60,
            "maxParallelNestedCalls": 2,
            "maxBindingBytes": 262144,
            "maxBindingValueBytes": 96000,
            "javascriptGlobals": "frozen-null-prototype-host-call-only",
            "bindingPromise": "prototype-free-awaitable",
            "directAppFileAccess": False,
            "networkBindings": False,
            "processBindings": False,
            "sandboxEscalation": False,
        },
        "artifacts": artifacts,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Staged offline Python {pyodide_lock['info']['python']} + NumPy {numpy['version']} ({DESTINATION})")


if __name__ == "__main__":
    main()
