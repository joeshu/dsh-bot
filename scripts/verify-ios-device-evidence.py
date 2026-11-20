#!/usr/bin/env python3
"""Validate a device report supplied on stdin against the candidate identity."""
import argparse
import json
import re
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("commit")
parser.add_argument("unsigned_sha256")
args = parser.parse_args()
required = {
    "cleanInstall", "sameIdentityUpgrade", "offlineColdLaunch", "deepSeekStreaming",
    "cancel", "backgroundResume", "sessionRecovery", "keychainRecovery",
    "toolApproval", "toolDenial", "pluginLifecycle", "pluginFailureRecovery",
}
try:
    report = json.load(sys.stdin)
    if (report["commit"], report["unsignedSha256"]) != (args.commit, args.unsigned_sha256):
        raise ValueError("evidence does not identify the exact candidate")
    if not re.fullmatch(r"[0-9a-f]{64}", report["signedSha256"]) or report["signedSha256"] == args.unsigned_sha256:
        raise ValueError("expected a separate re-signed IPA SHA-256")
    if not isinstance(report["signingToolVersion"], str) or not report["signingToolVersion"].strip():
        raise ValueError("missing signing tool version")
    versions = set()
    for device in report["devices"]:
        if not device["model"].strip() or not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", device["ios"]):
            raise ValueError("invalid device model or iOS version")
        versions.add(tuple(map(int, device["ios"].split(".")[:2])))
        if any(device["results"].get(case) != "pass" for case in required):
            raise ValueError("a required device scenario did not pass")
    if (16, 4) not in versions or len(versions) < 2:
        raise ValueError("record results for iOS 16.4 and a current iOS version")
except (AttributeError, KeyError, TypeError, ValueError) as error:
    parser.exit(1, f"Invalid iOS device evidence: {error}\n")
