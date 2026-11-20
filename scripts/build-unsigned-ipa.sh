#!/usr/bin/env bash
# Archive and verify the native iOS app for re-signing with a sideloading tool.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${DSBOT_OUT_DIR:-$ROOT/dist}"
REPO="${DSBOT_REPOSITORY:-joeshu/dsh-bot}"
COMMIT="${DSBOT_COMMIT:-$(git -C "$ROOT" rev-parse HEAD)}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

if [[ "$(node --version)" != "v24.22.1" || "$(npm --version)" != "11.9.0" ]]; then
  echo "Build requires Node v24.22.1 with npm 11.9.0" >&2
  exit 1
fi
npm --prefix "$ROOT/kernel/runtime" ci --ignore-scripts --omit=optional --no-audit --no-fund
python3 "$ROOT/scripts/prepare-dsh-runtime.py"
python3 "$ROOT/scripts/prepare-node-mobile-ios.py"
python3 "$ROOT/scripts/prepare-quickjs.py"
cd "$ROOT/ios"
xcodegen generate --spec project.yml
xcodebuild archive \
  -project DSBotStandalone.xcodeproj \
  -scheme DSBotStandalone \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$BUILD/DSBotStandalone.xcarchive" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" DEVELOPMENT_TEAM=""

shopt -s nullglob
apps=("$BUILD"/DSBotStandalone.xcarchive/Products/Applications/*.app)
if [[ ${#apps[@]} != 1 ]]; then
  echo "Expected exactly one .app in the archive" >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${apps[0]}/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid app version" >&2
  exit 1
fi
IPA="DS-Bot-iOS-Standalone-v${VERSION}-unsigned.ipa"

mkdir -p "$BUILD/Payload" "$BUILD/candidate"
cp -pR "${apps[0]}" "$BUILD/Payload/"
(cd "$BUILD" && /usr/bin/zip -qry -9 "candidate/$IPA" Payload)
python3 "$ROOT/scripts/verify-unsigned-ipa.py" "$BUILD/candidate/$IPA" \
  --release-dir "$BUILD/candidate" --repo "$REPO" --commit "$COMMIT"
for name in "$IPA" ipa-report.json source.json SHA256SUMS.txt; do
  mv "$BUILD/candidate/$name" "$OUT_DIR/$name"
done
echo "Verified unsigned IPA at $OUT_DIR/$IPA"
