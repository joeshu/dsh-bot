#!/usr/bin/env bash
# Build the full iPhoneOS and Simulator XCFramework from pinned sources on macOS.
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 && $# == 1 ]] || {
  echo "Usage on Apple Silicon with Xcode: $0 output.zip" >&2
  exit 2
}
OUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ ! -e "$OUT" ]] || { echo "Output already exists" >&2; exit 2; }
MOBILE_COMMIT=b5bcc8d8e70f055333cd5efc317e3eb55bf0c9a5
PATCH_SHA=c04d714db5a861f4934ee6649be9a0ed689138485e1dc975e8ed26cb0ee55f84
PATCH_URL=https://github.com/nodejs/node/compare/ce7aaf1cee78b8cf0ce17364260535c418d3ed26...e63cab040c09d43ceef8cb35508c40044614e906.diff
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init source
git -C source fetch --depth=1 https://github.com/fogtape/nodejs-mobile.git "$MOBILE_COMMIT"
git -C source checkout --detach FETCH_HEAD
test "$(git -C source rev-parse HEAD)" = "$MOBILE_COMMIT"
curl --fail --location --retry 3 --output node-security.diff "$PATCH_URL"
echo "$PATCH_SHA  node-security.diff" | shasum -a 256 -c -
git -C source apply --check ../node-security.diff
git -C source apply ../node-security.diff
cd source
grep -Eq '^#define NODE_PATCH_VERSION 3$' src/node_version.h
export NODEJS_MOBILE_FLAVOR=full
bash tools/ios_framework_prepare.sh arm64
bash tools/ios_framework_prepare.sh arm64-simulator
DEVICE=out_ios_arm64/iphoneos-arm64/Release-iphoneos/NodeMobile.framework
SIMULATOR=out_ios_arm64-simulator/iphonesimulator-arm64/Release-iphonesimulator/NodeMobile.framework
for framework in "$DEVICE" "$SIMULATOR"; do
  if codesign -d "$framework" >/dev/null 2>&1; then
    codesign --remove-signature "$framework/NodeMobile"
  fi
  rm -rf "$framework/_CodeSignature"
done
mkdir "$TMP/package"
xcodebuild -create-xcframework -framework "$DEVICE" -framework "$SIMULATOR" \
  -output "$TMP/package/NodeMobile.xcframework"
cp LICENSE "$TMP/package/NodeMobile-LICENSE.txt"
cd "$TMP/package"
zip -qry -9 "$OUT" NodeMobile.xcframework NodeMobile-LICENSE.txt
shasum -a 256 "$OUT"
