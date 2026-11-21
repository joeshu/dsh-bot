#!/usr/bin/env python3
"""Fetch and validate the pinned iOS NodeMobile XCFramework."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
from urllib.request import Request, urlopen
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "24.22.3"
MINIMUM_RELEASE_VERSION = (24, 22, 3)
RELEASE = "nodemobile-v24.22.3"
URL = "https://github.com/joeshu/dsh-bot/releases/download/nodemobile-v24.22.3/nodejs-mobile-ios-24.22.3-dsbot.zip"
ARCHIVE_SHA256 = "ea532ee844518be266f18597b38e3e9485c725d1f2fd195cc7f48007ff6bc32a"
SOURCE_COMMIT = "b5bcc8d8e70f055333cd5efc317e3eb55bf0c9a5"
SECURITY_PATCH_SHA256 = "c04d714db5a861f4934ee6649be9a0ed689138485e1dc975e8ed26cb0ee55f84"
LICENSE_SHA256 = "c373dabed995013e091b1908996a69a1647ef19d400e6c1fd4b7fb06d8bc0f66"
DESTINATION = ROOT / "ios" / "Vendor" / "NodeMobile.xcframework"
LICENSE_DESTINATION = ROOT / "ios" / "Sources" / "Resources" / "NodeMobile-LICENSE.txt"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(path):
    request = Request(URL, headers={"User-Agent": "DSBot-iOS-build/1.0"})
    with urlopen(request, timeout=120) as response, path.open("wb") as output:
        shutil.copyfileobj(response, output)


def main():
    local_archive = os.environ.get("DSBOT_SECURITY_NODE_ARCHIVE")
    version = "24.22.3" if local_archive else VERSION
    expected = os.environ.get("DSBOT_SECURITY_NODE_SHA256") if local_archive else ARCHIVE_SHA256
    archive = Path(local_archive) if local_archive else Path(os.environ.get(
        "DSBOT_RUNTIME_CACHE", Path(tempfile.gettempdir()) / "dsbot-node-mobile"
    )) / f"nodejs-mobile-ios-{RELEASE}.zip"
    if not local_archive and (not archive.is_file() or sha256(archive) != expected):
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.unlink(missing_ok=True)
        print(f"Downloading pinned NodeMobile {VERSION} XCFramework")
        download(archive)
    actual = sha256(archive)
    if actual != expected:
        raise SystemExit(f"NodeMobile archive SHA-256 mismatch: expected {expected}, got {actual}")

    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(archive) as bundle:
        for item in bundle.infolist():
            member = Path(item.filename)
            if member.is_absolute() or ".." in member.parts:
                raise SystemExit(f"Unsafe archive member in NodeMobile asset: {item.filename}")
        # This directory is generated. Remove the old copy before extraction,
        # and move the new directory into place without copying both slices.
        shutil.rmtree(DESTINATION, ignore_errors=True)
        with tempfile.TemporaryDirectory(prefix="node-mobile-", dir=DESTINATION.parent) as temporary:
            extracted = Path(temporary)
            bundle.extractall(extracted)
            frameworks = list(extracted.rglob("NodeMobile.xcframework"))
            if len(frameworks) != 1:
                raise SystemExit("NodeMobile archive is missing its XCFramework")
            frameworks[0].rename(DESTINATION)
            bundled_license = extracted / "NodeMobile-LICENSE.txt"
            if bundled_license.is_file():
                shutil.copyfile(bundled_license, LICENSE_DESTINATION)
        for signature in DESTINATION.rglob("_CodeSignature"):
            shutil.rmtree(signature)

    if not LICENSE_DESTINATION.is_file() or LICENSE_DESTINATION.stat().st_size == 0:
        raise SystemExit("The NodeMobile license must be present")

    binary = DESTINATION / "ios-arm64" / "NodeMobile.framework" / "NodeMobile"
    if not binary.is_file() or not os.access(binary, os.R_OK):
        raise SystemExit("Pinned NodeMobile archive does not contain an iPhoneOS device binary")
    if list(DESTINATION.rglob("_CodeSignature")):
        raise SystemExit("Unsigned IPA inputs must not contain upstream Apple code signatures")
    manifest_path = ROOT / "ios" / "Sources" / "Resources" / "DSHRuntime" / "runtime-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    version_tuple = tuple(int(part) for part in version.split("."))
    release_eligible = version_tuple >= MINIMUM_RELEASE_VERSION
    release_blocker = ""
    if not release_eligible:
        minimum = ".".join(str(part) for part in MINIMUM_RELEASE_VERSION)
        release_blocker = (
            f"This verified mobile binary is Node {version}; the current release security floor is {minimum}. "
            "Rebuild and validate the mobile framework at or above that Node security release before public distribution."
        )
    manifest["node"] = {
        "version": version,
        "minimumReleaseVersion": ".".join(str(part) for part in MINIMUM_RELEASE_VERSION),
        "mobileRelease": "v24.22.3-dsbot-source" if local_archive else RELEASE,
        "mobileSource": "https://github.com/fogtape/nodejs-mobile",
        "mobileSourceCommit": SOURCE_COMMIT,
        "archiveUrl": None if local_archive else URL,
        "securityPatchSha256": SECURITY_PATCH_SHA256,
        "archiveSha256": actual,
        "deviceBinarySha256": sha256(binary),
        "devicePlatform": "iPhoneOS",
        "deviceArchitecture": "arm64",
        "releaseEligible": release_eligible,
        "releaseBlocker": release_blocker,
    }
    manifest["releaseEligible"] = release_eligible
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Prepared NodeMobile {version} ({actual}) at {DESTINATION}")


if __name__ == "__main__":
    main()
