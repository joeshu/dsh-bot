#!/usr/bin/env bash
# Builds a 100% standalone, clean, unsigned arm64 iOS .ipa with embedded DSH 0.2.2-rc.5 kernel.
# Compatible with SideStore, AltStore, LiveContainer, TrollStore, and offline zsign re-signing.
set -euo pipefail

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_DIR="$ROOT_DIR/kernel"
IOS_DIR="$ROOT_DIR/ios"
OUT_DIR="$ROOT_DIR/dist"
KERNEL_ASSETS_DIR="$IOS_DIR/Resources/KernelAssets"

mkdir -p "$OUT_DIR" "$KERNEL_ASSETS_DIR"

echo "==> [1/5] Verifying DSH kernel alignment & running 4-gate contract tests"
(
  cd "$KERNEL_DIR"
  node scripts/sync-dsh-lock.mjs --check
  node --test test/*.test.mjs
  node scripts/build-kernel.mjs
)

DSH_VERSION="$(node -p "require('$KERNEL_DIR/dsh.lock.json').dshVersion")"
APP_VERSION="$(node -p "require('$KERNEL_DIR/package.json').version")"
IPA_NAME="DS-Bot-iOS-Standalone-v${APP_VERSION}-dsh${DSH_VERSION}-unsigned.ipa"
IPA_PATH="$OUT_DIR/$IPA_NAME"

echo "==> [2/5] Embedding DSH $DSH_VERSION kernel bundle into iOS resources"
rm -rf "$KERNEL_ASSETS_DIR"
mkdir -p "$KERNEL_ASSETS_DIR"
cp "$KERNEL_DIR/dist/dsh-kernel-${DSH_VERSION}.bundle" "$KERNEL_ASSETS_DIR/"
cp "$KERNEL_DIR/dist/kernel-manifest.json" "$KERNEL_ASSETS_DIR/"

echo "==> [3/5] Generating Xcode project & archiving unsigned arm64 release"
cd "$IOS_DIR"
xcodegen generate --spec project.yml

rm -rf build
xcodebuild \
  -project DSBotStandalone.xcodeproj \
  -scheme DSBotStandalone \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/DSBotStandalone.xcarchive \
  MARKETING_VERSION="$APP_VERSION" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  archive

echo "==> [4/5] Stripping signature residue & packing unsigned IPA"
APP_BUNDLE="$(ls -d build/DSBotStandalone.xcarchive/Products/Applications/*.app | head -n 1)"
if [[ -z "$APP_BUNDLE" || ! -d "$APP_BUNDLE" ]]; then
  echo "::error::No .app bundle found inside xcarchive"
  exit 1
fi

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
mkdir -p "$STAGE_DIR/Payload"
cp -a "$APP_BUNDLE" "$STAGE_DIR/Payload/"

# Strip any prebuilt framework _CodeSignature, provisioning profiles, and macOS metadata
find "$STAGE_DIR/Payload" -name "_CodeSignature" -type d -exec rm -rf {} +
find "$STAGE_DIR/Payload" -name "embedded.mobileprovision" -type f -delete
find "$STAGE_DIR/Payload" -name ".DS_Store" -type f -delete
rm -rf "$STAGE_DIR/Payload"/*.app/SC_Info

rm -f "$IPA_PATH"
(cd "$STAGE_DIR" && zip -r -y -9 -q "$IPA_PATH" Payload)

echo "==> [5/5] Running 4-gate unsigned IPA verification"
# Gate A: Info.plist & embedded DSH kernel present
if ! unzip -l "$IPA_PATH" | grep -q 'Payload/.*\.app/Info\.plist'; then
  echo "::error::Missing Payload/*.app/Info.plist"
  exit 1
fi
if ! unzip -l "$IPA_PATH" | grep -q "dsh-kernel-${DSH_VERSION}\.bundle"; then
  echo "::error::Missing embedded dsh-kernel-${DSH_VERSION}.bundle"
  exit 1
fi

# Gate B: Zero code signature or provisioning profile residue anywhere in Payload
if unzip -l "$IPA_PATH" | grep -Eq '(_CodeSignature|embedded\.mobileprovision)'; then
  echo "::error::Signature residue detected inside unsigned IPA"
  exit 1
fi

# Gate C: Main binary strictly contains arm64 device slice (no x86_64 simulator slice)
BIN_PATH="$STAGE_DIR/Payload/DSBotStandalone.app/DSBotStandalone"
if command -v lipo >/dev/null 2>&1 && [[ -f "$BIN_PATH" ]]; then
  ARCHS_OUT="$(lipo -archs "$BIN_PATH" | xargs)"
  if [[ "$ARCHS_OUT" != "arm64" ]]; then
    echo "::error::Expected arm64 binary slice, got: $ARCHS_OUT"
    exit 1
  fi
fi

# Gate D: Required privacy & sideload keys present in Info.plist
PLIST_PATH="$STAGE_DIR/Payload/DSBotStandalone.app/Info.plist"
for key in NSFaceIDUsageDescription NSLocalNetworkUsageDescription UIFileSharingEnabled ITSAppUsesNonExemptEncryption; do
  if ! plutil -extract "$key" raw "$PLIST_PATH" >/dev/null 2>&1; then
    echo "::error::Missing required Info.plist key: $key"
    exit 1
  fi
done

(cd "$OUT_DIR" && shasum -a 256 "$IPA_NAME" > SHA256SUMS.txt)
echo "SUCCESS: Verified unsigned IPA -> $IPA_PATH ($(stat -f %z "$IPA_PATH" 2>/dev/null || stat -c %s "$IPA_PATH") bytes)"
