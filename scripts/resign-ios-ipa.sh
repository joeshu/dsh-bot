#!/usr/bin/env bash
# Usage: resign-ios-ipa.sh unsigned.ipa profile.mobileprovision IDENTITY signed.ipa
set -euo pipefail
[[ $# == 4 ]] || { echo "Usage: $0 unsigned.ipa profile.mobileprovision IDENTITY signed.ipa" >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo "macOS codesign is required" >&2; exit 2; }
[[ ! -e "$4" && ! -L "$4" ]] || { echo "Output already exists" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
python3 "$ROOT/scripts/verify-unsigned-ipa.py" "$1" > "$TMP/report.json"
unzip -q "$1" -d "$TMP"
security cms -D -i "$2" > "$TMP/profile.plist"
apps=("$TMP"/Payload/*.app)
APP="${apps[0]}"
TEAM="$(python3 - "$TMP/profile.plist" "$TMP/report.json" "$TMP/entitlements.plist" <<'PY'
import datetime
import fnmatch
import json
import plistlib
import sys
from pathlib import Path

profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
report = json.loads(Path(sys.argv[2]).read_text())
expiration = profile["ExpirationDate"]
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=datetime.timezone.utc)
if expiration <= datetime.datetime.now(datetime.timezone.utc):
    sys.exit("Provisioning profile has expired")
team, = profile["TeamIdentifier"]
allowed = profile["Entitlements"]
pattern = allowed["application-identifier"]
prefix = pattern.split(".", 1)[0]
app_id = prefix + "." + report["bundleIdentifier"]
if not fnmatch.fnmatchcase(app_id, pattern):
    sys.exit("Provisioning profile does not authorize the original bundle identifier")
if not (profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices")):
    sys.exit("Use a provisioning profile that authorizes device installation")
entitlements = {"application-identifier": app_id, "com.apple.developer.team-identifier": team}
if allowed.get("get-task-allow") is True:
    entitlements["get-task-allow"] = True
if any(fnmatch.fnmatchcase(app_id, group) for group in allowed.get("keychain-access-groups", [])):
    entitlements["keychain-access-groups"] = [app_id]
Path(sys.argv[3]).write_bytes(plistlib.dumps(entitlements))
print(team)
PY
)"
cp "$2" "$APP/embedded.mobileprovision"
codesign --force --sign "$3" "$APP/Frameworks/NodeMobile.framework"
codesign --force --sign "$3" --entitlements "$TMP/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --verbose=4 "$APP" 2>&1 | grep -Fx "TeamIdentifier=$TEAM"
codesign -d --extract-certificates "$TMP/app-cert-" "$APP"
codesign -d --extract-certificates "$TMP/framework-cert-" "$APP/Frameworks/NodeMobile.framework"
python3 - "$TMP/profile.plist" "$TMP/app-cert-0" "$TMP/framework-cert-0" <<'PY'
import plistlib
import sys
from pathlib import Path

profile, application, framework = (Path(argument).read_bytes() for argument in sys.argv[1:])
if application != framework:
    sys.exit("The app and NodeMobile framework were signed with different certificates")
if application not in plistlib.loads(profile).get("DeveloperCertificates", []):
    sys.exit("The signing certificate is not authorized by this provisioning profile")
PY
(cd "$TMP" && zip -qry -9 signed.ipa Payload)
( set -o noclobber; cat "$TMP/signed.ipa" > "$4" )
shasum -a 256 "$1" "$4"
